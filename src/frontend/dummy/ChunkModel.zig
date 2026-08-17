//! A chunk's visual representation
//! This frontend draws nothing, so it just drops the mesh it is given

const std = @import("std");
const meshing = @import("meshing");

const ChunkModel = @This();

/// Amount of vertices the mesh had, so that headless runs can still be checked
vertex_count: u32 = 0,

pub fn upload(_: std.mem.Allocator, data: meshing.MeshData) !ChunkModel {
    defer data.deinit();
    return .{ .vertex_count = data.vertexCount() };
}

pub fn deinit(_: ChunkModel, _: std.mem.Allocator) void {}
