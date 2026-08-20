//! Turns one chunk snapshot into one chunk mesh.
//!
//! A `Mesher` owns the scratch space the two passes need (bit masks, merge
//! keys, the list of blocks that need the slow path). Every worker thread keeps
//! one around and reuses it for every chunk, so meshing a chunk allocates
//! nothing but the output buffers.

const std = @import("std");
const tracy = @import("tracy");

const MeshData = @import("MeshData.zig");
const Snapshot = @import("Snapshot.zig");
const Layers = @import("Layers.zig");
const greedy = @import("greedy.zig");
const special = @import("special.zig");
const visibility = @import("visibility.zig");

const Mesher = @This();

/// Allocator of the produced vertex buffers, given by the frontend so that the
/// renderer can take them over without a copy
mesh_alloc: std.mem.Allocator,
/// Allocator of the internal scratch space
alloc: std.mem.Allocator,
/// Scratch space, big enough that it lives on the heap
scratch: *greedy.Scratch,
/// Scratch space of the section connectivity pass
visibility_scratch: *visibility.Scratch,

pub fn init(alloc: std.mem.Allocator, mesh_alloc: std.mem.Allocator) !Mesher {
    const scratch = try alloc.create(greedy.Scratch);
    errdefer alloc.destroy(scratch);
    scratch.* = .{};

    const visibility_scratch = try alloc.create(visibility.Scratch);
    visibility_scratch.* = .{};

    return .{
        .alloc = alloc,
        .mesh_alloc = mesh_alloc,
        .scratch = scratch,
        .visibility_scratch = visibility_scratch,
    };
}

pub fn deinit(self: *Mesher) void {
    self.scratch.deinit(self.alloc);
    self.alloc.destroy(self.scratch);
    self.alloc.destroy(self.visibility_scratch);
}

/// Meshes a chunk. The caller owns the returned mesh.
pub fn run(self: *Mesher, snapshot: *const Snapshot) !MeshData {
    const zone = tracy.Zone.begin(.{
        .name = "Chunk meshing",
        .src = @src(),
        .color = .yellow,
    });
    defer zone.end();

    var layers: Layers = .init(self.mesh_alloc);
    errdefer layers.deinit();

    try greedy.run(self.scratch, self.alloc, snapshot, &layers);
    try special.run(snapshot, self.scratch.special.items, &layers);

    var result = try layers.finish(self.mesh_alloc);
    result.connectivity = visibility.run(self.visibility_scratch, snapshot);
    return result;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;
const coord = @import("coord");
const blocks = @import("blocks");
const terrain = @import("terrain");
const chunk = terrain.chunk;

/// An empty chunk under full sky light, with no neighbor
fn testSnapshot(alloc: std.mem.Allocator) !*Snapshot {
    const snapshot = try alloc.create(Snapshot);
    snapshot.* = .{};
    snapshot.clear();
    return snapshot;
}

fn setBlock(snapshot: *Snapshot, x: usize, y: usize, z: usize, block_id: u8) void {
    snapshot.idColumnMut(x, z)[y] = block_id;
}

fn setSkylight(snapshot: *Snapshot, x: usize, y: usize, z: usize, level: u4) void {
    snapshot.lightColumnMut(x, z)[y].skylight = level;
}

/// Amount of quads of a mesh
fn quadCount(result: MeshData) u32 {
    return result.vertexCount() / 4;
}

/// Meshes a snapshot with a throwaway mesher
fn mesh(alloc: std.mem.Allocator, snapshot: *const Snapshot) !MeshData {
    var mesher: Mesher = try .init(alloc, alloc);
    defer mesher.deinit();
    return mesher.run(snapshot);
}

test "an empty chunk produces no geometry" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 0), result.vertexCount());
    try testing.expectEqual(@as(usize, 0), result.partCount(.solid));
    try testing.expectEqual(@as(usize, 0), result.partCount(.transparent));
}

test "a lone block is a cube" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    setBlock(snapshot, 4, 40, 9, blocks.idOf(.stone));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 6), quadCount(result));
    try testing.expectEqual(@as(usize, 1), result.partCount(.solid));

    // Every vertex is on the surface of that one block, and every uv stays
    // inside a single tile
    const part = result.onlyPart(.solid);
    var i: usize = 0;
    while (i < part.vertex_count) : (i += 1) {
        const x = part.positions[i * 3 + 0];
        const y = part.positions[i * 3 + 1];
        const z = part.positions[i * 3 + 2];
        try testing.expect(x >= 4.0 and x <= 5.0);
        try testing.expect(y >= 40.0 and y <= 41.0);
        try testing.expect(z >= 9.0 and z <= 10.0);

        try testing.expect(part.uvs[i * 2 + 0] >= 0.0 and part.uvs[i * 2 + 0] <= 1.0);
        try testing.expect(part.uvs[i * 2 + 1] >= 0.0 and part.uvs[i * 2 + 1] <= 1.0);
    }
}

test "neighboring blocks merge and hide each other" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    // Two blocks side by side: the faces between them are gone, and each pair
    // of remaining coplanar faces becomes a single quad
    setBlock(snapshot, 4, 40, 9, blocks.idOf(.stone));
    setBlock(snapshot, 5, 40, 9, blocks.idOf(.stone));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 6), quadCount(result));

    // The top quad spans two blocks along x, so its uv goes from 0 to 2
    var widest: f32 = 0;
    for (result.onlyPart(.solid).uvs) |uv|
        widest = @max(widest, uv);
    try testing.expectEqual(@as(f32, 2.0), widest);
}

test "a plate of blocks collapses into six quads" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    for (2..6) |x| {
        for (3..7) |z|
            setBlock(snapshot, x, 20, z, blocks.idOf(.stone));
    }

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    // 16 blocks, 96 faces, 32 of them hidden: 6 quads once merged
    try testing.expectEqual(@as(u32, 6), quadCount(result));
}

test "a full chunk only keeps its shell" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    @memset(&snapshot.ids, blocks.idOf(.stone));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    // 32768 blocks come out as a shell: one quad for the top, one for the
    // bottom, and one per side per section, because a quad may not span two
    // sections. That is the price of being able to drop a section on its own,
    // and it is a good trade: four extra quads per section buys the renderer the
    // right to skip everything below the surface.
    try testing.expectEqual(@as(u32, 2 + 4 * chunk.section_count), quadCount(result));

    // Every section of a solid chunk carries its own four walls
    for (result.sections, 0..) |section, index| {
        const walls = section.solid[0].vertex_count / 4;
        try testing.expect(walls >= 4);
        _ = index;
    }
}

test "a quad never spans two sections" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    // A pillar tall enough to cross several section borders
    for (0..chunk.height) |y|
        setBlock(snapshot, 4, y, 9, blocks.idOf(.stone));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    // Each section only ever holds geometry of its own 16 blocks
    for (result.sections, 0..) |section, index| {
        const low: f32 = @floatFromInt(index * chunk.section_height);
        const high = low + chunk.section_height;

        for (section.solid) |part| {
            var i: usize = 0;
            while (i < part.vertex_count) : (i += 1) {
                const y = part.positions[i * 3 + 1];
                try testing.expect(y >= low and y <= high);
            }
        }
    }
}

test "loaded neighbors hide the faces at the chunk border" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    @memset(&snapshot.ids, blocks.idOf(.stone));

    // The chunk to the west is solid too
    for (&snapshot.edge_ids[@intFromEnum(coord.Face.west)]) |*column|
        @memset(column, blocks.idOf(.stone));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    // The west wall is not drawn any more: one wall per section is gone
    try testing.expectEqual(@as(u32, 2 + 3 * chunk.section_count), quadCount(result));
}

test "different blocks and different light do not merge" {
    const alloc = testing.allocator;

    {
        const snapshot = try testSnapshot(alloc);
        defer alloc.destroy(snapshot);

        setBlock(snapshot, 4, 40, 9, blocks.idOf(.stone));
        setBlock(snapshot, 5, 40, 9, blocks.idOf(.dirt));

        const result = try mesh(alloc, snapshot);
        defer result.deinit();

        // Nothing merges across block types, but the faces between the two
        // blocks are still hidden: 5 quads each
        try testing.expectEqual(@as(u32, 10), quadCount(result));
    }

    {
        const snapshot = try testSnapshot(alloc);
        defer alloc.destroy(snapshot);

        setBlock(snapshot, 4, 40, 9, blocks.idOf(.stone));
        setBlock(snapshot, 5, 40, 9, blocks.idOf(.stone));
        // The block above the second one is in the shade, so the two top faces
        // have a different color and can not be merged
        setSkylight(snapshot, 5, 41, 9, 4);

        const result = try mesh(alloc, snapshot);
        defer result.deinit();

        try testing.expectEqual(@as(u32, 7), quadCount(result));
    }
}

test "transparent blocks go to their own layer" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    setBlock(snapshot, 4, 40, 9, blocks.idOf(.stone));
    setBlock(snapshot, 8, 40, 9, blocks.idOf(.glass));
    setBlock(snapshot, 9, 40, 9, blocks.idOf(.glass));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.partCount(.solid));
    try testing.expectEqual(@as(usize, 1), result.partCount(.transparent));

    // Stone: 6 quads
    try testing.expectEqual(@as(u32, 6 * 4), result.onlyPart(.solid).vertex_count);
    // Glass does not hide glass, so the two faces that touch are still drawn,
    // one from each side. The six outer faces merge across the two blocks, so
    // that makes 6 + 2 quads.
    try testing.expectEqual(@as(u32, 8 * 4), result.onlyPart(.transparent).vertex_count);
}

test "an opaque neighbor still hides a transparent block's face" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    setBlock(snapshot, 4, 40, 9, blocks.idOf(.glass));
    setBlock(snapshot, 5, 40, 9, blocks.idOf(.stone));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    // Glass loses the face towards the stone, the stone loses the one towards
    // the glass only if the glass occluded, which it does not
    try testing.expectEqual(@as(u32, 5 * 4), result.onlyPart(.transparent).vertex_count);
    try testing.expectEqual(@as(u32, 6 * 4), result.onlyPart(.solid).vertex_count);
}

test "blocks with their own model take the per block path" {
    const alloc = testing.allocator;

    {
        // A slab: four sides, a top and a bottom, and the sides are half height
        const snapshot = try testSnapshot(alloc);
        defer alloc.destroy(snapshot);

        setBlock(snapshot, 4, 40, 9, blocks.idOf(.step));

        const result = try mesh(alloc, snapshot);
        defer result.deinit();

        try testing.expectEqual(@as(u32, 6), quadCount(result));

        const part = result.onlyPart(.solid);
        var highest: f32 = 0;
        var i: usize = 0;
        while (i < part.vertex_count) : (i += 1)
            highest = @max(highest, part.positions[i * 3 + 1]);
        try testing.expectEqual(@as(f32, 40.5), highest);
    }

    {
        // A plant: two crossed quads, drawn from both sides
        const snapshot = try testSnapshot(alloc);
        defer alloc.destroy(snapshot);

        setBlock(snapshot, 4, 40, 9, blocks.idOf(.tallgrass));

        const result = try mesh(alloc, snapshot);
        defer result.deinit();

        try testing.expectEqual(@as(u32, 4), quadCount(result));
        // Tall grass is tinted, and it is transparent
        try testing.expectEqual(@as(usize, 1), result.partCount(.transparent));
        try testing.expectEqual(@as(usize, 0), result.partCount(.solid));
        try testing.expect(result.onlyPart(.transparent).colors[0] != 0xff);
    }

    {
        // A still liquid is a single surface quad
        const snapshot = try testSnapshot(alloc);
        defer alloc.destroy(snapshot);

        // Block 9 is still water (a surface), block 8 is the flowing variant,
        // which is a plain cube
        try testing.expectEqual(blocks.Model.liquid_still, blocks.modelOf(9));
        setBlock(snapshot, 4, 40, 9, 9);
        setBlock(snapshot, 4, 39, 9, 8);

        const result = try mesh(alloc, snapshot);
        defer result.deinit();

        try testing.expectEqual(@as(usize, 1), result.partCount(.transparent));
        // One surface quad, plus five faces of the block below: the face the
        // two of them share is hidden, the way liquids do
        try testing.expectEqual(@as(u32, 6), quadCount(result));
    }
}

test "liquids hide the faces they share" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    // A three by three by three cube of water: only the shell is drawn, and
    // the block in the middle disappears entirely
    for (4..7) |x| {
        for (4..7) |y| {
            for (4..7) |z|
                setBlock(snapshot, x, y, z, 8);
        }
    }

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    // Six faces of nine blocks each, merged into six quads
    try testing.expectEqual(@as(u32, 6), quadCount(result));

    // Glass is transparent too, but it is not a liquid: it keeps its faces
    const glass = try testSnapshot(alloc);
    defer alloc.destroy(glass);

    setBlock(glass, 4, 40, 9, blocks.idOf(.glass));
    setBlock(glass, 5, 40, 9, blocks.idOf(.glass));

    const glass_result = try mesh(alloc, glass);
    defer glass_result.deinit();

    try testing.expectEqual(@as(u32, 8), quadCount(glass_result));
}

test "a slab under a solid block loses its top face only when covered" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    setBlock(snapshot, 4, 40, 9, blocks.idOf(.step));
    // Solid block right next to it hides the slab's side
    setBlock(snapshot, 5, 40, 9, blocks.idOf(.stone));

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    // Slab: 5 quads left (one side hidden). Stone: 6, since the slab does not
    // fill its face
    try testing.expectEqual(@as(u32, 11), quadCount(result));
}

test "every emitted index stays inside its part" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    // A checkerboard is the worst case for merging: nothing merges at all
    var rng = std.Random.DefaultPrng.init(@intCast(std.testing.random_seed));
    const random = rng.random();
    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            for (0..chunk.height) |y| {
                if ((x + y + z) % 2 == 0)
                    setBlock(snapshot, x, y, z, random.intRangeAtMost(u8, 1, 5));
            }
        }
    }

    const result = try mesh(alloc, snapshot);
    defer result.deinit();

    try testing.expect(result.partCount(.solid) > 1);

    var it = result.parts(.solid);
    while (it.next()) |part| {
        try testing.expectEqual(part.vertex_count * 3, @as(u32, @intCast(part.positions.len)));
        try testing.expectEqual(part.vertex_count * 2, @as(u32, @intCast(part.uvs.len)));
        try testing.expectEqual(part.vertex_count * 2, @as(u32, @intCast(part.tiles.len)));
        try testing.expectEqual(part.vertex_count * 4, @as(u32, @intCast(part.colors.len)));
        for (part.indices) |index|
            try testing.expect(index < part.vertex_count);
    }
}
