# Data oriented terrain, blocks and meshing

This document describes how the terrain, the block database and the chunk mesher
are laid out, and why. The short version: nothing here is an object. Chunks are
slots in parallel arrays, block types are indices into comptime tables and 256
bit sets, and meshing is a job that runs on worker threads over an owned copy of
the data.

## Contents

- [The block registry](#the-block-registry-data-driven-at-comptime)
- [The texture atlas](#the-texture-atlas-one-swappable-file)
- [The chunk store](#the-chunk-store-soa-and-slots)
- [Greedy meshing](#greedy-meshing)
- [The lock free meshing pipeline](#the-lock-free-meshing-pipeline)
- [What the frontend receives](#what-the-frontend-receives)
- [Build options](#build-options)
- [Numbers](#numbers)
- [Ideas that are not implemented yet](#ideas-that-are-not-implemented-yet)

## The block registry: data driven at comptime

`src/blocks/` is split in *data*, *layout* and *code*:

| file | role |
| --- | --- |
| `definitions.zig` | a sparse list of block definitions, pure data |
| `atlas.zig` | how texture ids map to the atlas, meant to be generated |
| `Block.zig` | the shape of a definition (only exists at comptime) |
| `registry.zig` | bakes the definitions into flat tables and bit sets |

Adding a block means adding one line to `definitions.zig`. Nothing else in the
engine changes: no switch, no `if (id == …)` anywhere.

At runtime a block type is just its `u8` id, and every question about it is
answered in one of two ways:

```zig
// a byte in a 256 entry table, always in L1
const model = blocks.modelOf(id);
const texture = blocks.texOf(.up, id);   // tex[face][id], SoA per face

// or one bit out of a 256 bit set: (set >> id) & 1
if (blocks.isOpaqueCube(id)) …
```

The bit sets (`blocks.set.opaque_cube`, `…full_cube`, `…transparent`,
`…hitbox`, `…special_model`, …) are `u256` values baked at comptime. Testing
membership is a shift and a mask, and — more importantly — the *sets themselves*
can be combined with plain bitwise operators, which is what lets the mesher ask
"is this column made of occluders" for 128 blocks at a time.

Tints (grass, foliage) used to be a `switch` on block ids in the mesher. They are
now a two bit field in the block flags, so the mesher never knows that grass
exists.

## The texture atlas: one swappable file

`src/blocks/atlas.zig` is the only file that knows the atlas layout. It exports
the grid size, the tile size in normalized coordinates, a half texel inset, and
`origins[tex_id]`, the table the mesher writes into the vertex data.

It is meant to be **generated**: write an atlas packer, have it emit a file with
the same declarations, and point the build at it:

```
zig build -Datlas=zig-out/generated_atlas.zig
```

The client also ships a set of single tile textures and packs them into that
layout at startup when no atlas image is around
(`src/frontend/raylib/TerrainAtlas.zig`), which is the "assemble the atlas from
loose files" case of the same idea.

The engine picks up the new layout with no other change, because:

- the mesher only ever reads `atlas.origins[…]`
- the chunk shader gets the tile size and the inset as a uniform
  (`RessourceManager.setAtlasUniform`), it has no constant of its own

## The chunk store: SoA and slots

`src/terrain/ChunkStore.zig` replaces the old `Chunk` object and the
`HashMap(coords, *Chunk)`. A chunk is a **slot**: an index that addresses one
item in each component pool.

```
slot:              0        1        2        3      …
coords            [ ][ ][ ][ ]        ← where the chunk is
revision          [ ][ ][ ][ ]        ← bumped on every block edit
meshed_revision   [ ][ ][ ][ ]        ← revision the current model was built from
in_flight         [ ][ ][ ][ ]        ← a meshing job is running
model             [ ][ ][ ][ ]        ← gpu side model, owned by the frontend
sections          [ ][ ][ ][ ]        ← non air blocks per 16 block slab
ids               [32 KiB ][32 KiB ]… ← block ids
meta/blocklight/skylight              ← one nibble per block each
```

Consequences:

- the systems that scan chunks (the remesh scheduler, the renderer) walk small
  dense arrays instead of chasing pointers through a hash map of fat structs
- `live` is a dense list of loaded slots, kept dense with a swap remove, so
  iteration order has nothing to do with hashing
- component pools are **paged** (`src/terrain/pool.zig`): growing the store
  allocates a new page instead of reallocating, so a slot index and a pointer to
  a chunk's block data stay valid for as long as the chunk lives. That is what
  makes it safe to hand chunk data to another thread.

Block data inside a chunk is y major: the 128 blocks of a column are contiguous
(`chunk.columnBase(x, z)`), which is both what the protocol sends and what lets
the mesher load a column as a single `u128`.

`World` is the system layer on top: it applies the server's packets, marks
chunks dirty, and drives the meshing pipeline.

## Greedy meshing

`src/meshing/greedy.zig`. Two ideas:

**1. Binary face culling.** Each column is summarized as two `u128` bit masks:
blocks that produce a full cube, and blocks that hide their neighbors. Then
visibility of a whole column of faces is one expression:

```zig
.up    => full & ~(occluders >> 1),
.down  => full & ~(occluders << 1),
.north => full & ~occludersAt(x, z - 1),   // may be a neighbor chunk
```

128 blocks of face culling per instruction, no per block branch. The border
columns of the neighbor chunks are part of the snapshot and are summarized the
same way, so chunk boundaries need no special case.

**2. Greedy merging.** For each face direction and each plane, visible faces are
keyed by everything that must match for two faces to be drawn as one quad — the
block id and the light level — and merged into maximal rectangles. A full stone
chunk (32768 blocks) comes out as **six quads**.

Blocks whose model is not a full cube (slabs, plants, liquids, snow, cactus) are
collected by the same scan into a small list and meshed one at a time in
`src/meshing/special.zig`.

Texture coordinates are expressed in **tile units**: a quad that spans five
blocks gets uvs from 0 to 5, and carries the origin of its atlas tile in a second
uv set. The chunk shader wraps them:

```glsl
vec2 inTile = clamp(fract(fragTexCoord)*tileSize, inset, tileSize - inset);
vec4 texelColor = texture(texture0, fragTileOrigin + inTile);
```

The same convention handles the odd models for free: a slab side is half a block
tall, so its uvs go from 0 to 0.5 and it samples the top half of its tile, which
is exactly what the old hand written uv tables did.

## The lock free meshing pipeline

`src/meshing/Scheduler.zig`.

```
 main thread                        workers                      main thread
 ───────────                        ───────                      ───────────
 snapshot a chunk  ──push job──▶   greedy + special  ──push result──▶  upload
 (a memcpy)                        meshing passes                      to gpu
```

- A **snapshot** (`Snapshot.zig`) is an owned copy of a chunk plus the border
  planes of its four neighbors, ~100 KiB. Copying it costs a few tens of
  microseconds and removes the need for any lock: the network thread can keep
  writing into the store while a worker meshes.
- Three **bounded lock free queues** (`queue.zig`, Vyukov MPMC) carry jobs,
  results, and the pool of free snapshots. The pool doubles as the back pressure
  mechanism: no free snapshot means the pipeline is saturated and the chunk stays
  queued.
- Workers that find nothing to do park on a futex, they never spin.
- Results carry the **revision** of the chunk they were built from. If the chunk
  changed while it was being meshed, the result is dropped and the chunk is
  queued again. If the chunk was unloaded, the mesh is freed and the slot is
  recycled. This is the only synchronization the whole thing needs.
- If no thread can be spawned, the scheduler transparently meshes on the calling
  thread, so a headless or single threaded build still works.

The snapshot is laid out for the mesher rather than for storage: light levels are
unpacked to one byte per block, and the neighbor border planes have exactly the
same shape as the chunk's own columns. Both sweeps then work on plain
`[128]u8` / `[128]LightLevel` columns.

## What the frontend receives

`meshing.MeshData` is SoA: one flat buffer per attribute (positions, tile space
uvs, tile origins, colors, indices), split into parts of at most 65532 vertices
so that 16 bit indices are enough. Buffers are allocated with the *mesh
allocator* the frontend exposes (`io.properties.mesh_allocator`), so the raylib
frontend hands them to `rl.Mesh` without a copy: `ChunkModel.upload` is the only
part of the pipeline that has to run on the thread that owns the GL context.

The renderer walks the dense slot list and culls chunks against the camera
frustum (`src/frontend/raylib/Frustum.zig`) before drawing.

## Where the chunks come from

Chunks are filled in by one of two systems, and neither one is visible to
anything downstream:

- the network path (`World.doChunkMap`), when a server sends them
- the generator (`src/worldgen`, driven by `engine.Singleplayer`), when the
  client plays a world of its own. See [world generation](worldgen.md).

Both write into the same store arrays and both end with `commitChunkData`,
which refreshes the derived data and queues the chunk for meshing.

## Build options

| option | meaning |
| --- | --- |
| `-Datlas=path` | file describing the texture atlas, defaults to `src/blocks/atlas.zig` |
| `-Dmesher-threads=n` | meshing worker threads, `0` (default) picks from the cpu count |
| `-Dfrontend=…` | unchanged: `raylib` or `dummy` |

## Numbers

Meshing one chunk, single thread, `ReleaseFast`, measured on the CI container
with a malloc style allocator (as in the real client):

| chunk | quads | time |
| --- | --- | --- |
| dense terrain, 600 cave holes, grass and plants | 4476 | 1.4 ms |
| solid stone (32768 blocks) | 6 | 0.23 ms |
| empty | 0 | 0.07 ms |

Those run on the worker threads, so they cost the frame nothing but the upload.

## Ideas that are not implemented yet

Roughly in order of "value for the work":

- **Ambient occlusion.** The classic four sample corner AO. It fits the merge key
  (two faces only merge if their AO matches), which is why it was left out for
  now: it needs the key widened and the corner samples added to the sweep.
- **Palette compressed sections.** Most 16³ sections use a handful of block
  types; storing a per section palette plus bit packed indices typically divides
  the memory of loaded terrain by 4 or more, and makes "is this section uniform"
  a single comparison.
- **Vertex packing.** Positions inside a chunk fit in 5+8+5 bits, the face normal
  in 3, the tile index in 8: a vertex could be one `u32` instead of 44 bytes,
  which is 10x less bandwidth to the gpu. Needs a vertex shader that unpacks, so
  it does not fit raylib's `Mesh` struct as is.
- **Per section meshes** instead of per chunk, so that editing one block only
  remeshes 16³ blocks, and so that vertical frustum culling has something to cull.
- **Occlusion culling** of chunks that are behind other chunks, using the same
  column bit masks (a chunk whose border planes are solid can hide what is
  behind it).
- **Job stealing / priority by distance.** The remesh queue is FIFO; sorting by
  distance to the player would make the world appear from the inside out.
- **Async light propagation** as its own job type, so that a light update does
  not have to wait for the server.
- **SIMD in the scan.** The column summary loop is a perfect `@Vector(16, u8)`
  candidate: compare 16 block ids against the set at once.
