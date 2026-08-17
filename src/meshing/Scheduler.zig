//! The multithreaded chunk meshing pipeline.
//!
//! ```
//!  main thread                     workers                    main thread
//!  ───────────                     ───────                    ───────────
//!  snapshot a chunk ──push job──▶  greedy + special  ──push result──▶  upload
//!  (memcpy, no lock)               meshing passes                      to gpu
//! ```
//!
//! Nothing is shared while a job runs: the job owns its snapshot, and the mesh
//! it produces is owned by the result. The only shared state is three lock free
//! queues, so the main thread never blocks on a worker and vice versa. Workers
//! that find nothing to do park on a futex instead of spinning.
//!
//! Results carry the revision of the chunk they were built from, so a mesh that
//! was made obsolete by a block update while it was in flight is simply dropped.

const std = @import("std");
const coord = @import("coord");
const tracy = @import("tracy");

const MeshData = @import("MeshData.zig");
const Mesher = @import("Mesher.zig");
const Snapshot = @import("Snapshot.zig");
const BoundedQueue = @import("queue.zig").BoundedQueue;

const Scheduler = @This();

/// Amount of chunks that can be meshed at the same time. Also the amount of
/// snapshots kept around, which is the memory the pipeline costs.
pub const capacity = 32;

/// How long a worker sleeps before checking the job queue again
const idle_timeout_ns = 100 * std.time.ns_per_ms;

/// A chunk waiting to be meshed
pub const Job = struct {
    /// Data to mesh, owned by the job
    snapshot: *Snapshot,
    /// Chunk slot the result belongs to
    slot: u32,
    /// Coordinates of the chunk, to detect a slot that was recycled meanwhile
    coords: coord.Chunk,
    /// Revision of the chunk data the snapshot was taken from
    revision: u32,
};

/// A finished chunk mesh
pub const Result = struct {
    /// The mesh, owned by the receiver
    mesh: MeshData,
    slot: u32,
    coords: coord.Chunk,
    revision: u32,
};

const JobQueue = BoundedQueue(Job, capacity);
const ResultQueue = BoundedQueue(Result, capacity);
const SnapshotQueue = BoundedQueue(*Snapshot, capacity);

alloc: std.mem.Allocator,
/// Allocator used for the vertex buffers handed to the frontend
mesh_alloc: std.mem.Allocator,

/// Chunks waiting to be meshed
jobs: JobQueue = .{},
/// Finished meshes waiting to be picked up
results: ResultQueue = .{},
/// Snapshots that are not in use
spare: SnapshotQueue = .{},

/// Backing memory of the snapshots
snapshots: []Snapshot = &.{},
/// Worker threads, empty when meshing runs on the calling thread
workers: []std.Thread = &.{},
/// Mesher used when there is no worker thread
inline_mesher: ?Mesher = null,

/// Cleared to ask the workers to stop
running: std.atomic.Value(bool) = .init(true),
/// Bumped on every submitted job, workers park on it
tickets: std.atomic.Value(u32) = .init(0),
/// Amount of jobs that were submitted and whose result was not picked up yet
in_flight: std.atomic.Value(u32) = .init(0),

/// Starts the pipeline. `worker_count` of 0 asks for a sensible default;
/// if no thread can be spawned, meshing transparently happens on the caller's
/// thread at submission time.
pub fn init(
    alloc: std.mem.Allocator,
    mesh_alloc: std.mem.Allocator,
    worker_count: u32,
) !*Scheduler {
    const self = try alloc.create(Scheduler);
    errdefer alloc.destroy(self);

    self.* = .{ .alloc = alloc, .mesh_alloc = mesh_alloc };
    self.jobs.init();
    self.results.init();
    self.spare.init();

    self.snapshots = try alloc.alloc(Snapshot, capacity);
    errdefer alloc.free(self.snapshots);

    for (self.snapshots) |*snapshot|
        _ = self.spare.push(snapshot);

    const wanted = if (worker_count != 0)
        worker_count
    else
        @max(1, (std.Thread.getCpuCount() catch 2) -| 1);

    var workers: std.ArrayListUnmanaged(std.Thread) = .empty;
    errdefer workers.deinit(alloc);

    for (0..@min(wanted, capacity)) |_| {
        const thread = std.Thread.spawn(.{}, worker, .{self}) catch break;
        try workers.append(alloc, thread);
    }

    self.workers = try workers.toOwnedSlice(alloc);

    if (self.workers.len == 0) {
        std.log.warn("No meshing worker thread, chunks are meshed on the main thread", .{});
        self.inline_mesher = try Mesher.init(alloc, mesh_alloc);
    }

    return self;
}

/// Stops the workers and frees everything the pipeline owns
pub fn deinit(self: *Scheduler) void {
    self.running.store(false, .release);
    _ = self.tickets.fetchAdd(1, .release);
    std.Thread.Futex.wake(&self.tickets, std.math.maxInt(u32));

    for (self.workers) |thread|
        thread.join();
    self.alloc.free(self.workers);

    // Drop the meshes nobody picked up
    while (self.results.pop()) |result|
        result.mesh.deinit();

    if (self.inline_mesher) |*mesher|
        mesher.deinit();

    self.alloc.free(self.snapshots);
    self.alloc.destroy(self);
}

/// Takes a free snapshot to fill, or null when the pipeline is saturated
pub fn acquireSnapshot(self: *Scheduler) ?*Snapshot {
    return self.spare.pop();
}

/// Gives a snapshot back without meshing it
pub fn releaseSnapshot(self: *Scheduler, snapshot: *Snapshot) void {
    const returned = self.spare.push(snapshot);
    // The pool is exactly as big as the amount of snapshots that exist
    std.debug.assert(returned);
}

/// Queues a job. The scheduler takes ownership of the job's snapshot.
/// Returns false if the queue is full, in which case the caller keeps the
/// snapshot and should try again later.
pub fn submit(self: *Scheduler, job: Job) bool {
    if (self.inline_mesher) |*mesher| {
        // No worker thread: mesh right here so that the client still works
        const mesh = mesher.run(job.snapshot) catch MeshData{ .alloc = self.mesh_alloc };
        self.releaseSnapshot(job.snapshot);
        const result: Result = .{
            .mesh = mesh,
            .slot = job.slot,
            .coords = job.coords,
            .revision = job.revision,
        };
        if (!self.results.push(result)) {
            mesh.deinit();
            return false;
        }
        _ = self.in_flight.fetchAdd(1, .monotonic);
        return true;
    }

    if (!self.jobs.push(job))
        return false;

    _ = self.in_flight.fetchAdd(1, .monotonic);
    _ = self.tickets.fetchAdd(1, .release);
    std.Thread.Futex.wake(&self.tickets, 1);
    return true;
}

/// Picks up a finished mesh, if any. The caller owns the returned mesh.
pub fn poll(self: *Scheduler) ?Result {
    const result = self.results.pop() orelse return null;
    _ = self.in_flight.fetchSub(1, .monotonic);
    return result;
}

/// Amount of jobs submitted whose result was not picked up yet
pub fn pending(self: *const Scheduler) u32 {
    return self.in_flight.load(.monotonic);
}

/// Amount of worker threads
pub fn workerCount(self: *const Scheduler) usize {
    return self.workers.len;
}

/// Worker thread body
fn worker(self: *Scheduler) void {
    var mesher: Mesher = Mesher.init(self.alloc, self.mesh_alloc) catch |err| {
        std.log.err("Meshing worker could not start: {}", .{err});
        return;
    };
    defer mesher.deinit();

    while (self.running.load(.acquire)) {
        // Read the ticket *before* looking at the queue, so that a job pushed
        // while we look is either seen now or wakes us up from the futex
        const ticket = self.tickets.load(.acquire);

        if (self.jobs.pop()) |job| {
            const mesh = mesher.run(job.snapshot) catch |err| blk: {
                std.log.err("Could not mesh chunk {},{}: {}", .{ job.coords.x, job.coords.z, err });
                break :blk MeshData{ .alloc = self.mesh_alloc };
            };

            const result: Result = .{
                .mesh = mesh,
                .slot = job.slot,
                .coords = job.coords,
                .revision = job.revision,
            };

            // The result queue is as big as the snapshot pool, and this job
            // still holds a snapshot, so there is always room
            while (!self.results.push(result)) {
                std.Thread.yield() catch {};
            }

            self.releaseSnapshot(job.snapshot);
            continue;
        }

        std.Thread.Futex.timedWait(&self.tickets, ticket, idle_timeout_ns) catch {};
    }
}

test "scheduler meshes chunks on worker threads" {
    const blocks = @import("blocks");

    const alloc = std.testing.allocator;

    const scheduler = try Scheduler.init(alloc, alloc, 2);
    defer scheduler.deinit();

    const jobs = 8;
    for (0..jobs) |i| {
        const snapshot = scheduler.acquireSnapshot().?;
        snapshot.* = .{ .coords = .{ .x = @intCast(i), .z = 0 } };
        snapshot.clear();

        // A single stone block, which must produce exactly six quads
        snapshot.idColumnMut(4, 4)[20] = blocks.idOf(.stone);

        try std.testing.expect(scheduler.submit(.{
            .snapshot = snapshot,
            .slot = @intCast(i),
            .coords = .{ .x = @intCast(i), .z = 0 },
            .revision = 1,
        }));
    }

    var received: usize = 0;
    while (received < jobs) {
        if (scheduler.poll()) |result| {
            defer result.mesh.deinit();
            received += 1;
            try std.testing.expectEqual(@as(u32, 6 * 4), result.mesh.vertexCount());
            try std.testing.expectEqual(@as(usize, 0), result.mesh.transparent.len);
        } else {
            std.Thread.yield() catch {};
        }
    }

    try std.testing.expectEqual(@as(u32, 0), scheduler.pending());
}
