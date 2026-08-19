# Maincraft

Minecraft compatible client for beta 1.7.3 servers.

This is a work in progress! Do not expect a functionnal client or good quality code.

```
zig build run                     # the title screen: create a world, or join one
zig build run -- --singleplayer   # skip the menu, straight into a new world
zig build run -- --server=host    # skip the menu, straight into a server

zig build run -- -s --fps=0 --stats   # uncapped, and log where the frame goes
```

The client opens on a menu: **Singleplayer** creates a world (name, seed, render
distance), **Multiplayer** joins a server, and **Options** holds the render
distance, field of view, sensitivity and frame cap. Escape brings the same menu
up over a running world. Options are kept in `craft_options.txt` next to the
executable.

The frame rate is drawn in the corner, and F3 breaks the frame down into what
the engine costs and what the graphics driver costs.

## Introduction

This is a project of writing a fully compatible Minecraft beta 1.7.3 client. This is not a full minecraft clone as it doesn't contain the code necessary for singleplayer or a server, it only allows connecting to servers (although hosting a local server can be considered as singleplayer and maybe automatized to have a singleplayer mode).

## Documentation

See [the docs folder](docs/), [the data oriented architecture](docs/dod_architecture.md)
for how terrain, blocks and chunk meshing are laid out, and
[world generation](docs/worldgen.md) for the single player worlds.

## Screenshots

![screenshot](screenshots/screenshot.png)

## License

This project uses a custom [license](LICENSE) that restricts commercial use.