//! Terrain generation.
//!
//! The generator is a pure function of (seed, chunk coordinates): it never
//! looks at neighboring chunks and never mutates anything shared, so chunks can
//! be generated in any order, on any thread.
//!
//! It works the way the original beta generator does, which happens to be the
//! data oriented way too: instead of asking "what is at this block" 32768 times,
//! it samples a coarse 5x5x17 grid of density values and interpolates it into
//! the chunk's flat block array, one contiguous column at a time.

const std = @import("std");
const coord = @import("coord");
const blocks = @import("blocks");
const terrain = @import("terrain");

const chunk = terrain.chunk;
const noise = @import("noise.zig");
const Fbm = noise.Fbm;

const Generator = @This();

/// Topmost water block of the oceans
pub const sea_surface = 63;

/// Sample points of the density grid, horizontally (every 4 blocks)
const grid_xz = 5;
/// Sample points of the density grid, vertically (every 4 blocks).
/// Coarser than this and the interpolation turns hillsides into staircases.
const grid_y = 33;
/// Blocks between two horizontal samples
const cell_xz = chunk.width / (grid_xz - 1);
/// Blocks between two vertical samples
const cell_y = chunk.height / (grid_y - 1);

/// Block ids the generator places, resolved at comptime
const id = struct {
    const air: u8 = 0;
    const stone = blocks.idOf(.stone);
    const grass = blocks.idOf(.grass);
    const dirt = blocks.idOf(.dirt);
    const sand = blocks.idOf(.sand);
    const gravel = blocks.idOf(.gravel);
    const clay = blocks.idOf(.clay);
    const sandstone = blocks.idOf(.sandStone);
    const bedrock = blocks.idOf(.bedrock);
    const log = blocks.idOf(.log);
    const leaves = blocks.idOf(.leaves);
    const tallgrass = blocks.idOf(.tallgrass);
    const rose = blocks.idOf(.rose);
    const flower = blocks.idOf(.flower);
    const deadbush = blocks.idOf(.deadbush);
    const cactus = blocks.idOf(.cactus);
    const reeds = blocks.idOf(.reeds);
    const coal = blocks.idOf(.oreCoal);
    const iron = blocks.idOf(.oreIron);
    const gold = blocks.idOf(.oreGold);
    const diamond = blocks.idOf(.oreDiamond);
    const redstone = blocks.idOf(.oreRedstone);
    const lapis = blocks.idOf(.oreLapis);

    /// Water that fills a whole block
    const water: u8 = 8;
    /// The surface layer of a body of water, which renders as a flat top
    const water_surface: u8 = 9;

    comptime {
        std.debug.assert(blocks.modelOf(water).isFullCube());
        std.debug.assert(blocks.modelOf(water_surface) == .liquid_still);
    }
};

/// Where the ground sits and how much the 3D noise may bend it, per column.
/// This part is sampled for every single column, which is what keeps hillsides
/// from turning into wide flat steps.
const Heightfield = struct {
    base: [chunk.width][chunk.width]f32,
    amplitude: [chunk.width][chunk.width]f32,
};

/// The chunk arrays the generator fills, borrowed from the chunk store
pub const Target = struct {
    /// Block ids of the chunk
    ids: *[chunk.volume]u8,
    /// Sky light, one nibble per block
    skylight: *[chunk.nibble_len]u8,
};

/// World seed
seed: u64,

// Terrain shape
elevation: Fbm(5),
hills: Fbm(4),
detail: Fbm(3),
roughness: Fbm(2),
ruggedness: Fbm(3),
density_low: Fbm(5),
density_high: Fbm(5),
density_select: Fbm(3),

// Everything else
caves: Fbm(3),
temperature: Fbm(3),
patches: Fbm(2),

pub fn init(seed: u64) Generator {
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    return .{
        .seed = seed,
        .elevation = .init(random),
        .hills = .init(random),
        .detail = .init(random),
        .roughness = .init(random),
        .ruggedness = .init(random),
        .density_low = .init(random),
        .density_high = .init(random),
        .density_select = .init(random),
        .caves = .init(random),
        .temperature = .init(random),
        .patches = .init(random),
    };
}

/// Generates one chunk. The target arrays are overwritten entirely.
pub fn generateChunk(self: *const Generator, coords: coord.Chunk, target: Target) void {
    @memset(target.ids, id.air);

    var field: Heightfield = undefined;
    self.sampleHeightfield(coords, &field);

    var density: [grid_xz][grid_xz][grid_y]f32 = undefined;
    var carve: [grid_xz][grid_xz][grid_y]f32 = undefined;
    self.sampleGrid(coords, &density, &carve);

    self.fillStone(&field, &density, &carve, target.ids);
    self.paintSurface(coords, target.ids);
    self.placeOres(coords, target.ids);
    self.decorate(coords, target.ids);
    computeSkylight(target.ids, target.skylight);
}

/// Height of the terrain at a world column, for spawning the player.
/// Generating the whole chunk and looking at it is the honest way to answer,
/// which is cheap enough for a handful of columns.
pub fn surfaceHeight(self: *const Generator, alloc: std.mem.Allocator, pos: coord.Block) !i32 {
    const target: Target = .{
        .ids = try alloc.create([chunk.volume]u8),
        .skylight = try alloc.create([chunk.nibble_len]u8),
    };
    defer alloc.destroy(target.ids);
    defer alloc.destroy(target.skylight);

    const chunk_pos = pos.getChunk();
    self.generateChunk(chunk_pos, target);

    const local = pos.getPosInChunk();
    const column = target.ids[chunk.columnBase(@intCast(local.x), @intCast(local.z))..][0..chunk.height];

    var y: i32 = chunk.height - 1;
    while (y > 0) : (y -= 1) {
        if (column[@intCast(y)] != id.air)
            return y + 1;
    }
    return sea_surface + 1;
}

// --- Terrain shape ---------------------------------------------------------

/// Samples the per column height field: this is the part that decides where
/// the ground is, and it is evaluated for every column of the chunk
fn sampleHeightfield(self: *const Generator, coords: coord.Chunk, field: *Heightfield) void {
    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const wx: f64 = @floatFromInt(coords.x * chunk.width + @as(i32, @intCast(x)));
            const wz: f64 = @floatFromInt(coords.z * chunk.width + @as(i32, @intCast(z)));

            // Continents: a slow swell that decides sea, coast or highland.
            // Summed octaves rarely reach their extremes, so every field gets
            // a gain and a soft clip: that is what turns a limp, evenly sloped
            // heightmap into plateaus with steep sides.
            const elevation = gain(self.elevation.sample2(wx, wz, 1.0 / 200.0), 2.2);
            const continent = std.math.pow(f64, @abs(elevation), 0.8) * std.math.sign(elevation);

            // Hills, the scale you actually walk across, and the small detail
            // that keeps slopes from looking like contour lines on a map
            const hills = gain(self.hills.sample2(wx, wz, 1.0 / 80.0), 3.2);
            const detail = self.detail.sample2(wx, wz, 1.0 / 26.0);

            // A block or two of jitter, fine enough that it never shows up as
            // a shape of its own: it exists to tear the terraces of a smooth
            // slope into a ragged edge
            const roughness = self.roughness.sample2(wx, wz, 1.0 / 7.0);

            field.base[x][z] = @floatCast(@as(f64, sea_surface + 4) +
                continent * 38.0 + hills * 22.0 + detail * 2.5 + roughness * 1.7);

            // How much the 3D noise is allowed to bend that: calm plains in
            // most places, cliffs and mountains where it peaks
            const rugged = clamp01(self.ruggedness.sample2(wx, wz, 1.0 / 150.0) * 0.6 + 0.5);
            field.amplitude[x][z] = @floatCast(10.0 + rugged * rugged * 46.0);
        }
    }
}

/// Samples the coarse grids: the 3D shape of the terrain, and the caves.
/// Those two are the expensive part, so they are taken every four blocks and
/// interpolated, exactly like the original generator does.
fn sampleGrid(
    self: *const Generator,
    coords: coord.Chunk,
    density: *[grid_xz][grid_xz][grid_y]f32,
    carve: *[grid_xz][grid_xz][grid_y]f32,
) void {
    for (0..grid_xz) |gx| {
        for (0..grid_xz) |gz| {
            const wx: f64 = @floatFromInt(coords.x * chunk.width + @as(i32, @intCast(gx * cell_xz)));
            const wz: f64 = @floatFromInt(coords.z * chunk.width + @as(i32, @intCast(gz * cell_xz)));

            for (0..grid_y) |gy| {
                const wy: f64 = @floatFromInt(gy * cell_y);

                // Two noises, picked between by a third one: smooth where the
                // selector sits on one side, jagged where it sits on the other
                const low = self.density_low.sample3(wx, wy, wz, 1.0 / 60.0);
                const high = self.density_high.sample3(wx, wy, wz, 1.0 / 60.0);
                const select = clamp01(self.density_select.sample3(wx, wy, wz, 1.0 / 40.0) * 0.7 + 0.5);

                density[gx][gz][gy] = @floatCast(gain(std.math.lerp(low, high, select), 2.0));
                carve[gx][gz][gy] = @floatCast(self.caves.sample3(wx, wy * 2.2, wz, 1.0 / 55.0));
            }
        }
    }
}

/// Interpolates the coarse grid into actual blocks
fn fillStone(
    self: *const Generator,
    field: *const Heightfield,
    density: *const [grid_xz][grid_xz][grid_y]f32,
    carve: *const [grid_xz][grid_xz][grid_y]f32,
    ids: *[chunk.volume]u8,
) void {
    _ = self;

    for (0..grid_xz - 1) |gx| {
        for (0..grid_xz - 1) |gz| {
            for (0..grid_y - 1) |gy| {
                // The eight corners of this grid cell
                const d000 = density[gx][gz][gy];
                const d001 = density[gx][gz][gy + 1];
                const d100 = density[gx + 1][gz][gy];
                const d101 = density[gx + 1][gz][gy + 1];
                const d010 = density[gx][gz + 1][gy];
                const d011 = density[gx][gz + 1][gy + 1];
                const d110 = density[gx + 1][gz + 1][gy];
                const d111 = density[gx + 1][gz + 1][gy + 1];

                const c000 = carve[gx][gz][gy];
                const c001 = carve[gx][gz][gy + 1];
                const c100 = carve[gx + 1][gz][gy];
                const c101 = carve[gx + 1][gz][gy + 1];
                const c010 = carve[gx][gz + 1][gy];
                const c011 = carve[gx][gz + 1][gy + 1];
                const c110 = carve[gx + 1][gz + 1][gy];
                const c111 = carve[gx + 1][gz + 1][gy + 1];

                for (0..cell_xz) |ox| {
                    const tx = @as(f32, @floatFromInt(ox)) / cell_xz;
                    const x = gx * cell_xz + ox;

                    for (0..cell_xz) |oz| {
                        const tz = @as(f32, @floatFromInt(oz)) / cell_xz;
                        const z = gz * cell_xz + oz;

                        // A whole column of a cell is contiguous in memory
                        const column = ids[chunk.columnBase(x, z)..][0..chunk.height];
                        const base = field.base[x][z];
                        const amplitude = field.amplitude[x][z];

                        for (0..cell_y) |oy| {
                            const ty = @as(f32, @floatFromInt(oy)) / cell_y;
                            const y = gy * cell_y + oy;
                            const height: f32 = @floatFromInt(y);

                            // Ground where the height field, bent by the 3D
                            // noise, still reaches above this block
                            const shape = trilinear(
                                tx, ty, tz,
                                d000, d001, d100, d101, d010, d011, d110, d111,
                            );

                            var value = base + shape * amplitude - height;

                            // A gentle pull towards the sea line, so the noise
                            // carves cliffs instead of a wall of stone
                            value -= (height - sea_surface) * 0.12;

                            // Nothing reaches the ceiling of the world
                            if (height > 104)
                                value -= (height - 104) * 4.0;

                            if (value <= 0)
                                continue;

                            // Caves are the same interpolation, one grid over
                            const cave = trilinear(
                                tx, ty, tz,
                                c000, c001, c100, c101, c010, c011, c110, c111,
                            );
                            if (y < sea_surface - 2 and y > 4 and @abs(cave) < 0.09)
                                continue;

                            column[y] = id.stone;
                        }
                    }
                }
            }
        }
    }
}

/// Trilinear interpolation inside one grid cell
inline fn trilinear(
    tx: f32, ty: f32, tz: f32,
    d000: f32, d001: f32, d100: f32, d101: f32,
    d010: f32, d011: f32, d110: f32, d111: f32,
) f32 {
    const x00 = std.math.lerp(d000, d100, tx);
    const x01 = std.math.lerp(d001, d101, tx);
    const x10 = std.math.lerp(d010, d110, tx);
    const x11 = std.math.lerp(d011, d111, tx);

    const y0 = std.math.lerp(x00, x01, ty);
    const y1 = std.math.lerp(x10, x11, ty);

    return std.math.lerp(y0, y1, tz);
}

// --- Surface ---------------------------------------------------------------

/// Turns the top of the stone into grass, sand or gravel, and fills the oceans
fn paintSurface(self: *const Generator, coords: coord.Chunk, ids: *[chunk.volume]u8) void {
    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const wx: f64 = @floatFromInt(coords.x * chunk.width + @as(i32, @intCast(x)));
            const wz: f64 = @floatFromInt(coords.z * chunk.width + @as(i32, @intCast(z)));

            const desert = self.temperature.sample2(wx, wz, 1.0 / 320.0) > 0.32;
            const patch = self.patches.sample2(wx, wz, 1.0 / 40.0);

            const column = ids[chunk.columnBase(x, z)..][0..chunk.height];

            // Depth into the current run of surface blocks, -1 while in the air
            var depth: i32 = -1;

            var y: usize = chunk.height;
            while (y > 0) {
                y -= 1;

                if (column[y] == id.air) {
                    depth = -1;
                    // Everything below the sea line that is not solid is ocean
                    if (y <= sea_surface)
                        column[y] = if (y == sea_surface) id.water_surface else id.water;
                    continue;
                }

                if (column[y] != id.stone)
                    continue;

                if (depth < 0) {
                    // First solid block from above: this is the surface
                    if (y < sea_surface - 1) {
                        // Sea floor: sand, with patches of gravel and clay
                        column[y] = if (patch > 0.45) id.gravel else if (patch < -0.55) id.clay else id.sand;
                    } else if (desert) {
                        column[y] = id.sand;
                    } else if (y <= sea_surface + 1) {
                        // Beaches
                        column[y] = id.sand;
                    } else {
                        column[y] = id.grass;
                    }
                    depth = 0;
                    continue;
                }

                const filler_depth: i32 = if (desert) 5 else 3;
                if (depth < filler_depth) {
                    column[y] = if (desert)
                        (if (depth < 2) id.sand else id.sandstone)
                    else if (y < sea_surface - 1 and patch > 0.45)
                        id.gravel
                    else
                        id.dirt;
                    depth += 1;
                }
            }

            // The floor of the world
            column[0] = id.bedrock;
            var rng = self.columnRandom(coords, x, z);
            for (1..5) |by| {
                if (rng.random().intRangeLessThan(usize, 0, 5) >= by)
                    column[by] = id.bedrock;
            }
        }
    }
}

// --- Ores ------------------------------------------------------------------

/// Sprinkles the usual ores through the stone
fn placeOres(self: *const Generator, coords: coord.Chunk, ids: *[chunk.volume]u8) void {
    var rng = self.chunkRandom(coords, 0x00e5);
    const random = rng.random();

    // id, veins per chunk, blocks per vein, highest level
    const veins = .{
        .{ id.coal, 20, 16, 128 },
        .{ id.iron, 20, 8, 64 },
        .{ id.gold, 2, 8, 32 },
        .{ id.redstone, 8, 7, 16 },
        .{ id.diamond, 1, 7, 16 },
        .{ id.lapis, 1, 6, 32 },
        .{ id.gravel, 10, 32, 128 },
        .{ id.dirt, 20, 32, 128 },
    };

    inline for (veins) |vein| {
        for (0..vein[1]) |_| {
            const cx = random.intRangeLessThan(usize, 0, chunk.width);
            const cz = random.intRangeLessThan(usize, 0, chunk.width);
            const cy = random.intRangeLessThan(usize, 4, vein[3]);
            placeVein(ids, random, vein[0], cx, cy, cz, vein[2]);
        }
    }
}

/// A small blob of one block type, only replacing stone
fn placeVein(
    ids: *[chunk.volume]u8,
    random: std.Random,
    block: u8,
    cx: usize,
    cy: usize,
    cz: usize,
    size: usize,
) void {
    var x = cx;
    var y = cy;
    var z = cz;

    for (0..size) |_| {
        const column = ids[chunk.columnBase(x, z)..][0..chunk.height];
        if (column[y] == id.stone)
            column[y] = block;

        // Random walk, staying inside the chunk
        switch (random.intRangeLessThan(u8, 0, 6)) {
            0 => x = @min(x + 1, chunk.width - 1),
            1 => x -|= 1,
            2 => y = @min(y + 1, chunk.height - 1),
            3 => y -|= 1,
            4 => z = @min(z + 1, chunk.width - 1),
            else => z -|= 1,
        }
    }
}

// --- Decoration ------------------------------------------------------------

/// Trees, plants and the like
fn decorate(self: *const Generator, coords: coord.Chunk, ids: *[chunk.volume]u8) void {
    var rng = self.chunkRandom(coords, 0xdec0);
    const random = rng.random();

    const wx: f64 = @floatFromInt(coords.x * chunk.width + 8);
    const wz: f64 = @floatFromInt(coords.z * chunk.width + 8);
    const desert = self.temperature.sample2(wx, wz, 1.0 / 320.0) > 0.32;
    const forest = self.temperature.sample2(wx, wz, 1.0 / 320.0) < -0.25;

    if (desert) {
        for (0..random.intRangeAtMost(u8, 0, 6)) |_|
            self.plantCactus(ids, random);
        for (0..random.intRangeAtMost(u8, 0, 4)) |_|
            plantSingle(ids, random, id.deadbush, id.sand);
        return;
    }

    // Trees are kept away from the chunk border so that they never have to
    // write into a neighbor chunk, which would break "a chunk only depends on
    // its own coordinates"
    const tree_count = if (forest)
        random.intRangeAtMost(u8, 4, 9)
    else
        random.intRangeAtMost(u8, 0, 3);

    for (0..tree_count) |_|
        plantTree(ids, random);

    for (0..random.intRangeAtMost(u8, 4, 14)) |_|
        plantSingle(ids, random, id.tallgrass, id.grass);
    for (0..random.intRangeAtMost(u8, 0, 3)) |_|
        plantSingle(ids, random, id.flower, id.grass);
    for (0..random.intRangeAtMost(u8, 0, 3)) |_|
        plantSingle(ids, random, id.rose, id.grass);
    for (0..random.intRangeAtMost(u8, 0, 4)) |_|
        plantReeds(ids, random);
}

/// Highest non air block of a column, or null if the column is empty
fn surfaceOf(ids: *const [chunk.volume]u8, x: usize, z: usize) ?usize {
    const column = ids[chunk.columnBase(x, z)..][0..chunk.height];
    var y: usize = chunk.height - 1;
    while (y > 0) : (y -= 1) {
        if (column[y] != id.air)
            return y;
    }
    return null;
}

/// One block on top of the given ground block
fn plantSingle(ids: *[chunk.volume]u8, random: std.Random, plant: u8, ground: u8) void {
    const x = random.intRangeLessThan(usize, 0, chunk.width);
    const z = random.intRangeLessThan(usize, 0, chunk.width);

    const surface = surfaceOf(ids, x, z) orelse return;
    if (surface + 1 >= chunk.height)
        return;

    const column = ids[chunk.columnBase(x, z)..][0..chunk.height];
    if (column[surface] != ground)
        return;

    column[surface + 1] = plant;
}

/// Sugar cane, which only grows next to water
fn plantReeds(ids: *[chunk.volume]u8, random: std.Random) void {
    const x = random.intRangeLessThan(usize, 1, chunk.width - 1);
    const z = random.intRangeLessThan(usize, 1, chunk.width - 1);

    const surface = surfaceOf(ids, x, z) orelse return;
    const column = ids[chunk.columnBase(x, z)..][0..chunk.height];

    if (column[surface] != id.sand and column[surface] != id.grass)
        return;
    if (surface + 3 >= chunk.height)
        return;

    // Water right next to it?
    const neighbors = [_][2]usize{ .{ x - 1, z }, .{ x + 1, z }, .{ x, z - 1 }, .{ x, z + 1 } };
    const wet = for (neighbors) |neighbor| {
        const other = ids[chunk.columnBase(neighbor[0], neighbor[1])..][0..chunk.height];
        if (other[surface] == id.water or other[surface] == id.water_surface)
            break true;
    } else false;

    if (!wet)
        return;

    for (1..random.intRangeAtMost(usize, 2, 3) + 1) |i|
        column[surface + i] = id.reeds;
}

/// A cactus, one to three blocks tall
fn plantCactus(self: *const Generator, ids: *[chunk.volume]u8, random: std.Random) void {
    _ = self;

    const x = random.intRangeLessThan(usize, 0, chunk.width);
    const z = random.intRangeLessThan(usize, 0, chunk.width);

    const surface = surfaceOf(ids, x, z) orelse return;
    const column = ids[chunk.columnBase(x, z)..][0..chunk.height];

    if (column[surface] != id.sand)
        return;
    if (surface + 4 >= chunk.height)
        return;

    for (1..random.intRangeAtMost(usize, 1, 3) + 1) |i|
        column[surface + i] = id.cactus;
}

/// An oak: a trunk and a blob of leaves, always fully inside the chunk
fn plantTree(ids: *[chunk.volume]u8, random: std.Random) void {
    const radius = 2;

    const x = random.intRangeLessThan(usize, radius, chunk.width - radius);
    const z = random.intRangeLessThan(usize, radius, chunk.width - radius);

    const surface = surfaceOf(ids, x, z) orelse return;
    const trunk_column = ids[chunk.columnBase(x, z)..][0..chunk.height];

    if (trunk_column[surface] != id.grass)
        return;

    const height = random.intRangeAtMost(usize, 4, 6);
    if (surface + height + 2 >= chunk.height)
        return;

    // Leaves first, so that the trunk overwrites them where they overlap
    var dy: i32 = -2;
    while (dy <= 1) : (dy += 1) {
        const spread: i32 = if (dy <= -1) 2 else 1;

        var dx: i32 = -spread;
        while (dx <= spread) : (dx += 1) {
            var dz: i32 = -spread;
            while (dz <= spread) : (dz += 1) {
                // Round the corners off
                if (@abs(dx) == spread and @abs(dz) == spread and (dy > -1 or random.boolean()))
                    continue;

                const lx: usize = @intCast(@as(i32, @intCast(x)) + dx);
                const lz: usize = @intCast(@as(i32, @intCast(z)) + dz);
                const ly: usize = @intCast(@as(i32, @intCast(surface + height)) + dy);

                const column = ids[chunk.columnBase(lx, lz)..][0..chunk.height];
                if (column[ly] == id.air)
                    column[ly] = id.leaves;
            }
        }
    }

    for (1..height + 1) |i|
        trunk_column[surface + i] = id.log;
}

// --- Light -----------------------------------------------------------------

/// Sky light.
///
/// Daylight falls straight down until something opaque stops it, and then
/// spreads sideways losing one level per block, so that a ledge or a cave
/// mouth fades into the dark instead of cutting to black.
///
/// The spread is done as two sweeps over the flat array rather than as a queue
/// based flood fill: same result for the distances involved, no allocation, and
/// it walks memory in order. Light does not cross chunk borders yet, so a chunk
/// is lit as if it stood alone.
fn computeSkylight(ids: *const [chunk.volume]u8, skylight: *[chunk.nibble_len]u8) void {
    var light: [chunk.volume]u8 = @splat(0);

    // Straight down, at full strength, until something blocks it
    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const base = chunk.columnBase(x, z);
            const column = ids[base..][0..chunk.height];

            var y: usize = chunk.height;
            while (y > 0) {
                y -= 1;
                if (blocks.isOpaqueCube(column[y]))
                    break;
                light[base + y] = 15;
            }
        }
    }

    // Then sideways. A forward sweep carries light from the neighbors that come
    // earlier in memory, a backward sweep from the ones that come later; two
    // rounds of both cover the fifteen levels light can travel.
    for (0..2) |_| {
        spreadPass(ids, &light, .forward);
        spreadPass(ids, &light, .backward);
    }

    for (light, 0..) |level, index|
        terrain.ChunkStore.writeNibble(skylight, index, @intCast(level));
}

/// One sweep of the light spreading, in one direction
fn spreadPass(
    ids: *const [chunk.volume]u8,
    light: *[chunk.volume]u8,
    comptime direction: enum { forward, backward },
) void {
    for (0..chunk.width) |ix| {
        for (0..chunk.width) |iz| {
            for (0..chunk.height) |iy| {
                const x = if (direction == .forward) ix else chunk.width - 1 - ix;
                const z = if (direction == .forward) iz else chunk.width - 1 - iz;
                const y = if (direction == .forward) iy else chunk.height - 1 - iy;

                const index = chunk.columnBase(x, z) + y;
                if (light[index] >= 15 or blocks.isOpaqueCube(ids[index]))
                    continue;

                var best = light[index];
                if (x > 0) best = @max(best, light[chunk.columnBase(x - 1, z) + y]);
                if (x + 1 < chunk.width) best = @max(best, light[chunk.columnBase(x + 1, z) + y]);
                if (z > 0) best = @max(best, light[chunk.columnBase(x, z - 1) + y]);
                if (z + 1 < chunk.width) best = @max(best, light[chunk.columnBase(x, z + 1) + y]);
                if (y > 0) best = @max(best, light[index - 1]);
                if (y + 1 < chunk.height) best = @max(best, light[index + 1]);

                if (best > light[index] + 1)
                    light[index] = best - 1;
            }
        }
    }
}

// --- Randomness ------------------------------------------------------------

/// A random sequence that only depends on the seed, the chunk and a salt
fn chunkRandom(self: *const Generator, coords: coord.Chunk, salt: u64) std.Random.DefaultPrng {
    var hash = self.seed ^ salt;
    hash = hash *% 6364136223846793005 +% @as(u64, @bitCast(@as(i64, coords.x)));
    hash = hash *% 6364136223846793005 +% @as(u64, @bitCast(@as(i64, coords.z)));
    hash ^= hash >> 33;
    return std.Random.DefaultPrng.init(hash);
}

/// Same, per column
fn columnRandom(self: *const Generator, coords: coord.Chunk, x: usize, z: usize) std.Random.DefaultPrng {
    return self.chunkRandom(coords, 0xb0dc *% (x + 1) *% (z + 31));
}

inline fn clamp01(value: f64) f64 {
    return std.math.clamp(value, 0.0, 1.0);
}

/// Pushes a noise value towards its extremes while staying inside [-1, 1]
inline fn gain(value: f64, strength: f64) f64 {
    return std.math.tanh(value * strength);
}
