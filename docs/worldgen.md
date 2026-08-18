# World generation

The client can play a world it generates itself, with no server involved:

```
zig build run -- --singleplayer
zig build run -- --seed=1234        # a specific world
zig build run -- --server=host:port # unchanged, joins a server
```

The generator lives in `src/worldgen/` and is written the same data oriented way
as the rest of the terrain code: it is a pure function of (seed, chunk
coordinates) that writes straight into the flat arrays of the chunk store.

- it never reads another chunk, so chunks can be generated in any order
- it never allocates and never touches shared state, so it is safe to run from
  any thread
- generating one chunk takes about **0.7 ms** (`ReleaseFast`), which is a third
  of what meshing the result costs

## What it makes

| step | what happens |
| --- | --- |
| height field | a per column base height, sampled for every column: continents (1/200), hills (1/80), detail (1/26) and a block of jitter (1/7) |
| density grid | a 5x5x33 grid of 3D noise, interpolated into the chunk: this is what bends the height field into cliffs and overhangs |
| caves | a second coarse grid, carved where the noise crosses zero |
| surface | grass, sand or gravel on top, dirt or sandstone under it, deserts where it is warm, beaches along the water |
| oceans | everything below y=63 that is not solid, with a flat surface block on top |
| ores | coal, iron, gold, redstone, diamond, lapis, plus dirt and gravel blobs, as random walks through the stone |
| plants | trees, tall grass, flowers, sugar cane by the water, cactus and dead bushes in the desert |
| light | daylight straight down, then spreading sideways one level per block |

Two details worth knowing:

- **noise gain**. Summed octaves of Perlin noise almost never reach their
  extremes, which gives limp, evenly sloped terrain. Every field goes through
  `tanh(value * strength)`, which is what turns it into plateaus with steep
  sides. The strengths are the knobs to turn if the terrain feels too flat or
  too wild.
- **trees stay inside their chunk**. A tree is placed at least two blocks from
  the chunk border so that generating a chunk never has to write into its
  neighbor. It costs a slightly lower tree density along borders and buys the
  "a chunk only depends on its own coordinates" rule, which is what makes
  threading and regeneration trivial.

## Single player

`src/engine/Singleplayer.zig` is the system that keeps the world around the
player filled in. Every update it generates the closest missing chunk (a couple
per frame, so a slow frame never turns into a stall), and unloads what fell
behind. It writes into the chunk store exactly where the network path writes,
so the meshing pipeline never learns whether the chunks came from a server or
from the generator.

## Known gaps

- light does not cross chunk borders yet, so a chunk is lit as if it stood
  alone; it shows as a seam in deep shade
- no swimming: the spawn point is picked on dry land for that reason
- caves are noise blobs, not the carved tunnels the original uses
- no biome variety beyond "desert or not", and no snow
