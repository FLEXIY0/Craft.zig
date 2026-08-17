//! The block data of the game, as plain data.
//!
//! This is a *data-driven registry*: this file contains no logic, only a sparse
//! list of block definitions. `registry.zig` turns it into flat lookup tables and
//! bitmasks at comptime, so adding a block never means touching any code path.

const Block = @import("Block.zig");
const atlas = @import("atlas");

/// A block definition bound to its network id
pub const Def = struct {
    /// Block id as used by the protocol and by the chunk storage
    id: u8,
    /// The block itself
    block: Block,
};

/// Shorthand for a tile of the atlas
const t = atlas.at;

/// Every block the client knows about.
/// Ids that are missing from this list are simply "undefined blocks": they are
/// stored and sent around, but they render and behave like air.
pub const list = [_]Def{
    .{ .id = 0, .block = .{ .name = "air", .flags = .{ .model = .air, .hitbox = false, .transparent = true } } },
    .{ .id = 1, .block = .{ .name = "stone", .tex = .{ .all = t(1, 0) } } },
    .{ .id = 2, .block = .{
        .name = "grass",
        .tex = .{ .barrel = .{ .side = t(3, 0), .top = t(0, 0), .bottom = t(2, 0) } },
        .flags = .{ .model = .full_barrel, .tint = .grass_top },
    } },
    .{ .id = 3, .block = .{ .name = "dirt", .tex = .{ .all = t(2, 0) } } },
    .{ .id = 4, .block = .{ .name = "cobblestone", .tex = .{ .all = t(0, 1) } } },
    .{ .id = 5, .block = .{ .name = "wood", .tex = .{ .all = t(4, 0) } } },
    .{ .id = 6, .block = .{
        .name = "sapling",
        .tex = .{ .all = t(15, 0) },
        .flags = .{ .transparent = true, .hitbox = false },
    } },
    .{ .id = 7, .block = .{ .name = "bedrock", .tex = .{ .all = t(1, 1) } } },
    .{ .id = 8, .block = .{
        .name = "water",
        .tex = .{ .all = t(15, 12) },
        .flags = .{ .transparent = true, .hitbox = false },
    } },
    .{ .id = 9, .block = .{
        .name = "water",
        .tex = .{ .all = t(15, 12) },
        .flags = .{ .model = .liquid_still, .transparent = true, .hitbox = false },
    } },
    .{ .id = 10, .block = .{
        .name = "lava",
        .tex = .{ .all = t(15, 14) },
        .flags = .{ .hitbox = false },
    } },
    .{ .id = 11, .block = .{
        .name = "lava",
        .tex = .{ .all = t(15, 14) },
        .flags = .{ .model = .liquid_still, .hitbox = false },
    } },
    .{ .id = 12, .block = .{ .name = "sand", .tex = .{ .all = t(2, 1) } } },
    .{ .id = 13, .block = .{ .name = "gravel", .tex = .{ .all = t(3, 1) } } },
    .{ .id = 14, .block = .{ .name = "oreGold", .tex = .{ .all = t(0, 2) } } },
    .{ .id = 15, .block = .{ .name = "oreIron", .tex = .{ .all = t(1, 2) } } },
    .{ .id = 16, .block = .{ .name = "oreCoal", .tex = .{ .all = t(2, 2) } } },
    .{ .id = 17, .block = .{
        .name = "log",
        .tex = .{ .barrel = .{ .side = t(4, 1), .top = t(5, 1), .bottom = t(5, 1) } },
        .flags = .{ .model = .full_barrel },
    } },
    .{ .id = 18, .block = .{
        .name = "leaves",
        .tex = .{ .all = t(4, 3) },
        .flags = .{ .transparent = true, .tint = .foliage },
    } },
    .{ .id = 20, .block = .{
        .name = "glass",
        .tex = .{ .all = t(1, 3) },
        .flags = .{ .transparent = true },
    } },
    .{ .id = 21, .block = .{ .name = "oreLapis", .tex = .{ .all = t(0, 10) } } },
    .{ .id = 24, .block = .{
        .name = "sandStone",
        .tex = .{ .barrel = .{ .side = t(0, 12), .top = t(0, 11), .bottom = t(0, 13) } },
        .flags = .{ .model = .full_barrel },
    } },
    .{ .id = 31, .block = .{
        .name = "tallgrass",
        .tex = .{ .all = t(7, 2) },
        .flags = .{ .model = .plant, .transparent = true, .hitbox = false, .tint = .foliage },
    } },
    .{ .id = 32, .block = .{
        .name = "deadbush",
        .tex = .{ .all = t(7, 3) },
        .flags = .{ .model = .plant, .transparent = true, .hitbox = false },
    } },
    .{ .id = 37, .block = .{
        .name = "flower",
        .tex = .{ .all = t(13, 0) },
        .flags = .{ .model = .plant, .transparent = true, .hitbox = false },
    } },
    .{ .id = 38, .block = .{
        .name = "rose",
        .tex = .{ .all = t(12, 0) },
        .flags = .{ .model = .plant, .transparent = true, .hitbox = false },
    } },
    .{ .id = 39, .block = .{
        .name = "mushroom",
        .tex = .{ .all = t(13, 1) },
        .flags = .{ .model = .plant, .transparent = true, .hitbox = false },
    } },
    .{ .id = 40, .block = .{
        .name = "mushroom",
        .tex = .{ .all = t(12, 1) },
        .flags = .{ .model = .plant, .transparent = true, .hitbox = false },
    } },
    .{ .id = 44, .block = .{
        .name = "step",
        .tex = .{ .barrel = .{ .side = t(5, 0), .top = t(6, 0), .bottom = t(6, 0) } },
        .flags = .{ .model = .slab },
    } },
    .{ .id = 48, .block = .{ .name = "stoneMoss", .tex = .{ .all = t(4, 2) } } },
    .{ .id = 49, .block = .{ .name = "obsidian", .tex = .{ .all = t(5, 2) } } },
    .{ .id = 52, .block = .{
        .name = "mobSpawner",
        .tex = .{ .all = t(1, 4) },
        .flags = .{ .transparent = true },
    } },
    .{ .id = 56, .block = .{ .name = "oreDiamond", .tex = .{ .all = t(2, 3) } } },
    .{ .id = 58, .block = .{
        .name = "workbench",
        .tex = .{ .faces = .{
            .north = t(12, 3),
            .east = t(11, 3),
            .south = t(11, 3),
            .west = t(12, 3),
            .top = t(11, 2),
            .bottom = t(4, 0),
        } },
        .flags = .{ .model = .full_advanced },
    } },
    .{ .id = 73, .block = .{ .name = "oreRedstone", .tex = .{ .all = t(3, 3) } } },
    .{ .id = 74, .block = .{ .name = "oreRedstone", .tex = .{ .all = t(3, 3) } } },
    .{ .id = 78, .block = .{
        .name = "snow",
        .tex = .{ .all = t(2, 4) },
        .flags = .{ .model = .snow_layer, .hitbox = false },
    } },
    .{ .id = 80, .block = .{ .name = "snow", .tex = .{ .all = t(2, 4) } } },
    .{ .id = 81, .block = .{
        .name = "cactus",
        .tex = .{ .barrel = .{ .side = t(6, 4), .top = t(5, 4), .bottom = t(7, 4) } },
        .flags = .{ .model = .cactus, .transparent = true },
    } },
    .{ .id = 82, .block = .{ .name = "clay", .tex = .{ .all = t(8, 4) } } },
    .{ .id = 83, .block = .{
        .name = "reeds",
        .tex = .{ .all = t(9, 4) },
        .flags = .{ .model = .plant, .transparent = true, .hitbox = false },
    } },
    .{ .id = 86, .block = .{
        .name = "pumpkin",
        .tex = .{ .faces = .{
            .north = t(7, 7),
            .east = t(6, 7),
            .south = t(6, 7),
            .west = t(6, 7),
            .top = t(6, 6),
            .bottom = t(6, 6),
        } },
        .flags = .{ .model = .full_advanced },
    } },
    .{ .id = 91, .block = .{
        .name = "litpumpkin",
        .tex = .{ .faces = .{
            .north = t(8, 7),
            .east = t(6, 7),
            .south = t(6, 7),
            .west = t(6, 7),
            .top = t(6, 6),
            .bottom = t(6, 6),
        } },
        .flags = .{ .model = .full_advanced },
    } },
};
