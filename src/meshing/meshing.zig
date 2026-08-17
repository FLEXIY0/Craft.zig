//! Root of the meshing module: turning chunks into triangles.
//!
//! The pipeline is:
//!
//!   ChunkStore ──snapshot──▶ Scheduler ──job──▶ Mesher ──▶ MeshData ──▶ frontend
//!
//!  - `Snapshot`  an owned copy of a chunk and of its neighbors' borders
//!  - `Scheduler` lock free job/result queues and the worker threads
//!  - `Mesher`    the greedy pass plus the per-block pass for odd models
//!  - `MeshData`  SoA vertex buffers, allocated so the frontend can take them
//!
//! Nothing in here knows about the graphics API: the frontend only receives
//! flat attribute arrays.

const std = @import("std");

pub const MeshData = @import("MeshData.zig");
pub const Mesher = @import("Mesher.zig");
pub const Snapshot = @import("Snapshot.zig");
pub const Scheduler = @import("Scheduler.zig");
pub const Layers = @import("Layers.zig");
pub const shading = @import("shading.zig");
pub const greedy = @import("greedy.zig");
pub const special = @import("special.zig");
pub const queue = @import("queue.zig");

pub const Part = MeshData.Part;
pub const VertexIdT = MeshData.VertexIdT;

test "meshing module" {
    std.testing.refAllDecls(@This());
}
