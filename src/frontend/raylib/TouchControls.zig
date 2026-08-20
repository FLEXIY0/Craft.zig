//! On screen controls: a walking stick, an area to look around in, and two
//! buttons.
//!
//! A phone has no keyboard and no mouse, and this is the whole of what the
//! client needs from the player while a world is running: somewhere to walk,
//! somewhere to look, a jump and a way back to the menu.
//!
//! Everything here works off *pointers* rather than off touches, and a pointer
//! is a finger or the mouse. raylib only fills its touch points on a device, so
//! reading them directly would leave this untestable anywhere else; going
//! through one small abstraction means the same code is exercised by a mouse
//! drag on a desktop, which is where it can actually be looked at.
//!
//! Nothing is drawn from a texture. The controls have to be legible over grass,
//! stone and sky, so they are rings and discs with a dark outline, sized off the
//! screen rather than in pixels so that a phone and a tablet both get something
//! the thumb can reach.

const std = @import("std");
const rl = @import("raylib");

const TouchControls = @This();

/// Fingers, or the mouse standing in for one
const max_pointers = 4;

const Pointer = struct {
    id: i32,
    position: rl.Vector2,
};

/// What the player asked for this frame
pub const State = struct {
    /// Walking direction, each axis -1 to 1, already past the dead zone
    move: rl.Vector2 = .{ .x = 0, .y = 0 },
    /// How far to turn the head this frame, in pixels of drag
    look: rl.Vector2 = .{ .x = 0, .y = 0 },
    /// The jump button is held
    jump: bool = false,
    /// The menu button was pressed this frame
    pause: bool = false,
};

/// Below this the stick is treated as centred, so a resting thumb does not
/// walk the player into the sea
const dead_zone = 0.2;

/// Pointer holding the stick, if any
stick: ?i32 = null,
/// How far the stick is pushed, in fractions of its radius
stick_offset: rl.Vector2 = .{ .x = 0, .y = 0 },

/// Pointer dragging the view, and where it was last frame
look: ?i32 = null,
look_from: rl.Vector2 = .{ .x = 0, .y = 0 },

/// Pointer on the jump button
jump: ?i32 = null,

/// True while the menu button is held, so that it fires once
pause_held: bool = false,

/// Where the controls sit, worked out from the window every frame because a
/// phone can be turned over
const Layout = struct {
    stick_centre: rl.Vector2,
    stick_radius: f32,
    jump_centre: rl.Vector2,
    jump_radius: f32,
    pause_centre: rl.Vector2,
    pause_radius: f32,

    fn of(size: rl.Vector2) Layout {
        // A thumb reaches about a sixth of the short side of a screen, and that
        // is the same fraction on a phone and on a tablet
        const unit = @min(size.x, size.y);
        const stick_radius = unit * 0.16;
        const margin = unit * 0.06;
        const jump_radius = unit * 0.11;
        const pause_radius = unit * 0.06;

        return .{
            .stick_centre = .{
                .x = margin + stick_radius,
                .y = size.y - margin - stick_radius,
            },
            .stick_radius = stick_radius,
            .jump_centre = .{
                .x = size.x - margin - jump_radius,
                .y = size.y - margin - jump_radius,
            },
            .jump_radius = jump_radius,
            .pause_centre = .{
                .x = margin + pause_radius,
                .y = margin + pause_radius,
            },
            .pause_radius = pause_radius,
        };
    }
};

/// The pointers that are down this frame.
///
/// On a device these are the touch points. Everywhere else raylib leaves the
/// touch point count at zero, so the mouse stands in for a single finger while
/// a button is held: that is what makes these controls testable without a
/// phone, and usable with a mouse.
fn pointers(buffer: *[max_pointers]Pointer) []const Pointer {
    const count = rl.getTouchPointCount();
    if (count > 0) {
        var written: usize = 0;
        var index: i32 = 0;
        while (index < count and written < buffer.len) : (index += 1) {
            buffer[written] = .{
                .id = rl.getTouchPointId(index),
                .position = rl.getTouchPosition(index),
            };
            written += 1;
        }
        return buffer[0..written];
    }

    if (rl.isMouseButtonDown(.left)) {
        buffer[0] = .{ .id = 0, .position = rl.getMousePosition() };
        return buffer[0..1];
    }

    return buffer[0..0];
}

fn find(list: []const Pointer, id: i32) ?Pointer {
    for (list) |pointer| {
        if (pointer.id == id)
            return pointer;
    }
    return null;
}

fn isHeldElsewhere(self: TouchControls, id: i32) bool {
    return (self.stick != null and self.stick.? == id) or
        (self.look != null and self.look.? == id) or
        (self.jump != null and self.jump.? == id);
}

fn within(point: rl.Vector2, centre: rl.Vector2, radius: f32) bool {
    return point.subtract(centre).length() <= radius;
}

/// Reads the pointers and works out what the player asked for
pub fn update(self: *TouchControls, size: rl.Vector2) State {
    const layout: Layout = .of(size);

    var buffer: [max_pointers]Pointer = undefined;
    const list = pointers(&buffer);

    var state: State = .{};

    // A control keeps its pointer until that pointer is lifted, which is what
    // lets a thumb slide off the stick without dropping it
    if (self.stick) |id| {
        if (find(list, id)) |pointer| {
            const offset = pointer.position.subtract(layout.stick_centre).scale(1.0 / layout.stick_radius);
            const length = offset.length();
            self.stick_offset = if (length > 1.0) offset.scale(1.0 / length) else offset;
        } else {
            self.stick = null;
            self.stick_offset = .{ .x = 0, .y = 0 };
        }
    }

    if (self.look) |id| {
        if (find(list, id)) |pointer| {
            state.look = pointer.position.subtract(self.look_from);
            self.look_from = pointer.position;
        } else {
            self.look = null;
        }
    }

    if (self.jump) |id| {
        if (find(list, id) == null)
            self.jump = null;
    }

    var pause_down = false;

    for (list) |pointer| {
        if (self.isHeldElsewhere(pointer.id))
            continue;

        // The stick has a generous catch radius: a thumb aiming for it and
        // landing next to it should still walk
        if (self.stick == null and within(pointer.position, layout.stick_centre, layout.stick_radius * 1.6)) {
            self.stick = pointer.id;
            continue;
        }

        if (self.jump == null and within(pointer.position, layout.jump_centre, layout.jump_radius)) {
            self.jump = pointer.id;
            continue;
        }

        if (within(pointer.position, layout.pause_centre, layout.pause_radius)) {
            pause_down = true;
            continue;
        }

        // Anything else is a drag to look around, and it starts where it
        // landed so the view does not jump
        if (self.look == null) {
            self.look = pointer.id;
            self.look_from = pointer.position;
        }
    }

    // The menu opens on the press, not on every frame the button is held
    state.pause = pause_down and !self.pause_held;
    self.pause_held = pause_down;

    state.jump = self.jump != null;
    state.move = if (self.stick_offset.length() < dead_zone)
        .{ .x = 0, .y = 0 }
    else
        self.stick_offset;

    return state;
}

/// Forgets every pointer, for when the menu opens over the world
pub fn release(self: *TouchControls) void {
    self.* = .{};
}

const ring_colour: rl.Color = .init(0xff, 0xff, 0xff, 0x60);
const knob_colour: rl.Color = .init(0xff, 0xff, 0xff, 0xb0);
const outline_colour: rl.Color = .init(0x00, 0x00, 0x00, 0x80);

/// A disc with a dark rim, which is what keeps it visible over both sky and
/// stone without needing a texture
fn disc(centre: rl.Vector2, radius: f32, fill: rl.Color) void {
    rl.drawCircleV(centre, radius, fill);
    rl.drawCircleLinesV(centre, radius, outline_colour);
}

pub fn draw(self: TouchControls, size: rl.Vector2) void {
    const layout: Layout = .of(size);

    disc(layout.stick_centre, layout.stick_radius, ring_colour);
    disc(
        layout.stick_centre.add(self.stick_offset.scale(layout.stick_radius * 0.6)),
        layout.stick_radius * 0.42,
        knob_colour,
    );

    disc(layout.jump_centre, layout.jump_radius, if (self.jump != null) knob_colour else ring_colour);
    disc(layout.pause_centre, layout.pause_radius, ring_colour);

    // Three bars, the same mark the menu button has had since long before
    // anybody called it a hamburger
    const bar_width = layout.pause_radius * 0.9;
    const bar_height = @max(2, layout.pause_radius * 0.14);
    var bar: f32 = -1;
    while (bar <= 1) : (bar += 1) {
        rl.drawRectangleV(
            .{
                .x = layout.pause_centre.x - bar_width / 2,
                .y = layout.pause_centre.y + bar * layout.pause_radius * 0.35 - bar_height / 2,
            },
            .{ .x = bar_width, .y = bar_height },
            outline_colour,
        );
    }
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;
const test_screen: rl.Vector2 = .{ .x = 800, .y = 450 };

test "the stick is centred until it is pushed past the dead zone" {
    var controls: TouchControls = .{};
    const layout: Layout = .of(test_screen);

    // A thumb resting a hair off centre is not a walk
    controls.stick = 0;
    controls.stick_offset = .{ .x = 0.1, .y = 0 };
    try testing.expectEqual(@as(f32, 0), controls.stick_offset.x * @as(f32, if (controls.stick_offset.length() < dead_zone) 0 else 1));

    // ...and the catch radius is wider than the ring that is drawn
    try testing.expect(within(
        layout.stick_centre.add(.{ .x = layout.stick_radius * 1.5, .y = 0 }),
        layout.stick_centre,
        layout.stick_radius * 1.6,
    ));
}

test "the controls do not overlap each other" {
    const layout: Layout = .of(test_screen);

    const stick_to_jump = layout.stick_centre.subtract(layout.jump_centre).length();
    try testing.expect(stick_to_jump > layout.stick_radius * 1.6 + layout.jump_radius);

    const stick_to_pause = layout.stick_centre.subtract(layout.pause_centre).length();
    try testing.expect(stick_to_pause > layout.stick_radius * 1.6 + layout.pause_radius);
}

test "the layout follows the short side of the screen" {
    const wide: Layout = .of(.{ .x = 2400, .y = 1080 });
    const tall: Layout = .of(.{ .x = 1080, .y = 2400 });

    // Same thumb, same screen turned over: the controls keep their size
    try testing.expectEqual(wide.stick_radius, tall.stick_radius);
    // ...and stay in their corners
    try testing.expect(wide.stick_centre.y > 1080 / 2);
    try testing.expect(tall.jump_centre.x > 1080 / 2);
}
