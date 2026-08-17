//! The render layers a chunk mesh is split into.
//!
//! Which layer a quad lands in is a property of its block id, so the meshers
//! never branch on "is this glass": they hand the quad over and the layer is
//! picked by a single bit test in the block registry.

const std = @import("std");
const blocks = @import("blocks");

const MeshData = @import("MeshData.zig");

const Layers = @This();

/// Fully opaque geometry
solid: MeshData.Builder,
/// Geometry that needs alpha, drawn after the opaque layer
transparent: MeshData.Builder,

pub fn init(alloc: std.mem.Allocator) Layers {
    return .{
        .solid = .init(alloc),
        .transparent = .init(alloc),
    };
}

/// The builder a block's geometry belongs to
pub inline fn of(self: *Layers, block_id: blocks.Id) *MeshData.Builder {
    return if (blocks.isTransparent(block_id)) &self.transparent else &self.solid;
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

/// Closes both builders and returns the finished mesh
pub fn finish(self: *Layers, alloc: std.mem.Allocator) !MeshData {
    const solid = try self.solid.toOwnedParts();
    errdefer {
        for (solid) |part| part.deinit(self.solid.alloc);
        self.solid.alloc.free(solid);
    }
    const transparent = try self.transparent.toOwnedParts();

    return .{
        .alloc = alloc,
        .solid = solid,
        .transparent = transparent,
    };
}

pub fn deinit(self: *Layers) void {
    self.solid.deinit();
    self.transparent.deinit();
}
