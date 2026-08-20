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
the engine costs and what the graphics driver costs. **F** cycles the render
distance the way the classic client did, without opening a screen.

The world has no edge: chunks are generated around wherever the player is, so
walking never runs out of ground. What is drawn fades into the sky over the last
stretch of the render distance, which is what keeps the far side of it from
being a cliff of terrain against open sky.

## Android

The client runs on a phone, and on an old one: the floor is Android 5.0 and
OpenGL ES 2.0, and the APK carries all four ABIs. There is no Android Studio
anywhere in this -- an APK is a zip with a compiled manifest, and the three
tools that make one ship in the SDK's build-tools on their own.

```sh
tools/android-build.sh /path/to/android-ndk      # one library per ABI
tools/android-apk.sh   /path/to/android-sdk      # zig-out/android/craft.apk
```

A built one is in [`dist/`](dist/), with what it is signed with and how to
install it.

With no keyboard and no mouse there is a stick in one corner, a jump button in
the other, a drag anywhere else to look around, and a button for the menu. They
are a setting, so they can be turned on with a mouse to see what they do, and
off on a tablet with a keyboard.

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