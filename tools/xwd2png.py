#!/usr/bin/env python3
"""Turns an `xwd` dump into a PNG.

`xwd` is the only screen grabber that is always present on a bare X server, and
neither PIL nor most viewers read its format, so this is the one step between a
headless run and a picture you can look at. The header is 25 big endian words
followed by an optional colour map; everything after that is rows of `bpl`
bytes, and the channel masks say where in a pixel each channel sits.

    xwd -root -silent > shot.xwd && tools/xwd2png.py shot.xwd shot.png

An optional fourth argument `x,y,w,h` crops, which is how a grab of the whole
root window becomes a picture of just the client.
"""

import struct
import sys

from PIL import Image


def convert(source: str, destination: str, crop: str | None = None) -> None:
    data = open(source, "rb").read()
    header = struct.unpack(">25I", data[:100])
    (header_size, _version, _format, _depth, width, height, _xoffset,
     byte_order, _bitmap_unit, _bit_order, _bitmap_pad, bits_per_pixel,
     bytes_per_line, _visual_class, red_mask, green_mask, blue_mask,
     _bits_per_rgb, _colourmap_entries, ncolours,
     *_rest) = header

    # The colour map sits between the header and the pixels, 12 bytes an entry
    pixels = data[header_size + ncolours * 12:]
    stride = bits_per_pixel // 8

    def shift_of(mask: int) -> int:
        shift = 0
        while mask and not mask & 1:
            mask >>= 1
            shift += 1
        return shift

    red_shift, green_shift, blue_shift = shift_of(red_mask), shift_of(green_mask), shift_of(blue_mask)
    order = "big" if byte_order else "little"

    out = []
    for y in range(height):
        row = pixels[y * bytes_per_line:(y + 1) * bytes_per_line]
        for x in range(width):
            value = int.from_bytes(row[x * stride:(x + 1) * stride], order)
            out.append((
                (value & red_mask) >> red_shift,
                (value & green_mask) >> green_shift,
                (value & blue_mask) >> blue_shift,
            ))

    image = Image.new("RGB", (width, height))
    image.putdata(out)

    if crop:
        x, y, w, h = (int(n) for n in crop.split(","))
        image = image.crop((x, y, x + w, y + h))

    image.save(destination)
    print(f"{image.width}x{image.height} bpp={bits_per_pixel} -> {destination}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit("usage: xwd2png.py <in.xwd> <out.png> [x,y,w,h]")
    convert(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
