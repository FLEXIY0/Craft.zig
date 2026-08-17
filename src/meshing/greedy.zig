//! Greedy meshing of the full cube blocks of a chunk.
//!
//! Two ideas do all the work here:
//!
//!  1. *Binary face culling*. A chunk column (16x16 columns of 128 blocks) is
//!     summarized as a `u128` bit mask, one bit per block. Whether a face of a
//!     whole column is visible is then a single instruction:
//!       - top faces:    `full & ~(occluders >> 1)`
//!       - bottom faces: `full & ~(occluders << 1)`
//!       - side faces:   `full & ~occluders_of_the_neighbor_column`
//!     128 blocks of face culling per instruction, no per-block branching, and
//!     the neighbor chunks fall out of the same expression because their border
//!     columns are part of the snapshot.
//!
//!  2. *Greedy merging*. Visible faces of a plane are keyed by everything that
//!     has to match for two faces to be drawn as one quad (block id and light
//!     level), then merged into maximal rectangles. A flat wall of stone under
//!     uniform light collapses from 256 quads to 1.

const std = @import("std");
const coord = @import("coord");
const blocks = @import("blocks");
const terrain = @import("terrain");
const tracy = @import("tracy");

const chunk = terrain.chunk;
const LightLevel = terrain.LightLevel;

const Snapshot = @import("Snapshot.zig");
const Layers = @import("Layers.zig");
const shading = @import("shading.zig");

/// A bit mask of a whole vertical column of blocks
const Column = chunk.Column;

/// Everything that has to match for two faces to merge, or 0 for "no face here"
const Key = u32;
/// Bit that tells an actual key from an empty cell
const key_present: Key = 1 << 31;

/// Biggest plane the mesher walks (the vertical ones)
const max_plane = chunk.width * chunk.height;

/// Per-worker scratch space, allocated once and reused for every chunk
pub const Scratch = struct {
    /// Blocks that the greedy mesher handles, per column
    full: [chunk.width][chunk.width]Column = @splat(@splat(0)),
    /// Blocks that hide their neighbors' faces, per column
    occluders: [chunk.width][chunk.width]Column = @splat(@splat(0)),
    /// Occluders of the neighbor chunks, indexed `[face][u]`
    edge_occluders: [Snapshot.side_count][chunk.width]Column = @splat(@splat(0)),
    /// Visible faces of the direction being processed, per column
    visible: [chunk.width][chunk.width]Column = @splat(@splat(0)),
    /// Block ids of every column of the chunk, so that the plane sweeps never
    /// recompute an address
    id_columns: [chunk.width][chunk.width]*const Snapshot.IdColumn = undefined,
    /// Light levels of every column, same idea
    light_columns: [chunk.width][chunk.width]*const Snapshot.LightColumn = undefined,
    /// Merge keys of the plane being processed
    keys: [max_plane]Key = @splat(0),
    /// Indices of the blocks that need the per-block mesher
    special: std.ArrayListUnmanaged(u16) = .empty,

    pub fn deinit(self: *Scratch, alloc: std.mem.Allocator) void {
        self.special.deinit(alloc);
    }
};

/// Meshes every full cube block of the snapshot.
/// The blocks that need the per-block mesher are left in `scratch.special`.
pub fn run(scratch: *Scratch, alloc: std.mem.Allocator, snapshot: *const Snapshot, layers: *Layers) !void {
    const zone = tracy.Zone.begin(.{
        .name = "Greedy meshing",
        .src = @src(),
        .color = .yellow,
    });
    defer zone.end();

    indexColumns(scratch, snapshot);
    try scan(scratch, alloc);
    scanEdges(scratch, snapshot);

    inline for (coord.Face.all) |face| {
        try meshFace(scratch, snapshot, layers, face);
    }
}

/// Summarizes the chunk as bit masks, and collects the blocks that need the
/// per-block mesher on the way
fn scan(scratch: *Scratch, alloc: std.mem.Allocator) !void {
    const zone = tracy.Zone.begin(.{
        .name = "Column scan",
        .src = @src(),
        .color = .orange,
    });
    defer zone.end();

    scratch.special.clearRetainingCapacity();

    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const base = chunk.columnBase(x, z);
            const column = scratch.id_columns[x][z];

            var full: Column = 0;
            var occluders: Column = 0;

            for (column, 0..) |block_id, y| {
                if (blocks.isInvisible(block_id))
                    continue;

                const bit = @as(Column, 1) << @intCast(y);
                if (blocks.isFullCube(block_id)) {
                    full |= bit;
                    if (blocks.isOpaqueCube(block_id))
                        occluders |= bit;
                } else {
                    try scratch.special.append(alloc, @intCast(base + y));
                }
            }

            scratch.full[x][z] = full;
            scratch.occluders[x][z] = occluders;
        }
    }
}

/// Same thing for the border planes of the neighbor chunks
fn scanEdges(scratch: *Scratch, snapshot: *const Snapshot) void {
    for (&scratch.edge_occluders, 0..) |*side, face| {
        for (side, 0..) |*column, u| {
            var occluders: Column = 0;
            for (snapshot.edge_ids[face][u], 0..) |block_id, y| {
                if (blocks.isOpaqueCube(block_id))
                    occluders |= @as(Column, 1) << @intCast(y);
            }
            column.* = occluders;
        }
    }
}

/// Occluders of a column, which may belong to a neighbor chunk
inline fn occludersAt(scratch: *const Scratch, x: i32, z: i32) Column {
    if (x < 0)
        return scratch.edge_occluders[@intFromEnum(coord.Face.west)][@intCast(z)];
    if (x >= chunk.width)
        return scratch.edge_occluders[@intFromEnum(coord.Face.east)][@intCast(z)];
    if (z < 0)
        return scratch.edge_occluders[@intFromEnum(coord.Face.north)][@intCast(x)];
    if (z >= chunk.width)
        return scratch.edge_occluders[@intFromEnum(coord.Face.south)][@intCast(x)];
    return scratch.occluders[@intCast(x)][@intCast(z)];
}

/// Bit mask of the visible faces of a column, for one face direction
inline fn visibleFaces(scratch: *const Scratch, comptime face: coord.Face, x: usize, z: usize) Column {
    const full = scratch.full[x][z];
    const ix: i32 = @intCast(x);
    const iz: i32 = @intCast(z);

    return full & ~switch (face) {
        .up => scratch.occluders[x][z] >> 1,
        .down => scratch.occluders[x][z] << 1,
        .north => occludersAt(scratch, ix, iz - 1),
        .east => occludersAt(scratch, ix + 1, iz),
        .south => occludersAt(scratch, ix, iz + 1),
        .west => occludersAt(scratch, ix - 1, iz),
    };
}

/// Points every column of the scratch at its data in the snapshot.
/// Both meshing sweeps then work on `[128]u8` and `[128]LightLevel` columns
/// directly: no address math, and one cache line of light per four blocks.
fn indexColumns(scratch: *Scratch, snapshot: *const Snapshot) void {
    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            scratch.id_columns[x][z] = snapshot.idColumn(x, z);
            scratch.light_columns[x][z] = snapshot.lightColumn(x, z);
        }
    }
}

/// Light levels of the blocks touching a face of a whole column, which for the
/// horizontal faces live in the neighbor column (possibly in a neighbor chunk)
inline fn faceLightColumn(
    scratch: *const Scratch,
    snapshot: *const Snapshot,
    comptime face: coord.Face,
    x: usize,
    z: usize,
) *const Snapshot.LightColumn {
    const offset = comptime face.asRelativeBlock();
    const nx = @as(i32, @intCast(x)) + offset.x;
    const nz = @as(i32, @intCast(z)) + offset.z;

    if (nx >= 0 and nx < chunk.width and nz >= 0 and nz < chunk.width)
        return scratch.light_columns[@intCast(nx)][@intCast(nz)];

    // One of the border planes of the snapshot
    return snapshot.lightColumnAt(nx, nz);
}

/// Merge key of a visible face, from the columns it belongs to
inline fn keyOf(
    ids: *const Snapshot.IdColumn,
    lights: *const Snapshot.LightColumn,
    comptime face: coord.Face,
    y: usize,
) Key {
    // Up and down faces look at the block above or below, in the same column
    const light = switch (face) {
        .up => if (y + 1 < chunk.height) lights[y + 1] else Snapshot.default_light,
        .down => if (y == 0) Snapshot.default_light else lights[y - 1],
        else => lights[y],
    };

    return key_present | ids[y] | (@as(Key, @as(u8, @bitCast(light))) << 8);
}

inline fn keyBlockId(key: Key) blocks.Id {
    return @truncate(key);
}

inline fn keyLight(key: Key) LightLevel {
    return @bitCast(@as(u8, @truncate(key >> 8)));
}

/// Meshes every visible face of one direction, plane by plane
fn meshFace(scratch: *Scratch, snapshot: *const Snapshot, layers: *Layers, comptime face: coord.Face) !void {
    // Cull every face of that direction at once: 128 blocks per instruction
    var anywhere: Column = 0;
    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const visible = visibleFaces(scratch, face, x, z);
            scratch.visible[x][z] = visible;
            anywhere |= visible;
        }
    }
    if (anywhere == 0)
        return;

    switch (face) {
        // Horizontal planes: one per y level, u is x and v is z
        .up, .down => {
            var levels = anywhere;
            while (levels != 0) {
                const y: usize = @ctz(levels);
                levels &= levels - 1;

                const keys = scratch.keys[0 .. chunk.width * chunk.width];
                @memset(keys, 0);

                for (0..chunk.width) |x| {
                    for (0..chunk.width) |z| {
                        if (@as(u1, @truncate(scratch.visible[x][z] >> @intCast(y))) == 0)
                            continue;
                        keys[z * chunk.width + x] = keyOf(
                            scratch.id_columns[x][z],
                            scratch.light_columns[x][z],
                            face,
                            y,
                        );
                    }
                }

                try mergePlane(keys, chunk.width, chunk.width, layers, face, y);
            }
        },
        // Vertical planes along z: one per z, u is x and v is y
        .north, .south => {
            for (0..chunk.width) |z| {
                const keys = scratch.keys[0..max_plane];
                @memset(keys, 0);

                var any = false;
                for (0..chunk.width) |x| {
                    var visible = scratch.visible[x][z];
                    if (visible == 0)
                        continue;

                    // The whole column shares its data: look it up once
                    const ids = scratch.id_columns[x][z];
                    const lights = faceLightColumn(scratch, snapshot, face, x, z);

                    while (visible != 0) {
                        const y: usize = @ctz(visible);
                        visible &= visible - 1;
                        keys[y * chunk.width + x] = keyOf(ids, lights, face, y);
                        any = true;
                    }
                }

                if (any)
                    try mergePlane(keys, chunk.width, chunk.height, layers, face, z);
            }
        },
        // Vertical planes along x: one per x, u is z and v is y
        .east, .west => {
            for (0..chunk.width) |x| {
                const keys = scratch.keys[0..max_plane];
                @memset(keys, 0);

                var any = false;
                for (0..chunk.width) |z| {
                    var visible = scratch.visible[x][z];
                    if (visible == 0)
                        continue;

                    const ids = scratch.id_columns[x][z];
                    const lights = faceLightColumn(scratch, snapshot, face, x, z);

                    while (visible != 0) {
                        const y: usize = @ctz(visible);
                        visible &= visible - 1;
                        keys[y * chunk.width + z] = keyOf(ids, lights, face, y);
                        any = true;
                    }
                }

                if (any)
                    try mergePlane(keys, chunk.width, chunk.height, layers, face, x);
            }
        },
    }
}

/// Merges the faces of a plane into maximal rectangles and emits them.
/// `keys` is consumed: merged cells are cleared as the sweep goes.
fn mergePlane(
    keys: []Key,
    u_len: usize,
    v_len: usize,
    layers: *Layers,
    comptime face: coord.Face,
    slice: usize,
) !void {
    var v: usize = 0;
    while (v < v_len) : (v += 1) {
        var u: usize = 0;
        while (u < u_len) {
            const key = keys[v * u_len + u];
            if (key == 0) {
                u += 1;
                continue;
            }

            // Grow along u
            var w: usize = 1;
            while (u + w < u_len and keys[v * u_len + u + w] == key)
                w += 1;

            // Grow along v, one full row at a time
            var h: usize = 1;
            grow: while (v + h < v_len) {
                const row = keys[(v + h) * u_len ..][0..u_len];
                for (row[u..][0..w]) |candidate| {
                    if (candidate != key)
                        break :grow;
                }
                h += 1;
            }

            // Consume the rectangle
            for (0..h) |dv|
                @memset(keys[(v + dv) * u_len + u ..][0..w], 0);

            try emitFace(layers, face, slice, u, v, w, h, key);

            u += w;
        }
    }
}

/// Emits one merged quad
fn emitFace(
    layers: *Layers,
    comptime face: coord.Face,
    slice: usize,
    u: usize,
    v: usize,
    w: usize,
    h: usize,
    key: Key,
) !void {
    const block_id = keyBlockId(key);
    const color = shading.faceColor(block_id, face, keyLight(key));
    const tile = blocks.atlas.origins[blocks.texOf(face, block_id)];

    const fu: f32 = @floatFromInt(u);
    const fv: f32 = @floatFromInt(v);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const fs: f32 = @floatFromInt(slice);

    // The uvs are given in tile units: a quad spanning several blocks repeats
    // its tile, which the chunk shader takes care of
    const uvs: [4][2]f32 = switch (face) {
        .down => .{ .{ 0, fh }, .{ fw, fh }, .{ fw, 0 }, .{ 0, 0 } },
        else => .{ .{ fw, fh }, .{ 0, fh }, .{ 0, 0 }, .{ fw, 0 } },
    };

    const positions: [4][3]f32 = switch (face) {
        // Plane at z = slice, u is x and v is y
        .north => .{
            .{ fu, fv, fs },
            .{ fu + fw, fv, fs },
            .{ fu + fw, fv + fh, fs },
            .{ fu, fv + fh, fs },
        },
        // Plane at z = slice + 1, u is x and v is y
        .south => .{
            .{ fu + fw, fv, fs + 1 },
            .{ fu, fv, fs + 1 },
            .{ fu, fv + fh, fs + 1 },
            .{ fu + fw, fv + fh, fs + 1 },
        },
        // Plane at x = slice + 1, u is z and v is y
        .east => .{
            .{ fs + 1, fv, fu },
            .{ fs + 1, fv, fu + fw },
            .{ fs + 1, fv + fh, fu + fw },
            .{ fs + 1, fv + fh, fu },
        },
        // Plane at x = slice, u is z and v is y
        .west => .{
            .{ fs, fv, fu + fw },
            .{ fs, fv, fu },
            .{ fs, fv + fh, fu },
            .{ fs, fv + fh, fu + fw },
        },
        // Plane at y = slice + 1, u is x and v is z
        .up => .{
            .{ fu + fw, fs + 1, fv + fh },
            .{ fu, fs + 1, fv + fh },
            .{ fu, fs + 1, fv },
            .{ fu + fw, fs + 1, fv },
        },
        // Plane at y = slice, u is x and v is z
        .down => .{
            .{ fu, fs, fv + fh },
            .{ fu + fw, fs, fv + fh },
            .{ fu + fw, fs, fv },
            .{ fu, fs, fv },
        },
    };

    try layers.quad(block_id, positions, uvs, tile, color);
}
