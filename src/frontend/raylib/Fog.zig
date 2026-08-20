//! Distance fog, and the two numbers that make it look like the classic client
//! rather than like haze.
//!
//! The fade is linear and it is the colour of the sky, so geometry does not go
//! grey in the distance, it goes *sky*. It starts a quarter of the way out and
//! is complete exactly at the view distance, which is what hides the edge of
//! the loaded world: without it the terrain ends in a wall of cross sections
//! against open sky, and the world reads as a box rather than as somewhere that
//! carries on.
//!
//! The shader takes the fog depth from the w of the clip position, which for a
//! perspective projection is the distance along the view axis. That is the same
//! quantity the fixed function pipeline fogged with, and it costs no uniform
//! and no interpolated position.

const std = @import("std");
const rl = @import("raylib");

const Fog = @This();

/// Where the fade begins, as a fraction of the view distance
const start_fraction = 0.25;

/// Colour the world fades into
colour: [4]f32,
/// Where the fade starts and where it is complete, in blocks. An end of zero
/// is the shader's "no fog"
range: [2]f32 = .{ 0, 0 },

/// Uniform slots, looked up once. A shader without them simply draws no fog.
loc_colour: ?i32 = null,
loc_range: ?i32 = null,

/// Reads a uniform slot, which raylib marks as absent with -1
fn slotOf(shader: rl.Shader, name: [:0]const u8) ?i32 {
    const location = rl.getShaderLocation(shader, name);
    return if (location < 0) null else location;
}

pub fn init(shader: rl.Shader, sky: rl.Color) Fog {
    return .{
        .colour = .{
            @as(f32, @floatFromInt(sky.r)) / 255.0,
            @as(f32, @floatFromInt(sky.g)) / 255.0,
            @as(f32, @floatFromInt(sky.b)) / 255.0,
            1.0,
        },
        .loc_colour = slotOf(shader, "fogColor"),
        .loc_range = slotOf(shader, "fogRange"),
    };
}

/// Puts the far edge of the fade at the last chunk that is loaded
pub fn setViewDistance(self: *Fog, chunks: i32, chunk_width: i32) void {
    const blocks: f32 = @floatFromInt(@max(0, chunks * chunk_width));
    self.range = .{ blocks * start_fraction, blocks };
}

/// Uploads the two uniforms. The shader has to be the current one already,
/// which is what the chunk batch does before it draws anything.
pub fn upload(self: Fog) void {
    if (self.loc_colour) |location|
        rl.gl.rlSetUniform(location, &self.colour, @intFromEnum(rl.ShaderUniformDataType.vec4), 1);
    if (self.loc_range) |location|
        rl.gl.rlSetUniform(location, &self.range, @intFromEnum(rl.ShaderUniformDataType.vec2), 1);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the fade is complete exactly where the chunks stop" {
    var fog: Fog = .{ .colour = .{ 0, 0, 0, 1 } };
    fog.setViewDistance(8, 16);

    try testing.expectEqual(@as(f32, 128), fog.range[1]);
    try testing.expectEqual(@as(f32, 32), fog.range[0]);
}

test "a view distance of zero turns the fog off rather than dividing by it" {
    var fog: Fog = .{ .colour = .{ 0, 0, 0, 1 } };
    fog.setViewDistance(0, 16);

    // The shader reads an end of zero as "no fog", which is what keeps a world
    // that has not started yet from being drawn as a solid sheet of sky
    try testing.expectEqual(@as(f32, 0), fog.range[1]);
}
