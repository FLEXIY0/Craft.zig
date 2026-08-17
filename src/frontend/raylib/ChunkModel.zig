//! A chunk's visual representation.
//!
//! All the work happens in the meshing module, on worker threads: this is only
//! the part that has to run on the thread that owns the OpenGL context, i.e.
//! handing the finished vertex buffers to the driver and drawing them.

const std = @import("std");
const rl = @import("raylib");
const coord = @import("coord");
const meshing = @import("meshing");
const tracy = @import("tracy");

const ChunkModel = @This();

/// Opaque geometry
meshes: []rl.Mesh,
/// Geometry drawn on the transparent layer
transparent_meshes: []rl.Mesh,

/// Uploads a finished chunk mesh to the gpu.
/// Takes ownership of `data`, whatever happens.
pub fn upload(alloc: std.mem.Allocator, data: meshing.MeshData) !ChunkModel {
    const zone = tracy.Zone.begin(.{
        .name = "Chunk model upload",
        .src = @src(),
        .color = .green,
    });
    defer zone.end();

    const meshes = alloc.alloc(rl.Mesh, data.solid.len) catch |err| {
        data.deinit();
        return err;
    };
    errdefer alloc.free(meshes);

    const transparent_meshes = alloc.alloc(rl.Mesh, data.transparent.len) catch |err| {
        alloc.free(meshes);
        data.deinit();
        return err;
    };

    // Talking to the driver needs a window, which a headless run (tests, or a
    // client that has not opened its window yet) does not have. The mesh is
    // still built and owned, it just stays on the cpu side.
    const can_upload = rl.isWindowReady();

    // From here on the vertex buffers belong to the meshes
    for (data.solid, meshes) |part, *mesh| {
        mesh.* = meshFromPart(part);
        if (can_upload)
            rl.uploadMesh(mesh, false);
    }
    for (data.transparent, transparent_meshes) |part, *mesh| {
        mesh.* = meshFromPart(part);
        if (can_upload)
            rl.uploadMesh(mesh, false);
    }

    // Only the (now empty) part arrays are left to free
    data.alloc.free(data.solid);
    data.alloc.free(data.transparent);

    return .{
        .meshes = meshes,
        .transparent_meshes = transparent_meshes,
    };
}

/// Wraps the buffers of a mesh part in a raylib mesh, without copying them
fn meshFromPart(part: meshing.Part) rl.Mesh {
    return .{
        .vertexCount = @intCast(part.vertex_count),
        .triangleCount = @intCast(part.triangle_count),
        .vertices = @ptrCast(part.positions.ptr),
        // Texture coordinates are in tile units and are wrapped inside their
        // atlas tile by the chunk shader, which needs to know which tile that
        // is: that is what the second uv set carries
        .texcoords = @ptrCast(part.uvs.ptr),
        .texcoords2 = @ptrCast(part.tiles.ptr),
        .colors = @ptrCast(part.colors.ptr),
        .indices = @ptrCast(part.indices.ptr),
        .animNormals = @ptrFromInt(0),
        .animVertices = @ptrFromInt(0),
        .boneCount = 0,
        .boneIds = @ptrFromInt(0),
        .boneMatrices = @ptrFromInt(0),
        .boneWeights = @ptrFromInt(0),
        .normals = @ptrFromInt(0),
        .tangents = @ptrFromInt(0),
        .vaoId = 0,
        .vboId = @ptrFromInt(0),
    };
}

pub fn draw(self: ChunkModel, pos: coord.Chunk, material: *const rl.Material) void {
    const transform: rl.Matrix = .translate(
        @floatFromInt(pos.x * 16),
        0,
        @floatFromInt(pos.z * 16),
    );
    for (self.meshes) |mesh|
        rl.drawMesh(mesh, material.*, transform);
}

pub fn drawTransparentLayer(self: ChunkModel, pos: coord.Chunk, material: *const rl.Material) void {
    const transform: rl.Matrix = .translate(
        @floatFromInt(pos.x * 16),
        0,
        @floatFromInt(pos.z * 16),
    );
    for (self.transparent_meshes) |mesh|
        rl.drawMesh(mesh, material.*, transform);
}

/// Amount of triangles the model draws, for the debug overlay
pub fn triangleCount(self: ChunkModel) usize {
    var total: usize = 0;
    for (self.meshes) |mesh|
        total += @intCast(mesh.triangleCount);
    for (self.transparent_meshes) |mesh|
        total += @intCast(mesh.triangleCount);
    return total;
}

pub fn deinit(self: ChunkModel, alloc: std.mem.Allocator) void {
    for (self.meshes) |mesh|
        mesh.unload();
    for (self.transparent_meshes) |mesh|
        mesh.unload();
    alloc.free(self.meshes);
    alloc.free(self.transparent_meshes);
}
