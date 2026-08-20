//! The render layers a chunk mesh is split into, and the sections it is cut in.
//!
//! Which layer a quad lands in is a property of its block id, so the meshers
//! never branch on "is this glass": they hand the quad over and the layer is
//! picked by a single bit test in the block registry.
//!
//! Geometry is also cut in sections of 16 blocks along y, the same sections the
//! chunk store already tracks. A chunk is 128 blocks tall and most of that is
//! underground: a renderer that can skip a section skips the caves the player
//! can not possibly see. The meshers announce which section they are working on
//! with `setSection` instead of passing it down through every emit function.

const std = @import("std");
const blocks = @import("blocks");
const terrain = @import("terrain");

const chunk = terrain.chunk;
const MeshData = @import("MeshData.zig");

const Layers = @This();

/// The two render layers a quad can belong to
pub const Layer = enum { solid, transparent };

/// Builders of a single section
const SectionBuilders = struct {
    solid: MeshData.Builder,
    transparent: MeshData.Builder,
};

/// One pair of builders per section of the chunk
sections: [chunk.section_count]SectionBuilders,
/// Section the meshers are currently emitting into
current: usize = 0,

pub fn init(alloc: std.mem.Allocator) Layers {
    var self: Layers = .{ .sections = undefined };
    for (&self.sections) |*section| {
        section.* = .{
            .solid = .init(alloc),
            .transparent = .init(alloc),
        };
    }
    return self;
}

/// Selects the section the following quads belong to
pub inline fn setSection(self: *Layers, section: usize) void {
    std.debug.assert(section < chunk.section_count);
    self.current = section;
}

/// Selects the section a block at height `y` belongs to
pub inline fn setSectionOfHeight(self: *Layers, y: usize) void {
    self.setSection(y / chunk.section_height);
}

/// The builder a block's geometry belongs to, in the current section
pub inline fn of(self: *Layers, block_id: blocks.Id) *MeshData.Builder {
    const section = &self.sections[self.current];
    return if (blocks.isTransparent(block_id)) &section.transparent else &section.solid;
}

/// Appends a quad to the layer of a block
pub inline fn quad(
    self: *Layers,
    block_id: blocks.Id,
    positions: [4][3]f32,
    uvs: [4][2]f32,
    tile: [2]f32,
    color: [4]u8,
) !void {
    try self.of(block_id).quad(positions, uvs, tile, color);
}

/// Closes every builder and returns the finished mesh
pub fn finish(self: *Layers, alloc: std.mem.Allocator) !MeshData {
    var mesh: MeshData = .{ .alloc = alloc };
    // On failure the sections built so far are owned by the mesh, and the ones
    // left are still owned by their builder: `deinit` on either frees them once
    errdefer mesh.deinit();

    for (&self.sections, &mesh.sections) |*builders, *section| {
        section.solid = try builders.solid.toOwnedParts();
        section.transparent = try builders.transparent.toOwnedParts();
    }

    return mesh;
}

pub fn deinit(self: *Layers) void {
    for (&self.sections) |*section| {
        section.solid.deinit();
        section.transparent.deinit();
    }
}
