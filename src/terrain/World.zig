//! The loaded world: a chunk store, plus the systems that keep it in sync with
//! the server and with the renderer.
//!
//! The world owns the meshing pipeline. Chunks are never meshed inline: an edit
//! bumps the chunk's revision and pushes its slot in the remesh queue, and
//! `update` snapshots the queued chunks, hands them to the workers and uploads
//! whatever came back.

const std = @import("std");
const coord = @import("coord");
const io = @import("io");
const meshing = @import("meshing");
const tracy = @import("tracy");
const build_options = @import("build_options");

const chunk = @import("chunk.zig");
const ChunkStore = @import("ChunkStore.zig");
const LightLevel = @import("light_level.zig").LightLevel;

const World = @This();

const Slot = ChunkStore.Slot;

/// Amount of finished meshes uploaded per update, to spread the cost of
/// talking to the graphics driver over several frames
const max_uploads_per_update = 8;

alloc: std.mem.Allocator,
/// Every loaded chunk
store: ChunkStore,
/// Chunk meshing pipeline
scheduler: *meshing.Scheduler,
/// Slots waiting to be remeshed, oldest first
remesh_queue: std.ArrayListUnmanaged(Slot) = .empty,
/// Read position in `remesh_queue`
remesh_head: usize = 0,

pub fn init(alloc: std.mem.Allocator) !World {
    const scheduler = try meshing.Scheduler.init(
        alloc,
        io.properties.mesh_allocator,
        build_options.mesher_threads,
    );
    errdefer scheduler.deinit();

    std.log.info("Chunk meshing runs on {} worker thread(s)", .{scheduler.workerCount()});

    return .{
        .alloc = alloc,
        .store = .init(alloc),
        .scheduler = scheduler,
    };
}

pub fn deinit(self: *World) void {
    // Stop the workers first: they must not touch anything afterwards
    self.scheduler.deinit();
    self.remesh_queue.deinit(self.alloc);
    self.store.deinit();
}

/// Slot of a loaded chunk, if it is loaded
pub fn getChunk(self: *World, coords: coord.Chunk) ?Slot {
    return self.store.find(coords);
}

// --- Remesh queue ----------------------------------------------------------

/// Queues a chunk for remeshing
pub fn markDirty(self: *World, slot: Slot) void {
    if (self.store.queued.get(slot))
        return;
    self.store.queued.put(slot, true);
    self.remesh_queue.append(self.alloc, slot) catch {
        // Losing a queue entry only delays a mesh update: the next edit of that
        // chunk queues it again, and the revision still says it is out of date
        self.store.queued.put(slot, false);
    };
}

/// Queues the chunk at those coordinates, if it is loaded
fn markDirtyAt(self: *World, coords: coord.Chunk) void {
    if (self.store.find(coords)) |slot|
        self.markDirty(slot);
}

/// Queues the neighbors of a chunk whose border blocks changed
fn markNeighborsDirty(self: *World, coords: coord.Chunk, sides: struct {
    north: bool = false,
    east: bool = false,
    south: bool = false,
    west: bool = false,
}) void {
    if (sides.north) self.markDirtyAt(.{ .x = coords.x, .z = coords.z - 1 });
    if (sides.south) self.markDirtyAt(.{ .x = coords.x, .z = coords.z + 1 });
    if (sides.west) self.markDirtyAt(.{ .x = coords.x - 1, .z = coords.z });
    if (sides.east) self.markDirtyAt(.{ .x = coords.x + 1, .z = coords.z });
}

/// Takes the next slot out of the remesh queue
fn popRemesh(self: *World) ?Slot {
    if (self.remesh_head >= self.remesh_queue.items.len) {
        // Empty: reset instead of growing forever
        self.remesh_queue.clearRetainingCapacity();
        self.remesh_head = 0;
        return null;
    }

    const slot = self.remesh_queue.items[self.remesh_head];
    self.remesh_head += 1;
    self.store.queued.put(slot, false);

    // Reclaim the consumed part of the queue once it is worth it
    if (self.remesh_head > 64 and self.remesh_head * 2 > self.remesh_queue.items.len) {
        const rest = self.remesh_queue.items.len - self.remesh_head;
        std.mem.copyForwards(
            Slot,
            self.remesh_queue.items[0..rest],
            self.remesh_queue.items[self.remesh_head..],
        );
        self.remesh_queue.shrinkRetainingCapacity(rest);
        self.remesh_head = 0;
    }

    return slot;
}

/// Puts a slot back at the end of the queue
fn requeue(self: *World, slot: Slot) void {
    self.store.queued.put(slot, false);
    self.markDirty(slot);
}

// --- Meshing pipeline ------------------------------------------------------

/// Picks up finished meshes and starts new meshing jobs.
/// Returns true if a model was updated.
pub fn update(self: *World) !bool {
    const zone = tracy.Zone.begin(.{
        .name = "World update",
        .src = @src(),
        .color = .blue1,
    });
    defer zone.end();

    const updated = self.collectMeshes();
    self.submitMeshJobs();
    return updated;
}

/// Uploads the meshes the workers finished
fn collectMeshes(self: *World) bool {
    var uploaded: usize = 0;

    while (uploaded < max_uploads_per_update) {
        const result = self.scheduler.poll() orelse break;
        var mesh = result.mesh;

        self.store.in_flight.put(result.slot, false);

        // The chunk was unloaded (or replaced) while we were meshing it
        if (!self.store.holds(result.slot, result.coords)) {
            mesh.deinit();
            self.store.recycle(result.slot);
            continue;
        }

        // The chunk changed while we were meshing it
        if (result.revision != self.store.revision.get(result.slot)) {
            mesh.deinit();
            self.markDirty(result.slot);
            continue;
        }

        const model = io.ChunkModel.upload(self.alloc, mesh) catch |err| {
            std.log.err("Could not upload chunk model: {}", .{err});
            continue;
        };

        self.store.setModel(result.slot, model);
        self.store.meshed_revision.put(result.slot, result.revision);
        uploaded += 1;
    }

    return uploaded != 0;
}

/// Sends queued chunks to the workers, as long as the pipeline has room
fn submitMeshJobs(self: *World) void {
    while (self.popRemesh()) |slot| {
        if (!self.store.loaded.get(slot) or !self.store.needsRemesh(slot))
            continue;

        // A job is already running for that chunk: it will be queued again
        // when its (now stale) result comes back
        if (self.store.in_flight.get(slot))
            continue;

        // A chunk of pure air has no geometry: no job, no snapshot, no upload
        if (self.store.isEmpty(slot)) {
            self.store.setModel(slot, null);
            self.store.meshed_revision.put(slot, self.store.revision.get(slot));
            continue;
        }

        const snapshot = self.scheduler.acquireSnapshot() orelse {
            // The pipeline is saturated, try again next frame
            self.requeue(slot);
            return;
        };

        const coords = self.store.coords.get(slot);
        const revision = self.store.revision.get(slot);
        self.fillSnapshot(snapshot, slot, coords);

        const submitted = self.scheduler.submit(.{
            .snapshot = snapshot,
            .slot = slot,
            .coords = coords,
            .revision = revision,
        });

        if (!submitted) {
            self.scheduler.releaseSnapshot(snapshot);
            self.requeue(slot);
            return;
        }

        self.store.in_flight.put(slot, true);
    }
}

/// Copies everything the mesher needs out of the store
fn fillSnapshot(self: *World, snapshot: *meshing.Snapshot, slot: Slot, coords: coord.Chunk) void {
    const zone = tracy.Zone.begin(.{
        .name = "Chunk snapshot",
        .src = @src(),
        .color = .cyan,
    });
    defer zone.end();

    snapshot.coords = coords;
    @memcpy(&snapshot.ids, self.store.ids.at(slot));
    snapshot.clearEdges();

    // The mesher wants one byte of light per block, the store keeps nibbles
    unpackLight(
        &snapshot.light,
        self.store.blocklight.at(slot),
        self.store.skylight.at(slot),
        0,
        chunk.volume,
    );

    inline for (coord.Face.all) |face| {
        // Only the four horizontal sides have a neighbor chunk
        if (comptime face != .up and face != .down) {
            const offset = comptime face.asRelativeBlock();
            const neighbor_coords: coord.Chunk = .{
                .x = coords.x + offset.x,
                .z = coords.z + offset.z,
            };

            if (self.store.find(neighbor_coords)) |neighbor| {
                const ids = self.store.ids.at(neighbor);
                const blocklight = self.store.blocklight.at(neighbor);
                const skylight = self.store.skylight.at(neighbor);

                // The plane of the neighbor that touches this chunk
                for (0..chunk.width) |u| {
                    const base = switch (face) {
                        .north => chunk.columnBase(u, chunk.width - 1),
                        .south => chunk.columnBase(u, 0),
                        .east => chunk.columnBase(0, u),
                        .west => chunk.columnBase(chunk.width - 1, u),
                        else => unreachable,
                    };

                    @memcpy(&snapshot.edge_ids[face.index()][u], ids[base..][0..chunk.height]);
                    unpackLight(
                        &snapshot.edge_light[face.index()][u],
                        blocklight,
                        skylight,
                        base,
                        chunk.height,
                    );
                }
            }
        }
    }
}

/// Unpacks `len` light levels starting at `base` into one byte per block
fn unpackLight(dest: []LightLevel, blocklight: []const u8, skylight: []const u8, base: usize, len: usize) void {
    for (dest[0..len], 0..) |*level, i| {
        level.* = .{
            .blocklight = ChunkStore.readNibble(blocklight, base + i),
            .skylight = ChunkStore.readNibble(skylight, base + i),
        };
    }
}

// --- World edits -----------------------------------------------------------

/// Prepare a chunk for population or remove it (for Packet50PreChunk)
pub fn doPreChunk(self: *World, coords: coord.Chunk, add: bool) !void {
    if (add) {
        _ = try self.store.load(coords);
        // The new chunk may unhide faces of its neighbors
        self.markNeighborsDirty(coords, .{ .north = true, .east = true, .south = true, .west = true });
    } else {
        self.store.unload(coords);
        self.markNeighborsDirty(coords, .{ .north = true, .east = true, .south = true, .west = true });
    }
}

/// Loads an empty chunk, for a world that is filled in locally instead of
/// being sent by a server. Write into the store's arrays, then call
/// `commitChunkData`.
pub fn loadChunk(self: *World, coords: coord.Chunk) !Slot {
    const slot = try self.store.load(coords);
    self.markNeighborsDirty(coords, .{ .north = true, .east = true, .south = true, .west = true });
    return slot;
}

/// Unloads a chunk and queues its neighbors, whose faces towards it change
pub fn unloadChunk(self: *World, coords: coord.Chunk) void {
    self.store.unload(coords);
    self.markNeighborsDirty(coords, .{ .north = true, .east = true, .south = true, .west = true });
}

/// Call after writing block data straight into the store: refreshes what the
/// store derives from the blocks and queues the chunk (and its neighbors) for
/// meshing
pub fn commitChunkData(self: *World, slot: Slot) void {
    self.store.recountSections(slot);
    self.store.touch(slot);

    self.markDirty(slot);
    self.markNeighborsDirty(self.store.coords.get(slot), .{
        .north = true,
        .east = true,
        .south = true,
        .west = true,
    });
}

/// Take block data and apply it to chunks
pub fn doChunkMap(self: *World, x: i32, y: i16, z: i32, size_x: u8, size_y: u8, size_z: u8, data: []const u8) !void {
    // Tracking data left to read
    var remaining = data;

    const y1 = @max(0, y);
    const y2 = @min(chunk.height, y + size_y);

    // Find relevant chunk range
    const chunk_x1 = x >> 4;
    const chunk_z1 = z >> 4;
    const chunk_x2 = (x + size_x - 1) >> 4;
    const chunk_z2 = (z + size_z - 1) >> 4;

    // Iterate through relevant chunks
    var chunk_x = chunk_x1;
    while (chunk_x <= chunk_x2) : (chunk_x += 1) {
        // Clamped boundaries within chunk
        const x1 = @max(0, x - chunk_x * chunk.width);
        const x2 = @min(x + size_x - chunk_x * chunk.width, chunk.width);

        var chunk_z = chunk_z1;
        while (chunk_z <= chunk_z2) : (chunk_z += 1) {
            // Clamped boundaries within chunk
            const z1 = @max(0, z - chunk_z * chunk.width);
            const z2 = @min(z + size_z - chunk_z * chunk.width, chunk.width);

            const coords = coord.Chunk{ .x = chunk_x, .z = chunk_z };

            // Apply modifications to selected chunk
            const slot = self.store.find(coords) orelse return; // TODO: what to do in that case?
            remaining = self.store.setChunkData(slot, remaining, x1, y1, z1, x2, y2, z2);

            self.markDirty(slot);
            self.markNeighborsDirty(coords, .{
                .west = x1 <= 0,
                .east = x2 >= chunk.width - 1,
                .north = z1 <= 0,
                .south = z2 >= chunk.width - 1,
            });
        }
    }
}

/// Change multiple blocks
pub fn doMultiBlockChange(self: *World, chunk_pos: coord.Chunk, coord_array: []i16, block_ids: []u8, block_metas: []u8) !void {
    const slot = self.store.find(chunk_pos) orelse return; // TODO: what to do in that case?

    var sides: struct {
        north: bool = false,
        east: bool = false,
        south: bool = false,
        west: bool = false,
    } = .{};

    for (coord_array, block_ids, block_metas) |pos, block_id, block_meta| {
        const xyz = coord.Block{
            .x = pos >> 12 & 15,
            .y = pos & 255,
            .z = pos >> 8 & 15,
        };

        if (xyz.x == 0) {
            sides.west = true;
        } else if (xyz.x == chunk.width - 1) {
            sides.east = true;
        }

        if (xyz.z == 0) {
            sides.north = true;
        } else if (xyz.z == chunk.width - 1) {
            sides.south = true;
        }

        self.store.setBlockIdAndMetadata(slot, xyz, block_id, @truncate(block_meta));
    }

    self.markDirty(slot);
    self.markNeighborsDirty(chunk_pos, .{
        .north = sides.north,
        .east = sides.east,
        .south = sides.south,
        .west = sides.west,
    });
}

/// Set a block ID at coordinates, does nothing if the chunk isn't loaded
pub fn setBlockIdAndMetadata(self: *World, pos: coord.Block, block_id: u8, block_meta: u4) !void {
    const chunk_pos = pos.getChunk();
    const slot = self.store.find(chunk_pos) orelse return; // TODO: what to do in that case?
    const pos_in_chunk = pos.getPosInChunk();

    if (!pos_in_chunk.isWithinChunk())
        return;

    self.store.setBlockIdAndMetadata(slot, pos_in_chunk, block_id, block_meta);

    self.markDirty(slot);
    self.markNeighborsDirty(chunk_pos, .{
        .west = pos_in_chunk.x == 0,
        .east = pos_in_chunk.x == chunk.width - 1,
        .north = pos_in_chunk.z == 0,
        .south = pos_in_chunk.z == chunk.width - 1,
    });
}

/// Gets a block id at global coordinates, returns 0 if the chunk isn't loaded
pub fn getBlockId(self: *World, pos: coord.Block) u8 {
    if (pos.y < 0 or pos.y >= chunk.height)
        return 0;

    const slot = self.store.find(pos.getChunk()) orelse return 0;
    return self.store.getBlockId(slot, pos.getPosInChunk());
}

/// Gets the light levels at global coordinates
pub fn getLight(self: *World, pos: coord.Block) LightLevel {
    if (pos.y < 0 or pos.y >= chunk.height)
        return ChunkStore.default_light;

    const slot = self.store.find(pos.getChunk()) orelse return ChunkStore.default_light;
    return self.store.getLight(slot, pos.getPosInChunk());
}

/// Runs the world until a condition is met, or fails the test after a while.
/// Meshing happens on other threads, so tests have to wait for it.
fn pump(world: *World, done: *const fn (*World) bool) !void {
    const deadline = std.time.milliTimestamp() + 10 * std.time.ms_per_s;

    while (!done(world)) {
        _ = try world.update();
        if (std.time.milliTimestamp() > deadline)
            return error.MeshingTimeout;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    // One last update, to pick up whatever the condition did not cover
    _ = try world.update();
}

test "edits queue chunks for remeshing" {
    var world: World = try .init(std.testing.allocator);
    defer world.deinit();

    try world.doPreChunk(.{ .x = 0, .z = 0 }, true);
    const slot = world.getChunk(.{ .x = 0, .z = 0 }).?;

    // A fresh chunk is empty, there is nothing to draw yet
    try std.testing.expect(!world.store.needsRemesh(slot));

    try world.setBlockIdAndMetadata(.{ .x = 4, .y = 40, .z = 4 }, 1, 0);
    try std.testing.expect(world.store.needsRemesh(slot));
    try std.testing.expect(world.store.queued.get(slot));

    // The mesh comes back within a few updates
    try pump(&world, struct {
        fn done(w: *World) bool {
            return !w.store.needsRemesh(w.getChunk(.{ .x = 0, .z = 0 }).?);
        }
    }.done);

    try std.testing.expect(!world.store.needsRemesh(slot));
    try std.testing.expect(world.store.model.get(slot) != null);
}

test "empty chunks are not meshed at all" {
    var world: World = try .init(std.testing.allocator);
    defer world.deinit();

    try world.doPreChunk(.{ .x = 0, .z = 0 }, true);
    const slot = world.getChunk(.{ .x = 0, .z = 0 }).?;

    // Setting a block and taking it back leaves an empty, but dirty, chunk
    try world.setBlockIdAndMetadata(.{ .x = 1, .y = 1, .z = 1 }, 1, 0);
    try world.setBlockIdAndMetadata(.{ .x = 1, .y = 1, .z = 1 }, 0, 0);
    try std.testing.expect(world.store.needsRemesh(slot));

    _ = try world.update();

    try std.testing.expect(!world.store.needsRemesh(slot));
    try std.testing.expectEqual(@as(u32, 0), world.scheduler.pending());
    try std.testing.expectEqual(@as(?io.ChunkModel, null), world.store.model.get(slot));
}

test "unloading a chunk with a job in flight" {
    var world: World = try .init(std.testing.allocator);
    defer world.deinit();

    try world.doPreChunk(.{ .x = 2, .z = 3 }, true);
    try world.setBlockIdAndMetadata(.{ .x = 33, .y = 10, .z = 50 }, 1, 0);

    // Start the job, then drop the chunk before picking the result up
    world.submitMeshJobs();
    try world.doPreChunk(.{ .x = 2, .z = 3 }, false);

    try pump(&world, struct {
        fn done(w: *World) bool {
            return w.scheduler.pending() == 0;
        }
    }.done);

    try std.testing.expectEqual(@as(u32, 0), world.scheduler.pending());
    try std.testing.expectEqual(@as(?Slot, null), world.getChunk(.{ .x = 2, .z = 3 }));
}
