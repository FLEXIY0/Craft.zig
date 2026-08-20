//! Root of the terrain module.
//!
//! Chunks are stored the data oriented way: `ChunkStore` is a struct of arrays
//! indexed by chunk *slot*, and `chunk.zig` describes the layout of the block
//! data inside one chunk. `World` is the system on top: it applies the server's
//! updates and drives the meshing pipeline.

const std = @import("std");

pub const chunk = @import("chunk.zig");
pub const ChunkStore = @import("ChunkStore.zig");
pub const World = @import("World.zig");
pub const LightLevel = @import("light_level.zig").LightLevel;
pub const Pool = @import("pool.zig").Pool;

/// Index of a chunk in the store
pub const Slot = ChunkStore.Slot;

test "terrain tests" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("pool.zig"));
}
