//! View frustum of the camera, used to skip chunks that are behind the player.
//!
//! Culling a chunk costs six dot products against its bounding box, which is
//! nothing compared to a draw call, and the chunk store hands the coordinates
//! over as a dense array, so the whole pass is a linear scan.

const std = @import("std");
const rl = @import("raylib");
const coord = @import("coord");

const terrain = @import("terrain");
const chunk = terrain.chunk;

const Frustum = @This();

/// The same near and far planes rlgl builds its own projection with
/// (RL_CULL_DISTANCE_NEAR and RL_CULL_DISTANCE_FAR). They have to match: a
/// nearer far plane here culls sections the renderer would have drawn, which is
/// invisible at a small view distance and a hole in the world at a large one.
const near_plane = 0.05;
const far_plane = 4000.0;

/// The six planes, as (a, b, c, d) with a*x + b*y + c*z + d >= 0 inside
planes: [6][4]f32,

/// A frustum that contains everything
pub const everything: Frustum = .{ .planes = @splat(@splat(0)) };

/// Extracts the frustum planes of a view projection matrix
pub fn fromMatrix(m: rl.Matrix) Frustum {
    var self: Frustum = undefined;

    // Gribb & Hartmann plane extraction: each plane is the w row of the matrix
    // plus or minus one of the other rows
    self.planes[0] = .{ m.m3 + m.m0, m.m7 + m.m4, m.m11 + m.m8, m.m15 + m.m12 }; // left
    self.planes[1] = .{ m.m3 - m.m0, m.m7 - m.m4, m.m11 - m.m8, m.m15 - m.m12 }; // right
    self.planes[2] = .{ m.m3 + m.m1, m.m7 + m.m5, m.m11 + m.m9, m.m15 + m.m13 }; // bottom
    self.planes[3] = .{ m.m3 - m.m1, m.m7 - m.m5, m.m11 - m.m9, m.m15 - m.m13 }; // top
    self.planes[4] = .{ m.m3 + m.m2, m.m7 + m.m6, m.m11 + m.m10, m.m15 + m.m14 }; // near
    self.planes[5] = .{ m.m3 - m.m2, m.m7 - m.m6, m.m11 - m.m10, m.m15 - m.m14 }; // far

    for (&self.planes) |*plane| {
        const length = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
        if (length > 0) {
            for (plane) |*component|
                component.* /= length;
        }
    }

    return self;
}

/// Frustum of a camera, for a viewport of the given aspect ratio
pub fn fromCamera(camera: rl.Camera, aspect: f32) Frustum {
    if (camera.projection != .perspective)
        return everything;

    const view: rl.Matrix = .lookAt(camera.position, camera.target, camera.up);
    const projection: rl.Matrix = .perspective(
        std.math.degreesToRadians(camera.fovy),
        aspect,
        near_plane,
        far_plane,
    );

    return .fromMatrix(view.multiply(projection));
}

/// True if the axis aligned box is at least partly inside the frustum
pub fn containsBox(self: Frustum, min: [3]f32, max: [3]f32) bool {
    for (self.planes) |plane| {
        // Corner of the box that is the furthest along the plane normal: if
        // even that one is behind the plane, the whole box is
        const corner: [3]f32 = .{
            if (plane[0] >= 0) max[0] else min[0],
            if (plane[1] >= 0) max[1] else min[1],
            if (plane[2] >= 0) max[2] else min[2],
        };

        const distance = plane[0] * corner[0] + plane[1] * corner[1] + plane[2] * corner[2] + plane[3];
        if (distance < 0)
            return false;
    }
    return true;
}

/// True if any part of the chunk column is visible
pub fn containsChunk(self: Frustum, coords: coord.Chunk) bool {
    const x: f32 = @floatFromInt(coords.x * chunk.width);
    const z: f32 = @floatFromInt(coords.z * chunk.width);

    return self.containsBox(
        .{ x, 0, z },
        .{ x + chunk.width, chunk.height, z + chunk.width },
    );
}

/// True if any part of one 16 block section of a chunk is visible.
/// A chunk is 128 blocks tall, so testing it whole keeps most of the underground
/// in the frame no matter where the camera looks: the section is the box that is
/// actually worth culling.
pub fn containsSection(self: Frustum, coords: coord.Chunk, section: usize) bool {
    const x: f32 = @floatFromInt(coords.x * chunk.width);
    const z: f32 = @floatFromInt(coords.z * chunk.width);
    const y: f32 = @floatFromInt(section * chunk.section_height);

    return self.containsBox(
        .{ x, y, z },
        .{ x + chunk.width, y + chunk.section_height, z + chunk.width },
    );
}

test "chunks behind the camera are culled" {
    const camera: rl.Camera = .{
        // Standing in the middle of chunk 0,0, looking towards +x
        .position = .init(8, 64, 8),
        .target = .init(100, 64, 8),
        .up = .init(0, 1, 0),
        .fovy = 60,
        .projection = .perspective,
    };

    const frustum: Frustum = .fromCamera(camera, 16.0 / 9.0);

    // The chunk we stand in, and the ones ahead
    try std.testing.expect(frustum.containsChunk(.{ .x = 0, .z = 0 }));
    try std.testing.expect(frustum.containsChunk(.{ .x = 1, .z = 0 }));
    try std.testing.expect(frustum.containsChunk(.{ .x = 4, .z = 0 }));

    // Behind the camera
    try std.testing.expect(!frustum.containsChunk(.{ .x = -3, .z = 0 }));
    try std.testing.expect(!frustum.containsChunk(.{ .x = -8, .z = 0 }));

    // Far off to the side
    try std.testing.expect(!frustum.containsChunk(.{ .x = 1, .z = 12 }));
    try std.testing.expect(!frustum.containsChunk(.{ .x = 1, .z = -12 }));

    // Way beyond the far plane
    try std.testing.expect(!frustum.containsChunk(.{ .x = 200, .z = 0 }));
}

test "the empty frustum contains everything" {
    try std.testing.expect(everything.containsChunk(.{ .x = 1000, .z = -1000 }));
}
