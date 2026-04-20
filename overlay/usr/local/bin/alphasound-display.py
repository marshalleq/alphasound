#!/usr/bin/env python3
"""Render shairport-sync metadata to a Pimoroni Pirate Audio LCD.

Reads the named pipe shairport-sync writes its metadata to, parses the
DAAP/DACP fields we care about (track title, artist, album, cover art),
and pushes a 240x240 RGB image to the ST7789 LCD over SPI.

Designed for Pi Zero 2 W + Pimoroni Pirate Audio (any of the variants;
they all use the same display + pin layout). Other ST7789-based screens
should work with minimal changes — adjust PIN_DC / PIN_BL.
"""

import base64
import io
import os
import re
import sys
import time

import gpiod
import numpy as np
import spidev
from PIL import Image, ImageDraw, ImageFont

# Pirate Audio pin assignments (BCM)
PIN_DC = 9
PIN_BL = 13

WIDTH = 240
HEIGHT = 240

# ST7789 commands we use
CMD_SWRESET = 0x01
CMD_SLPOUT = 0x11
CMD_NORON = 0x13
CMD_INVON = 0x21
CMD_DISPON = 0x29
CMD_CASET = 0x2A
CMD_RASET = 0x2B
CMD_RAMWR = 0x2C
CMD_MADCTL = 0x36
CMD_COLMOD = 0x3A


class ST7789:
    """Minimal ST7789 driver — no external Pimoroni libs required."""

    def __init__(self):
        self.spi = spidev.SpiDev()
        self.spi.open(0, 0)
        self.spi.max_speed_hz = 60_000_000
        self.spi.mode = 0

        # libgpiod handles for DC + backlight on gpiochip0 (Pi BCM bank)
        chip = gpiod.Chip("gpiochip0")
        self.dc = chip.get_line(PIN_DC)
        self.bl = chip.get_line(PIN_BL)
        self.dc.request(consumer="alphasound-display", type=gpiod.LINE_REQ_DIR_OUT)
        self.bl.request(consumer="alphasound-display", type=gpiod.LINE_REQ_DIR_OUT)
        self.bl.set_value(1)
        self._init_panel()

    def _send(self, cmd, data=None):
        self.dc.set_value(0)
        self.spi.writebytes([cmd])
        if data is not None:
            self.dc.set_value(1)
            buf = [data] if isinstance(data, int) else list(data)
            self.spi.writebytes(buf)

    def _init_panel(self):
        self._send(CMD_SWRESET); time.sleep(0.15)
        self._send(CMD_SLPOUT); time.sleep(0.05)
        self._send(CMD_MADCTL, 0x00)
        self._send(CMD_COLMOD, 0x55)  # 16-bit RGB565
        self._send(CMD_INVON)
        self._send(CMD_NORON)
        self._send(CMD_DISPON); time.sleep(0.05)

    def display(self, image):
        """Push a PIL image to the panel (resizes/converts as needed)."""
        if image.size != (WIDTH, HEIGHT):
            image = image.resize((WIDTH, HEIGHT))
        if image.mode != "RGB":
            image = image.convert("RGB")

        self._send(CMD_CASET, [0, 0, 0, WIDTH - 1])
        self._send(CMD_RASET, [0, 0, 0, HEIGHT - 1])

        # RGB888 -> RGB565 big-endian via numpy (fast; pure Python is too slow)
        px = np.array(image, dtype=np.uint16)
        rgb565 = (
            ((px[:, :, 0] & 0xF8) << 8)
            | ((px[:, :, 1] & 0xFC) << 3)
            | ((px[:, :, 2] & 0xF8) >> 3)
        )
        data = rgb565.byteswap().tobytes()

        self.dc.set_value(0)
        self.spi.writebytes([CMD_RAMWR])
        self.dc.set_value(1)
        # spidev caps each transfer; chunk it
        for i in range(0, len(data), 4096):
            self.spi.writebytes2(data[i : i + 4096])


# Each metadata item in shairport-sync's pipe looks like:
#   <item><type>HEX8</type><code>HEX8</code><length>N</length>
#   <data encoding="base64">B64</data></item>
# (data block is omitted for code-only events). The codes we care about
# are 4-char DAAP/DACP names (decoded from the hex).
ITEM_RE = re.compile(
    rb"<item><type>([0-9a-f]{8})</type><code>([0-9a-f]{8})</code>"
    rb"<length>(\d+)</length>(?:\s*<data[^>]*>([^<]*)</data>)?\s*</item>",
    re.MULTILINE,
)


def stream_items(pipe_path):
    """Yield (code, payload-bytes) tuples forever."""
    buf = b""
    f = None
    while True:
        if f is None:
            try:
                f = open(pipe_path, "rb")
            except OSError:
                time.sleep(1); continue
        chunk = f.read(8192)
        if not chunk:
            time.sleep(0.2); continue
        buf += chunk
        while True:
            m = ITEM_RE.search(buf)
            if not m:
                break
            _, code_hex, _, b64 = m.groups()
            buf = buf[m.end():]
            try:
                code = bytes.fromhex(code_hex.decode()).decode("ascii", errors="replace")
            except ValueError:
                continue
            payload = base64.b64decode(b64) if b64 else b""
            yield code, payload


def render(disp, state, fonts):
    """Compose the on-screen image from current state and push it."""
    img = Image.new("RGB", (WIDTH, HEIGHT), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    art = state.get("art")
    text_y = 5
    if art:
        try:
            art_img = Image.open(io.BytesIO(art)).convert("RGB")
            art_img.thumbnail((WIDTH, 160))
            x = (WIDTH - art_img.width) // 2
            img.paste(art_img, (x, 0))
            text_y = art_img.height + 8
        except Exception:
            pass

    title = state.get("title", "").strip()
    artist = state.get("artist", "").strip()

    if title:
        draw.text((6, text_y), title[:40], fill=(255, 255, 255), font=fonts["title"])
        text_y += 22
    if artist:
        draw.text((6, text_y), artist[:40], fill=(180, 180, 180), font=fonts["body"])

    if not title and not artist and not art:
        # Idle screen
        draw.text((20, 100), "Alphasound", fill=(255, 255, 255), font=fonts["title"])
        draw.text((20, 130), "Waiting for music…", fill=(140, 140, 140), font=fonts["body"])

    disp.display(img)


def load_fonts():
    candidates = [
        ("/usr/share/fonts/noto/NotoSans-Bold.ttf", "/usr/share/fonts/noto/NotoSans-Regular.ttf"),
        ("/usr/share/fonts/TTF/NotoSans-Bold.ttf", "/usr/share/fonts/TTF/NotoSans-Regular.ttf"),
    ]
    for bold, reg in candidates:
        if os.path.exists(bold) and os.path.exists(reg):
            return {
                "title": ImageFont.truetype(bold, 18),
                "body": ImageFont.truetype(reg, 14),
            }
    # Fall back to PIL's tiny default bitmap font
    return {"title": ImageFont.load_default(), "body": ImageFont.load_default()}


def main():
    pipe_path = "/tmp/shairport-sync-metadata"
    fonts = load_fonts()
    disp = ST7789()

    state = {}
    render(disp, state, fonts)

    # Wait for shairport-sync to create the pipe (it's created when the
    # first AirPlay client connects in some configs; usually on startup
    # though).
    for _ in range(60):
        if os.path.exists(pipe_path):
            break
        time.sleep(1)
    else:
        print("metadata pipe never appeared", file=sys.stderr)
        sys.exit(1)

    last_render = 0.0
    for code, payload in stream_items(pipe_path):
        if code == "minm":      # song title
            state["title"] = payload.decode("utf-8", errors="replace")
        elif code == "asar":    # artist
            state["artist"] = payload.decode("utf-8", errors="replace")
        elif code == "asal":    # album (we don't render but track it)
            state["album"] = payload.decode("utf-8", errors="replace")
        elif code == "PICT":    # cover art (binary jpeg/png)
            state["art"] = payload
        elif code == "pend":    # play session ended — clear state
            state = {}
        else:
            continue

        # Burst-throttle: shairport spams items together at track changes
        now = time.time()
        if now - last_render >= 0.4:
            try:
                render(disp, state, fonts)
                last_render = now
            except Exception as exc:
                print(f"render failed: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
