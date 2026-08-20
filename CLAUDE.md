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

## Making a change without hunting for the place

Most changes land in one file, and it is usually not the one the symptom points
at:

- **A block, or how one behaves** — `blocks/definitions.zig`, one line. New
  behaviour is a flag on `Block.Flags` and a set in `blocks/registry.zig`, never
  a comparison against an id.
- **An option the player can set** — one field on `frontend/raylib/Settings.zig`.
  The parser, the writer and the range check are generated from the fields, so
  the field is the whole change.
- **A menu screen** — `frontend/raylib/Menu.zig`, one `draw*` function per
  screen, laid out with `row` / `labelledRow` / `halfRow`.
- **How a widget looks** — `frontend/raylib/ui/Theme.zig`. How it behaves —
  `ui/Ui.zig`.
- **The crosshair, the frame rate, the F3 overlay** — `GameWindow.zig`,
  `drawGui`.
- **The distance fade** — `frontend/raylib/Fog.zig` for the two numbers,
  `res/shaders/chunk.fs` for the fade itself. The depth it fades over is the `w`
  of the clip position, so there is no camera uniform to keep in step.
- **What a frame is spent on** — `FrameStats.zig`, and `--stats` to print it.
- **Which geometry is drawn at all** — `frontend/raylib/VisibleSet.zig` decides,
  `meshing/visibility.zig` says what can be seen through, and
  `meshing/greedy.zig` (`mergePlane`) decides how it is merged.

Two habits that save a rebuild:

- The linker prints about twenty `ld.lld: warning:` lines every build. Filter
  them so a real error is visible: `zig build 2>&1 | grep -v 'warning(link)'`.
- A struct that is returned by value must not hold a pointer into itself. It
  compiles, it runs, and it draws out of a dead stack frame — `Menu` had exactly
  that bug, and `engine.Client` is initialised in place to avoid it.

## Seeing a change

There is no screen on a build machine, so the client is driven on a virtual X
server. `tools/headless.sh` wraps that, and every coordinate it takes is
relative to the client window — the same ones read off a screenshot:

```sh
zig build                                    # the raylib frontend, not dummy
tools/headless.sh start --singleplayer --seed=4242
tools/headless.sh shot /tmp/shot.png
tools/headless.sh click 400 200              # a menu button
tools/headless.sh type "my world"
tools/headless.sh key Escape
tools/headless.sh log                        # the client's own output
tools/headless.sh stop
```

Clicks have to be slow — a press and a release inside one frame is one raylib
never sees — and the script already sleeps between them. Keys go through XTEST,
because GLFW ignores the `XSendEvent` path `xdotool key --window` uses.

The frame rate measured this way is Mesa's software rasteriser, not the engine:
`--stats` splits the frame, and `update` is the part this codebase owns.


## Android

`-Dtarget=aarch64-linux-android -Dandroid-ndk=<path>` builds a shared library
rather than an executable, because that is what an Android app is: the system's
`NativeActivity` opens it and calls `ANativeActivity_onCreate`, which comes from
the NDK's glue. raylib expects that glue to exist but does not build it, so
`build.zig` compiles it in.

Two things to know before touching this:

- raylib's own `build.zig` writes the file describing the NDK's libc using the
  pre 0.15 spelling of `Io.Writer`, so it comes out **empty** and the build
  stops on a parse error. `addAndroidSupport` is applied to raylib's artifact as
  well as to ours, which replaces that file. If an NDK build fails with
  `missing field: include_dir`, this is why.
- The chunk shader exists twice: `chunk.vs`/`chunk.fs` for desktop GL 3.3 and
  `chunk_es.*` for GL ES 2.0. `RessourceManager` picks by asking rlgl which
  version it actually got, so one binary covers both. `flat` does not exist in
  ES 2.0 and is not needed: all four vertices of a quad carry the same tile.

Files the game writes (the options) go through raylib's file API, not
`std.fs`: on Android the working directory is not writable and the assets live
inside the APK, and raylib's reads fall back from the package to the app's own
directory.

`tools/android-build.sh` builds every ABI, `tools/android-apk.sh` packs and
signs. Neither needs Android Studio.

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
