//! What the player can change in the options screen, and how it is kept.
//!
//! Stored as `key value` lines next to the executable. A hand written parser is
//! the right size here: the file is a dozen numbers, an unknown key is skipped
//! rather than being an error, and a missing file just means the defaults.
//!
//! The reading and the writing go through raylib rather than through std.fs,
//! and that is not a matter of taste. On Android there is no working directory
//! the app may write to, and the game's own files live inside the APK; raylib's
//! file functions know about both, reading from the package first and falling
//! back to the one directory the app owns, and writing only ever to that. On a
//! desktop they are fopen and fwrite next to the executable, which is what this
//! did before.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const Settings = @This();

/// A phone has no keyboard and no mouse, so the on screen controls are on there
/// and off where there is one. Both can be changed in the options: a tablet
/// with a keyboard exists, and so does someone who wants to try the controls on
/// a desktop.
const touch_by_default = switch (builtin.target.abi) {
    .android, .androideabi => true,
    else => false,
};

/// Name of the file: next to the executable on a desktop, in the app's own
/// directory on a phone
pub const path: [:0]const u8 = "craft_options.txt";

/// Chunks loaded around the player
view_distance: i32 = 8,
/// Vertical field of view, in degrees
fov: i32 = 60,
/// How fast looking around is
sensitivity: i32 = 10,
/// Frames per second the client aims for, or zero for uncapped
fps_cap: i32 = 60,
/// Draw the frame rate in the corner
show_fps: bool = true,
/// Draw the walking stick, the jump button and the look area
touch_controls: bool = touch_by_default,

/// The range each setting is offered in. This is what the options screen's
/// sliders span, not a hard limit: see `hard_limits`.
pub const limits = struct {
    pub const view_distance = .{ .min = 2, .max = 32 };
    pub const fov = .{ .min = 30, .max = 110 };
    pub const sensitivity = .{ .min = 1, .max = 30 };
    pub const fps_cap = .{ .min = 0, .max = 480 };
};

/// What a value is held to whatever it came from.
///
/// The view distance is the one setting where the slider is not the limit. What
/// it costs is memory and patience -- a radius of n loads (2n+1)^2 chunks at
/// 80 KiB of block data each, and the generator fills two of them a frame --
/// so a slider that goes far past what is comfortable is a trap, while a
/// command line or a hand edited file asking for more is somebody who means it.
/// The ceiling here is only where the projection stops: raylib draws out to
/// 4000 blocks, which is 250 chunks.
pub const hard_limits = struct {
    pub const view_distance = .{ .min = 2, .max = 250 };
};

/// The view distances the F key steps through, largest first, the way the
/// classic client cycled Far, Normal, Short and Tiny
pub const view_distance_steps = [_]i32{ 32, 16, 8, 4, 2 };

/// Moves to the next view distance of `view_distance_steps`, wrapping. A value
/// that is not one of the steps (the slider gives plenty) drops to the largest
/// step below it, so the key always makes the world smaller first.
pub fn cycleViewDistance(self: *Settings) void {
    for (view_distance_steps) |step| {
        if (step < self.view_distance) {
            self.view_distance = step;
            return;
        }
    }
    self.view_distance = view_distance_steps[0];
}

/// Brings every value back inside its range, so a hand edited file can not
/// produce a camera with a field of view of nine thousand
pub fn clampAll(self: *Settings) void {
    self.view_distance = std.math.clamp(self.view_distance, hard_limits.view_distance.min, hard_limits.view_distance.max);
    self.fov = std.math.clamp(self.fov, limits.fov.min, limits.fov.max);
    self.sensitivity = std.math.clamp(self.sensitivity, limits.sensitivity.min, limits.sensitivity.max);
    self.fps_cap = std.math.clamp(self.fps_cap, limits.fps_cap.min, limits.fps_cap.max);
}

/// Reads the options file, falling back to the defaults for anything missing
pub fn load() Settings {
    var self: Settings = .{};

    // Not having one is the normal case on a first run, and raylib has already
    // said so in the log
    const text = rl.loadFileData(path) catch return self;
    defer rl.unloadFileData(text);

    self.parse(text);
    self.clampAll();
    return self;
}

/// Applies every `key value` line of a settings file
pub fn parse(self: *Settings, text: []const u8) void {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#')
            continue;

        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const key = parts.next() orelse continue;
        const value = parts.next() orelse continue;

        inline for (@typeInfo(Settings).@"struct".fields) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                switch (field.type) {
                    // A value that is not a number leaves the field alone
                    i32 => @field(self, field.name) = std.fmt.parseInt(i32, value, 10) catch @field(self, field.name),
                    bool => @field(self, field.name) = std.mem.eql(u8, value, "true"),
                    else => @compileError("Settings holds a type its parser does not know: " ++ @typeName(field.type)),
                }
            }
        }
    }
}

/// Writes the options back out. Failing to save is worth a line in the log and
/// nothing more: the player is either quitting or still playing.
pub fn save(self: Settings) void {
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    writer.writeAll("# Craft.zig options\n") catch return;
    inline for (@typeInfo(Settings).@"struct".fields) |field| {
        switch (field.type) {
            i32 => writer.print("{s} {}\n", .{ field.name, @field(self, field.name) }) catch return,
            bool => writer.print("{s} {s}\n", .{ field.name, if (@field(self, field.name)) "true" else "false" }) catch return,
            else => {},
        }
    }

    if (!rl.saveFileData(path, @constCast(stream.getWritten())))
        std.log.warn("Could not write {s}", .{path});
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "an empty file leaves the defaults alone" {
    var settings: Settings = .{};
    settings.parse("");
    try testing.expectEqual(@as(i32, 8), settings.view_distance);
    try testing.expectEqual(true, settings.show_fps);
}

test "parsing reads every kind of field and skips the rest" {
    var settings: Settings = .{};
    settings.parse(
        \\# a comment
        \\view_distance 12
        \\fov 90
        \\show_fps false
        \\nonsense 4
        \\fps_cap
    );

    try testing.expectEqual(@as(i32, 12), settings.view_distance);
    try testing.expectEqual(@as(i32, 90), settings.fov);
    try testing.expectEqual(false, settings.show_fps);
    // A key with no value, and an unknown key, both leave the default
    try testing.expectEqual(@as(i32, 60), settings.fps_cap);
}

test "the F key steps down through the classic distances and wraps" {
    var settings: Settings = .{ .view_distance = 32 };

    for ([_]i32{ 16, 8, 4, 2, 32, 16 }) |expected| {
        settings.cycleViewDistance();
        try testing.expectEqual(expected, settings.view_distance);
    }
}

test "a distance off the ladder drops to the step below it" {
    var settings: Settings = .{ .view_distance = 12 };
    settings.cycleViewDistance();
    try testing.expectEqual(@as(i32, 8), settings.view_distance);
}

test "the view distance is held to the hard limit, not to the slider" {
    var settings: Settings = .{};
    settings.parse("view_distance 64");
    settings.clampAll();

    // Past what the options screen offers, because what it costs is memory
    // rather than correctness
    try testing.expectEqual(@as(i32, 64), settings.view_distance);

    settings.parse("view_distance 100000");
    settings.clampAll();
    try testing.expectEqual(hard_limits.view_distance.max, settings.view_distance);
}

test "values out of range are brought back in" {
    var settings: Settings = .{};
    settings.parse(
        \\view_distance 9000
        \\fov -30
    );
    settings.clampAll();

    try testing.expectEqual(hard_limits.view_distance.max, settings.view_distance);
    try testing.expectEqual(limits.fov.min, settings.fov);
}

test "what is written back parses to the same thing" {
    const written: Settings = .{ .view_distance = 11, .fov = 75, .sensitivity = 3, .fps_cap = 0, .show_fps = false };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();
    inline for (@typeInfo(Settings).@"struct".fields) |field| {
        switch (field.type) {
            i32 => try writer.print("{s} {}\n", .{ field.name, @field(written, field.name) }),
            bool => try writer.print("{s} {s}\n", .{ field.name, if (@field(written, field.name)) "true" else "false" }),
            else => {},
        }
    }

    var read: Settings = .{};
    read.parse(stream.getWritten());
    try testing.expectEqual(written, read);
}
