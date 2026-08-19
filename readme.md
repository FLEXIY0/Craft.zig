# Maincraft

Minecraft compatible client for beta 1.7.3 servers.

This is a work in progress! Do not expect a functionnal client or good quality code.

```
zig build run -- --singleplayer   # a world the client generates itself
zig build run --                  # join a server on localhost

zig build run -- -s --fps=0 --stats   # uncapped, and log where the frame goes
```

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