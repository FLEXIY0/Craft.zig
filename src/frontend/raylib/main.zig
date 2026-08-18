//! Entry point of the frontend

const std = @import("std");
const rl = @import("raylib");
const engine = @import("engine");
const tracy = @import("tracy");

const GameWindow = @import("GameWindow.zig");

/// What the player asked for on the command line
const Options = struct {
    /// Play a locally generated world instead of joining a server
    singleplayer: bool = false,
    /// Seed of that world
    seed: u64 = 0,
    /// Server to join
    address: []const u8 = "localhost",
    port: u16 = 25565,
};

/// Parses `--singleplayer`, `--seed=N`, `--server=host[:port]`
fn parseOptions(args: []const [:0]const u8) Options {
    var options: Options = .{ .seed = @bitCast(std.time.milliTimestamp()) };

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--singleplayer") or std.mem.eql(u8, arg, "-s")) {
            options.singleplayer = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            options.seed = std.fmt.parseInt(u64, arg["--seed=".len..], 10) catch options.seed;
            options.singleplayer = true;
        } else if (std.mem.startsWith(u8, arg, "--server=")) {
            const target = arg["--server=".len..];
            if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
                options.address = target[0..colon];
                options.port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch options.port;
            } else {
                options.address = target;
            }
        }
    }

    return options;
}

/// Entry point of the frontend
pub fn main(default_alloc: std.mem.Allocator) !void {
    const alloc = default_alloc;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const options = parseOptions(args[@min(1, args.len)..]);

    var window: GameWindow = try .init(alloc);
    defer window.deinit();

    var client: engine.Client = undefined;

    if (options.singleplayer) {
        std.log.info("Generating a world...", .{});
        try client.initLocal(alloc, &window, options.seed);
    } else {
        std.log.info("Connecting...", .{});
        client.init(alloc, &window, options.address, options.port) catch |e| {
            if (e == error.CouldNotConnect) {
                std.log.err("Could not connect to server!", .{});
                return;
            } else {
                return e;
            }
        };
    }
    defer client.deinit();
    std.log.debug("Client started", .{});

    window.enterGame(&client.game);
    defer window.exitGame();

    // TODO: make menus
    while (!window.hasClosed()) {
        const dt = rl.getFrameTime();

        if (!try client.update(dt))
            break;

        // TODO: who should call that?
        try window.update(dt);
        {
            const zone = tracy.Zone.begin(.{
                .name = "Game draw",
                .src = @src(),
                .color = .red1,
            });
            defer zone.end();
            window.beginDraw();
            window.drawWorld();
            window.drawGui();
        }
        window.endDraw();
    }
}
