//! Shape of a chunk and the index math that goes with it.
//!
//! There is no `Chunk` struct any more: a chunk is a *slot* in the `ChunkStore`,
//! and its data lives in the store's parallel arrays. This file only describes
//! the layout of the per-block data inside one chunk.
//!
//! Block data is laid out y-major, i.e. the 128 blocks of a vertical column are
//! contiguous. That is what the protocol sends, and it is what lets the mesher
//! load a whole column as a single `u128` bit mask.

const std = @import("std");
const coord = @import("coord");

/// Width and depth of a chunk, in blocks
pub const width = 16;
/// Height of a chunk, in blocks
pub const height = 128;

/// Amount of columns in a chunk
pub const area = width * width;
/// Amount of blocks in a chunk
pub const volume = area * height;
/// Amount of bytes needed for one nibble per block (metadata, light levels)
pub const nibble_len = volume / 2;

/// Height of a chunk section, the granularity at which the store tracks
/// emptiness so that the mesher can skip whole slabs of air
pub const section_height = 16;
/// Amount of sections in a chunk
pub const section_count = height / section_height;
/// Amount of blocks in a section
pub const section_volume = area * section_height;

/// The bit mask of a full column of blocks, one bit per block of the column
pub const Column = std.meta.Int(.unsigned, height);

/// Index of the first block of the (x, z) column
pub inline fn columnBase(x: usize, z: usize) usize {
    std.debug.assert(x < width and z < width);
    return (x * width + z) * height;
}

/// Pass a set of coordinates that is within the chunk, get the offset of that
/// block in the block arrays
pub inline fn indexFromCoord(coords: coord.Block) usize {
    std.debug.assert(coords.isWithinChunk());
    return @intCast(coords.y + coords.x * height * width + coords.z * height);
}

/// Pass an index of the block arrays, get the corresponding block coords
pub inline fn coordFromIndex(index: usize) coord.Block {
    const i: i32 = @intCast(index);
    return .{
        .x = @divFloor(i, height * width),
        .y = @mod(i, height),
        .z = @mod(@divFloor(i, height), width),
    };
}

/// Section a block index belongs to
pub inline fn sectionOfIndex(index: usize) usize {
    return (index % height) / section_height;
}

test "coords from index from coords" {
    var rng = std.Random.DefaultPrng.init(@intCast(std.testing.random_seed));
    const random = rng.random();

    const in = coord.Block{
        .x = random.intRangeLessThan(i32, 0, width),
        .y = random.intRangeLessThan(i32, 0, height),
        .z = random.intRangeLessThan(i32, 0, width),
    };

    const index = indexFromCoord(in);
    const out = coordFromIndex(index);

    try std.testing.expectEqualDeep(in, out);
}

test "columns are contiguous" {
    for (0..width) |x| {
        for (0..width) |z| {
            const base = columnBase(x, z);
            for (0..height) |y| {
                const pos = coord.Block{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .z = @intCast(z),
                };
                try std.testing.expectEqual(base + y, indexFromCoord(pos));
            }
        }
    }
}

test "sections" {
    try std.testing.expectEqual(@as(usize, 0), sectionOfIndex(indexFromCoord(.{ .x = 3, .y = 0, .z = 5 })));
    try std.testing.expectEqual(@as(usize, 1), sectionOfIndex(indexFromCoord(.{ .x = 3, .y = 16, .z = 5 })));
    try std.testing.expectEqual(@as(usize, 7), sectionOfIndex(indexFromCoord(.{ .x = 3, .y = 127, .z = 5 })));
}
