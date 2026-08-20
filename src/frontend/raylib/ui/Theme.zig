//! Look of the menus: the textures and the few metrics every screen shares.
//!
//! The classic game's interface is a handful of small images, so that is all
//! this loads. Everything is drawn with point filtering and at whole pixel
//! scales, because the whole style depends on the pixels staying square.
//!
//! The text is raylib's built in font, which is already a pixel font at the
//! right weight. The classic browser build ships a truetype one, but raylib
//! bakes a broken atlas from it — glyphs come out as one quad of the whole
//! sheet — and it is Mojang derived, so it is not worth carrying.
//!
//! Any texture may be missing — they ship with the client but a stripped
//! checkout is a normal thing to run — so every field is optional and the
//! widgets fall back to flat colours.

const std = @import("std");
const rl = @import("raylib");

const Theme = @This();

/// Height of a button, in the classic game's pixels
pub const button_height = 40;
/// Width of a button on the main menu
pub const button_width = 400;
/// Gap between two stacked widgets
pub const gap = 8;
/// Body text size
pub const text_size = 20;
/// Title text size
pub const title_size = 40;

/// Colours, all from the classic interface
pub const text_colour: rl.Color = .init(0xff, 0xff, 0xff, 0xff);
pub const shadow_colour: rl.Color = .init(0x3f, 0x3f, 0x3f, 0xff);
pub const hint_colour: rl.Color = .init(0xa0, 0xa0, 0xa0, 0xff);
pub const disabled_colour: rl.Color = .init(0x70, 0x70, 0x70, 0xff);
/// The dirt the menu background is tiled with, darkened the way the game does
pub const background_tint: rl.Color = .init(0x40, 0x40, 0x40, 0xff);
/// Veil drawn over the world behind the pause menu
pub const pause_veil: rl.Color = .init(0x00, 0x00, 0x00, 0x9f);

/// Button in its resting state
button: ?rl.Texture = null,
/// Button under the pointer
button_over: ?rl.Texture = null,
/// Tiled behind the menus
dirt: ?rl.Texture = null,

pub fn load() Theme {
    var self: Theme = .{};

    self.button = loadTexture("res/textures/classic/gui/button.png");
    self.button_over = loadTexture("res/textures/classic/gui/button_over.png");
    self.dirt = loadTexture("res/textures/classic/dirt.png");

    return self;
}

fn loadTexture(path: [:0]const u8) ?rl.Texture {
    const texture = rl.loadTexture(path) catch |err| {
        std.log.warn("No {s} ({}), the menus will be plain", .{ path, err });
        return null;
    };
    rl.setTextureFilter(texture, .point);
    return texture;
}

pub fn unload(self: Theme) void {
    if (self.button) |texture| texture.unload();
    if (self.button_over) |texture| texture.unload();
    if (self.dirt) |texture| texture.unload();
}

/// The font every screen draws with
pub fn textFont(self: Theme) rl.Font {
    _ = self;
    return rl.getFontDefault() catch unreachable;
}

/// Width of a string, so that screens can centre their own text
pub fn textWidth(self: Theme, text: [:0]const u8, size: f32) f32 {
    return rl.measureTextEx(self.textFont(), text, size, size / 10).x;
}

/// Draws text with the drop shadow the classic interface has on everything
pub fn drawText(self: Theme, text: [:0]const u8, x: f32, y: f32, size: f32, colour: rl.Color) void {
    const font = self.textFont();
    const spacing = size / 10;
    const offset = @max(1, @round(size / 16));

    rl.drawTextEx(font, text, .{ .x = x + offset, .y = y + offset }, size, spacing, shadow_colour);
    rl.drawTextEx(font, text, .{ .x = x, .y = y }, size, spacing, colour);
}

/// Draws text centred on `centre_x`
pub fn drawTextCentred(self: Theme, text: [:0]const u8, centre_x: f32, y: f32, size: f32, colour: rl.Color) void {
    self.drawText(text, centre_x - self.textWidth(text, size) / 2, y, size, colour);
}

/// Tiles the dirt texture over the whole screen, darkened. This is the classic
/// game's menu background, and it costs one texture and no gradient.
pub fn drawBackground(self: Theme, width: f32, height: f32) void {
    const dirt = self.dirt orelse {
        rl.drawRectangle(0, 0, @intFromFloat(width), @intFromFloat(height), background_tint);
        return;
    };

    // Each tile is drawn at 2x, which is the scale the game uses
    const scale = 32;
    const source: rl.Rectangle = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(dirt.width),
        .height = @floatFromInt(dirt.height),
    };

    var y: f32 = 0;
    while (y < height) : (y += scale) {
        var x: f32 = 0;
        while (x < width) : (x += scale) {
            rl.drawTexturePro(
                dirt,
                source,
                .{ .x = x, .y = y, .width = scale, .height = scale },
                .zero(),
                0,
                background_tint,
            );
        }
    }
}

/// Draws a button plate, stretched to the rectangle asked for.
/// The classic button texture is a flat plate with a one pixel bevel, so the
/// three slices (left edge, middle, right edge) keep the bevel square while the
/// middle stretches.
pub fn drawPlate(self: Theme, rect: rl.Rectangle, hovered: bool, enabled: bool) void {
    const texture = (if (hovered and enabled) self.button_over else self.button) orelse {
        rl.drawRectangleRec(rect, if (hovered and enabled) rl.Color.init(0x6d, 0x6d, 0xd4, 0xff) else rl.Color.init(0x6d, 0x6d, 0x6d, 0xff));
        return;
    };

    const tint: rl.Color = if (enabled) .white else .init(0x80, 0x80, 0x80, 0xff);
    const full: f32 = @floatFromInt(texture.width);
    const tall: f32 = @floatFromInt(texture.height);

    // Two pixels of the source are the bevel, drawn at 2x and never stretched
    const edge_src = 2;
    const edge_dst = 4;
    const middle_src = full - edge_src * 2;
    const middle_dst = @max(0, rect.width - edge_dst * 2);

    const slices = [3][4]f32{
        // source x, source width, destination x, destination width
        .{ 0, edge_src, rect.x, edge_dst },
        .{ edge_src, middle_src, rect.x + edge_dst, middle_dst },
        .{ full - edge_src, edge_src, rect.x + rect.width - edge_dst, edge_dst },
    };

    for (slices) |slice| {
        rl.drawTexturePro(
            texture,
            .{ .x = slice[0], .y = 0, .width = slice[1], .height = tall },
            .{ .x = slice[2], .y = rect.y, .width = slice[3], .height = rect.height },
            .zero(),
            0,
            tint,
        );
    }
}
