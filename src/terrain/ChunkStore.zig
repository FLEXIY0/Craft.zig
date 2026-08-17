//! Storage of all the loaded chunks, laid out as a struct of arrays.
//!
//! A chunk is not an object: it is a *slot*, i.e. an index that addresses one
//! item in each of the component pools below. Systems that only care about one
//! aspect of a chunk (the remesh scheduler looks at revisions, the renderer
//! looks at models and coordinates) walk a small dense array instead of chasing
//! pointers through a hash map of fat structs.
//!
//! Slot indices are stable for the whole lifetime of a chunk, and pool pages are
//! never reallocated, so a pointer to a chunk's block data stays valid while
//! other chunks are loaded or unloaded.

const std = @import("std");
const coord = @import("coord");
const io = @import("io");

const chunk = @import("chunk.zig");
const Pool = @import("pool.zig").Pool;
const LightLevel = @import("light_level.zig").LightLevel;

const ChunkStore = @This();

/// Index of a chunk in the store
pub const Slot = u32;

/// Slot value that addresses no chunk
pub const invalid_slot: Slot = std.math.maxInt(Slot);

/// Block ids of a whole chunk
pub const BlockIds = [chunk.volume]u8;
/// One nibble per block of a chunk (metadata, block light, sky light)
pub const Nibbles = [chunk.nibble_len]u8;
/// Amount of non-air blocks per section
pub const SectionCounts = [chunk.section_count]u16;

/// Light level returned for blocks outside of the loaded world
pub const default_light: LightLevel = .{ .blocklight = 0, .skylight = 15 };

/// Slots per page for the small per-chunk components
const meta_page = 256;
/// Slots per page for the big per-block arrays (16 * 32K = 512K per page)
const data_page = 16;

alloc: std.mem.Allocator,

/// Coordinates to slot lookup
map: std.AutoHashMapUnmanaged(coord.Chunk, Slot) = .empty,
/// Dense list of the loaded slots, for iteration
live: std.ArrayListUnmanaged(Slot) = .empty,
/// Slots that were freed and can be reused
recycled: std.ArrayListUnmanaged(Slot) = .empty,
/// Amount of slots ever handed out
slot_count: Slot = 0,

// Per-chunk components
/// Coordinates of the chunk
coords: Pool(coord.Chunk, meta_page) = .{},
/// Position of the slot inside `live`, for O(1) removal
live_at: Pool(u32, meta_page) = .{},
/// True while the slot holds a loaded chunk
loaded: Pool(bool, meta_page) = .{},
/// Bumped on every block edit, used to detect stale meshes
revision: Pool(u32, meta_page) = .{},
/// Revision the current model was generated from
meshed_revision: Pool(u32, meta_page) = .{},
/// True while the chunk sits in the remesh queue
queued: Pool(bool, meta_page) = .{},
/// True while a meshing job for that chunk is running
in_flight: Pool(bool, meta_page) = .{},
/// Renderable model, owned by the frontend
model: Pool(?io.ChunkModel, meta_page) = .{},
/// Amount of non-air blocks per section, used to skip chunks that hold nothing
sections: Pool(SectionCounts, meta_page) = .{},

// Per-block data
/// Block ids
ids: Pool(BlockIds, data_page) = .{},
/// Block metadata, one nibble per block
meta: Pool(Nibbles, data_page) = .{},
/// Block light, one nibble per block
blocklight: Pool(Nibbles, data_page) = .{},
/// Sky light, one nibble per block
skylight: Pool(Nibbles, data_page) = .{},

pub fn init(alloc: std.mem.Allocator) ChunkStore {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *ChunkStore) void {
    for (self.live.items) |slot| {
        if (self.model.get(slot)) |model|
            model.deinit(self.alloc);
    }

    self.map.deinit(self.alloc);
    self.live.deinit(self.alloc);
    self.recycled.deinit(self.alloc);

    self.coords.deinit(self.alloc);
    self.live_at.deinit(self.alloc);
    self.loaded.deinit(self.alloc);
    self.revision.deinit(self.alloc);
    self.meshed_revision.deinit(self.alloc);
    self.queued.deinit(self.alloc);
    self.in_flight.deinit(self.alloc);
    self.model.deinit(self.alloc);
    self.sections.deinit(self.alloc);

    self.ids.deinit(self.alloc);
    self.meta.deinit(self.alloc);
    self.blocklight.deinit(self.alloc);
    self.skylight.deinit(self.alloc);
}

/// Slot of a loaded chunk, if any
pub fn find(self: ChunkStore, coords: coord.Chunk) ?Slot {
    return self.map.get(coords);
}

/// True if the slot currently holds the chunk at `coords`
pub fn holds(self: ChunkStore, slot: Slot, coords: coord.Chunk) bool {
    if (slot >= self.slot_count or !self.loaded.get(slot))
        return false;
    const slot_coords = self.coords.get(slot);
    return slot_coords.x == coords.x and slot_coords.z == coords.z;
}

/// Loads an empty chunk at the given coordinates, or returns the existing slot
pub fn load(self: *ChunkStore, coords: coord.Chunk) !Slot {
    if (self.find(coords)) |existing|
        return existing;

    const slot = self.recycled.pop() orelse blk: {
        const new_slot = self.slot_count;
        self.slot_count += 1;
        break :blk new_slot;
    };

    // Make sure every component of that slot exists and is zeroed
    _ = try self.coords.ensure(self.alloc, slot, .{});
    _ = try self.live_at.ensure(self.alloc, slot, 0);
    _ = try self.loaded.ensure(self.alloc, slot, false);
    _ = try self.revision.ensure(self.alloc, slot, 0);
    _ = try self.meshed_revision.ensure(self.alloc, slot, 0);
    _ = try self.queued.ensure(self.alloc, slot, false);
    _ = try self.in_flight.ensure(self.alloc, slot, false);
    _ = try self.model.ensure(self.alloc, slot, null);
    _ = try self.sections.ensure(self.alloc, slot, @splat(0));
    _ = try self.ids.ensure(self.alloc, slot, @splat(0));
    _ = try self.meta.ensure(self.alloc, slot, @splat(0));
    _ = try self.blocklight.ensure(self.alloc, slot, @splat(0));
    _ = try self.skylight.ensure(self.alloc, slot, @splat(0));

    try self.map.put(self.alloc, coords, slot);
    errdefer _ = self.map.remove(coords);

    try self.live.append(self.alloc, slot);

    // A recycled slot still holds the previous chunk's data
    @memset(self.ids.at(slot), 0);
    @memset(self.meta.at(slot), 0);
    @memset(self.blocklight.at(slot), 0);
    @memset(self.skylight.at(slot), 0);
    self.sections.put(slot, @splat(0));

    self.coords.put(slot, coords);
    self.loaded.put(slot, true);
    self.live_at.put(slot, @intCast(self.live.items.len - 1));
    self.queued.put(slot, false);
    self.model.put(slot, null);
    // Keep counting up: an in flight job for the recycled slot must not be
    // mistaken for a fresh result. A freshly loaded chunk is empty, so it
    // starts out with nothing to remesh until data actually arrives.
    self.revision.put(slot, self.revision.get(slot) +% 1);
    self.meshed_revision.put(slot, self.revision.get(slot));

    return slot;
}

/// Unloads the chunk at the given coordinates, if it is loaded
pub fn unload(self: *ChunkStore, coords: coord.Chunk) void {
    const slot = self.find(coords) orelse return;

    if (self.model.get(slot)) |model| {
        model.deinit(self.alloc);
        self.model.put(slot, null);
    }

    // Swap remove from the dense live list
    const position = self.live_at.get(slot);
    const last = self.live.items[self.live.items.len - 1];
    self.live.items[position] = last;
    self.live_at.put(last, position);
    _ = self.live.pop();

    self.loaded.put(slot, false);
    self.queued.put(slot, false);
    self.revision.put(slot, self.revision.get(slot) +% 1);
    _ = self.map.remove(coords);

    // A slot with a job in flight can not be reused right away: the result
    // would land on the wrong chunk. It is recycled when the job comes back.
    if (!self.in_flight.get(slot))
        self.recycled.append(self.alloc, slot) catch {};
}

/// Gives back a slot whose last job just came back
pub fn recycle(self: *ChunkStore, slot: Slot) void {
    if (self.loaded.get(slot))
        return;
    self.recycled.append(self.alloc, slot) catch {};
}

/// Marks the chunk as edited, so that its model is rebuilt
pub inline fn touch(self: *ChunkStore, slot: Slot) void {
    self.revision.put(slot, self.revision.get(slot) +% 1);
}

/// True if the model of that chunk is out of date
pub inline fn needsRemesh(self: ChunkStore, slot: Slot) bool {
    return self.revision.get(slot) != self.meshed_revision.get(slot);
}

/// Replaces the model of a chunk, freeing the previous one
pub fn setModel(self: *ChunkStore, slot: Slot, new_model: ?io.ChunkModel) void {
    if (self.model.get(slot)) |old|
        old.deinit(self.alloc);
    self.model.put(slot, new_model);
}

// --- Block accessors -------------------------------------------------------

/// Block id at local coordinates, 0 (air) if outside of the chunk
pub inline fn getBlockId(self: ChunkStore, slot: Slot, pos: coord.Block) u8 {
    if (!pos.isWithinChunk())
        return 0;
    return self.ids.at(slot)[chunk.indexFromCoord(pos)];
}

/// Block metadata at local coordinates, 0 if outside of the chunk
pub inline fn getBlockMeta(self: ChunkStore, slot: Slot, pos: coord.Block) u4 {
    if (!pos.isWithinChunk())
        return 0;
    return readNibble(self.meta.at(slot), chunk.indexFromCoord(pos));
}

/// Light levels at local coordinates, full sky light if outside of the chunk
pub inline fn getLight(self: ChunkStore, slot: Slot, pos: coord.Block) LightLevel {
    if (!pos.isWithinChunk())
        return default_light;
    const index = chunk.indexFromCoord(pos);
    return .{
        .blocklight = readNibble(self.blocklight.at(slot), index),
        .skylight = readNibble(self.skylight.at(slot), index),
    };
}

/// Sets a block id and its metadata at local coordinates
pub fn setBlockIdAndMetadata(self: *ChunkStore, slot: Slot, pos: coord.Block, block_id: u8, block_meta: u4) void {
    std.debug.assert(pos.isWithinChunk());

    const index = chunk.indexFromCoord(pos);
    const ids = self.ids.at(slot);

    // Keep the per-section non-air counts up to date
    const old_id = ids[index];
    if ((old_id == 0) != (block_id == 0)) {
        const counts = self.sections.at(slot);
        const section = chunk.sectionOfIndex(index);
        if (block_id == 0) counts[section] -= 1 else counts[section] += 1;
    }

    ids[index] = block_id;
    writeNibble(self.meta.at(slot), index, block_meta);

    self.touch(slot);
}

/// Amount of non-air blocks in a section
pub inline fn sectionCount(self: ChunkStore, slot: Slot, section: usize) u16 {
    return self.sections.at(slot)[section];
}

/// True if the chunk holds nothing but air, in which case there is nothing to
/// mesh at all. Servers send plenty of those.
pub fn isEmpty(self: ChunkStore, slot: Slot) bool {
    for (self.sections.at(slot)) |count| {
        if (count != 0)
            return false;
    }
    return true;
}

/// Applies a piece of chunk data as sent by the server, returns the unread rest.
/// The area is given in chunk local coordinates.
pub fn setChunkData(self: *ChunkStore, slot: Slot, data: []const u8, x1: i32, y1: i32, z1: i32, x2: i32, y2: i32, z2: i32) []const u8 {
    var remaining = data;

    const dy: usize = @intCast(@abs(y2 - y1));
    const half_dy = dy / 2;

    const ids = self.ids.at(slot);
    const metas = self.meta.at(slot);
    const blocklights = self.blocklight.at(slot);
    const skylights = self.skylight.at(slot);

    // Block ids (a vertical run at a time, columns are contiguous)
    var x = x1;
    while (x < x2) : (x += 1) {
        var z = z1;
        while (z < z2) : (z += 1) {
            const offset = chunk.columnBase(@intCast(x), @intCast(z)) + @as(usize, @intCast(y1));
            @memcpy(ids[offset..][0..dy], remaining[0..dy]);
            remaining = remaining[dy..];
        }
    }

    // Nibble arrays: metadata, block light and sky light, in that order
    for ([_][]u8{ metas, blocklights, skylights }) |dest| {
        x = x1;
        while (x < x2) : (x += 1) {
            var z = z1;
            while (z < z2) : (z += 1) {
                const offset = (chunk.columnBase(@intCast(x), @intCast(z)) + @as(usize, @intCast(y1))) / 2;
                @memcpy(dest[offset..][0..half_dy], remaining[0..half_dy]);
                remaining = remaining[half_dy..];
            }
        }
    }

    self.recountSections(slot);
    self.touch(slot);

    return remaining;
}

/// Recomputes the per-section non-air counts of a chunk
pub fn recountSections(self: *ChunkStore, slot: Slot) void {
    const ids = self.ids.at(slot);
    var counts: SectionCounts = @splat(0);

    for (0..chunk.area) |column| {
        const base = column * chunk.height;
        for (0..chunk.section_count) |section| {
            var count: u16 = 0;
            for (ids[base + section * chunk.section_height ..][0..chunk.section_height]) |block_id| {
                count += @intFromBool(block_id != 0);
            }
            counts[section] += count;
        }
    }

    self.sections.put(slot, counts);
}

// --- Nibble helpers --------------------------------------------------------

/// Reads the nibble of a block in a half-sized array
pub inline fn readNibble(array: []const u8, index: usize) u4 {
    const byte = array[index / 2];
    return if (index % 2 == 0)
        @intCast(byte & 0x0f)
    else
        @intCast((byte & 0xf0) >> 4);
}

/// Writes the nibble of a block in a half-sized array
pub inline fn writeNibble(array: []u8, index: usize, value: u4) void {
    const byte = &array[index / 2];
    if (index % 2 == 0) {
        byte.* = (byte.* & 0xf0) | value;
    } else {
        byte.* = (byte.* & 0x0f) | (@as(u8, value) << 4);
    }
}

test "nibbles" {
    var array: [4]u8 = @splat(0);
    writeNibble(&array, 0, 3);
    writeNibble(&array, 1, 12);
    writeNibble(&array, 7, 5);

    try std.testing.expectEqual(@as(u4, 3), readNibble(&array, 0));
    try std.testing.expectEqual(@as(u4, 12), readNibble(&array, 1));
    try std.testing.expectEqual(@as(u4, 5), readNibble(&array, 7));
    try std.testing.expectEqual(@as(u4, 0), readNibble(&array, 6));
    try std.testing.expectEqual(@as(u8, 0xc3), array[0]);
}

test "load, edit and unload chunks" {
    var store: ChunkStore = .init(std.testing.allocator);
    defer store.deinit();

    const slot = try store.load(.{ .x = 1, .z = -2 });
    try std.testing.expectEqual(slot, store.find(.{ .x = 1, .z = -2 }).?);
    try std.testing.expect(store.holds(slot, .{ .x = 1, .z = -2 }));
    try std.testing.expectEqual(@as(usize, 1), store.live.items.len);

    // Loading twice gives the same slot
    try std.testing.expectEqual(slot, try store.load(.{ .x = 1, .z = -2 }));

    const pos: coord.Block = .{ .x = 3, .y = 40, .z = 9 };
    const revision = store.revision.get(slot);
    store.setBlockIdAndMetadata(slot, pos, 7, 5);

    try std.testing.expectEqual(@as(u8, 7), store.getBlockId(slot, pos));
    try std.testing.expectEqual(@as(u4, 5), store.getBlockMeta(slot, pos));
    try std.testing.expect(store.revision.get(slot) != revision);
    try std.testing.expectEqual(@as(u16, 1), store.sectionCount(slot, 2));

    // Out of bounds reads are air and full sky light
    try std.testing.expectEqual(@as(u8, 0), store.getBlockId(slot, .{ .x = -1, .y = 40, .z = 9 }));
    try std.testing.expectEqual(default_light, store.getLight(slot, .{ .x = 16, .y = 40, .z = 9 }));

    // Removing a block again empties the section
    store.setBlockIdAndMetadata(slot, pos, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), store.sectionCount(slot, 2));

    store.unload(.{ .x = 1, .z = -2 });
    try std.testing.expectEqual(@as(?Slot, null), store.find(.{ .x = 1, .z = -2 }));
    try std.testing.expectEqual(@as(usize, 0), store.live.items.len);

    // The slot is reused, and comes back empty
    const other = try store.load(.{ .x = 5, .z = 5 });
    try std.testing.expectEqual(slot, other);
    try std.testing.expectEqual(@as(u8, 0), store.getBlockId(other, pos));
}

test "live list stays dense" {
    var store: ChunkStore = .init(std.testing.allocator);
    defer store.deinit();

    for (0..8) |i| {
        _ = try store.load(.{ .x = @intCast(i), .z = 0 });
    }
    store.unload(.{ .x = 3, .z = 0 });
    store.unload(.{ .x = 0, .z = 0 });

    try std.testing.expectEqual(@as(usize, 6), store.live.items.len);
    for (store.live.items) |slot| {
        try std.testing.expect(store.loaded.get(slot));
        try std.testing.expectEqual(slot, store.live.items[store.live_at.get(slot)]);
    }
}
