//! A world that is generated locally instead of being sent by a server.
//!
//! The client normally receives chunks over the network. In single player it
//! receives them from `worldgen` instead, and nothing downstream notices: the
//! generator writes into the very same chunk store arrays the network path
//! writes into, and the meshing pipeline picks the chunks up the same way.

const std = @import("std");
const coord = @import("coord");
const terrain = @import("terrain");
const worldgen = @import("worldgen");
const tracy = @import("tracy");

const chunk = terrain.chunk;

const Singleplayer = @This();

/// How far chunks are generated around the player, in chunks
pub const default_view_distance = 8;

/// Chunks generated per update. Generating one takes about a millisecond, and
/// the mesher behind it is the real bottleneck anyway.
const chunks_per_update = 2;

alloc: std.mem.Allocator,
/// The world being filled
world: *terrain.World,
/// Terrain generator
generator: worldgen.Generator,
/// Radius of generated chunks around the player
view_distance: i32 = default_view_distance,

pub fn init(alloc: std.mem.Allocator, world: *terrain.World, seed: u64) Singleplayer {
    return .{
        .alloc = alloc,
        .world = world,
        .generator = .init(seed),
    };
}

/// A safe place to drop the player in: dry land, close to the origin.
/// Dropping them wherever the origin happens to be would sometimes mean the
/// middle of an ocean, and the player can not swim yet.
pub fn spawnPosition(self: *const Singleplayer) !coord.Vec3f {
    const step = 16;
    const attempts = 24;

    var best: coord.Block = .{ .x = 0, .y = worldgen.sea_surface + 1, .z = 0 };

    // Walk outwards in a square spiral until the ground is above the water
    for (0..attempts) |attempt| {
        const ring: i32 = @intCast(attempt / 4);
        const side: i32 = @intCast(attempt % 4);

        const offset: coord.Block = switch (side) {
            0 => .{ .x = ring * step, .y = 0, .z = 0 },
            1 => .{ .x = 0, .y = 0, .z = ring * step },
            2 => .{ .x = -ring * step, .y = 0, .z = 0 },
            else => .{ .x = 0, .y = 0, .z = -ring * step },
        };

        const height = try self.generator.surfaceHeight(self.alloc, offset);
        if (height > worldgen.sea_surface + 1) {
            best = .{ .x = offset.x, .y = height, .z = offset.z };
            break;
        }
    }

    return .{
        .x = @as(f64, @floatFromInt(best.x)) + 0.5,
        .y = @floatFromInt(best.y + 1),
        .z = @as(f64, @floatFromInt(best.z)) + 0.5,
    };
}

/// Generates what is missing around the player, and drops what is too far away
pub fn update(self: *Singleplayer, player: coord.Vec3f) !void {
    const zone = tracy.Zone.begin(.{
        .name = "World generation",
        .src = @src(),
        .color = .green1,
    });
    defer zone.end();

    const center = player.getBlock().getChunk();

    try self.generateAround(center);
    self.unloadFarChunks(center);
}

/// Generates up to `chunks_per_update` missing chunks, closest to the player
/// first, so that the world grows outwards from where they stand
fn generateAround(self: *Singleplayer, center: coord.Chunk) !void {
    var generated: usize = 0;

    var ring: i32 = 0;
    while (ring <= self.view_distance) : (ring += 1) {
        var dx: i32 = -ring;
        while (dx <= ring) : (dx += 1) {
            var dz: i32 = -ring;
            while (dz <= ring) : (dz += 1) {
                // Only the edge of the ring, the inside was done already
                if (@abs(dx) != ring and @abs(dz) != ring)
                    continue;

                const coords: coord.Chunk = .{ .x = center.x + dx, .z = center.z + dz };
                if (self.world.getChunk(coords) != null)
                    continue;

                try self.generateChunk(coords);

                generated += 1;
                if (generated >= chunks_per_update)
                    return;
            }
        }
    }
}

/// Generates one chunk straight into the store
fn generateChunk(self: *Singleplayer, coords: coord.Chunk) !void {
    const slot = try self.world.store.load(coords);

    self.generator.generateChunk(coords, .{
        .ids = self.world.store.ids.at(slot),
        .skylight = self.world.store.skylight.at(slot),
    });

    self.world.commitChunkData(slot);
}

/// Frees the chunks the player walked away from
fn unloadFarChunks(self: *Singleplayer, center: coord.Chunk) void {
    // Some hysteresis, so that walking along a border does not load and unload
    // the same chunk every other frame
    const limit = self.view_distance + 2;

    var far: ?coord.Chunk = null;
    for (self.world.store.live.items) |slot| {
        const coords = self.world.store.coords.get(slot);
        if (@abs(coords.x - center.x) > limit or @abs(coords.z - center.z) > limit) {
            far = coords;
            break;
        }
    }

    if (far) |coords|
        self.world.unloadChunk(coords);
}

test "the world grows around the player" {
    const alloc = std.testing.allocator;

    var world: terrain.World = try .init(alloc);
    defer world.deinit();

    var singleplayer: Singleplayer = .init(alloc, &world, 42);
    singleplayer.view_distance = 2;

    const spawn = try singleplayer.spawnPosition();

    // The player starts on dry land, not at the bottom of an ocean
    try std.testing.expect(spawn.y > worldgen.sea_surface);

    // The chunk the player stands in comes first
    try singleplayer.update(spawn);
    try std.testing.expect(world.getChunk(.{ .x = 0, .z = 0 }) != null);

    // Everything within the view distance shows up eventually
    for (0..64) |_|
        try singleplayer.update(spawn);

    var cx: i32 = -2;
    while (cx <= 2) : (cx += 1) {
        var cz: i32 = -2;
        while (cz <= 2) : (cz += 1) {
            try std.testing.expect(world.getChunk(.{ .x = cx, .z = cz }) != null);
        }
    }

    // Walking away drops what is behind
    const far: coord.Vec3f = .{ .x = 16 * 40, .y = spawn.y, .z = 0 };
    for (0..64) |_|
        try singleplayer.update(far);

    try std.testing.expectEqual(@as(?terrain.Slot, null), world.getChunk(.{ .x = 0, .z = 0 }));
}
