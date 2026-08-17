//! Declarative description of a single block type.
//!
//! Instances of this struct only ever exist at comptime: `definitions.zig` lists
//! them, `registry.zig` bakes them down into flat SoA tables and bitmasks. No
//! runtime code should ever hold a `Block`.

const std = @import("std");
const atlas = @import("atlas");

pub const Block = @This();

/// Block name, also used to generate the block enum. Empty means "not a block"
name: []const u8 = "",
/// Textures of the block, per face
tex: Tex = .none,
/// Model, render layer, collision and tint, packed in a single byte
flags: Flags = .{},

/// Texture assignment of a block, expanded to one texture id per face at comptime
pub const Tex = union(enum) {
    /// No texture at all (undefined blocks, invisible blocks)
    none,
    /// Same texture on all six faces
    all: u8,
    /// One texture for the sides, one for the top, one for the bottom
    barrel: struct { side: u8, top: u8, bottom: u8 },
    /// One texture per face
    faces: struct { north: u8, east: u8, south: u8, west: u8, top: u8, bottom: u8 },

    /// Texture id of a face, in `coord.Face` order
    pub fn ofFace(self: Tex, face: usize) u8 {
        return switch (self) {
            .none => atlas.no_tex,
            .all => |t| t,
            .barrel => |t| switch (face) {
                4 => t.top,
                5 => t.bottom,
                else => t.side,
            },
            .faces => |t| switch (face) {
                0 => t.north,
                1 => t.east,
                2 => t.south,
                3 => t.west,
                4 => t.top,
                5 => t.bottom,
                else => unreachable,
            },
        };
    }
};

/// Enumeration of all block models and their uv variants
pub const Model = enum(u4) {
    full_basic, // Cube with same texture on each faces
    full_barrel, // Cube with side texture, top and bottom
    full_advanced, // Cube with texture for each face
    slab,
    plant,
    cactus,
    liquid_still,
    snow_layer,
    // and others...
    /// No geometry at all
    air,

    /// True for the models that are exactly one full cube, i.e. the models the
    /// greedy mesher is able to merge into bigger quads
    pub inline fn isFullCube(self: Model) bool {
        return switch (self) {
            .full_basic, .full_barrel, .full_advanced => true,
            else => false,
        };
    }

    /// True for the models that produce no geometry at all
    pub inline fn isInvisible(self: Model) bool {
        return self == .air;
    }
};

/// Vertex tint applied on top of the texture
pub const Tint = enum(u2) {
    /// No tint (white vertices)
    none,
    /// Grass tint, but only on the top face (grass block)
    grass_top,
    /// Foliage tint on every face (leaves, tall grass)
    foliage,
};

/// Packed bitfield for model related flags (for compaction)
pub const Flags = packed struct(u8) {
    /// Model and UV used
    model: Model = .full_basic,
    /// Texture has transparent parts (should be rendered on a different layer)
    transparent: bool = false,
    /// Can be walked through
    hitbox: bool = true, // Later: enum
    /// Vertex tint of the block
    tint: Tint = .none,

    /// Returns true if the block is a full opaque block, i.e. a block that hides
    /// the faces of its neighbors
    pub inline fn isOpaqueCube(self: Flags) bool {
        return self.model.isFullCube() and !self.transparent;
    }
};

// TODO: direction-based opacity: example: slab occults face below but not others

test "flags fit in a byte" {
    try std.testing.expectEqual(1, @sizeOf(Flags));
    try std.testing.expect((Flags{ .model = .full_basic }).isOpaqueCube());
    try std.testing.expect(!(Flags{ .model = .full_basic, .transparent = true }).isOpaqueCube());
    try std.testing.expect(!(Flags{ .model = .slab }).isOpaqueCube());
}
