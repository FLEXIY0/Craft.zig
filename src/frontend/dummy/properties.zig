//! Properties of the dummy frontend, read by the shared modules

const std = @import("std");

/// Type used by the 3D rendering system for vertex indices (if any)
pub const VertexIdT = usize;

/// Allocator the chunk meshes are built with, from several threads
pub const mesh_allocator: std.mem.Allocator = std.heap.smp_allocator;
