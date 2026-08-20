//! The sections the camera can actually see, found by walking the world.
//!
//! Drawing every loaded chunk means drawing the caves under them, which is most
//! of a world's geometry and almost none of its picture. Frustum culling does
//! not catch that: a frustum widens with distance and a chunk is 128 blocks
//! tall, so a distant chunk is "visible" from its bedrock to its treetops.
//!
//! Instead this walks outwards from the section the camera stands in, and only
//! steps into a neighbor when the section it is leaving really does connect the
//! face it came in through to the face it is leaving by (`meshing.visibility`).
//! Sealed rock connects nothing, so the walk never reaches the caves behind it.
//! This is the same idea Minecraft has used since 1.8.
//!
//! Two rules keep the walk finite and honest:
//!
//!  - a section is only ever entered once, and
//!  - once the walk has stepped in a direction it never steps back the opposite
//!    way, so it spreads away from the camera instead of circling around it.
//!
//! Chunks that are loaded but not meshed yet are treated as fully open: refusing
//! to walk through them would punch holes in the world while it streams in.

const std = @import("std");
const rl = @import("raylib");
const coord = @import("coord");
const terrain = @import("terrain");
const meshing = @import("meshing");
const blocks = @import("blocks");

const chunk = terrain.chunk;
const Frustum = @import("Frustum.zig");
const Connectivity = meshing.visibility.Connectivity;

const VisibleSet = @This();

/// One section the walk decided to draw
pub const Visible = struct {
    slot: terrain.ChunkStore.Slot,
    coords: coord.Chunk,
    section: u8,
};

/// A section waiting to be expanded
const Step = struct {
    slot: terrain.ChunkStore.Slot,
    coords: coord.Chunk,
    section: u8,
    /// Face the walk came in through, or null for the section the camera is in
    entered: ?coord.Face,
    /// Directions already taken, so the walk never turns back on itself
    taken: u8,
};

alloc: std.mem.Allocator,
/// Sections to draw, in the order the walk found them
visible: std.ArrayListUnmanaged(Visible) = .empty,
/// Sections already reached, indexed `slot * section_count + section`
seen: std.ArrayListUnmanaged(bool) = .empty,
/// Sections left to expand
pending: std.ArrayListUnmanaged(Step) = .empty,

pub fn init(alloc: std.mem.Allocator) VisibleSet {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *VisibleSet) void {
    self.visible.deinit(self.alloc);
    self.seen.deinit(self.alloc);
    self.pending.deinit(self.alloc);
}

/// Fills `visible` with the sections worth drawing this frame
pub fn gather(
    self: *VisibleSet,
    store: *const terrain.ChunkStore,
    frustum: Frustum,
    camera: rl.Vector3,
) !void {
    self.visible.clearRetainingCapacity();
    self.pending.clearRetainingCapacity();

    // One flag per section of every slot the store may hand out
    const flags = store.capacity() * chunk.section_count;
    try self.seen.resize(self.alloc, flags);
    @memset(self.seen.items, false);

    const origin: coord.Chunk = .{
        .x = @intFromFloat(@floor(camera.x / chunk.width)),
        .z = @intFromFloat(@floor(camera.z / chunk.width)),
    };
    const start_section: u8 = @intCast(std.math.clamp(
        @as(i32, @intFromFloat(@floor(camera.y / chunk.section_height))),
        0,
        chunk.section_count - 1,
    ));

    const start_slot = store.find(origin) orelse {
        // The camera is outside the loaded world: there is nothing to walk from,
        // so fall back to plain frustum culling
        return self.gatherEverything(store, frustum);
    };

    // Sight is stopped by water, which is the point of the walk over an ocean.
    // With the camera inside that water the very first section is sealed and
    // the walk would end there, so a swimming player gets plain frustum culling.
    const eye: coord.Block = .{
        .x = @intFromFloat(@floor(camera.x)),
        .y = std.math.clamp(@as(i32, @intFromFloat(@floor(camera.y))), 0, chunk.height - 1),
        .z = @intFromFloat(@floor(camera.z)),
    };
    if (blocks.blocksSight(store.getBlockId(start_slot, eye.getPosInChunk())))
        return self.gatherEverything(store, frustum);

    try self.push(.{
        .slot = start_slot,
        .coords = origin,
        .section = start_section,
        .entered = null,
        .taken = 0,
    });

    var next: usize = 0;
    while (next < self.pending.items.len) : (next += 1) {
        const step = self.pending.items[next];

        try self.visible.append(self.alloc, .{
            .slot = step.slot,
            .coords = step.coords,
            .section = step.section,
        });

        const connectivity = connectivityOf(store, step.slot, step.section);

        for (coord.Face.all) |face| {
            // Never step back the way the walk came
            if (step.taken & backMask(face) != 0)
                continue;

            // Sight has to actually cross this section to leave by that face.
            // The section the camera is in is entered from nowhere, so it lets
            // the walk out in every direction.
            if (step.entered) |entered| {
                if (!connectivity.connects(entered, face))
                    continue;
            }

            const target = stepThrough(step.coords, step.section, face) orelse continue;

            const slot = store.find(target.coords) orelse continue;
            const index = self.seenIndex(slot, target.section);
            if (index >= self.seen.items.len or self.seen.items[index])
                continue;

            if (!frustum.containsSection(target.coords, target.section))
                continue;

            try self.push(.{
                .slot = slot,
                .coords = target.coords,
                .section = target.section,
                .entered = face.opposite(),
                .taken = step.taken | @as(u8, 1) << @intCast(face.index()),
            });
        }
    }
}

/// Marks a section as reached and queues it
fn push(self: *VisibleSet, step: Step) !void {
    const index = self.seenIndex(step.slot, step.section);
    if (index < self.seen.items.len)
        self.seen.items[index] = true;
    try self.pending.append(self.alloc, step);
}

inline fn seenIndex(self: VisibleSet, slot: terrain.ChunkStore.Slot, section: usize) usize {
    _ = self;
    return @as(usize, slot) * chunk.section_count + section;
}

/// Connectivity of a section, permissive when the chunk has no mesh yet
fn connectivityOf(store: *const terrain.ChunkStore, slot: terrain.ChunkStore.Slot, section: usize) Connectivity {
    const model = store.model.get(slot) orelse return .open;
    return model.connectivity[section];
}

/// The section on the other side of a face, if there is one
fn stepThrough(coords: coord.Chunk, section: u8, face: coord.Face) ?struct { coords: coord.Chunk, section: u8 } {
    const offset = face.asRelativeBlock();

    const y = @as(i32, section) + offset.y;
    if (y < 0 or y >= chunk.section_count)
        return null;

    return .{
        .coords = .{ .x = coords.x + offset.x, .z = coords.z + offset.z },
        .section = @intCast(y),
    };
}

/// Bit of the direction that would take the walk back towards the camera
inline fn backMask(face: coord.Face) u8 {
    return @as(u8, 1) << @intCast(face.opposite().index());
}

/// Every loaded section that survives frustum culling, for when there is no
/// section to start the walk from
fn gatherEverything(self: *VisibleSet, store: *const terrain.ChunkStore, frustum: Frustum) !void {
    for (store.live.items) |slot| {
        const coords = store.coords.get(slot);
        if (!frustum.containsChunk(coords))
            continue;

        for (0..chunk.section_count) |section| {
            if (!frustum.containsSection(coords, section))
                continue;
            try self.visible.append(self.alloc, .{
                .slot = slot,
                .coords = coords,
                .section = @intCast(section),
            });
        }
    }
}
