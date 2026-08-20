//! Entry point of the frontend.
//!
//! This is the layer that owns the difference between "in a menu" and "in a
//! world": the menu never starts anything itself, it returns what the player
//! asked for and this decides what that costs.

const std = @import("std");
const rl = @import("raylib");
const engine = @import("engine");
const tracy = @import("tracy");

const GameWindow = @import("GameWindow.zig");
const Menu = @import("Menu.zig");
const Settings = @import("Settings.zig");

/// What the player asked for on the command line.
/// Everything here is a way of skipping the menu, which is what a benchmark or
/// a screenshot run wants; the normal way in is the title screen.
const Options = struct {
    /// Go straight into a locally generated world
    singleplayer: bool = false,
    /// Seed of that world
    seed: u64 = 0,
    /// Go straight into a server
    server: bool = false,
    address: []const u8 = "localhost",
    port: u16 = 25565,
    /// Overrides of the saved options, for measuring
    fps: ?u32 = null,
    view_distance: ?i32 = null,
    /// Log where the frame goes once a second
    stats: bool = false,
};

/// Parses `--singleplayer`, `--seed=N`, `--server=host[:port]`, `--fps=N`,
/// `--view-distance=N` and `--stats`
fn parseOptions(args: []const [:0]const u8) Options {
    var options: Options = .{ .seed = @bitCast(std.time.milliTimestamp()) };

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--singleplayer") or std.mem.eql(u8, arg, "-s")) {
            options.singleplayer = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            options.stats = true;
        } else if (std.mem.startsWith(u8, arg, "--view-distance=")) {
            options.view_distance = std.fmt.parseInt(i32, arg["--view-distance=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--fps=")) {
            options.fps = std.fmt.parseInt(u32, arg["--fps=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            options.seed = std.fmt.parseInt(u64, arg["--seed=".len..], 10) catch options.seed;
            options.singleplayer = true;
        } else if (std.mem.startsWith(u8, arg, "--server=")) {
            options.server = true;
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

/// The world the client currently has, if any.
///
/// `engine.Client` owns threads and a chunk store, and things inside it point at
/// each other, so it lives in this frame and is only ever initialised in place.
const Session = struct {
    client: engine.Client = undefined,
    running: bool = false,

    fn startLocal(self: *Session, alloc: std.mem.Allocator, window: *GameWindow, seed: u64, view_distance: i32) !void {
        std.debug.assert(!self.running);

        try self.client.initLocal(alloc, window, seed);
        self.running = true;
        self.client.singleplayer.?.view_distance = view_distance;

        window.enterGame(&self.client.game);
    }

    fn startRemote(self: *Session, alloc: std.mem.Allocator, window: *GameWindow, address: []const u8, port: u16) !void {
        std.debug.assert(!self.running);

        try self.client.init(alloc, window, address, port);
        self.running = true;

        window.enterGame(&self.client.game);
    }

    /// The view distance can change while a world is running, from the options
    /// screen or from the F key. Only a single player world generates its own
    /// chunks; on a server the radius is the server's to decide.
    fn setViewDistance(self: *Session, view_distance: i32) void {
        if (!self.running)
            return;
        if (self.client.singleplayer) |*singleplayer|
            singleplayer.view_distance = view_distance;
    }

    fn stop(self: *Session, window: *GameWindow) void {
        if (!self.running)
            return;
        window.exitGame();
        self.client.deinit();
        self.running = false;
    }
};

/// Entry point of the frontend
pub fn main(default_alloc: std.mem.Allocator) !void {
    const alloc = default_alloc;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const options = parseOptions(args[@min(1, args.len)..]);

    var settings: Settings = .load();
    if (options.fps) |fps| settings.fps_cap = @intCast(fps);
    if (options.view_distance) |distance| settings.view_distance = distance;
    settings.clampAll();

    var window: GameWindow = try .init(alloc, &settings);
    defer window.deinit();

    var menu: Menu = .init(&settings);
    defer menu.deinit();

    var session: Session = .{};
    defer session.stop(&window);

    // The command line can skip the title screen, which is what a measurement
    // run or a screenshot wants
    if (options.singleplayer) {
        std.log.info("Generating a world...", .{});
        try session.startLocal(alloc, &window, options.seed, settings.view_distance);
        menu.enterGame();
        if (!settings.touch_controls)
            rl.disableCursor();
    } else if (options.server) {
        std.log.info("Connecting...", .{});
        session.startRemote(alloc, &window, options.address, options.port) catch |err| {
            std.log.err("Could not connect to the server ({})", .{err});
            return;
        };
        menu.enterGame();
        if (!settings.touch_controls)
            rl.disableCursor();
    }

    // Splitting the frame in "what the engine does" and "what the driver does"
    // is the only way to tell an engine that is too slow from a frame that is
    // simply waiting on the gpu or on the frame rate cap
    var timer: std.time.Timer = try .start();
    var report: std.time.Timer = try .start();

    var last_fps_cap = settings.fps_cap;
    var last_view_distance = settings.view_distance;

    while (!window.hasClosed()) {
        const dt = rl.getFrameTime();

        // The options screen can change the frame cap while it is open
        if (settings.fps_cap != last_fps_cap) {
            last_fps_cap = settings.fps_cap;
            rl.setTargetFPS(@intCast(settings.fps_cap));
        }

        // ...and the view distance, which the running world has to be told
        // about, or it keeps generating the old radius
        if (settings.view_distance != last_view_distance) {
            last_view_distance = settings.view_distance;
            session.setViewDistance(settings.view_distance);
        }

        timer.reset();

        // A world only ticks while the player is actually in it
        if (session.running and !menu.isOpen()) {
            if (!try session.client.update(dt))
                break;
            try window.update(dt);

            // F cycles the view distance the way the classic client did, so it
            // can be turned down without opening a screen
            if (rl.isKeyPressed(.f))
                settings.cycleViewDistance();

            if (rl.isKeyPressed(.escape) or window.takePauseRequest())
                pauseGame(&menu, &window);
        } else if (session.running) {
            // Paused: no time passes for the world, but the generator and the
            // meshing pipeline are still allowed to finish what they started
            _ = try session.client.update(0);
        }

        window.stats.addUpdate(timer.lap());
        {
            const zone = tracy.Zone.begin(.{
                .name = "Game draw",
                .src = @src(),
                .color = .red1,
            });
            defer zone.end();

            window.beginDraw();
            if (session.running) {
                window.drawWorld();
                window.drawGui();
            }

            if (menu.isOpen()) {
                switch (menu.draw()) {
                    .none => {},
                    .quit => break,
                    .resume_game => resumeGame(&menu, &window),
                    .leave_game => {
                        session.stop(&window);
                        menu.exitGame();
                    },
                    .play_local => |world| {
                        std.log.info("Generating \"{s}\", seed {}", .{ world.name, world.seed });
                        session.startLocal(alloc, &window, world.seed, settings.view_distance) catch |err| {
                            std.log.err("Could not start the world ({})", .{err});
                        };
                        if (session.running)
                            resumeGame(&menu, &window);
                    },
                    .join => |server| {
                        std.log.info("Connecting to {s}:{}", .{ server.address, server.port });
                        session.startRemote(alloc, &window, server.address, server.port) catch |err| {
                            std.log.err("Could not connect ({})", .{err});
                        };
                        if (session.running)
                            resumeGame(&menu, &window);
                    },
                }
            }
        }
        window.stats.addSubmit(timer.lap());

        window.endDraw();
        window.stats.addPresent(timer.lap());

        if (options.stats and report.read() > std.time.ns_per_s) {
            report.reset();
            window.stats.log();
        }
    }

    settings.save();
}

/// Gives the world the pointer and the keyboard back.
///
/// The cursor is only captured when the player is looking around with a mouse.
/// With the on screen controls the look comes from a drag, and a captured
/// cursor would mean nothing can be touched -- which is also what a phone has,
/// where there is no cursor to capture in the first place.
fn resumeGame(menu: *Menu, window: *GameWindow) void {
    if (!menu.in_game)
        menu.enterGame();
    menu.unpause();
    window.focused = true;
    window.touch.release();
    if (!window.settings.touch_controls)
        rl.disableCursor();
}

/// Puts the pause menu up over the world
fn pauseGame(menu: *Menu, window: *GameWindow) void {
    menu.pause();
    window.focused = false;
    // A finger that is still down belongs to the button that opened the menu,
    // not to the stick
    window.touch.release();
    rl.enableCursor();
}
