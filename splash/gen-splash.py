#!/usr/bin/env python3
"""Render the boot-splash image and emit raw RGB565 pixels.

Called from build.sh during image build. Produces a 240x240 splash
containing an "alphasound" title + "loading…" subtitle on a near-black
background, then writes it as 115200 bytes of big-endian RGB565 (which
is what the ST7789 panel expects — matches alphasound-display.py's
output after byteswap()).
"""

import struct
import sys

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 240, 240
BG = (12, 12, 16)
FG = (230, 230, 235)
DIM = (150, 150, 165)


def load_font(size, bold=False):
    candidates = [
        f"/usr/share/fonts/noto/NotoSans-{'Bold' if bold else 'Regular'}.ttf",
        f"/usr/share/fonts/TTF/NotoSans-{'Bold' if bold else 'Regular'}.ttf",
    ]
    for p in candidates:
        try:
            return ImageFont.truetype(p, size)
        except (OSError, IOError):
            continue
    return ImageFont.load_default()


def centred(draw, text, y, font, fill):
    bbox = draw.textbbox((0, 0), text, font=font)
    x = (WIDTH - bbox[2]) // 2
    draw.text((x, y), text, fill=fill, font=font)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "splash.raw"

    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)

    title_font = load_font(40, bold=True)
    sub_font = load_font(16)

    centred(draw, "alphasound", HEIGHT // 2 - 42, title_font, FG)
    centred(draw, "loading…", HEIGHT // 2 + 18, sub_font, DIM)

    data = bytearray()
    for r, g, b in img.getdata():
        rgb565 = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3)
        data += struct.pack(">H", rgb565)

    assert len(data) == WIDTH * HEIGHT * 2

    with open(out, "wb") as f:
        f.write(data)

    print(f"wrote {len(data)} bytes to {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
