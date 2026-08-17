//! Properties of the raylib frontend, read by the shared modules

const std = @import("std");
const rl = @import("raylib");

/// Type used by the 3D rendering system for vertex indices (if any)
pub const VertexIdT = c_ushort;

/// Allocator the chunk meshes are built with.
/// Raylib frees the buffers of a mesh itself when the mesh is unloaded, so they
/// have to come from raylib's own allocator. It is a plain malloc/free pair,
/// which is fine to call from the meshing worker threads.
pub const mesh_allocator: std.mem.Allocator = rl.mem;
