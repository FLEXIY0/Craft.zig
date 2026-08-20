//! A small immediate mode widget set for the menus.
//!
//! Immediate mode suits this project: there is no widget tree to keep in sync
//! with anything, a screen is a function that runs once per frame, and a widget
//! is a rectangle plus the value it edits. The only state that has to survive a
//! frame is which text field has the keyboard, which is one integer.
//!
//! Widgets are identified by their source location, so two calls never collide
//! and nobody has to hand out ids by hand.

const std = @import("std");
const rl = @import("raylib");

const Theme = @import("Theme.zig");

const Ui = @This();

/// Identifies a widget across frames. Built from the call site, so it is stable
/// as long as the screen is
pub const Id = u64;

/// Owned by value on purpose. A pointer to a theme living next to the Ui
/// inside the same struct would dangle the moment that struct is returned or
/// moved, and the failure is quiet: the widgets keep drawing, out of whatever
/// the freed frame holds.
theme: Theme = .{},

/// Pointer position this frame
mouse: rl.Vector2 = .{ .x = 0, .y = 0 },
/// The pointer went down this frame
clicked: bool = false,
/// The pointer is held
held: bool = false,
/// Text field that currently has the keyboard
focus: ?Id = null,
/// Widget the pointer is being dragged on, so a slider keeps it when the
/// pointer leaves the track
dragging: ?Id = null,
/// Set once a click has been used, so one click never triggers two widgets
click_consumed: bool = false,

pub fn init(theme: Theme) Ui {
    return .{ .theme = theme };
}

/// Reads the input once, at the top of a frame
pub fn beginFrame(self: *Ui) void {
    self.mouse = rl.getMousePosition();
    self.clicked = rl.isMouseButtonPressed(.left);
    self.held = rl.isMouseButtonDown(.left);

    if (!self.held)
        self.dragging = null;

    // Clicking outside every text field gives the keyboard back
    if (self.clicked)
        self.click_consumed = false;
}

/// An id from a call site
pub inline fn idOf(comptime src: std.builtin.SourceLocation, salt: u64) Id {
    const base = comptime std.hash.Wyhash.hash(0, src.file ++ ":" ++ src.fn_name);
    return base ^ (salt *% 0x9e3779b97f4a7c15) ^ @as(u64, src.line);
}

fn hovering(self: Ui, rect: rl.Rectangle) bool {
    return rl.checkCollisionPointRec(self.mouse, rect);
}

/// Takes the frame's click if the pointer is inside the rectangle
fn takeClick(self: *Ui, rect: rl.Rectangle) bool {
    if (!self.clicked or self.click_consumed)
        return false;
    if (!self.hovering(rect))
        return false;

    self.click_consumed = true;
    return true;
}

/// A push button. Returns true on the frame it is pressed.
pub fn button(self: *Ui, rect: rl.Rectangle, label: [:0]const u8) bool {
    return self.buttonEnabled(rect, label, true);
}

/// A push button that may be greyed out
pub fn buttonEnabled(self: *Ui, rect: rl.Rectangle, label: [:0]const u8, enabled: bool) bool {
    const hovered = self.hovering(rect);
    self.theme.drawPlate(rect, if (!enabled) .disabled else if (hovered) .hovered else .normal);

    const colour = if (enabled) Theme.text_colour else Theme.disabled_colour;
    self.theme.drawTextCentred(
        label,
        rect.x + rect.width / 2,
        rect.y + (rect.height - Theme.text_size) / 2,
        Theme.text_size,
        colour,
    );

    if (!enabled)
        return false;
    return self.takeClick(rect);
}

/// A labelled slider over a whole number range. Returns true when the value
/// changed, so a caller can act on it (a view distance reload, say).
pub fn slider(
    self: *Ui,
    id: Id,
    rect: rl.Rectangle,
    label: [:0]const u8,
    value: *i32,
    min: i32,
    max: i32,
) bool {
    std.debug.assert(max > min);

    const hovered = self.hovering(rect);
    if (self.clicked and hovered and !self.click_consumed) {
        self.click_consumed = true;
        self.dragging = id;
    }

    const before = value.*;
    if (self.dragging != null and self.dragging.? == id and self.held) {
        const span: f32 = @floatFromInt(max - min);
        const t = std.math.clamp((self.mouse.x - rect.x) / rect.width, 0, 1);
        value.* = min + @as(i32, @intFromFloat(@round(t * span)));
    }

    self.theme.drawPlate(rect, .sunken);

    // The knob sits at the value, and is one button's worth of the track wide
    const t = @as(f32, @floatFromInt(value.* - min)) / @as(f32, @floatFromInt(max - min));
    const knob_width = @max(16, rect.width / 10);
    const knob: rl.Rectangle = .{
        .x = rect.x + t * (rect.width - knob_width),
        .y = rect.y,
        .width = knob_width,
        .height = rect.height,
    };
    const grabbed = hovered or (self.dragging != null and self.dragging.? == id);
    self.theme.drawPlate(knob, if (grabbed) .hovered else .normal);

    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, "{s}: {}", .{ label, value.* }) catch label;
    self.theme.drawTextCentred(
        text,
        rect.x + rect.width / 2,
        rect.y + (rect.height - Theme.text_size) / 2,
        Theme.text_size,
        Theme.text_colour,
    );

    return value.* != before;
}

/// A two state button, the way the classic options screen does them
pub fn toggle(self: *Ui, rect: rl.Rectangle, label: [:0]const u8, value: *bool) bool {
    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, "{s}: {s}", .{ label, if (value.*) "ON" else "OFF" }) catch label;

    if (self.button(rect, text)) {
        value.* = !value.*;
        return true;
    }
    return false;
}

/// A single line text field. `text` is edited in place.
pub fn textField(self: *Ui, id: Id, rect: rl.Rectangle, text: *Text, hint: [:0]const u8) void {
    if (self.takeClick(rect))
        self.focus = id;
    // A click anywhere else drops the keyboard
    if (self.clicked and !self.hovering(rect) and self.focus == id)
        self.focus = null;

    const focused = self.focus == id;
    if (focused)
        text.handleInput();

    self.theme.drawPlate(rect, if (focused) .hovered else .normal);

    const padding = 8;
    const baseline = rect.y + (rect.height - Theme.text_size) / 2;

    if (text.len == 0 and !focused) {
        self.theme.drawText(hint, rect.x + padding, baseline, Theme.text_size, Theme.hint_colour);
    } else {
        self.theme.drawText(text.slice(), rect.x + padding, baseline, Theme.text_size, Theme.text_colour);
    }

    // A blinking caret, on for half of each second
    if (focused and @mod(rl.getTime(), 1.0) < 0.5) {
        const caret_x = rect.x + padding + self.theme.textWidth(text.slice(), Theme.text_size);
        rl.drawRectangleRec(
            .{ .x = caret_x + 2, .y = baseline, .width = 2, .height = Theme.text_size },
            Theme.text_colour,
        );
    }
}

/// Fixed size editable string, so that no menu needs an allocator
pub const Text = struct {
    /// Longest thing a menu asks for is a server address
    pub const capacity = 64;

    data: [capacity:0]u8 = @splat(0),
    len: usize = 0,
    /// Only these characters are accepted, or null for anything printable
    allowed: ?[]const u8 = null,

    pub fn from(initial: []const u8) Text {
        var self: Text = .{};
        self.set(initial);
        return self;
    }

    pub fn set(self: *Text, value: []const u8) void {
        self.len = @min(value.len, capacity);
        @memcpy(self.data[0..self.len], value[0..self.len]);
        self.data[self.len] = 0;
    }

    pub fn slice(self: *const Text) [:0]const u8 {
        return self.data[0..self.len :0];
    }

    pub fn isEmpty(self: *const Text) bool {
        return self.len == 0;
    }

    fn accepts(self: *const Text, char: u8) bool {
        const allowed = self.allowed orelse return true;
        return std.mem.indexOfScalar(u8, allowed, char) != null;
    }

    /// Pulls this frame's typing out of raylib's queue
    fn handleInput(self: *Text) void {
        while (true) {
            const code = rl.getCharPressed();
            if (code == 0)
                break;
            if (code < 32 or code > 126)
                continue;

            const char: u8 = @intCast(code);
            if (!self.accepts(char) or self.len >= capacity)
                continue;

            self.data[self.len] = char;
            self.len += 1;
            self.data[self.len] = 0;
        }

        if ((rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace)) and self.len > 0) {
            self.len -= 1;
            self.data[self.len] = 0;
        }
    }
};

/// Characters a numeric field accepts
pub const digits = "0123456789";
/// Characters a seed field accepts: any number, including a negative one
pub const seed_chars = "0123456789-";
/// Characters an address field accepts
pub const address_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_";

// --- Tests -----------------------------------------------------------------

test "text buffer holds what fits and stays terminated" {
    var text: Text = .from("hello");
    try std.testing.expectEqualStrings("hello", text.slice());
    try std.testing.expect(!text.isEmpty());

    text.set("");
    try std.testing.expect(text.isEmpty());
    try std.testing.expectEqualStrings("", text.slice());

    // Longer than the field: the tail is dropped rather than overrunning
    const long = "x" ** (Text.capacity * 2);
    text.set(long);
    try std.testing.expectEqual(Text.capacity, text.len);
    try std.testing.expectEqual(@as(u8, 0), text.data[Text.capacity]);
}

test "a numeric field only accepts numbers" {
    var text: Text = .{ .allowed = digits };
    try std.testing.expect(text.accepts('4'));
    try std.testing.expect(!text.accepts('x'));

    var seed: Text = .{ .allowed = seed_chars };
    try std.testing.expect(seed.accepts('-'));
    try std.testing.expect(!seed.accepts(' '));
}

test "widget ids differ per call site" {
    const a = idOf(@src(), 0);
    const b = idOf(@src(), 0);
    const c = idOf(@src(), 1);
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
}
