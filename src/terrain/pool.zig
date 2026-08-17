//! Paged component storage.
//!
//! The chunk store keeps one of these per component (block ids, light levels,
//! coordinates, dirty flags...). Growing a pool allocates a new page instead of
//! reallocating, so:
//!  - slot indices stay valid forever, and
//!  - pointers into a component stay valid while other chunks are loaded,
//!    which is what makes it safe to hand a chunk's data to a worker thread.

const std = @import("std");

/// A paged array of `T`, indexed by chunk slot
pub fn Pool(comptime T: type, comptime page_len: usize) type {
    comptime std.debug.assert(page_len > 0);

    return struct {
        const Self = @This();

        /// Allocated pages, `page_len` items each
        pages: std.ArrayListUnmanaged([]T) = .empty,

        /// Makes sure the pool can address `index`, and returns a pointer to it.
        /// Newly allocated items are set to `default`.
        pub fn ensure(self: *Self, alloc: std.mem.Allocator, index: usize, default: T) !*T {
            const page = index / page_len;
            while (self.pages.items.len <= page) {
                const new_page = try alloc.alloc(T, page_len);
                @memset(new_page, default);
                errdefer alloc.free(new_page);
                try self.pages.append(alloc, new_page);
            }
            return &self.pages.items[page][index % page_len];
        }

        /// Pointer to an item that is known to be addressable
        pub inline fn at(self: Self, index: usize) *T {
            return &self.pages.items[index / page_len][index % page_len];
        }

        /// Value of an item that is known to be addressable
        pub inline fn get(self: Self, index: usize) T {
            return self.at(index).*;
        }

        /// Overwrite an item that is known to be addressable
        pub inline fn put(self: Self, index: usize, value: T) void {
            self.at(index).* = value;
        }

        /// True if `index` has been allocated already
        pub inline fn addressable(self: Self, index: usize) bool {
            return index / page_len < self.pages.items.len;
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            for (self.pages.items) |page|
                alloc.free(page);
            self.pages.deinit(alloc);
        }
    };
}

test "pool keeps pointers stable" {
    const alloc = std.testing.allocator;

    var pool: Pool(u32, 4) = .{};
    defer pool.deinit(alloc);

    const first = try pool.ensure(alloc, 0, 0);
    first.* = 42;

    // Force a bunch of new pages
    for (1..100) |i|
        (try pool.ensure(alloc, i, 0)).* = @intCast(i);

    try std.testing.expectEqual(@as(u32, 42), first.*);
    try std.testing.expectEqual(@as(u32, 42), pool.get(0));
    try std.testing.expectEqual(@as(u32, 99), pool.get(99));
    try std.testing.expect(pool.addressable(99));
    try std.testing.expect(!pool.addressable(100));
}

test "pool defaults" {
    const alloc = std.testing.allocator;

    var pool: Pool(?u8, 2) = .{};
    defer pool.deinit(alloc);

    _ = try pool.ensure(alloc, 5, null);
    for (0..6) |i|
        try std.testing.expectEqual(@as(?u8, null), pool.get(i));
}
