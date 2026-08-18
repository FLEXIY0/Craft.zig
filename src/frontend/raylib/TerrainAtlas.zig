//! The terrain texture.
//!
//! The engine wants one atlas image, laid out the way `blocks.atlas` describes.
//! There are two ways to get one:
//!
//!  - `res/jar/minecraft/terrain.png`, taken from the game's jar. Complete, and
//!    always preferred when it is there.
//!  - the single tiles in `res/textures/classic`, packed here at startup. That
//!    is what the client shows out of the box, so that it runs with nothing but
//!    this repository.
//!
//! Packing is a plain blit of 16x16 tiles into a 16x16 grid, and tiles nobody
//! claims keep the missing texture checker.

const std = @import("std");
const rl = @import("raylib");
const blocks = @import("blocks");

const atlas = blocks.atlas;

/// Side of the atlas, in pixels
const size = atlas.columns * atlas.tile_px;

/// The atlas that ships with the client
const tile_folder = "res/textures/classic";
/// The atlas of whoever unpacked their own jar
const jar_atlas = "res/jar/minecraft/terrain.png";

/// One texture file and the tile it goes to
const Tile = struct {
    x: u8,
    y: u8,
    file: []const u8,
    /// Alpha forced on the whole tile, for textures that have none of their own
    alpha: ?u8 = null,
};

/// Where each classic texture goes in the beta atlas.
/// Classic has fewer blocks, so a few tiles are stood in for by the closest
/// thing it has; see the readme next to the textures.
const tiles = [_]Tile{
    .{ .x = 0, .y = 0, .file = "grass.png" }, // grass top
    .{ .x = 1, .y = 0, .file = "rock.png" }, // stone
    .{ .x = 2, .y = 0, .file = "dirt.png" },
    .{ .x = 3, .y = 0, .file = "grass_dirt.png" }, // grass side
    .{ .x = 4, .y = 0, .file = "wood.png" }, // planks
    .{ .x = 5, .y = 0, .file = "stone.png" }, // slab side
    .{ .x = 6, .y = 0, .file = "rock.png" }, // slab top
    .{ .x = 12, .y = 0, .file = "red_flower.png" }, // rose
    .{ .x = 13, .y = 0, .file = "yellow_flower.png" }, // flower
    .{ .x = 15, .y = 0, .file = "bush.png" }, // sapling
    .{ .x = 0, .y = 1, .file = "stone.png" }, // cobblestone
    .{ .x = 1, .y = 1, .file = "bedrock.png" },
    .{ .x = 2, .y = 1, .file = "sand.png" },
    .{ .x = 3, .y = 1, .file = "gravel.png" },
    .{ .x = 4, .y = 1, .file = "tree_side.png" }, // log side
    .{ .x = 5, .y = 1, .file = "tree_top.png" },
    .{ .x = 12, .y = 1, .file = "red_mushroom.png" },
    .{ .x = 13, .y = 1, .file = "brown_mushroom.png" },
    .{ .x = 0, .y = 2, .file = "rock_gold.png" }, // gold ore
    .{ .x = 1, .y = 2, .file = "rock_bronze.png" }, // iron ore
    .{ .x = 2, .y = 2, .file = "rock_coal.png" }, // coal ore
    .{ .x = 7, .y = 2, .file = "bush.png" }, // tall grass
    .{ .x = 0, .y = 3, .file = "sponge.png" },
    .{ .x = 1, .y = 3, .file = "glass.png" },
    .{ .x = 4, .y = 3, .file = "leaves_opaque.png" }, // leaves
    .{ .x = 7, .y = 3, .file = "bush.png" }, // dead bush, stood in for
    .{ .x = 2, .y = 4, .file = "white_wool.png" }, // snow, stood in for
    .{ .x = 5, .y = 4, .file = "leaves_opaque.png" }, // cactus top, stood in for
    .{ .x = 6, .y = 4, .file = "leaves_opaque.png" }, // cactus side, stood in for
    .{ .x = 7, .y = 4, .file = "leaves_opaque.png" }, // cactus bottom, stood in for
    .{ .x = 8, .y = 4, .file = "gravel.png" }, // clay, stood in for
    .{ .x = 9, .y = 4, .file = "bush.png" }, // sugar cane, stood in for
    .{ .x = 0, .y = 11, .file = "sand.png" }, // sandstone top, stood in for
    .{ .x = 0, .y = 12, .file = "sand.png" }, // sandstone side, stood in for
    .{ .x = 0, .y = 13, .file = "sand.png" }, // sandstone bottom, stood in for
    // Classic liquids are opaque, the beta renderer wants an alpha channel
    .{ .x = 15, .y = 12, .file = "water.png", .alpha = 0xb0 },
    .{ .x = 15, .y = 14, .file = "lava.png" },
};

/// Loads the terrain atlas, packing the shipped tiles if there is no jar
pub fn load(alloc: std.mem.Allocator) !rl.Texture {
    if (std.fs.cwd().access(jar_atlas, .{})) |_| {
        std.log.info("Terrain atlas from {s}", .{jar_atlas});
        return rl.loadTexture(jar_atlas);
    } else |_| {}

    std.log.info("No {s}, packing the atlas from {s}", .{ jar_atlas, tile_folder });
    return packed_atlas: {
        const pixels = try alloc.alloc(rl.Color, size * size);
        defer alloc.free(pixels);

        paintMissing(pixels);
        try packTiles(alloc, pixels);

        const image: rl.Image = .{
            .data = pixels.ptr,
            .width = size,
            .height = size,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };

        break :packed_atlas rl.loadTextureFromImage(image);
    };
}

/// The magenta and black checker, for every tile no texture claims
fn paintMissing(pixels: []rl.Color) void {
    for (pixels, 0..) |*pixel, i| {
        const x = i % size;
        const y = i / size;
        const checker = ((x / (atlas.tile_px / 2)) + (y / (atlas.tile_px / 2))) % 2 == 0;
        pixel.* = if (checker) .init(236, 0, 236, 255) else .init(20, 20, 20, 255);
    }
}

/// Blits every tile file into its place
fn packTiles(alloc: std.mem.Allocator, pixels: []rl.Color) !void {
    var packed_count: usize = 0;

    for (tiles) |tile| {
        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ tile_folder, tile.file }, 0);
        defer alloc.free(path);

        var image = rl.loadImage(path) catch {
            std.log.warn("Missing terrain texture {s}", .{tile.file});
            continue;
        };
        defer image.unload();

        if (image.width != atlas.tile_px or image.height != atlas.tile_px)
            rl.imageResize(&image, atlas.tile_px, atlas.tile_px);

        const colors = rl.loadImageColors(image) catch continue;
        defer rl.unloadImageColors(colors);

        for (0..atlas.tile_px) |ty| {
            for (0..atlas.tile_px) |tx| {
                var color = colors[ty * atlas.tile_px + tx];
                if (tile.alpha) |alpha| {
                    if (color.a != 0)
                        color.a = alpha;
                }

                const x = @as(usize, tile.x) * atlas.tile_px + tx;
                const y = @as(usize, tile.y) * atlas.tile_px + ty;
                pixels[y * size + x] = color;
            }
        }

        packed_count += 1;
    }

    std.log.info("Packed {} terrain tiles", .{packed_count});
}
