# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Minecraft beta 1.7.3 compatible client written in Zig 0.15.2, plus a local
world generator so it can be played without a server. The terrain, block
database and chunk mesher are written data oriented: there is no `Chunk` object,
block types are indices into comptime tables, and meshing is a job on worker
threads.

## Commands

```sh
zig build                       # raylib frontend, Debug (this is the default)
zig build -Doptimize=ReleaseFast
zig build run                   # opens on the title screen
zig build run -- --singleplayer --seed=4242   # skip the menu, for measuring
zig build run -- --fps=0 --stats              # uncapped, log the frame breakdown once a second

zig build test                  # every module
zig build test_meshing          # one module: test_net test_inv test_io test_coord
                                # test_terrain test_blocks test_meshing test_worldgen
                                # test_engine test_exe
```

There is no per-test filter: the module test steps are the granularity.

Build options: `-Dfrontend=raylib|dummy`, `-Dtracy`, `-Datlas=path`,
`-Dmesher-threads=N` (0 picks from the cpu count).

Two things that trip people up:

- **`zig build -Dfrontend=dummy` overwrites `zig-out/bin/maincraft`** with the
  headless build. Rebuild with the raylib frontend before running the client.
- The linker prints a wall of `ld.lld: warning: ... is neither ET_REL nor LLVM
  bitcode` about raylib's archive. The build still exits 0; ignore them.

`docs/io_api.md` claims the default frontend is `dummy`. It is `raylib`
(`build.zig`).

## Assets

`res/jar/minecraft/` (an unpacked b1.7.3 jar) is optional and gitignored. Without
it the client packs its atlas at startup from the single tiles in
`res/textures/classic/` (`TerrainAtlas.zig`), and anything that only exists in a
jar — the HUD icons — is loaded through `loadOptionalTexture` and simply skipped.
Keep new asset loading optional the same way.

## Architecture

`build.zig` is the authority on the module graph — read it first. Modules import
each other by name, so a missing import shows up as `no module named 'x'`.

```
coord ─ blocks(+atlas) ─ terrain ─ meshing ─ io ─ engine
                              worldgen ┘        net ┘
```

### The IO boundary

`io` is a *swappable module*: `src/frontend/raylib/` and `src/frontend/dummy/`
both export the same surface (`io.zig`), and the engine and meshing modules
import `io` without knowing which one they got. Two things cross that boundary
and matter:

- `io.properties.VertexIdT` — the index type mesh parts are capped for.
- `io.properties.mesh_allocator` — the allocator chunk vertex buffers are built
  with, so the renderer can take them over without a copy. In the raylib
  frontend that is raylib's own malloc, because raylib frees mesh buffers itself.

Anything graphics-library specific belongs behind this boundary. Adding a
frontend means filling in the dummy one.

### Terrain: slots, not objects

`terrain/ChunkStore.zig` holds parallel arrays (`coords`, `revision`,
`meshed_revision`, `model`, `ids`, `meta`, `blocklight`, `skylight`, …) indexed
by a `Slot`. `live` is a dense list of loaded slots for iteration; `map` is the
coords lookup. Component pools (`terrain/pool.zig`) are **paged**, so a slot
index and a pointer into a chunk's block data stay valid for the chunk's life —
that is what makes it safe to hand chunk data to a meshing thread.

Block data is y-major: a column's 128 blocks are contiguous
(`chunk.columnBase(x, z)`), which is what lets the mesher load a column as one
`u128` bit mask.

`terrain/World.zig` is the system layer: it applies packets or generated chunks,
marks chunks dirty, and drives meshing. Both the network path (`doChunkMap`) and
the generator end with `commitChunkData`.

### Blocks: data driven at comptime

`blocks/definitions.zig` is a sparse list of pure data. `blocks/registry.zig`
bakes it into flat 256 entry tables and `u256` bit sets at comptime. **Adding a
block is one line in `definitions.zig`** — there is no `switch` on block ids
anywhere in the engine, and there should not be one. Membership is
`(set >> id) & 1`, and the sets combine with plain bitwise operators, which is
what lets the mesher cull 128 blocks per instruction.

If a block needs new behaviour, add a flag to `Block.Flags` (a
`packed struct(u16)`) and a set in the registry rather than special casing an id.

`blocks/atlas.zig` is the only file that knows the atlas layout, and is a
swappable module (`-Datlas=`) so a generated atlas can replace it.

### Meshing: snapshots and a lock free pipeline

```
ChunkStore ──snapshot──▶ Scheduler ──job──▶ Mesher ──▶ MeshData ──▶ frontend
```

A `Snapshot` is an owned copy of a chunk plus its neighbours' border planes, so
the main thread can keep writing while a worker meshes. Results carry the
`revision` they were built from; a stale result is dropped and the chunk is
requeued. That is the whole of the synchronisation.

Geometry is cut into **sections** of 16 blocks, and `mergePlane` may not merge a
quad across a section border — that is deliberate, it is what lets the renderer
drop a section. `meshing/visibility.zig` records which faces of each section see
each other, and the renderer walks outwards from the camera
(`frontend/raylib/VisibleSet.zig`) instead of iterating loaded chunks. What stops
the walk is `blocks.blocksSight`, which is wider than `isOpaqueCube`: water and
lava carry `stops_sight`, so their faces are still drawn but nothing far behind
them is walked to.

See `docs/dod_architecture.md` for the measurements behind all of this.

### Frontend loop

`frontend/raylib/main.zig` owns the split between menu and world. `Menu.zig`
never touches the engine — it returns an `Action`, and `main.zig` decides what
starting a world costs. `engine.Client` lives in `main`'s frame and is
initialised in place, because things inside it point at each other.

`ChunkBatch.zig` draws chunks without going through `rl.drawMesh`, which would
rebind the shader and re-upload four matrices per section.

## Conventions

- Comments explain *why*, in prose, and are worth writing. Match the density of
  the file you are in; the doc comment at the top of a file says what it is for
  and what the alternative would have cost.
- Tests live at the bottom of the file they test, under a
  `// --- Tests ---` rule, and assert behaviour rather than implementation.
- Everything is measured before it is optimised. `--stats` prints the frame split
  (`update` / `submit` / `present`) and `--view-distance=N` varies the load;
  numbers in `docs/` come from those and should be updated when they change.
- This project deliberately contains no Mojang code or assets. Texture folders
  that are derived from them carry a readme saying so and are removable.
