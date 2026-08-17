//! Description of the terrain texture atlas.
//!
//! This is the *only* place in the engine that knows how a texture id maps to a
//! position in the atlas image. Everything else (the block registry, the mesher,
//! the chunk shader) consumes the declarations below, so replacing this file is
//! enough to change the atlas layout.
//!
//! The file is meant to eventually be *generated* by an atlas packer: run the
//! packer as a build step, have it emit a file with the same declarations, and
//! point the build at it with `zig build -Datlas=path/to/generated_atlas.zig`.
//! See `docs/dod_architecture.md`.

const std = @import("std");

/// Number of tiles per atlas row
pub const columns = 16;
/// Number of tile rows
pub const rows = 16;
/// Side of a single tile, in pixels (only used to compute the sampling inset)
pub const tile_px = 16;

/// Amount of addressable tiles
pub const tile_count = columns * rows;

/// Id used by blocks that have no texture for a given face
pub const no_tex: u8 = 253;

/// Size of a tile in normalized atlas coordinates
pub const tile_size: [2]f32 = .{ 1.0 / @as(f32, columns), 1.0 / @as(f32, rows) };

/// Half a texel, in normalized atlas coordinates.
/// The chunk shader insets tiled uvs by this much so that a greedy quad
/// repeating a tile never samples the neighboring tile of the atlas.
pub const inset: [2]f32 = .{
    0.5 / @as(f32, columns * tile_px),
    0.5 / @as(f32, rows * tile_px),
};

/// Texture id of the tile at column `x`, row `y`
pub inline fn at(x: comptime_int, y: comptime_int) u8 {
    comptime std.debug.assert(x >= 0 and x < columns);
    comptime std.debug.assert(y >= 0 and y < rows);
    return y * columns + x;
}

/// Origin (upper left corner) of every tile, in normalized atlas coordinates.
/// SoA-friendly lookup table: the mesher only ever does `origins[tex_id]`.
pub const origins: [tile_count][2]f32 = blk: {
    var ret: [tile_count][2]f32 = undefined;
    for (&ret, 0..) |*origin, i| {
        origin.* = .{
            @as(f32, @floatFromInt(i % columns)) * tile_size[0],
            @as(f32, @floatFromInt(i / columns)) * tile_size[1],
        };
    }
    break :blk ret;
};

test "atlas origins" {
    try std.testing.expectEqual(@as(u8, 0), at(0, 0));
    try std.testing.expectEqual(@as(u8, 17), at(1, 1));
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, origins[0]);
    try std.testing.expectEqual([2]f32{ 1.0 / 16.0, 1.0 / 16.0 }, origins[17]);
}
