//! The screens outside of the world: the title, creating a world, joining a
//! server, the options, and the pause menu.
//!
//! The menu never touches the engine. It runs a frame and returns an `Action`,
//! and the caller decides what that means — which keeps starting a world, the
//! thing that allocates threads and generators, out of a button handler.

const std = @import("std");
const rl = @import("raylib");

const Theme = @import("ui/Theme.zig");
const Ui = @import("ui/Ui.zig");
const Settings = @import("Settings.zig");

const Menu = @This();

/// Which screen is up
pub const Screen = enum {
    title,
    /// Name, seed and view distance of a world about to be created
    create_world,
    /// Address of a server to join
    join_server,
    options,
    /// Shown over the world, on escape
    paused,
};

/// What the caller should do about this frame
pub const Action = union(enum) {
    /// Carry on showing the menu
    none,
    /// Start a locally generated world
    play_local: struct { seed: u64, name: []const u8 },
    /// Join a server
    join: struct { address: []const u8, port: u16 },
    /// Put the player back in the world that is already running
    resume_game,
    /// Leave the world and go back to the title
    leave_game,
    /// Close the client
    quit,
};

ui: Ui,
settings: *Settings,

screen: Screen = .title,
/// Screen to go back to from the options, which are reachable from two places
options_return: Screen = .title,

// Fields of the create world screen
world_name: Ui.Text = .from("New World"),
seed_text: Ui.Text = .{ .allowed = Ui.seed_chars },
// Fields of the join server screen
address_text: Ui.Text = .from("localhost"),
port_text: Ui.Text = .from("25565"),

/// Set while a world is loaded, which is what turns the pause menu on
in_game: bool = false,
/// True while the menu is on screen and owns the pointer and the keyboard
visible: bool = true,
/// Set when the menu was opened by a press that is still in flight.
///
/// The press that opens the menu belongs to the world, but the menu is drawn on
/// that same frame, and raylib puts the cursor back in the middle of the window
/// when it is released -- which is where a button usually is. Without this, one
/// tap on the on screen menu button opened the menu and pressed whatever was
/// under the centre of the screen.
swallow_click: bool = false,

pub fn init(settings: *Settings) Menu {
    var self: Menu = .{
        .ui = .init(.load()),
        .settings = settings,
    };
    self.address_text.allowed = Ui.address_chars;
    self.port_text.allowed = Ui.digits;
    return self;
}

pub fn deinit(self: *Menu) void {
    self.ui.theme.unload();
}

/// True while the menu wants the pointer and the keyboard
pub fn isOpen(self: Menu) bool {
    return self.visible;
}

/// Opens the pause menu over a running world
pub fn pause(self: *Menu) void {
    std.debug.assert(self.in_game);
    self.screen = .paused;
    self.visible = true;
    self.swallow_click = true;
}

/// Puts the player back in the world
pub fn unpause(self: *Menu) void {
    std.debug.assert(self.in_game);
    self.visible = false;
}

/// Called when a world starts
pub fn enterGame(self: *Menu) void {
    self.in_game = true;
    self.screen = .paused;
    self.visible = false;
}

/// Called when a world is closed
pub fn exitGame(self: *Menu) void {
    self.in_game = false;
    self.screen = .title;
    self.visible = true;
}

/// Runs one frame of whichever screen is up. The world, if there is one, has
/// already been drawn behind it.
pub fn draw(self: *Menu) Action {
    const width: f32 = @floatFromInt(rl.getScreenWidth());
    const height: f32 = @floatFromInt(rl.getScreenHeight());

    self.ui.beginFrame();

    if (self.swallow_click) {
        self.swallow_click = false;
        self.ui.click_consumed = true;
    }

    if (self.in_game) {
        // There is a world behind the menu: leave it visible and dim it, which
        // is what makes the pause menu feel like a pause rather than a screen
        rl.drawRectangle(0, 0, @intFromFloat(width), @intFromFloat(height), Theme.pause_veil);
    } else {
        self.ui.theme.drawBackground(width, height);
    }

    return switch (self.screen) {
        .title => self.drawTitle(width, height),
        .create_world => self.drawCreateWorld(width, height),
        .join_server => self.drawJoinServer(width, height),
        .options => self.drawOptions(width, height),
        .paused => self.drawPaused(width, height),
    };
}

/// A column of full width buttons, centred, the way every classic menu is laid
/// out. Returns the rectangle of the nth row.
fn row(width: f32, top: f32, index: f32) rl.Rectangle {
    return .{
        .x = (width - Theme.button_width) / 2,
        .y = top + index * (Theme.button_height + Theme.gap),
        .width = Theme.button_width,
        .height = Theme.button_height,
    };
}

/// Rows on the screens where every field has a label written above it, which
/// needs a taller pitch than a plain column of buttons
fn labelledRow(width: f32, top: f32, index: f32) rl.Rectangle {
    return .{
        .x = (width - Theme.button_width) / 2,
        .y = top + index * (Theme.button_height + label_height),
        .width = Theme.button_width,
        .height = Theme.button_height,
    };
}

/// Room a label above a field takes
const label_height = 26;

/// Half width buttons, for the pairs at the bottom of a screen
fn halfRow(width: f32, top: f32, index: f32, right: bool) rl.Rectangle {
    const half = (Theme.button_width - Theme.gap) / 2;
    const left = (width - Theme.button_width) / 2;
    return .{
        .x = if (right) left + half + Theme.gap else left,
        .y = top + index * (Theme.button_height + Theme.gap),
        .width = half,
        .height = Theme.button_height,
    };
}

fn drawTitle(self: *Menu, width: f32, height: f32) Action {
    self.ui.theme.drawTextCentred("Craft.zig", width / 2, height * 0.18, Theme.title_size, Theme.text_colour);
    self.ui.theme.drawTextCentred(
        "a data oriented minecraft beta 1.7.3 client",
        width / 2,
        height * 0.18 + Theme.title_size + 6,
        Theme.text_size * 0.8,
        Theme.hint_colour,
    );

    const top = height * 0.4;

    if (self.ui.button(row(width, top, 0), "Singleplayer")) {
        self.screen = .create_world;
        return .none;
    }
    if (self.ui.button(row(width, top, 1), "Multiplayer")) {
        self.screen = .join_server;
        return .none;
    }
    if (self.ui.button(row(width, top, 2), "Options...")) {
        self.options_return = .title;
        self.screen = .options;
        return .none;
    }
    if (self.ui.button(row(width, top, 3), "Quit Game"))
        return .quit;

    return .none;
}

fn drawCreateWorld(self: *Menu, width: f32, height: f32) Action {
    self.ui.theme.drawTextCentred("Create New World", width / 2, height * 0.14, Theme.title_size * 0.7, Theme.text_colour);

    const top = height * 0.28;

    const name_row = labelledRow(width, top, 0);
    self.drawLabel("World Name", name_row);
    self.ui.textField(Ui.idOf(@src(), 0), name_row, &self.world_name, "New World");

    const seed_row = labelledRow(width, top, 1);
    self.drawLabel("Seed (leave blank for a random one)", seed_row);
    self.ui.textField(Ui.idOf(@src(), 1), seed_row, &self.seed_text, "random");

    const distance_row = labelledRow(width, top, 2);
    _ = self.ui.slider(
        Ui.idOf(@src(), 2),
        distance_row,
        "Render Distance",
        &self.settings.view_distance,
        Settings.limits.view_distance.min,
        Settings.limits.view_distance.max,
    );

    if (self.ui.button(halfRow(width, top + label_height, 3.2, false), "Create New World")) {
        self.settings.save();
        return .{ .play_local = .{
            .seed = self.chosenSeed(),
            .name = self.world_name.slice(),
        } };
    }
    if (self.ui.button(halfRow(width, top + label_height, 3.2, true), "Cancel")) {
        self.screen = .title;
        return .none;
    }

    return .none;
}

/// Writes a field's label just above it
fn drawLabel(self: *const Menu, text: [:0]const u8, field: rl.Rectangle) void {
    self.ui.theme.drawText(text, field.x, field.y - label_height + 2, Theme.text_size * 0.8, Theme.hint_colour);
}

/// The seed the player typed, or one from the clock. A seed that is not a
/// number is hashed instead of rejected, the way the game does it.
fn chosenSeed(self: *const Menu) u64 {
    const text = self.seed_text.slice();
    if (text.len == 0)
        return @bitCast(std.time.milliTimestamp());

    if (std.fmt.parseInt(i64, text, 10)) |number| {
        return @bitCast(number);
    } else |_| {
        return std.hash.Wyhash.hash(0, text);
    }
}

fn drawJoinServer(self: *Menu, width: f32, height: f32) Action {
    self.ui.theme.drawTextCentred("Join Server", width / 2, height * 0.14, Theme.title_size * 0.7, Theme.text_colour);

    const top = height * 0.3;

    const address_row = labelledRow(width, top, 0);
    self.drawLabel("Server Address", address_row);
    self.ui.textField(Ui.idOf(@src(), 0), address_row, &self.address_text, "localhost");

    const port_row = labelledRow(width, top, 1);
    self.drawLabel("Port", port_row);
    self.ui.textField(Ui.idOf(@src(), 1), port_row, &self.port_text, "25565");

    const can_join = !self.address_text.isEmpty();
    if (self.ui.buttonEnabled(halfRow(width, top + label_height, 2.2, false), "Join Server", can_join)) {
        return .{ .join = .{
            .address = self.address_text.slice(),
            .port = std.fmt.parseInt(u16, self.port_text.slice(), 10) catch 25565,
        } };
    }
    if (self.ui.button(halfRow(width, top + label_height, 2.2, true), "Cancel")) {
        self.screen = .title;
        return .none;
    }

    return .none;
}

fn drawOptions(self: *Menu, width: f32, height: f32) Action {
    self.ui.theme.drawTextCentred("Options", width / 2, height * 0.14, Theme.title_size * 0.7, Theme.text_colour);

    const top = height * 0.3;

    _ = self.ui.slider(
        Ui.idOf(@src(), 0),
        row(width, top, 0),
        "Render Distance",
        &self.settings.view_distance,
        Settings.limits.view_distance.min,
        Settings.limits.view_distance.max,
    );
    _ = self.ui.slider(
        Ui.idOf(@src(), 1),
        row(width, top, 1),
        "FOV",
        &self.settings.fov,
        Settings.limits.fov.min,
        Settings.limits.fov.max,
    );
    _ = self.ui.slider(
        Ui.idOf(@src(), 2),
        row(width, top, 2),
        "Sensitivity",
        &self.settings.sensitivity,
        Settings.limits.sensitivity.min,
        Settings.limits.sensitivity.max,
    );
    _ = self.ui.slider(
        Ui.idOf(@src(), 3),
        row(width, top, 3),
        "Max Framerate",
        &self.settings.fps_cap,
        Settings.limits.fps_cap.min,
        Settings.limits.fps_cap.max,
    );
    _ = self.ui.toggle(row(width, top, 4), "Show FPS", &self.settings.show_fps);
    _ = self.ui.toggle(row(width, top, 5), "Touch Controls", &self.settings.touch_controls);

    if (self.ui.button(row(width, top, 6.4), "Done")) {
        self.settings.save();
        self.screen = self.options_return;
    }

    return .none;
}

fn drawPaused(self: *Menu, width: f32, height: f32) Action {
    self.ui.theme.drawTextCentred("Game menu", width / 2, height * 0.16, Theme.title_size * 0.7, Theme.text_colour);

    const top = height * 0.34;

    if (self.ui.button(row(width, top, 0), "Back to Game"))
        return .resume_game;

    if (self.ui.button(row(width, top, 1), "Options...")) {
        self.options_return = .paused;
        self.screen = .options;
        return .none;
    }

    if (self.ui.button(row(width, top, 2), "Save and Quit to Title")) {
        self.settings.save();
        return .leave_game;
    }

    return .none;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "a blank seed is random, a number is itself, and anything else hashes" {
    var settings: Settings = .{};
    var menu: Menu = .{ .ui = .{}, .settings = &settings };

    // Not a number: stable, and not zero
    menu.seed_text.set("hello world");
    const hashed = menu.chosenSeed();
    try testing.expectEqual(hashed, menu.chosenSeed());

    menu.seed_text.set("4242");
    try testing.expectEqual(@as(u64, 4242), menu.chosenSeed());

    menu.seed_text.set("-1");
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), menu.chosenSeed());

    // Blank means "pick one", which changes with the clock rather than being 0
    menu.seed_text.set("");
    try testing.expect(menu.chosenSeed() != 0);
}

test "the menu is open outside a world, and only when paused inside one" {
    var settings: Settings = .{};
    var menu: Menu = .{ .ui = .{}, .settings = &settings };

    // No world yet: the title screen is up
    try testing.expect(menu.isOpen());

    // Entering a world hands the pointer over to it
    menu.enterGame();
    try testing.expect(!menu.isOpen());

    menu.pause();
    try testing.expectEqual(Screen.paused, menu.screen);
    try testing.expect(menu.isOpen());

    menu.unpause();
    try testing.expect(!menu.isOpen());

    // Leaving the world comes back to the title
    menu.exitGame();
    try testing.expect(menu.isOpen());
    try testing.expectEqual(Screen.title, menu.screen);
}
