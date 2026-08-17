const Block = @import("vectors.zig").Block;

pub const Direction = enum {
    north, // -Z
    east, // +X
    south, // +Z
    west, // -X
    up, // +Y
    down, // -Y
    self, // same

    pub inline fn asRelativeBlock(self: Direction) Block {
        return switch (self) {
            .north => .{ .x = 0, .y = 0, .z = -1 },
            .east => .{ .x = 1, .y = 0, .z = 0 },
            .south => .{ .x = 0, .y = 0, .z = 1 },
            .west => .{ .x = -1, .y = 0, .z = 0 },
            .up => .{ .x = 0, .y = 1, .z = 0 },
            .down => .{ .x = 0, .y = -1, .z = 0 },
            .self => .{ .x = 0, .y = 0, .z = 0 },
        };
    }
};

/// A cube face, i.e. a `Direction` without the `self` case
/// The tag values are used to index the per-face arrays of the block registry,
/// so their order is part of the data layout and must not be shuffled around
pub const Face = enum(u3) {
    north = 0, // -Z
    east = 1, // +X
    south = 2, // +Z
    west = 3, // -X
    up = 4, // +Y
    down = 5, // -Y

    /// Amount of distinct faces, i.e. the length of the per-face arrays
    pub const count = 6;

    /// All faces, in data layout order (handy for `inline for`)
    pub const all = [count]Face{ .north, .east, .south, .west, .up, .down };

    /// Index of that face in the per-face arrays
    pub inline fn index(self: Face) usize {
        return @intFromEnum(self);
    }

    /// The equivalent `Direction`
    pub inline fn asDirection(self: Face) Direction {
        return switch (self) {
            .north => .north,
            .east => .east,
            .south => .south,
            .west => .west,
            .up => .up,
            .down => .down,
        };
    }

    /// The face pointing the opposite way
    pub inline fn opposite(self: Face) Face {
        return switch (self) {
            .north => .south,
            .east => .west,
            .south => .north,
            .west => .east,
            .up => .down,
            .down => .up,
        };
    }

    /// Offset of the neighbor block touching that face
    pub inline fn asRelativeBlock(self: Face) Block {
        return self.asDirection().asRelativeBlock();
    }
};
