//! Per-block meshing of everything that is not a full cube.
//!
//! Slabs, plants, liquids and the like can not be merged with their neighbors,
//! so they get the slow path: one block at a time, from the list the greedy
//! scan collected. There are few of them, and skipping them entirely in the hot
//! loop is exactly why the scan sorts blocks into "cube" and "not a cube" with
//! a bit test in the first place.
//!
//! Texture coordinates are expressed in *tile units*, like in the greedy mesher:
//! a face that is half a block tall gets uvs from 0 to 0.5 and so covers the top
//! half of its tile, which is what the old hand written uv tables did.

const std = @import("std");
const coord = @import("coord");
const blocks = @import("blocks");
const terrain = @import("terrain");
const tracy = @import("tracy");

const chunk = terrain.chunk;
const LightLevel = terrain.LightLevel;

const Snapshot = @import("Snapshot.zig");
const Layers = @import("Layers.zig");
const shading = @import("shading.zig");

/// Occlusion state of the six neighbors of a block
const Occlusion = struct {
    faces: [coord.Face.count]bool,

    inline fn of(self: Occlusion, face: coord.Face) bool {
        return self.faces[face.index()];
    }

    fn around(snapshot: *const Snapshot, x: usize, y: usize, z: usize) Occlusion {
        var ret: Occlusion = .{ .faces = @splat(false) };
        inline for (coord.Face.all) |face| {
            const offset = comptime face.asRelativeBlock();
            const neighbor = snapshot.idAtOffset(
                @as(i32, @intCast(x)) + offset.x,
                @as(i32, @intCast(y)) + offset.y,
                @as(i32, @intCast(z)) + offset.z,
            );
            ret.faces[face.index()] = blocks.isOpaqueCube(neighbor);
        }
        return ret;
    }
};

/// Meshes every block of the special list
pub fn run(snapshot: *const Snapshot, indices: []const u16, layers: *Layers) !void {
    if (indices.len == 0)
        return;

    const zone = tracy.Zone.begin(.{
        .name = "Special block meshing",
        .src = @src(),
        .color = .orange_red,
    });
    defer zone.end();

    for (indices) |index| {
        const pos = chunk.coordFromIndex(index);
        const x: usize = @intCast(pos.x);
        const y: usize = @intCast(pos.y);
        const z: usize = @intCast(pos.z);

        const block_id = snapshot.idAt(x, y, z);
        const light = snapshot.lightAt(x, y, z);
        const occlusion: Occlusion = .around(snapshot, x, y, z);

        // Every model here fits inside its own block, so the whole block's
        // geometry belongs to the section that block is in
        layers.setSectionOfHeight(y);

        const origin: [3]f32 = .{
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(z),
        };

        switch (blocks.modelOf(block_id)) {
            // Handled by the greedy mesher
            .full_basic, .full_barrel, .full_advanced, .air => unreachable,
            .slab => try box(layers, block_id, origin, light, occlusion, 0.5, 0.0, true),
            .snow_layer => try box(layers, block_id, origin, light, occlusion, 2.0 / 16.0, 0.0, true),
            .cactus => try cactus(layers, block_id, origin, light, occlusion),
            .plant => try plant(layers, block_id, origin, light),
            .liquid_still => try liquidSurface(layers, block_id, origin, light),
        }
    }
}

/// Emits a quad of a block face
inline fn faceQuad(
    layers: *Layers,
    block_id: blocks.Id,
    face: coord.Face,
    light: LightLevel,
    positions: [4][3]f32,
    uvs: [4][2]f32,
) !void {
    try layers.quad(
        block_id,
        positions,
        uvs,
        blocks.atlas.origins[blocks.texOf(face, block_id)],
        shading.faceColor(block_id, face, light),
    );
}

/// Uv rectangle of a face that is `w` wide and `h` tall, in tile units
inline fn uvRect(w: f32, h: f32, comptime reversed: bool) [4][2]f32 {
    return if (reversed)
        .{ .{ 0, h }, .{ w, h }, .{ w, 0 }, .{ 0, 0 } }
    else
        .{ .{ w, h }, .{ 0, h }, .{ 0, 0 }, .{ w, 0 } };
}

/// A box of the full block footprint, `height` tall, optionally shrunk
/// horizontally by `inset`. Used by slabs and snow layers.
fn box(
    layers: *Layers,
    block_id: blocks.Id,
    origin: [3]f32,
    light: LightLevel,
    occlusion: Occlusion,
    height: f32,
    inset: f32,
    /// True when the top face is drawn even if the neighbor above occludes it
    always_top: bool,
) !void {
    const x1 = origin[0] + inset;
    const x2 = origin[0] + 1.0 - inset;
    const y1 = origin[1];
    const y2 = origin[1] + height;
    const z1 = origin[2] + inset;
    const z2 = origin[2] + 1.0 - inset;

    // Sides, uvs cropped to the height of the box
    const side_uvs = uvRect(1.0, height, false);

    if (!occlusion.of(.north))
        try faceQuad(layers, block_id, .north, light, .{
            .{ x1, y1, z1 }, .{ x2, y1, z1 }, .{ x2, y2, z1 }, .{ x1, y2, z1 },
        }, side_uvs);

    if (!occlusion.of(.east))
        try faceQuad(layers, block_id, .east, light, .{
            .{ x2, y1, z1 }, .{ x2, y1, z2 }, .{ x2, y2, z2 }, .{ x2, y2, z1 },
        }, side_uvs);

    if (!occlusion.of(.south))
        try faceQuad(layers, block_id, .south, light, .{
            .{ x2, y1, z2 }, .{ x1, y1, z2 }, .{ x1, y2, z2 }, .{ x2, y2, z2 },
        }, side_uvs);

    if (!occlusion.of(.west))
        try faceQuad(layers, block_id, .west, light, .{
            .{ x1, y1, z2 }, .{ x1, y1, z1 }, .{ x1, y2, z1 }, .{ x1, y2, z2 },
        }, side_uvs);

    if (always_top or !occlusion.of(.up))
        try faceQuad(layers, block_id, .up, light, .{
            .{ x2, y2, z2 }, .{ x1, y2, z2 }, .{ x1, y2, z1 }, .{ x2, y2, z1 },
        }, uvRect(1.0, 1.0, false));

    if (!occlusion.of(.down))
        try faceQuad(layers, block_id, .down, light, .{
            .{ x1, y1, z2 }, .{ x2, y1, z2 }, .{ x2, y1, z1 }, .{ x1, y1, z1 },
        }, uvRect(1.0, 1.0, true));
}

/// A full height box whose sides are pushed one pixel inwards
fn cactus(
    layers: *Layers,
    block_id: blocks.Id,
    origin: [3]f32,
    light: LightLevel,
    occlusion: Occlusion,
) !void {
    const offset: f32 = 1.0 / 16.0;

    const x1 = origin[0];
    const x2 = origin[0] + 1.0;
    const y1 = origin[1];
    const y2 = origin[1] + 1.0;
    const z1 = origin[2];
    const z2 = origin[2] + 1.0;

    const full_uvs = uvRect(1.0, 1.0, false);

    // The sides are inset, so they are never hidden by a neighbor
    try faceQuad(layers, block_id, .north, light, .{
        .{ x1, y1, z1 + offset }, .{ x2, y1, z1 + offset },
        .{ x2, y2, z1 + offset }, .{ x1, y2, z1 + offset },
    }, full_uvs);

    try faceQuad(layers, block_id, .east, light, .{
        .{ x2 - offset, y1, z1 }, .{ x2 - offset, y1, z2 },
        .{ x2 - offset, y2, z2 }, .{ x2 - offset, y2, z1 },
    }, full_uvs);

    try faceQuad(layers, block_id, .south, light, .{
        .{ x2, y1, z2 - offset }, .{ x1, y1, z2 - offset },
        .{ x1, y2, z2 - offset }, .{ x2, y2, z2 - offset },
    }, full_uvs);

    try faceQuad(layers, block_id, .west, light, .{
        .{ x1 + offset, y1, z2 }, .{ x1 + offset, y1, z1 },
        .{ x1 + offset, y2, z1 }, .{ x1 + offset, y2, z2 },
    }, full_uvs);

    if (!occlusion.of(.up))
        try faceQuad(layers, block_id, .up, light, .{
            .{ x2, y2, z2 }, .{ x1, y2, z2 }, .{ x1, y2, z1 }, .{ x2, y2, z1 },
        }, full_uvs);

    if (!occlusion.of(.down))
        try faceQuad(layers, block_id, .down, light, .{
            .{ x1, y1, z2 }, .{ x2, y1, z2 }, .{ x2, y1, z1 }, .{ x1, y1, z1 },
        }, uvRect(1.0, 1.0, true));
}

/// Two crossed, double sided quads
fn plant(layers: *Layers, block_id: blocks.Id, origin: [3]f32, light: LightLevel) !void {
    const thin: f32 = 1.0 - 0.853;

    const x1 = origin[0] + thin;
    const x2 = origin[0] + 0.853;
    const y1 = origin[1];
    const y2 = origin[1] + 1.0;
    const z1 = origin[2] + thin;
    const z2 = origin[2] + 0.853;

    const uvs = uvRect(1.0, 1.0, false);

    // Both planes are drawn twice so that they are visible from any side
    try faceQuad(layers, block_id, .north, light, .{
        .{ x1, y1, z1 }, .{ x2, y1, z2 }, .{ x2, y2, z2 }, .{ x1, y2, z1 },
    }, uvs);
    try faceQuad(layers, block_id, .south, light, .{
        .{ x2, y1, z2 }, .{ x1, y1, z1 }, .{ x1, y2, z1 }, .{ x2, y2, z2 },
    }, uvs);
    try faceQuad(layers, block_id, .east, light, .{
        .{ x1, y1, z2 }, .{ x2, y1, z1 }, .{ x2, y2, z1 }, .{ x1, y2, z2 },
    }, uvs);
    try faceQuad(layers, block_id, .west, light, .{
        .{ x2, y1, z1 }, .{ x1, y1, z2 }, .{ x1, y2, z2 }, .{ x2, y2, z1 },
    }, uvs);
}

/// The flat surface of a still liquid
fn liquidSurface(layers: *Layers, block_id: blocks.Id, origin: [3]f32, light: LightLevel) !void {
    const x1 = origin[0];
    const x2 = origin[0] + 1.0;
    const y = origin[1] + (14.2 / 16.0);
    const z1 = origin[2];
    const z2 = origin[2] + 1.0;

    try faceQuad(layers, block_id, .up, light, .{
        .{ x1, y, z1 }, .{ x2, y, z1 }, .{ x2, y, z2 }, .{ x1, y, z2 },
    }, uvRect(1.0, 1.0, false));
}
