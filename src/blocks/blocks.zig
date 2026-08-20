//! Root of the blocks module.
//!
//! The block "database" is data-driven and fully baked at comptime:
//!  - `definitions.zig` holds the data (a sparse list of block definitions)
//!  - `atlas.zig` holds the texture atlas layout (meant to be generated)
//!  - `registry.zig` bakes both into flat SoA tables and 256 bit sets
//!
//! Runtime code only ever manipulates `blocks.Id` values and asks the registry.

const std = @import("std");

pub const atlas = @import("atlas");
pub const registry = @import("registry.zig");
pub const definitions = @import("definitions.zig");

pub const Block = registry.Block;
pub const Model = registry.Model;
pub const Tint = registry.Tint;
pub const Flags = registry.Flags;

pub const Id = registry.Id;
pub const Set = registry.Set;
pub const count = registry.count;

/// Enum of all the named blocks, generated from the definitions
pub const Blocks = registry.Blocks;

// Tables
pub const names = registry.names;
pub const flags = registry.flags;
pub const tex = registry.tex;
pub const set = registry.set;

// Queries
pub const isIn = registry.isIn;
pub const idOf = registry.idOf;
pub const nameOf = registry.nameOf;
pub const flagsOf = registry.flagsOf;
pub const modelOf = registry.modelOf;
pub const tintOf = registry.tintOf;
pub const texOf = registry.texOf;
pub const isInvisible = registry.isInvisible;
pub const isOpaqueCube = registry.isOpaqueCube;
pub const isFullCube = registry.isFullCube;
pub const isTransparent = registry.isTransparent;
pub const hasHitbox = registry.hasHitbox;
pub const hasSpecialModel = registry.hasSpecialModel;
pub const hidesSelf = registry.hidesSelf;
pub const blocksSight = registry.blocksSight;

test "blocks module" {
    std.testing.refAllDecls(registry);
    std.testing.refAllDecls(atlas);
}
