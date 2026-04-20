#!/usr/bin/env python3
"""Render shairport-sync metadata to an SPI-attached LCD.

Reads the named pipe shairport-sync writes its metadata to, parses the
DAAP/DACP fields we care about (track title, artist, album, cover art),
and pushes an RGB image to a ST7789 LCD over SPI.

Selected via ALPHASOUND_DISPLAY in alphasound.txt. Add new screens by
extending DEVICES below — the driver only needs pin numbers, dimensions,
and an optional offset/rotation for panels with non-standard mappings.
"""

import base64
import fcntl
import io
import os
import re
import struct
import sys
import time

import gpiod
import numpy as np
from PIL import Image, ImageDraw, ImageFont

# spidev kernel ioctls — see linux/spi/spidev.h. Lets us talk to
# /dev/spidev0.0 directly without needing a Python spidev binding (Alpine
# doesn't package one). Speed and mode are the only knobs we touch.
SPI_IOC_WR_MODE = 0x40016B01
SPI_IOC_WR_MAX_SPEED_HZ = 0x40046B04


class SpiDev:
    def __init__(self, bus=0, dev=0, speed_hz=32_000_000, mode=0):
        self.fd = os.open(f"/dev/spidev{bus}.{dev}", os.O_RDWR)
        fcntl.ioctl(self.fd, SPI_IOC_WR_MODE, struct.pack("B", mode))
        fcntl.ioctl(self.fd, SPI_IOC_WR_MAX_SPEED_HZ, struct.pack("<I", speed_hz))

    def write(self, data):
        if not isinstance(data, (bytes, bytearray)):
            data = bytes(data)
        # Kernel default max bufsiz for /dev/spidev is 4096 bytes; chunk.
        for i in range(0, len(data), 4096):
            os.write(self.fd, data[i : i + 4096])

# Per-device configuration. Add new entries as more screens are supported.
# offset_x/y handle panels whose visible area doesn't start at (0,0) in
# the controller's framebuffer (common on rectangular ST7789s).
DEVICES = {
    "pirate-audio": {
        "width": 240, "height": 240,
        "dc_pin": 9, "bl_pin": 13,
        "offset_x": 0, "offset_y": 0,
        "madctl": 0x00,
    },
    "adafruit-1.3-tft": {
        "width": 240, "height": 240,
        "dc_pin": 25, "bl_pin": 22,
        "offset_x": 0, "offset_y": 0,
        "madctl": 0x00,
    },
    "adafruit-mini-pitft": {  # 1.14" 240x135 — landscape orientation
        "width": 240, "height": 135,
        "dc_pin": 25, "bl_pin": 22,
        "offset_x": 40, "offset_y": 53,
        "madctl": 0x60,  # MX | MV — rotate 90° CW
    },
}

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
    """Minimal ST7789 driver. Pin assignments + panel offsets are
    config-driven so the same code works for Pirate Audio, Adafruit Mini
    PiTFT, and any other ST7789 board on the Pi's main SPI bus."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.spi = SpiDev(bus=0, dev=0, speed_hz=32_000_000, mode=0)

        # libgpiod handles for DC + backlight on gpiochip0 (Pi BCM bank)
        chip = gpiod.Chip("gpiochip0")
        self.dc = chip.get_line(cfg["dc_pin"])
        self.bl = chip.get_line(cfg["bl_pin"])
        self.dc.request(consumer="alphasound-display", type=gpiod.LINE_REQ_DIR_OUT)
        self.bl.request(consumer="alphasound-display", type=gpiod.LINE_REQ_DIR_OUT)
        self.bl.set_value(1)
        self._init_panel()

    def _send(self, cmd, data=None):
        self.dc.set_value(0)
        self.spi.write(bytes([cmd]))
        if data is not None:
            self.dc.set_value(1)
            buf = bytes([data]) if isinstance(data, int) else bytes(data)
            self.spi.write(buf)

    def _init_panel(self):
        self._send(CMD_SWRESET); time.sleep(0.15)
        self._send(CMD_SLPOUT); time.sleep(0.05)
        self._send(CMD_MADCTL, self.cfg["madctl"])
        self._send(CMD_COLMOD, 0x55)  # 16-bit RGB565
        self._send(CMD_INVON)
        self._send(CMD_NORON)
        self._send(CMD_DISPON); time.sleep(0.05)

    def display(self, image):
        """Push a PIL image to the panel (resizes/converts as needed)."""
        w, h = self.cfg["width"], self.cfg["height"]
        ox, oy = self.cfg["offset_x"], self.cfg["offset_y"]
        if image.size != (w, h):
            image = image.resize((w, h))
        if image.mode != "RGB":
            image = image.convert("RGB")

        # Address window — accounts for panels whose visible area is
        # offset within the controller's framebuffer.
        x0, x1 = ox, ox + w - 1
        y0, y1 = oy, oy + h - 1
        self._send(CMD_CASET, [x0 >> 8, x0 & 0xFF, x1 >> 8, x1 & 0xFF])
        self._send(CMD_RASET, [y0 >> 8, y0 & 0xFF, y1 >> 8, y1 & 0xFF])

        # RGB888 -> RGB565 big-endian via numpy (pure Python is too slow)
        px = np.array(image, dtype=np.uint16)
        rgb565 = (
            ((px[:, :, 0] & 0xF8) << 8)
            | ((px[:, :, 1] & 0xFC) << 3)
            | ((px[:, :, 2] & 0xF8) >> 3)
        )
        data = rgb565.byteswap().tobytes()

        self.dc.set_value(0)
        self.spi.write(bytes([CMD_RAMWR]))
        self.dc.set_value(1)
        self.spi.write(data)


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
    w, h = disp.cfg["width"], disp.cfg["height"]
    img = Image.new("RGB", (w, h), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    # On square 240x240 panels we have room for art + text. On rectangular
    # 240x135 panels we put text only — art doesn't fit usefully.
    art = state.get("art")
    text_y = 5
    art_max = min(h - 50, w)
    if art and h >= 200:
        try:
            art_img = Image.open(io.BytesIO(art)).convert("RGB")
            art_img.thumbnail((w, art_max))
            x = (w - art_img.width) // 2
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
        draw.text((10, h // 2 - 20), "Alphasound", fill=(255, 255, 255), font=fonts["title"])
        draw.text((10, h // 2 + 5), "Waiting for music…", fill=(140, 140, 140), font=fonts["body"])

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
    device_name = os.environ.get("ALPHASOUND_DISPLAY", "pirate-audio")
    cfg = DEVICES.get(device_name)
    if cfg is None:
        print(f"unknown display: {device_name}; supported: {sorted(DEVICES)}", file=sys.stderr)
        sys.exit(1)
    print(f"display: {device_name} ({cfg['width']}x{cfg['height']})", file=sys.stderr)

    pipe_path = "/tmp/shairport-sync-metadata"
    fonts = load_fonts()
    disp = ST7789(cfg)

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
