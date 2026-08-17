//! CPU side mesh of a chunk, and the builder that fills it.
//!
//! The vertex data is kept as a struct of arrays, one flat buffer per attribute,
//! which is both what the greedy mesher wants to write and what the graphics API
//! wants to upload. Buffers are allocated with the *mesh allocator*, the one the
//! frontend hands over, so that a finished mesh can be given to the renderer
//! without a copy.
//!
//! A chunk mesh is split in several `Part`s: the vertex index type is usually 16
//! bits, so a part is capped at 65532 vertices and a new one is started when it
//! fills up.

const std = @import("std");
const io = @import("io");

const MeshData = @This();

/// Vertex index type used by the frontend
pub const VertexIdT = io.properties.VertexIdT;

/// Maximum amount of vertices in a single part (multiple of 4)
pub const max_vertices: u32 = @min(std.math.maxInt(VertexIdT) - 3, 65532);

/// One uploadable chunk of geometry
pub const Part = struct {
    /// 3 floats per vertex
    positions: []f32 = &.{},
    /// 2 floats per vertex, in tile units: a greedy quad spanning 4 blocks goes
    /// from 0 to 4, and the shader wraps it inside its atlas tile
    uvs: []f32 = &.{},
    /// 2 floats per vertex: origin of the atlas tile of that vertex
    tiles: []f32 = &.{},
    /// 4 bytes per vertex (rgba)
    colors: []u8 = &.{},
    /// 6 indices per quad
    indices: []VertexIdT = &.{},

    vertex_count: u32 = 0,
    triangle_count: u32 = 0,

    pub fn deinit(self: Part, alloc: std.mem.Allocator) void {
        alloc.free(self.positions);
        alloc.free(self.uvs);
        alloc.free(self.tiles);
        alloc.free(self.colors);
        alloc.free(self.indices);
    }
};

/// Allocator the parts were allocated with
alloc: std.mem.Allocator,
/// Geometry of the opaque render layer
solid: []Part = &.{},
/// Geometry of the transparent render layer
transparent: []Part = &.{},

/// Frees everything the mesh owns
pub fn deinit(self: MeshData) void {
    for (self.solid) |part|
        part.deinit(self.alloc);
    for (self.transparent) |part|
        part.deinit(self.alloc);
    self.alloc.free(self.solid);
    self.alloc.free(self.transparent);
}

/// Amount of vertices of the whole mesh, for statistics and tests
pub fn vertexCount(self: MeshData) u32 {
    var total: u32 = 0;
    for (self.solid) |part|
        total += part.vertex_count;
    for (self.transparent) |part|
        total += part.vertex_count;
    return total;
}

/// Accumulates quads into vertex buffers, splitting them into parts when the
/// vertex index type runs out of range
pub const Builder = struct {
    alloc: std.mem.Allocator,

    positions: std.ArrayListUnmanaged(f32) = .empty,
    uvs: std.ArrayListUnmanaged(f32) = .empty,
    tiles: std.ArrayListUnmanaged(f32) = .empty,
    colors: std.ArrayListUnmanaged(u8) = .empty,
    indices: std.ArrayListUnmanaged(VertexIdT) = .empty,

    parts: std.ArrayListUnmanaged(Part) = .empty,
    vertex_count: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) Builder {
        return .{ .alloc = alloc };
    }

    /// Appends a quad, given its four vertices in winding order
    pub fn quad(
        self: *Builder,
        positions: [4][3]f32,
        uvs: [4][2]f32,
        tile: [2]f32,
        color: [4]u8,
    ) !void {
        if (self.vertex_count >= max_vertices)
            try self.flush();

        try self.positions.ensureUnusedCapacity(self.alloc, 4 * 3);
        try self.uvs.ensureUnusedCapacity(self.alloc, 4 * 2);
        try self.tiles.ensureUnusedCapacity(self.alloc, 4 * 2);
        try self.colors.ensureUnusedCapacity(self.alloc, 4 * 4);
        try self.indices.ensureUnusedCapacity(self.alloc, 6);

        for (positions, uvs) |position, uv| {
            self.positions.appendSliceAssumeCapacity(&position);
            self.uvs.appendSliceAssumeCapacity(&uv);
            self.tiles.appendSliceAssumeCapacity(&tile);
            self.colors.appendSliceAssumeCapacity(&color);
        }

        const base: VertexIdT = @intCast(self.vertex_count);
        self.indices.appendSliceAssumeCapacity(&.{
            base + 0, base + 2, base + 1,
            base + 0, base + 3, base + 2,
        });

        self.vertex_count += 4;
    }

    /// Closes the part being built, if it holds anything
    pub fn flush(self: *Builder) !void {
        if (self.vertex_count == 0)
            return;

        var part: Part = .{
            .vertex_count = self.vertex_count,
            .triangle_count = @intCast(self.indices.items.len / 3),
        };

        part.positions = try self.positions.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(part.positions);
        part.uvs = try self.uvs.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(part.uvs);
        part.tiles = try self.tiles.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(part.tiles);
        part.colors = try self.colors.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(part.colors);
        part.indices = try self.indices.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(part.indices);

        try self.parts.append(self.alloc, part);
        self.vertex_count = 0;
    }

    /// Closes the current part and gives away every part built so far
    pub fn toOwnedParts(self: *Builder) ![]Part {
        try self.flush();
        return self.parts.toOwnedSlice(self.alloc);
    }

    pub fn deinit(self: *Builder) void {
        self.positions.deinit(self.alloc);
        self.uvs.deinit(self.alloc);
        self.tiles.deinit(self.alloc);
        self.colors.deinit(self.alloc);
        self.indices.deinit(self.alloc);
        for (self.parts.items) |part|
            part.deinit(self.alloc);
        self.parts.deinit(self.alloc);
    }
};

test "builder splits parts" {
    const alloc = std.testing.allocator;

    var builder: Builder = .init(alloc);
    defer builder.deinit();

    const quads = max_vertices / 4 + 2;
    for (0..quads) |_| {
        try builder.quad(
            .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } },
            .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } },
            .{ 0, 0 },
            .{ 255, 255, 255, 255 },
        );
    }

    const parts = try builder.toOwnedParts();
    const mesh: MeshData = .{ .alloc = alloc, .solid = parts };
    defer mesh.deinit();

    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqual(max_vertices, parts[0].vertex_count);
    try std.testing.expectEqual(@as(u32, 8), parts[1].vertex_count);
    try std.testing.expectEqual(quads * 4, mesh.vertexCount());

    // Every index must stay addressable by the frontend's index type
    for (parts) |part| {
        try std.testing.expectEqual(part.vertex_count * 3, @as(u32, @intCast(part.positions.len)));
        try std.testing.expectEqual(part.triangle_count * 3, @as(u32, @intCast(part.indices.len)));
        for (part.indices) |index|
            try std.testing.expect(index < part.vertex_count);
    }
}
