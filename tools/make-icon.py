#!/usr/bin/env python3
"""Draws the launcher icon.

Original artwork on purpose: the texture folders in res/ are derived from a
game that is not ours and carry a readme saying so, and an icon is the one
asset that ends up inside a published APK. This is a block in the same spirit,
drawn from three polygons and a palette, at every density Android asks for.
"""

import os

from PIL import Image, ImageDraw

# Top, left and right faces, plus the outline. Grass over dirt, the way the
# first block anybody sees in this game looks.
TOP = (0x7C, 0xB3, 0x42)
TOP_SHADE = (0x6A, 0x9B, 0x38)
LEFT = (0x77, 0x53, 0x36)
RIGHT = (0x5E, 0x41, 0x2A)
GRASS_LEFT = (0x63, 0x91, 0x35)
GRASS_RIGHT = (0x52, 0x78, 0x2C)
OUTLINE = (0x2B, 0x1D, 0x12)
SKY = (0x7E, 0xB0, 0xE8)

DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def draw(size: int) -> Image.Image:
    # Drawn large and reduced, so the diagonals are clean at every density
    scale = 8
    n = size * scale
    image = Image.new("RGBA", (n, n), SKY + (255,))
    pen = ImageDraw.Draw(image)

    # A cube seen from above and to the left, inset from the edges
    pad = n * 0.08
    w = n - pad * 2
    top_y = pad + w * 0.06
    mid_y = pad + w * 0.36
    low_y = pad + w * 0.66
    bot_y = pad + w * 0.94
    left_x = pad
    mid_x = pad + w / 2
    right_x = pad + w

    pen.polygon([(mid_x, top_y), (right_x, mid_y), (mid_x, low_y), (left_x, mid_y)], fill=TOP)
    pen.polygon([(mid_x, top_y), (right_x, mid_y), (mid_x, low_y)], fill=TOP_SHADE)

    # The band of grass hanging over the dirt, on both visible sides
    band = (bot_y - mid_y) * 0.22
    pen.polygon([(left_x, mid_y), (mid_x, low_y), (mid_x, low_y + band), (left_x, mid_y + band)], fill=GRASS_LEFT)
    pen.polygon([(right_x, mid_y), (mid_x, low_y), (mid_x, low_y + band), (right_x, mid_y + band)], fill=GRASS_RIGHT)

    pen.polygon(
        [(left_x, mid_y + band), (mid_x, low_y + band), (mid_x, bot_y), (left_x, bot_y - (low_y - mid_y))],
        fill=LEFT,
    )
    pen.polygon(
        [(right_x, mid_y + band), (mid_x, low_y + band), (mid_x, bot_y), (right_x, bot_y - (low_y - mid_y))],
        fill=RIGHT,
    )

    width = max(1, int(n * 0.012))
    for a, b in (
        ((mid_x, top_y), (right_x, mid_y)),
        ((right_x, mid_y), (mid_x, low_y)),
        ((mid_x, low_y), (left_x, mid_y)),
        ((left_x, mid_y), (mid_x, top_y)),
        ((mid_x, low_y), (mid_x, bot_y)),
        ((left_x, mid_y), (left_x, bot_y - (low_y - mid_y))),
        ((right_x, mid_y), (right_x, bot_y - (low_y - mid_y))),
        ((left_x, bot_y - (low_y - mid_y)), (mid_x, bot_y)),
        ((mid_x, bot_y), (right_x, bot_y - (low_y - mid_y))),
    ):
        pen.line([a, b], fill=OUTLINE, width=width)

    return image.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    root = os.path.join(os.path.dirname(__file__), "..", "android", "res")
    for density, size in DENSITIES.items():
        folder = os.path.join(root, "mipmap-" + density)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "icon.png")
        draw(size).save(path)
        print(f"{size}x{size} -> {os.path.normpath(path)}")
