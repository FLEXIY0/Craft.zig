//! Root of the world generation module.
//!
//! `Generator` turns (seed, chunk coordinates) into the block ids and light of
//! a chunk, writing straight into the flat arrays of the chunk store. It knows
//! nothing about the world, the renderer or the network, which is what lets the
//! client run it on its own (a generated single player world) or ignore it
//! entirely (a server sends the chunks instead).

const std = @import("std");

pub const noise = @import("noise.zig");
pub const Generator = @import("Generator.zig");

pub const sea_surface = Generator.sea_surface;

const terrain = @import("terrain");
const blocks = @import("blocks");
const coord = @import("coord");
const chunk = terrain.chunk;

/// Test helper: generates one chunk into freshly allocated arrays
fn generate(alloc: std.mem.Allocator, generator: *const Generator, coords: coord.Chunk) !Generator.Target {
    const target: Generator.Target = .{
        .ids = try alloc.create([chunk.volume]u8),
        .skylight = try alloc.create([chunk.nibble_len]u8),
    };
    generator.generateChunk(coords, target);
    return target;
}

fn free(alloc: std.mem.Allocator, target: Generator.Target) void {
    alloc.destroy(target.ids);
    alloc.destroy(target.skylight);
}

test "generation only depends on the seed and the coordinates" {
    const alloc = std.testing.allocator;

    const generator: Generator = .init(1234);
    const other: Generator = .init(1234);
    const different: Generator = .init(1235);

    const coords: coord.Chunk = .{ .x = 3, .z = -7 };

    const a = try generate(alloc, &generator, coords);
    defer free(alloc, a);
    const b = try generate(alloc, &other, coords);
    defer free(alloc, b);
    const c = try generate(alloc, &different, coords);
    defer free(alloc, c);

    // Same seed, same chunk, down to the last block
    try std.testing.expectEqualSlices(u8, a.ids, b.ids);
    try std.testing.expectEqualSlices(u8, a.skylight, b.skylight);

    // A different seed gives a different world
    try std.testing.expect(!std.mem.eql(u8, a.ids, c.ids));
}

test "the world is made of ground, sea and sky" {
    const alloc = std.testing.allocator;
    const generator: Generator = .init(20260818);

    const target = try generate(alloc, &generator, .{ .x = 0, .z = 0 });
    defer free(alloc, target);

    var grass: usize = 0;
    var stone: usize = 0;
    var water: usize = 0;

    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const column = target.ids[chunk.columnBase(x, z)..][0..chunk.height];

            // The world has a floor
            try std.testing.expectEqual(blocks.idOf(.bedrock), column[0]);

            for (column, 0..) |block, y| {
                switch (block) {
                    blocks.idOf(.grass) => {
                        grass += 1;
                        // Grass is always the top of the ground
                        try std.testing.expect(y + 1 < chunk.height);
                        try std.testing.expect(!blocks.isOpaqueCube(column[y + 1]));
                    },
                    blocks.idOf(.stone) => stone += 1,
                    8, 9 => {
                        water += 1;
                        // Water never floats above the sea line
                        try std.testing.expect(y <= sea_surface);
                    },
                    else => {},
                }
            }
        }
    }

    try std.testing.expect(stone > 1000);
    try std.testing.expect(grass + water > 100);
}

test "neighboring chunks line up" {
    const alloc = std.testing.allocator;
    const generator: Generator = .init(99);

    const left = try generate(alloc, &generator, .{ .x = 0, .z = 0 });
    defer free(alloc, left);
    const right = try generate(alloc, &generator, .{ .x = 1, .z = 0 });
    defer free(alloc, right);

    // The border columns of two chunks are two samples of one continuous
    // density field, so the ground can not jump between them
    for (0..chunk.width) |z| {
        const a = surfaceOf(left.ids, chunk.width - 1, z);
        const b = surfaceOf(right.ids, 0, z);
        const difference = @abs(@as(i32, @intCast(a)) - @as(i32, @intCast(b)));
        try std.testing.expect(difference <= 4);
    }
}

test "sky light reaches the ground and fades under it" {
    const alloc = std.testing.allocator;
    const generator: Generator = .init(5);

    const target = try generate(alloc, &generator, .{ .x = -2, .z = 4 });
    defer free(alloc, target);

    var lit_under_cover: usize = 0;

    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const base = chunk.columnBase(x, z);
            const column = target.ids[base..][0..chunk.height];

            // Above the world everything is in full daylight
            try std.testing.expectEqual(
                @as(u4, 15),
                terrain.ChunkStore.readNibble(target.skylight, base + chunk.height - 1),
            );

            // Find the roof of this column
            var y: usize = chunk.height;
            const covered = while (y > 0) {
                y -= 1;
                if (blocks.isOpaqueCube(column[y]))
                    break true;
            } else false;

            if (!covered)
                continue;

            // Light travels one block per level, so twenty blocks under the
            // roof it can not reach, whichever way around it goes
            if (y > 25) {
                try std.testing.expectEqual(
                    @as(u4, 0),
                    terrain.ChunkStore.readNibble(target.skylight, base + y - 20),
                );
            }

            // Right under the roof it can, if there is a way in from the side
            if (y > 1 and terrain.ChunkStore.readNibble(target.skylight, base + y - 1) > 0)
                lit_under_cover += 1;
        }
    }

    // Overhangs and cave mouths are lit, not pitch black: that is the whole
    // point of letting the light spread sideways
    try std.testing.expect(lit_under_cover > 0);
}

/// Highest non air block of a column
fn surfaceOf(ids: *const [chunk.volume]u8, x: usize, z: usize) usize {
    const column = ids[chunk.columnBase(x, z)..][0..chunk.height];
    var y: usize = chunk.height - 1;
    while (y > 0) : (y -= 1) {
        if (column[y] != 0)
            return y;
    }
    return 0;
}
