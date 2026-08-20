//! Drawing many chunk sections without telling the driver the same thing twice.
//!
//! `rl.drawMesh` is written to draw *one* mesh of *any* material: every call
//! binds the shader, uploads four matrices and the diffuse colour, binds every
//! texture of the material, binds the vertex array, draws, and then unbinds all
//! of it again. That is around fifteen calls into the driver for one draw, and a
//! frame of terrain is a few hundred draws — with the same shader and the same
//! texture every single time.
//!
//! Measured on this project (seed 4242, no gpu, sections culled by the
//! visibility walk), the cost of a draw was about 25 microseconds, where a few
//! is the norm. It also barely moved when the window shrank to a twenty fifth of
//! the pixels, which is what says the time went to talking to the driver rather
//! than to filling triangles.
//!
//! So the state is split by how often it really changes:
//!
//!   per frame:   shader, texture, diffuse colour, view and projection
//!   per chunk:   the model matrix and the matrices derived from it
//!   per section: bind the vertex array and draw
//!
//! Nothing here changes what ends up on screen: it is the same geometry with the
//! same uniforms, just uploaded once instead of once per section.

const std = @import("std");
const rl = @import("raylib");
const coord = @import("coord");
const terrain = @import("terrain");

const chunk = terrain.chunk;
const ChunkModel = @import("ChunkModel.zig");

const ChunkBatch = @This();

/// Shader uniform slot, or null when this shader does not have that uniform
const Slot = ?i32;

/// Material every chunk is drawn with
material: rl.Material,
/// Camera matrices, constant for the whole frame
view: rl.Matrix,
projection: rl.Matrix,

// The uniform slots, looked up once instead of per draw
loc_mvp: Slot,
loc_model: Slot,
loc_view: Slot,
loc_projection: Slot,
loc_normal: Slot,
loc_colour: Slot,

/// True while the batch owns the driver's state
open: bool = false,

/// Reads a shader uniform slot, which raylib marks as absent with -1
fn slotOf(shader: rl.Shader, index: rl.ShaderLocationIndex) Slot {
    const location = shader.locs[@intCast(@intFromEnum(index))];
    return if (location < 0) null else location;
}

/// Binds everything a frame's worth of chunks has in common
pub fn begin(material: *const rl.Material) ChunkBatch {
    const shader = material.shader;

    var self: ChunkBatch = .{
        .material = material.*,
        .view = rl.gl.rlGetMatrixModelview(),
        .projection = rl.gl.rlGetMatrixProjection(),
        .loc_mvp = slotOf(shader, .matrix_mvp),
        .loc_model = slotOf(shader, .matrix_model),
        .loc_view = slotOf(shader, .matrix_view),
        .loc_projection = slotOf(shader, .matrix_projection),
        .loc_normal = slotOf(shader, .matrix_normal),
        .loc_colour = slotOf(shader, .color_diffuse),
    };

    rl.gl.rlEnableShader(shader.id);
    self.open = true;

    if (self.loc_view) |location|
        rl.gl.rlSetUniformMatrix(location, self.view);
    if (self.loc_projection) |location|
        rl.gl.rlSetUniformMatrix(location, self.projection);

    // The diffuse colour and the terrain texture are the same for every chunk
    const map = self.material.maps[0];
    if (self.loc_colour) |location| {
        const colour: [4]f32 = .{
            @as(f32, @floatFromInt(map.color.r)) / 255.0,
            @as(f32, @floatFromInt(map.color.g)) / 255.0,
            @as(f32, @floatFromInt(map.color.b)) / 255.0,
            @as(f32, @floatFromInt(map.color.a)) / 255.0,
        };
        rl.gl.rlSetUniform(location, &colour, @intFromEnum(rl.ShaderUniformDataType.vec4), 1);
    }

    if (map.texture.id > 0) {
        rl.gl.rlActiveTextureSlot(0);
        rl.gl.rlEnableTexture(map.texture.id);

        const slot: i32 = 0;
        const sampler = shader.locs[@intCast(@intFromEnum(rl.ShaderLocationIndex.map_albedo))];
        if (sampler >= 0)
            rl.gl.rlSetUniform(sampler, &slot, @intFromEnum(rl.ShaderUniformDataType.int), 1);
    }

    return self;
}

/// Moves the batch to a chunk. Every section drawn after this belongs to it.
pub fn beginChunk(self: *const ChunkBatch, pos: coord.Chunk) void {
    const model: rl.Matrix = .translate(
        @floatFromInt(pos.x * chunk.width),
        0,
        @floatFromInt(pos.z * chunk.width),
    );

    if (self.loc_model) |location|
        rl.gl.rlSetUniformMatrix(location, model);
    if (self.loc_normal) |location|
        rl.gl.rlSetUniformMatrix(location, model.invert().transpose());
    if (self.loc_mvp) |location|
        rl.gl.rlSetUniformMatrix(location, model.multiply(self.view).multiply(self.projection));
}

/// Draws the opaque geometry of one section of the current chunk
pub fn drawSection(self: *const ChunkBatch, model: ChunkModel, section: usize) void {
    self.drawMeshes(model.sections[section].meshes);
}

/// Draws the transparent geometry of one section of the current chunk
pub fn drawSectionTransparent(self: *const ChunkBatch, model: ChunkModel, section: usize) void {
    self.drawMeshes(model.sections[section].transparent_meshes);
}

fn drawMeshes(self: *const ChunkBatch, meshes: []const rl.Mesh) void {
    for (meshes) |mesh| {
        // Every attribute of a chunk mesh lives in its vertex array, which the
        // upload set up: binding it is the whole of the per draw state
        if (!rl.gl.rlEnableVertexArray(@intCast(mesh.vaoId))) {
            // No vertex array objects on this driver: let raylib do it the slow
            // way rather than draw nothing
            rl.drawMesh(mesh, self.material, rl.Matrix.identity());
            continue;
        }
        rl.gl.rlDrawVertexArrayElements(0, mesh.triangleCount * 3, null);
    }
}

/// Gives the driver's state back to raylib
pub fn end(self: *ChunkBatch) void {
    if (!self.open)
        return;
    self.open = false;

    rl.gl.rlDisableVertexArray();
    rl.gl.rlDisableVertexBuffer();
    rl.gl.rlDisableVertexBufferElement();
    rl.gl.rlActiveTextureSlot(0);
    rl.gl.rlDisableTexture();
    rl.gl.rlDisableShader();

    // raylib's own drawing carries on from these
    rl.gl.rlSetMatrixModelview(self.view);
    rl.gl.rlSetMatrixProjection(self.projection);
}
