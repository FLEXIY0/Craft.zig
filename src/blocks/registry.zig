//! Block registry: turns the declarative block list into flat runtime tables.
//!
//! Everything here is baked at comptime, so at runtime a block "type" is nothing
//! but its `Id`, and asking a question about it is either
//!  - an indexed load in a small SoA table (`tex[face][id]`, `flags[id]`), or
//!  - a single shift and mask on a 256 bit set (`(set >> id) & 1`).
//!
//! There is no `Block` struct at runtime, and no branch on the block type in any
//! hot loop: the mesher pulls whole bit sets and processes 128 blocks worth of
//! "is this an opaque cube" per instruction.

const std = @import("std");

const Face = @import("coord").Face;

const atlas = @import("atlas");
const definitions = @import("definitions.zig");

pub const Block = @import("Block.zig");
pub const Model = Block.Model;
pub const Tint = Block.Tint;
pub const Flags = Block.Flags;

/// A block id, as used by the protocol and the chunk storage
pub const Id = u8;

/// Amount of distinct block ids
pub const count = 256;

/// A set of block ids, one bit per id.
/// Tested with `(set >> id) & 1`, which is why it is exactly `count` bits wide.
pub const Set = std.meta.Int(.unsigned, count);

comptime {
    // The shift amount of a `Set` must be exactly an `Id`, otherwise every
    // membership test would need a cast (and a bounds check in safe builds)
    std.debug.assert(std.math.Log2Int(Set) == Id);
}

/// Membership test of a block id in a set of block ids
pub inline fn isIn(id_set: Set, block_id: Id) bool {
    return @as(u1, @truncate(id_set >> block_id)) != 0;
}

/// Everything the registry bakes, in one comptime pass over the definitions
const baked = blk: {
    @setEvalBranchQuota(20000);

    var b: struct {
        names: [count][]const u8 = @splat(""),
        flags: [count]Flags = @splat(.{}),
        tex: [Face.count][count]u8 = @splat(@splat(atlas.no_tex)),
        defined: Set = 0,
        invisible: Set = 0,
        full_cube: Set = 0,
        opaque_cube: Set = 0,
        transparent: Set = 0,
        hitbox: Set = 0,
        special_model: Set = 0,
        tinted: Set = 0,
    } = .{};

    // Undefined ids keep the default `Block` behaviour: they render as a full
    // cube with the "missing texture" tile, which makes unimplemented blocks
    // obvious instead of invisible
    for (0..count) |undefined_id| {
        b.flags[undefined_id] = .{};
        b.full_cube |= @as(Set, 1) << undefined_id;
        b.opaque_cube |= @as(Set, 1) << undefined_id;
        b.hitbox |= @as(Set, 1) << undefined_id;
    }

    for (definitions.list) |def| {
        const bit = @as(Set, 1) << def.id;

        if (b.defined & bit != 0)
            @compileError("Duplicate block id in the block definitions: " ++ def.block.name);
        b.defined |= bit;

        b.names[def.id] = def.block.name;
        b.flags[def.id] = def.block.flags;

        for (0..Face.count) |face|
            b.tex[face][def.id] = def.block.tex.ofFace(face);

        // Reset the "undefined block" defaults before applying the real ones
        b.invisible &= ~bit;
        b.full_cube &= ~bit;
        b.opaque_cube &= ~bit;
        b.transparent &= ~bit;
        b.hitbox &= ~bit;
        b.special_model &= ~bit;
        b.tinted &= ~bit;

        const def_flags = def.block.flags;
        if (def_flags.model.isInvisible())
            b.invisible |= bit;
        if (def_flags.model.isFullCube())
            b.full_cube |= bit;
        if (def_flags.isOpaqueCube())
            b.opaque_cube |= bit;
        if (def_flags.transparent)
            b.transparent |= bit;
        if (def_flags.hitbox)
            b.hitbox |= bit;
        if (!def_flags.model.isInvisible() and !def_flags.model.isFullCube())
            b.special_model |= bit;
        if (def_flags.tint != .none)
            b.tinted |= bit;
    }

    break :blk b;
};

/// Name of every block, for debugging and for the generated enum
pub const names: [count][]const u8 = baked.names;

/// Model, render layer, collision and tint of every block
pub const flags: [count]Flags = baked.flags;

/// Texture id of every block, per face: `tex[face][id]`.
/// SoA on purpose: meshing a plane only ever touches one face row.
pub const tex: [Face.count][count]u8 = baked.tex;

/// Bit sets of block ids, tested with `isIn(set, id)`
pub const set = struct {
    /// Ids that actually have a definition
    pub const defined: Set = baked.defined;
    /// Ids that generate no geometry at all (air)
    pub const invisible: Set = baked.invisible;
    /// Ids whose model is exactly one full cube: the greedy mesher handles those
    pub const full_cube: Set = baked.full_cube;
    /// Ids that hide the faces of their neighbors
    pub const opaque_cube: Set = baked.opaque_cube;
    /// Ids that must be drawn on the transparent layer
    pub const transparent: Set = baked.transparent;
    /// Ids the player collides with
    pub const hitbox: Set = baked.hitbox;
    /// Ids that need the per-block mesher (plants, slabs, liquids...)
    pub const special_model: Set = baked.special_model;
    /// Ids whose vertices are tinted
    pub const tinted: Set = baked.tinted;
};

/// Name of a block, empty for undefined blocks
pub inline fn nameOf(block_id: Id) []const u8 {
    return names[block_id];
}

/// Flags of a block
pub inline fn flagsOf(block_id: Id) Flags {
    return flags[block_id];
}

/// Model of a block
pub inline fn modelOf(block_id: Id) Model {
    return flags[block_id].model;
}

/// Tint of a block
pub inline fn tintOf(block_id: Id) Tint {
    return flags[block_id].tint;
}

/// Texture id of one face of a block
pub inline fn texOf(face: Face, block_id: Id) u8 {
    return tex[face.index()][block_id];
}

/// True if the block generates no geometry
pub inline fn isInvisible(block_id: Id) bool {
    return isIn(set.invisible, block_id);
}

/// True if the block hides the faces of its neighbors
pub inline fn isOpaqueCube(block_id: Id) bool {
    return isIn(set.opaque_cube, block_id);
}

/// True if the block is exactly one full cube (mergeable by the greedy mesher)
pub inline fn isFullCube(block_id: Id) bool {
    return isIn(set.full_cube, block_id);
}

/// True if the block belongs to the transparent render layer
pub inline fn isTransparent(block_id: Id) bool {
    return isIn(set.transparent, block_id);
}

/// True if the player collides with the block
pub inline fn hasHitbox(block_id: Id) bool {
    return isIn(set.hitbox, block_id);
}

/// True if the block needs the slow per-block mesher
pub inline fn hasSpecialModel(block_id: Id) bool {
    return isIn(set.special_model, block_id);
}

/// Generate the blocks enum at compile time, from the block names
pub const Blocks = blk: {
    @setEvalBranchQuota(20000);
    var fields_ret: []const std.builtin.Type.EnumField = &.{};

    for (names, 0..) |name, i| {
        // Block doesn't exist
        if (name.len == 0)
            continue;

        // Check that we didn't already add that name
        if (for (fields_ret) |existing_field| {
            if (std.mem.eql(u8, existing_field.name, name))
                break true;
        } else false)
            continue;

        // Add to the fields
        fields_ret = fields_ret ++ &[_]std.builtin.Type.EnumField{.{
            .name = (name ++ &[_]u8{0})[0..name.len :0],
            .value = i,
        }};
    }

    // Reify
    break :blk @Type(.{ .@"enum" = .{
        .decls = &.{},
        .fields = fields_ret,
        .is_exhaustive = false,
        .tag_type = Id,
    } });
};

/// Id of a block, by name, resolved at comptime
pub inline fn idOf(comptime name: @TypeOf(.enum_literal)) Id {
    return @intFromEnum(@field(Blocks, @tagName(name)));
}

test "registry queries" {
    try std.testing.expect(isInvisible(idOf(.air)));
    try std.testing.expect(!isOpaqueCube(idOf(.air)));
    try std.testing.expect(!hasHitbox(idOf(.air)));

    try std.testing.expect(isOpaqueCube(idOf(.stone)));
    try std.testing.expect(isFullCube(idOf(.stone)));
    try std.testing.expect(hasHitbox(idOf(.stone)));
    try std.testing.expect(!hasSpecialModel(idOf(.stone)));

    // Glass is a full cube but doesn't occlude its neighbors
    try std.testing.expect(isFullCube(idOf(.glass)));
    try std.testing.expect(!isOpaqueCube(idOf(.glass)));
    try std.testing.expect(isTransparent(idOf(.glass)));

    // Slabs and plants go through the per-block mesher
    try std.testing.expect(hasSpecialModel(idOf(.step)));
    try std.testing.expect(hasSpecialModel(idOf(.tallgrass)));
    try std.testing.expect(!isOpaqueCube(idOf(.step)));

    // Undefined ids render as full "missing texture" cubes
    try std.testing.expect(!isIn(set.defined, 100));
    try std.testing.expect(isOpaqueCube(100));
    try std.testing.expectEqual(atlas.no_tex, texOf(.north, 100));
}

test "per face textures" {
    // Barrel: sides, top and bottom
    try std.testing.expectEqual(atlas.at(3, 0), texOf(.north, idOf(.grass)));
    try std.testing.expectEqual(atlas.at(3, 0), texOf(.east, idOf(.grass)));
    try std.testing.expectEqual(atlas.at(0, 0), texOf(.up, idOf(.grass)));
    try std.testing.expectEqual(atlas.at(2, 0), texOf(.down, idOf(.grass)));

    // Advanced: one texture per face
    try std.testing.expectEqual(atlas.at(12, 3), texOf(.north, idOf(.workbench)));
    try std.testing.expectEqual(atlas.at(11, 3), texOf(.east, idOf(.workbench)));
    try std.testing.expectEqual(atlas.at(11, 2), texOf(.up, idOf(.workbench)));

    // Tints are data, not a switch in the mesher
    try std.testing.expectEqual(Tint.grass_top, tintOf(idOf(.grass)));
    try std.testing.expectEqual(Tint.foliage, tintOf(idOf(.leaves)));
    try std.testing.expectEqual(Tint.none, tintOf(idOf(.stone)));
}

test "sets are consistent" {
    for (0..count) |i| {
        const block_id: Id = @intCast(i);
        // A block is either invisible, a full cube, or handled by the special mesher
        const kinds = @as(u8, @intFromBool(isInvisible(block_id))) +
            @intFromBool(isFullCube(block_id)) +
            @intFromBool(hasSpecialModel(block_id));
        try std.testing.expectEqual(@as(u8, 1), kinds);
        // Occluding implies being a full cube
        if (isOpaqueCube(block_id))
            try std.testing.expect(isFullCube(block_id));
    }
}
