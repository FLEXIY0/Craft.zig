//! A bounded lock free queue.
//!
//! This is Dmitry Vyukov's bounded MPMC queue: every cell carries a sequence
//! number, producers and consumers claim a position with a single compare and
//! swap, and the sequence number tells them whether the cell is theirs to write
//! or to read. No mutex is taken anywhere, a producer that gets descheduled
//! never blocks a consumer, and a full or empty queue is reported instead of
//! blocking.
//!
//! The mesher uses three of those: jobs (main thread to workers), results
//! (workers to main thread) and the pool of free snapshots.

const std = @import("std");

/// Padding used to keep the producer and consumer counters on separate cache
/// lines, so that they do not ping pong between cores
const cache_line = std.atomic.cache_line;

/// A bounded multi producer, multi consumer queue of `capacity` items.
/// `capacity` must be a power of two.
pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 1);
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        const Self = @This();

        const mask = capacity - 1;

        const Cell = struct {
            sequence: std.atomic.Value(usize) = .init(0),
            data: T = undefined,
        };

        buffer: [capacity]Cell = @splat(.{}),
        enqueue_pos: std.atomic.Value(usize) align(cache_line) = .init(0),
        dequeue_pos: std.atomic.Value(usize) align(cache_line) = .init(0),

        /// A queue must be initialized before use: the cell sequence numbers
        /// encode the position each cell is waiting for
        pub fn init(self: *Self) void {
            for (&self.buffer, 0..) |*cell, i|
                cell.sequence = .init(i);
            self.enqueue_pos = .init(0);
            self.dequeue_pos = .init(0);
        }

        /// Appends an item, returns false if the queue is full
        pub fn push(self: *Self, item: T) bool {
            var pos = self.enqueue_pos.load(.monotonic);

            while (true) {
                const cell = &self.buffer[pos & mask];
                const sequence = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(sequence)) -% @as(isize, @bitCast(pos));

                if (diff == 0) {
                    // The cell is free and ours if we win the position
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |current| {
                        pos = current;
                    } else {
                        cell.data = item;
                        cell.sequence.store(pos +% 1, .release);
                        return true;
                    }
                } else if (diff < 0) {
                    // The consumer has not caught up with that cell yet
                    return false;
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }
        }

        /// Takes the oldest item, or null if the queue is empty
        pub fn pop(self: *Self) ?T {
            var pos = self.dequeue_pos.load(.monotonic);

            while (true) {
                const cell = &self.buffer[pos & mask];
                const sequence = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(sequence)) -% @as(isize, @bitCast(pos +% 1));

                if (diff == 0) {
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |current| {
                        pos = current;
                    } else {
                        const item = cell.data;
                        cell.sequence.store(pos +% mask +% 1, .release);
                        return item;
                    }
                } else if (diff < 0) {
                    // Nothing was published at that position
                    return null;
                } else {
                    pos = self.dequeue_pos.load(.monotonic);
                }
            }
        }

        /// Approximate amount of queued items (may be stale as soon as it is read)
        pub fn len(self: *const Self) usize {
            const enqueue = self.enqueue_pos.load(.monotonic);
            const dequeue = self.dequeue_pos.load(.monotonic);
            return enqueue -% dequeue;
        }

        /// True if the queue looked empty at the time of the call
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }
    };
}

test "queue keeps order and reports fullness" {
    const Queue = BoundedQueue(u32, 4);

    var queue: Queue = .{};
    queue.init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());

    for (0..4) |i|
        try std.testing.expect(queue.push(@intCast(i)));

    // Full
    try std.testing.expect(!queue.push(4));
    try std.testing.expectEqual(@as(usize, 4), queue.len());

    for (0..4) |i|
        try std.testing.expectEqual(@as(?u32, @intCast(i)), queue.pop());

    try std.testing.expect(queue.isEmpty());

    // The queue wraps around and can be reused
    try std.testing.expect(queue.push(42));
    try std.testing.expectEqual(@as(?u32, 42), queue.pop());
}

test "queue survives concurrent producers and consumers" {
    if (@import("builtin").single_threaded)
        return error.SkipZigTest;

    const Queue = BoundedQueue(u32, 64);
    const items_per_producer = 2000;
    const producer_count = 3;
    const consumer_count = 3;

    const Shared = struct {
        queue: Queue = .{},
        produced: std.atomic.Value(u32) = .init(0),
        consumed: std.atomic.Value(u32) = .init(0),
        sum: std.atomic.Value(u64) = .init(0),
        done: std.atomic.Value(bool) = .init(false),

        fn produce(self: *@This()) void {
            for (0..items_per_producer) |i| {
                while (!self.queue.push(@intCast(i + 1))) {
                    std.Thread.yield() catch {};
                }
                _ = self.produced.fetchAdd(1, .monotonic);
            }
        }

        fn consume(self: *@This()) void {
            while (true) {
                if (self.queue.pop()) |item| {
                    _ = self.sum.fetchAdd(item, .monotonic);
                    _ = self.consumed.fetchAdd(1, .monotonic);
                } else if (self.done.load(.acquire)) {
                    // One last look, a producer may have pushed just before
                    if (self.queue.isEmpty())
                        return;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const shared = try std.testing.allocator.create(Shared);
    defer std.testing.allocator.destroy(shared);
    shared.* = .{};
    shared.queue.init();

    var producers: [producer_count]std.Thread = undefined;
    var consumers: [consumer_count]std.Thread = undefined;

    for (&consumers) |*thread|
        thread.* = try std.Thread.spawn(.{}, Shared.consume, .{shared});
    for (&producers) |*thread|
        thread.* = try std.Thread.spawn(.{}, Shared.produce, .{shared});

    for (&producers) |thread|
        thread.join();
    shared.done.store(true, .release);
    for (&consumers) |thread|
        thread.join();

    const expected_count = producer_count * items_per_producer;
    const expected_sum = @as(u64, producer_count) * (items_per_producer * (items_per_producer + 1) / 2);

    try std.testing.expectEqual(@as(u32, expected_count), shared.produced.load(.monotonic));
    try std.testing.expectEqual(@as(u32, expected_count), shared.consumed.load(.monotonic));
    try std.testing.expectEqual(expected_sum, shared.sum.load(.monotonic));
}
