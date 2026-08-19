//! Which faces of a chunk section can see each other through its own blocks.
//!
//! This is the data that lets a renderer skip what it cannot see. A chunk is 128
//! blocks tall and the surface sits around y 64, so most of a world's geometry
//! is below it: the walls and floor of every ocean basin, and the cave walls
//! behind solid rock. All of it perfectly well meshed, and almost none of it
//! ever on screen.
//!
//! Sight is stopped by more than solid rock (`blocks.blocksSight`): sixty blocks
//! of sea water stop it just as surely, which is why the classic game's oceans
//! are a flat blue surface rather than a window onto the sea bed. The faces
//! touching that water are still meshed and drawn — the shallows still show
//! their bottom — but nothing deeper is walked to.
//!
//! Frustum culling does not help there, because a frustum widens with distance
//! and swallows whole chunk columns. What does help is knowing, for each 16x16x16
//! section, whether sight can pass through it at all, and between which of its
//! six faces. A renderer can then walk outwards from the section the camera is
//! in, only stepping into a neighbor when the section it is leaving actually
//! connects the face it came in through to the face it is leaving by. Sections
//! nothing connects to are never reached, and never drawn.
//!
//! The connectivity is computed once per meshing job, from the same snapshot the
//! mesher already has in cache.

const std = @import("std");
const coord = @import("coord");
const blocks = @import("blocks");
const terrain = @import("terrain");

const chunk = terrain.chunk;
const Snapshot = @import("Snapshot.zig");

/// Faces reachable from each face of a section, as a bit set of face indices:
/// bit `j` of `connections[i]` means sight can travel from face `i` to face `j`.
/// Always symmetric, and all zero for a section of solid rock.
pub const Connectivity = struct {
    connections: [coord.Face.count]u8 = @splat(0),

    /// A section sight passes through in every direction, which is what an
    /// unmeshed or missing chunk has to be treated as: refusing to traverse it
    /// would hide everything behind it
    pub const open: Connectivity = .{ .connections = @splat(0b111111) };

    /// True if sight entering through `from` can leave through `to`
    pub inline fn connects(self: Connectivity, from: coord.Face, to: coord.Face) bool {
        return (self.connections[from.index()] >> @intCast(to.index())) & 1 != 0;
    }

    /// True if nothing passes through this section at all
    pub inline fn isSealed(self: Connectivity) bool {
        for (self.connections) |mask| {
            if (mask != 0)
                return false;
        }
        return true;
    }

    fn link(self: *Connectivity, a: usize, b: usize) void {
        self.connections[a] |= @as(u8, 1) << @intCast(b);
        self.connections[b] |= @as(u8, 1) << @intCast(a);
    }
};

/// Blocks of a section, in the order the flood fill walks them
const section_area = chunk.width * chunk.width;
const section_volume = section_area * chunk.section_height;

/// Scratch space of the flood fill, kept by the mesher and reused
pub const Scratch = struct {
    /// Cells already assigned to a region
    visited: [section_volume]bool = @splat(false),
    /// Cells left to expand
    stack: [section_volume]u16 = @splat(0),
};

/// Local index of a cell of a section
inline fn cellIndex(x: usize, z: usize, y: usize) u16 {
    return @intCast((x * chunk.width + z) * chunk.section_height + y);
}

/// Computes the connectivity of every section of a snapshot
pub fn run(scratch: *Scratch, snapshot: *const Snapshot) [chunk.section_count]Connectivity {
    var result: [chunk.section_count]Connectivity = @splat(.{});
    for (&result, 0..) |*connectivity, section|
        connectivity.* = ofSection(scratch, snapshot, section);
    return result;
}

/// Flood fills one section and records which of its faces end up in the same
/// region. Two faces of the same region can see each other through the section.
pub fn ofSection(scratch: *Scratch, snapshot: *const Snapshot, section: usize) Connectivity {
    const base = section * chunk.section_height;

    @memset(&scratch.visited, false);
    var result: Connectivity = .{};

    for (0..chunk.width) |start_x| {
        for (0..chunk.width) |start_z| {
            const column = snapshot.idColumn(start_x, start_z);

            for (0..chunk.section_height) |start_y| {
                const start = cellIndex(start_x, start_z, start_y);
                if (scratch.visited[start])
                    continue;
                if (blocks.blocksSight(column[base + start_y]))
                    continue;

                // Every face this region touches, as a bit set
                var touched: u8 = 0;
                var top: usize = 0;
                scratch.stack[top] = start;
                top += 1;
                scratch.visited[start] = true;

                while (top > 0) {
                    top -= 1;
                    const cell = scratch.stack[top];

                    const y = cell % chunk.section_height;
                    const z = (cell / chunk.section_height) % chunk.width;
                    const x = cell / (chunk.section_height * chunk.width);

                    // Cells on a boundary put their face in the region
                    if (z == 0) touched |= 1 << @intFromEnum(coord.Face.north);
                    if (z == chunk.width - 1) touched |= 1 << @intFromEnum(coord.Face.south);
                    if (x == 0) touched |= 1 << @intFromEnum(coord.Face.west);
                    if (x == chunk.width - 1) touched |= 1 << @intFromEnum(coord.Face.east);
                    if (y == 0) touched |= 1 << @intFromEnum(coord.Face.down);
                    if (y == chunk.section_height - 1) touched |= 1 << @intFromEnum(coord.Face.up);

                    inline for (.{
                        .{ -1, 0, 0 }, .{ 1, 0, 0 },
                        .{ 0, -1, 0 }, .{ 0, 1, 0 },
                        .{ 0, 0, -1 }, .{ 0, 0, 1 },
                    }) |step| {
                        const nx = @as(i32, @intCast(x)) + step[0];
                        const nz = @as(i32, @intCast(z)) + step[1];
                        const ny = @as(i32, @intCast(y)) + step[2];

                        if (nx >= 0 and nx < chunk.width and
                            nz >= 0 and nz < chunk.width and
                            ny >= 0 and ny < chunk.section_height)
                        {
                            const neighbor = cellIndex(@intCast(nx), @intCast(nz), @intCast(ny));
                            if (!scratch.visited[neighbor]) {
                                const ids = snapshot.idColumn(@intCast(nx), @intCast(nz));
                                if (!blocks.blocksSight(ids[base + @as(usize, @intCast(ny))])) {
                                    scratch.visited[neighbor] = true;
                                    scratch.stack[top] = neighbor;
                                    top += 1;
                                }
                            }
                        }
                    }
                }

                // Every pair of faces this region reached can see each other
                for (0..coord.Face.count) |a| {
                    if ((touched >> @intCast(a)) & 1 == 0)
                        continue;
                    for (a..coord.Face.count) |b| {
                        if ((touched >> @intCast(b)) & 1 != 0)
                            result.link(a, b);
                    }
                }
            }
        }
    }

    return result;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn testSnapshot(alloc: std.mem.Allocator) !*Snapshot {
    const snapshot = try alloc.create(Snapshot);
    snapshot.* = .{};
    snapshot.clear();
    return snapshot;
}

test "solid rock lets nothing through" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);
    @memset(&snapshot.ids, blocks.idOf(.stone));

    const scratch = try alloc.create(Scratch);
    defer alloc.destroy(scratch);
    scratch.* = .{};

    const connectivity = ofSection(scratch, snapshot, 2);
    try testing.expect(connectivity.isSealed());
    try testing.expect(!connectivity.connects(.up, .down));
}

test "air lets everything through" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    const scratch = try alloc.create(Scratch);
    defer alloc.destroy(scratch);
    scratch.* = .{};

    const connectivity = ofSection(scratch, snapshot, 2);
    try testing.expect(!connectivity.isSealed());
    for (coord.Face.all) |from| {
        for (coord.Face.all) |to|
            try testing.expect(connectivity.connects(from, to));
    }
}

test "a tunnel only connects the faces it reaches" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);
    @memset(&snapshot.ids, blocks.idOf(.stone));

    // A straight tunnel along x, through the middle of section 2
    const y = 2 * chunk.section_height + 8;
    for (0..chunk.width) |x|
        snapshot.idColumnMut(x, 8)[y] = 0;

    const scratch = try alloc.create(Scratch);
    defer alloc.destroy(scratch);
    scratch.* = .{};

    const connectivity = ofSection(scratch, snapshot, 2);

    // East and west see each other through the tunnel
    try testing.expect(connectivity.connects(.east, .west));
    // Nothing else does: the tunnel touches no other face
    try testing.expect(!connectivity.connects(.up, .down));
    try testing.expect(!connectivity.connects(.north, .south));
    try testing.expect(!connectivity.connects(.east, .up));
}

test "two separate caves do not connect their faces to each other" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);
    @memset(&snapshot.ids, blocks.idOf(.stone));

    const base = 2 * chunk.section_height;

    // One tunnel along x near the bottom, one along z near the top, with solid
    // rock in between: no path goes from the first one to the second
    for (0..chunk.width) |x|
        snapshot.idColumnMut(x, 4)[base + 2] = 0;
    for (0..chunk.width) |z|
        snapshot.idColumnMut(4, z)[base + 12] = 0;

    const scratch = try alloc.create(Scratch);
    defer alloc.destroy(scratch);
    scratch.* = .{};

    const connectivity = ofSection(scratch, snapshot, 2);

    try testing.expect(connectivity.connects(.east, .west));
    try testing.expect(connectivity.connects(.north, .south));
    // The two tunnels never meet
    try testing.expect(!connectivity.connects(.east, .north));
    try testing.expect(!connectivity.connects(.west, .south));
}

test "deep water stops sight the way rock does" {
    const alloc = testing.allocator;

    const snapshot = try testSnapshot(alloc);
    defer alloc.destroy(snapshot);

    const scratch = try alloc.create(Scratch);
    defer alloc.destroy(scratch);
    scratch.* = .{};

    // A section entirely under water: the sea bed behind it is not worth
    // walking to, no matter that its faces are real geometry
    for (0..chunk.width) |x| {
        for (0..chunk.width) |z| {
            const column = snapshot.idColumnMut(x, z);
            for (2 * chunk.section_height..3 * chunk.section_height) |y|
                column[y] = 8;
        }
    }

    try testing.expect(ofSection(scratch, snapshot, 2).isSealed());

    // Water still draws its faces: this is a sight rule, not a meshing one
    try testing.expect(!blocks.isOpaqueCube(8));
    try testing.expect(blocks.blocksSight(8));
}

test "an open section is traversable in every direction" {
    for (coord.Face.all) |from| {
        for (coord.Face.all) |to|
            try testing.expect(Connectivity.open.connects(from, to));
    }
    try testing.expect(!Connectivity.open.isSealed());
}
