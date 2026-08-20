//! A 64 bit value shared between threads, including on machines that cannot
//! share one.
//!
//! zig refuses a 64 bit atomic on a 32 bit target, whatever cpu is asked for,
//! and armeabi-v7a is the whole reason this file exists: it is the ABI of every
//! Android phone older than about 2014, and the client has two of these -- the
//! world clock and the timestamp of the last packet -- both written by one
//! thread and read by another.
//!
//! Where the target can do it, this *is* `std.atomic.Value` and costs nothing.
//! Where it cannot, it is a mutex around a plain integer. For a clock read once
//! a frame that is not a cost worth measuring, and it is the only way to read
//! eight bytes without seeing half of an old value and half of a new one.

const std = @import("std");
const builtin = @import("builtin");

/// Whether the target has a 64 bit atomic at all. Pointer width is the rule for
/// every target this client is built for: aarch64 and x86_64 have them, arm and
/// x86 do not, and no cpu feature changes that as far as zig is concerned.
pub const native = builtin.target.ptrBitWidth() >= 64;

pub fn Value(comptime T: type) type {
    comptime std.debug.assert(@bitSizeOf(T) == 64);
    return if (native) std.atomic.Value(T) else Locked(T);
}

/// The fallback, named rather than hidden inside the branch above so that it is
/// tested on every machine and not only on the one that needs it
pub fn Locked(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: T,
        lock: std.Thread.Mutex = .{},

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        /// The memory order is accepted and ignored: a mutex already orders
        /// everything either side of it, which is stronger than any of them
        pub fn load(self: *Self, comptime order: std.builtin.AtomicOrder) T {
            _ = order;
            self.lock.lock();
            defer self.lock.unlock();
            return self.raw;
        }

        pub fn store(self: *Self, value: T, comptime order: std.builtin.AtomicOrder) void {
            _ = order;
            self.lock.lock();
            defer self.lock.unlock();
            self.raw = value;
        }
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the fallback keeps a value across a store" {
    var value: Locked(i64) = .init(-1);

    try testing.expectEqual(@as(i64, -1), value.load(.unordered));
    value.store(std.math.maxInt(i64), .unordered);
    try testing.expectEqual(std.math.maxInt(i64), value.load(.unordered));
}

test "the fallback survives two threads writing at once" {
    // What a 32 bit machine cannot do without this is read the two halves of a
    // value that changed in between them, so the assertion is that no reader
    // ever sees a number that was never written
    const rounds = 2000;
    const Shared = struct {
        value: Locked(i64) = .init(0),

        fn write(self: *@This(), tag: i64) void {
            for (0..rounds) |i|
                self.value.store(tag * 0x1_0000_0000 + @as(i64, @intCast(i)), .unordered);
        }
    };

    var shared: Shared = .{};
    const a = try std.Thread.spawn(.{}, Shared.write, .{ &shared, 1 });
    const b = try std.Thread.spawn(.{}, Shared.write, .{ &shared, 2 });

    for (0..rounds) |_| {
        const seen = shared.value.load(.unordered);
        const tag = @divFloor(seen, 0x1_0000_0000);
        const counter = @mod(seen, 0x1_0000_0000);
        try testing.expect(tag == 0 or tag == 1 or tag == 2);
        try testing.expect(counter >= 0 and counter < rounds);
    }

    a.join();
    b.join();
}
