//! Vertex colors: block tint and light levels.
//!
//! Tints are data (`blocks.tintOf`), not a switch on block ids like they used to
//! be, and the light of a face is folded into the vertex color at meshing time.
//! Two faces only merge if their color matches, which is why this is a pure
//! function of (block id, face, light level).

const std = @import("std");
const coord = @import("coord");
const blocks = @import("blocks");
const terrain = @import("terrain");

const LightLevel = terrain.LightLevel;

/// The higher this is, the less impact light levels have on blocks
pub const lighting_adjustment = 2;

/// Divider applied to a color channel at full light
const light_divider = 15 + lighting_adjustment;

// TODO: based on biome
const grass_color: [4]u8 = .{ 0x44, 0xbb, 0x44, 0xff };
const foliage_color: [4]u8 = .{ 0x44, 0x99, 0x44, 0xff };
const default_color: [4]u8 = .{ 0xff, 0xff, 0xff, 0xff };

/// Untinted, unlit color of a block face
pub inline fn tintOf(block_id: blocks.Id, face: coord.Face) [4]u8 {
    return switch (blocks.tintOf(block_id)) {
        .none => default_color,
        .grass_top => if (face == .up) grass_color else default_color,
        .foliage => foliage_color,
    };
}

/// Applies a light level to a color
pub inline fn applyLight(color: [4]u8, light: LightLevel) [4]u8 {
    const total: u32 = @as(u32, light.blocklight) + light.skylight + lighting_adjustment;
    const lit = @min(total, light_divider);

    var ret = color;
    inline for (0..3) |channel| {
        ret[channel] = @intCast(@as(u32, color[channel]) * lit / light_divider);
    }
    return ret;
}

/// Final vertex color of a block face
pub inline fn faceColor(block_id: blocks.Id, face: coord.Face, light: LightLevel) [4]u8 {
    return applyLight(tintOf(block_id, face), light);
}

test "light darkens colors" {
    const dark = faceColor(0, .north, .{ .blocklight = 0, .skylight = 0 });
    const lit = faceColor(0, .north, .{ .blocklight = 0, .skylight = 15 });

    try std.testing.expectEqual([4]u8{ 30, 30, 30, 255 }, dark);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, lit);
}

test "tints come from the registry" {
    const full = LightLevel{ .blocklight = 15, .skylight = 15 };

    // Grass is only tinted on top
    try std.testing.expectEqual(grass_color, faceColor(blocks.idOf(.grass), .up, full));
    try std.testing.expectEqual(default_color, faceColor(blocks.idOf(.grass), .north, full));
    // Leaves are tinted everywhere
    try std.testing.expectEqual(foliage_color, faceColor(blocks.idOf(.leaves), .north, full));
    // Stone is not tinted
    try std.testing.expectEqual(default_color, faceColor(blocks.idOf(.stone), .up, full));
}
