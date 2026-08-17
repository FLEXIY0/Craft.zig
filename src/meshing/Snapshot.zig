//! An immutable copy of everything a worker thread needs to mesh one chunk.
//!
//! Meshing happens off the main thread while the network thread keeps writing
//! block updates into the chunk store. Rather than locking chunks, the main
//! thread copies the ~100 KiB a chunk mesh depends on into a snapshot and hands
//! ownership of that snapshot to a worker. From then on the worker touches
//! nothing shared, which is what makes the whole pipeline lock free.
//!
//! The snapshot is laid out for the *mesher*, not for storage: light levels are
//! unpacked to one byte per block (the store keeps them as nibbles to halve the
//! memory), and the border planes of the neighbor chunks have the exact same
//! shape as the chunk's own columns. Both meshing passes then walk whole
//! columns with a plain indexed load and never do any per-block address math.

const std = @import("std");
const coord = @import("coord");
const terrain = @import("terrain");

const chunk = terrain.chunk;
const LightLevel = terrain.LightLevel;

const Snapshot = @This();

/// Amount of horizontal sides a chunk has (north, east, south, west)
pub const side_count = 4;

/// Light levels used for blocks outside of the loaded world
pub const default_light: LightLevel = .{ .blocklight = 0, .skylight = 15 };

/// The block ids of one vertical column
pub const IdColumn = [chunk.height]u8;
/// The light levels of one vertical column
pub const LightColumn = [chunk.height]LightLevel;

/// Coordinates of the snapshotted chunk
coords: coord.Chunk = .{},

/// Block ids of the chunk, one column at a time
ids: [chunk.volume]u8 = undefined,
/// Light levels of the chunk, unpacked, one column at a time
light: [chunk.volume]LightLevel = undefined,

/// Block ids of the neighbor chunks, on the plane touching each side.
/// Indexed `[face][u]`, where `u` is x for the north and south sides, and z for
/// the east and west sides. Missing neighbors are filled with air.
edge_ids: [side_count][chunk.width]IdColumn = undefined,
/// Light levels of the neighbor chunks, same indexing as `edge_ids`
edge_light: [side_count][chunk.width]LightColumn = undefined,

/// The block ids of a column of the chunk
pub inline fn idColumn(self: *const Snapshot, x: usize, z: usize) *const IdColumn {
    return self.ids[chunk.columnBase(x, z)..][0..chunk.height];
}

/// Mutable block ids of a column, for whoever fills the snapshot
pub inline fn idColumnMut(self: *Snapshot, x: usize, z: usize) *IdColumn {
    return self.ids[chunk.columnBase(x, z)..][0..chunk.height];
}

/// The light levels of a column of the chunk
pub inline fn lightColumn(self: *const Snapshot, x: usize, z: usize) *const LightColumn {
    return self.light[chunk.columnBase(x, z)..][0..chunk.height];
}

/// Mutable light levels of a column, for whoever fills the snapshot
pub inline fn lightColumnMut(self: *Snapshot, x: usize, z: usize) *LightColumn {
    return self.light[chunk.columnBase(x, z)..][0..chunk.height];
}

/// The block ids of a column that may belong to a neighbor chunk.
/// The coordinates may be one block outside of the chunk horizontally.
pub fn idColumnAt(self: *const Snapshot, x: i32, z: i32) *const IdColumn {
    if (x < 0)
        return &self.edge_ids[@intFromEnum(coord.Face.west)][@intCast(z)];
    if (x >= chunk.width)
        return &self.edge_ids[@intFromEnum(coord.Face.east)][@intCast(z)];
    if (z < 0)
        return &self.edge_ids[@intFromEnum(coord.Face.north)][@intCast(x)];
    if (z >= chunk.width)
        return &self.edge_ids[@intFromEnum(coord.Face.south)][@intCast(x)];
    return self.idColumn(@intCast(x), @intCast(z));
}

/// The light levels of a column that may belong to a neighbor chunk
pub fn lightColumnAt(self: *const Snapshot, x: i32, z: i32) *const LightColumn {
    if (x < 0)
        return &self.edge_light[@intFromEnum(coord.Face.west)][@intCast(z)];
    if (x >= chunk.width)
        return &self.edge_light[@intFromEnum(coord.Face.east)][@intCast(z)];
    if (z < 0)
        return &self.edge_light[@intFromEnum(coord.Face.north)][@intCast(x)];
    if (z >= chunk.width)
        return &self.edge_light[@intFromEnum(coord.Face.south)][@intCast(x)];
    return self.lightColumn(@intCast(x), @intCast(z));
}

/// Block id at local coordinates
pub inline fn idAt(self: *const Snapshot, x: usize, y: usize, z: usize) u8 {
    return self.idColumn(x, z)[y];
}

/// Light level at local coordinates
pub inline fn lightAt(self: *const Snapshot, x: usize, y: usize, z: usize) LightLevel {
    return self.lightColumn(x, z)[y];
}

/// Block id of a neighbor block, transcending the chunk boundaries.
/// Coordinates may be one block outside of the chunk horizontally; above and
/// below the chunk everything is air.
pub fn idAtOffset(self: *const Snapshot, x: i32, y: i32, z: i32) u8 {
    if (y < 0 or y >= chunk.height)
        return 0;
    return self.idColumnAt(x, z)[@intCast(y)];
}

/// Light level of a neighbor block, transcending the chunk boundaries
pub fn lightAtOffset(self: *const Snapshot, x: i32, y: i32, z: i32) LightLevel {
    if (y < 0 or y >= chunk.height)
        return default_light;
    return self.lightColumnAt(x, z)[@intCast(y)];
}

/// Light level of the block touching a face of a block
pub inline fn lightAtFace(self: *const Snapshot, x: usize, y: usize, z: usize, face: coord.Face) LightLevel {
    const offset = face.asRelativeBlock();
    return self.lightAtOffset(
        @as(i32, @intCast(x)) + offset.x,
        @as(i32, @intCast(y)) + offset.y,
        @as(i32, @intCast(z)) + offset.z,
    );
}

/// Empties the chunk, for tests and for whoever fills the snapshot
pub fn clear(self: *Snapshot) void {
    @memset(&self.ids, 0);
    @memset(&self.light, default_light);
    self.clearEdges();
}

/// Fills the neighbor planes with air and full sky light, which is what a side
/// whose neighbor chunk is not loaded looks like
pub fn clearEdges(self: *Snapshot) void {
    self.edge_ids = @splat(@splat(@splat(0)));
    self.edge_light = @splat(@splat(@splat(default_light)));
}

test "snapshot reads" {
    const alloc = std.testing.allocator;

    const snapshot = try alloc.create(Snapshot);
    defer alloc.destroy(snapshot);

    snapshot.* = .{};
    snapshot.clear();

    snapshot.idColumnMut(2, 3)[40] = 12;
    try std.testing.expectEqual(@as(u8, 12), snapshot.idAt(2, 40, 3));
    try std.testing.expectEqual(@as(u8, 12), snapshot.idAtOffset(2, 40, 3));

    // Outside of the chunk, vertically
    try std.testing.expectEqual(@as(u8, 0), snapshot.idAtOffset(2, -1, 3));
    try std.testing.expectEqual(default_light, snapshot.lightAtOffset(2, 128, 3));

    // Outside of the chunk, horizontally: the neighbor planes answer
    snapshot.edge_ids[@intFromEnum(coord.Face.west)][3][40] = 7;
    try std.testing.expectEqual(@as(u8, 7), snapshot.idAtOffset(-1, 40, 3));
    snapshot.edge_ids[@intFromEnum(coord.Face.south)][2][40] = 9;
    try std.testing.expectEqual(@as(u8, 9), snapshot.idAtOffset(2, 40, 16));

    // A column is contiguous and matches the per block accessors
    snapshot.lightColumnMut(5, 6)[10] = .{ .blocklight = 3, .skylight = 4 };
    try std.testing.expectEqual(
        LightLevel{ .blocklight = 3, .skylight = 4 },
        snapshot.lightAt(5, 10, 6),
    );
    try std.testing.expectEqual(
        LightLevel{ .blocklight = 3, .skylight = 4 },
        snapshot.lightColumnAt(5, 6)[10],
    );
}
