//! What the player can change in the options screen, and how it is kept.
//!
//! Stored as `key value` lines next to the executable. A hand written parser is
//! the right size here: the file is a dozen numbers, an unknown key is skipped
//! rather than being an error, and a missing file just means the defaults.

const std = @import("std");

const Settings = @This();

/// Name of the file, in the working directory the client was started from
pub const path = "craft_options.txt";

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

/// The range each setting is allowed to take, so that the options screen and a
/// hand edited file agree on what is valid
pub const limits = struct {
    pub const view_distance = .{ .min = 2, .max = 16 };
    pub const fov = .{ .min = 30, .max = 110 };
    pub const sensitivity = .{ .min = 1, .max = 30 };
    pub const fps_cap = .{ .min = 0, .max = 480 };
};

/// Brings every value back inside its range, so a hand edited file can not
/// produce a camera with a field of view of nine thousand
pub fn clampAll(self: *Settings) void {
    self.view_distance = std.math.clamp(self.view_distance, limits.view_distance.min, limits.view_distance.max);
    self.fov = std.math.clamp(self.fov, limits.fov.min, limits.fov.max);
    self.sensitivity = std.math.clamp(self.sensitivity, limits.sensitivity.min, limits.sensitivity.max);
    self.fps_cap = std.math.clamp(self.fps_cap, limits.fps_cap.min, limits.fps_cap.max);
}

/// Reads the options file, falling back to the defaults for anything missing
pub fn load(alloc: std.mem.Allocator) Settings {
    var self: Settings = .{};

    const text = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("Could not read {s} ({}), using the defaults", .{ path, err });
        return self;
    };
    defer alloc.free(text);

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

    std.fs.cwd().writeFile(.{ .sub_path = path, .data = stream.getWritten() }) catch |err| {
        std.log.warn("Could not write {s} ({})", .{ path, err });
    };
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

test "values out of range are brought back in" {
    var settings: Settings = .{};
    settings.parse(
        \\view_distance 9000
        \\fov -30
    );
    settings.clampAll();

    try testing.expectEqual(limits.view_distance.max, settings.view_distance);
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
