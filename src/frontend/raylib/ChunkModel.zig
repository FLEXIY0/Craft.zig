//! A chunk's visual representation.
//!
//! All the work happens in the meshing module, on worker threads: this is only
//! the part that has to run on the thread that owns the OpenGL context, i.e.
//! handing the finished vertex buffers to the driver and drawing them.

const std = @import("std");
const rl = @import("raylib");
const coord = @import("coord");
const terrain = @import("terrain");
const meshing = @import("meshing");
const tracy = @import("tracy");

const chunk = terrain.chunk;

const ChunkModel = @This();

/// The uploaded geometry of one 16 block section of the chunk
pub const Section = struct {
    /// Opaque geometry
    meshes: []rl.Mesh = &.{},
    /// Geometry drawn on the transparent layer
    transparent_meshes: []rl.Mesh = &.{},

    /// True when the section has nothing to draw at all, which is the common
    /// case: most sections of most chunks are solid rock or plain air
    pub inline fn isEmpty(self: Section) bool {
        return self.meshes.len == 0 and self.transparent_meshes.len == 0;
    }
};

/// Geometry, one entry per section of the chunk, bottom first
sections: [chunk.section_count]Section,
/// Which faces of each section can see each other, for the visibility walk
connectivity: [chunk.section_count]meshing.visibility.Connectivity = @splat(.{}),

/// Uploads a finished chunk mesh to the gpu.
/// Takes ownership of `data`, whatever happens.
pub fn upload(alloc: std.mem.Allocator, data: meshing.MeshData) !ChunkModel {
    const zone = tracy.Zone.begin(.{
        .name = "Chunk model upload",
        .src = @src(),
        .color = .green,
    });
    defer zone.end();

    var model: ChunkModel = .{
        .sections = @splat(.{}),
        .connectivity = data.connectivity,
    };

    // Every allocation happens before a single buffer changes hands, so that a
    // failure here leaves the mesh entirely owned by `data` and freeing it once
    // is correct
    for (data.sections, &model.sections) |source, *section| {
        section.meshes = allocMeshes(alloc, source.solid.len) catch |err| {
            freeMeshArrays(alloc, &model);
            data.deinit();
            return err;
        };
        section.transparent_meshes = allocMeshes(alloc, source.transparent.len) catch |err| {
            freeMeshArrays(alloc, &model);
            data.deinit();
            return err;
        };
    }

    // Talking to the driver needs a window, which a headless run (tests, or a
    // client that has not opened its window yet) does not have. The mesh is
    // still built and owned, it just stays on the cpu side.
    const can_upload = rl.isWindowReady();

    // From here on the vertex buffers belong to the meshes, and nothing fails
    for (data.sections, &model.sections) |source, *section| {
        for (source.solid, section.meshes) |part, *mesh| {
            mesh.* = meshFromPart(part);
            if (can_upload)
                rl.uploadMesh(mesh, false);
        }
        for (source.transparent, section.transparent_meshes) |part, *mesh| {
            mesh.* = meshFromPart(part);
            if (can_upload)
                rl.uploadMesh(mesh, false);
        }

        // Only the (now empty) part arrays are left to free
        data.alloc.free(source.solid);
        data.alloc.free(source.transparent);
    }

    return model;
}

/// Allocates the mesh array of one layer of one section
fn allocMeshes(alloc: std.mem.Allocator, count: usize) ![]rl.Mesh {
    if (count == 0)
        return &.{};
    return alloc.alloc(rl.Mesh, count);
}

/// Frees the mesh arrays of a model that does not own any vertex buffer yet
fn freeMeshArrays(alloc: std.mem.Allocator, model: *ChunkModel) void {
    for (&model.sections) |*section| {
        alloc.free(section.meshes);
        alloc.free(section.transparent_meshes);
        section.* = .{};
    }
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

/// Transform of the chunk, shared by all of its sections: the geometry carries
/// its real height, so a section needs no offset of its own
inline fn transformOf(pos: coord.Chunk) rl.Matrix {
    return .translate(
        @floatFromInt(pos.x * chunk.width),
        0,
        @floatFromInt(pos.z * chunk.width),
    );
}

/// Draws the opaque geometry of one section
pub fn drawSection(self: ChunkModel, section: usize, pos: coord.Chunk, material: *const rl.Material) void {
    const transform = transformOf(pos);
    for (self.sections[section].meshes) |mesh|
        rl.drawMesh(mesh, material.*, transform);
}

/// Draws the transparent geometry of one section
pub fn drawSectionTransparent(self: ChunkModel, section: usize, pos: coord.Chunk, material: *const rl.Material) void {
    const transform = transformOf(pos);
    for (self.sections[section].transparent_meshes) |mesh|
        rl.drawMesh(mesh, material.*, transform);
}

/// Amount of draw calls one section costs, for the debug overlay. Every mesh
/// part is a full material bind, so this is the number that has to stay small
pub fn sectionDrawCallCount(self: ChunkModel, section: usize) usize {
    return self.sections[section].meshes.len + self.sections[section].transparent_meshes.len;
}

/// Amount of triangles one section draws, for the debug overlay
pub fn sectionTriangleCount(self: ChunkModel, section: usize) usize {
    var total: usize = 0;
    for (self.sections[section].meshes) |mesh|
        total += @intCast(mesh.triangleCount);
    for (self.sections[section].transparent_meshes) |mesh|
        total += @intCast(mesh.triangleCount);
    return total;
}

/// Amount of triangles of the whole chunk
pub fn triangleCount(self: ChunkModel) usize {
    var total: usize = 0;
    for (0..chunk.section_count) |section|
        total += self.sectionTriangleCount(section);
    return total;
}

pub fn deinit(self: ChunkModel, alloc: std.mem.Allocator) void {
    for (self.sections) |section| {
        for (section.meshes) |mesh|
            mesh.unload();
        for (section.transparent_meshes) |mesh|
            mesh.unload();
        alloc.free(section.meshes);
        alloc.free(section.transparent_meshes);
    }
}
