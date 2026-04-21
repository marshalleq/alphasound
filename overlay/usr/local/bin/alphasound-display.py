#!/usr/bin/env python3
"""Render shairport-sync metadata to a screen.

Two backends:
  * ST7789 over SPI — Pirate Audio, Adafruit Mini PiTFT, etc.
  * HDMI framebuffer (/dev/fb0) — any monitor connected to the Pi's HDMI
    port. Takes over the console for as long as it's running; toggle
    ALPHASOUND_DISPLAY back to "none" via the web UI to get the console
    back on next boot.

Selected via ALPHASOUND_DISPLAY in alphasound.txt. Add new ST7789 panels
by extending DEVICES below.
"""

import base64
import fcntl
import io
import mmap
import os
import re
import struct
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SPI_IOC_WR_MODE = 0x40016B01
SPI_IOC_WR_MAX_SPEED_HZ = 0x40046B04


class SpiDev:
    """Raw /dev/spidev0.0 access — no Python spidev binding required."""

    def __init__(self, bus=0, dev=0, speed_hz=32_000_000, mode=0):
        self.fd = os.open(f"/dev/spidev{bus}.{dev}", os.O_RDWR)
        fcntl.ioctl(self.fd, SPI_IOC_WR_MODE, struct.pack("B", mode))
        fcntl.ioctl(self.fd, SPI_IOC_WR_MAX_SPEED_HZ, struct.pack("<I", speed_hz))

    def write(self, data):
        if not isinstance(data, (bytes, bytearray)):
            data = bytes(data)
        for i in range(0, len(data), 4096):
            os.write(self.fd, data[i : i + 4096])


class PiGPIO:
    """Direct BCM2835 GPIO register access via /dev/gpiomem.

    We can't use libgpiod for DC here: GPIO 9 is also SPI0 MISO, and
    pinctrl keeps it in SPI alt-mode even after a gpiod line request,
    so set_value() silently no-ops and DC never toggles. Writing GPFSEL
    directly (what RPi.GPIO does) overrides pinctrl and gives us real
    GPIO control. Valid for pins 0-31 on every Pi through Pi 4; Pi 5
    would need a different path (RP1)."""

    GPFSEL0 = 0x00   # one 32-bit reg per 10 pins, 3 bits per pin
    GPSET0  = 0x1C
    GPCLR0  = 0x28

    def __init__(self):
        fd = os.open("/dev/gpiomem", os.O_RDWR | os.O_SYNC)
        try:
            self.mem = mmap.mmap(fd, 4096, mmap.MAP_SHARED,
                                 mmap.PROT_READ | mmap.PROT_WRITE)
        finally:
            os.close(fd)

    def setup_output(self, pin):
        reg = self.GPFSEL0 + (pin // 10) * 4
        shift = (pin % 10) * 3
        val = int.from_bytes(self.mem[reg:reg + 4], "little")
        val = (val & ~(0b111 << shift)) | (0b001 << shift)
        self.mem[reg:reg + 4] = val.to_bytes(4, "little")

    def set(self, pin, high):
        reg = self.GPSET0 if high else self.GPCLR0
        self.mem[reg:reg + 4] = (1 << pin).to_bytes(4, "little")


# ---------------------------------------------------------------------------
# ST7789 (SPI) backend
# ---------------------------------------------------------------------------

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

DEVICES = {
    # Pirate Audio wires its LCD to CE1, not the Pi's default CE0.
    "pirate-audio": {
        "width": 240, "height": 240,
        "spi_cs": 1,
        "dc_pin": 9, "bl_pin": 13,
        "offset_x": 0, "offset_y": 0,
        "madctl": 0x00,
    },
    "adafruit-1.3-tft": {
        "width": 240, "height": 240,
        "spi_cs": 0,
        "dc_pin": 25, "bl_pin": 22,
        "offset_x": 0, "offset_y": 0,
        "madctl": 0x00,
    },
    "adafruit-mini-pitft": {
        "width": 240, "height": 135,
        "spi_cs": 0,
        "dc_pin": 25, "bl_pin": 22,
        "offset_x": 40, "offset_y": 53,
        "madctl": 0x60,
    },
}


class ST7789Display:
    backend = "spi"

    def __init__(self, cfg):
        self.cfg = cfg
        self.spi = SpiDev(bus=0, dev=cfg["spi_cs"], speed_hz=32_000_000, mode=0)

        self.dc_pin = cfg["dc_pin"]
        self.bl_pin = cfg["bl_pin"]
        self.gpio = PiGPIO()
        self.gpio.setup_output(self.dc_pin)
        self.gpio.setup_output(self.bl_pin)
        self.gpio.set(self.bl_pin, True)
        self._init_panel()

    def _dc(self, high):
        self.gpio.set(self.dc_pin, bool(high))

    def _send(self, cmd, data=None):
        self._dc(0)
        self.spi.write(bytes([cmd]))
        if data is not None:
            self._dc(1)
            self.spi.write(bytes([data]) if isinstance(data, int) else bytes(data))

    def _init_panel(self):
        self._send(CMD_SWRESET); time.sleep(0.15)
        self._send(CMD_SLPOUT); time.sleep(0.05)
        self._send(CMD_MADCTL, self.cfg["madctl"])
        self._send(CMD_COLMOD, 0x55)  # 16-bit RGB565
        self._send(CMD_INVON)
        self._send(CMD_NORON)
        self._send(CMD_DISPON); time.sleep(0.05)

    def display(self, image):
        w, h = self.cfg["width"], self.cfg["height"]
        ox, oy = self.cfg["offset_x"], self.cfg["offset_y"]
        if image.size != (w, h):
            image = image.resize((w, h))
        if image.mode != "RGB":
            image = image.convert("RGB")

        x0, x1 = ox, ox + w - 1
        y0, y1 = oy, oy + h - 1
        self._send(CMD_CASET, [x0 >> 8, x0 & 0xFF, x1 >> 8, x1 & 0xFF])
        self._send(CMD_RASET, [y0 >> 8, y0 & 0xFF, y1 >> 8, y1 & 0xFF])

        px = np.array(image, dtype=np.uint16)
        rgb565 = (
            ((px[:, :, 0] & 0xF8) << 8)
            | ((px[:, :, 1] & 0xFC) << 3)
            | ((px[:, :, 2] & 0xF8) >> 3)
        )
        data = rgb565.byteswap().tobytes()

        self._dc(0)
        self.spi.write(bytes([CMD_RAMWR]))
        self._dc(1)
        self.spi.write(data)


# ---------------------------------------------------------------------------
# HDMI framebuffer backend
# ---------------------------------------------------------------------------


class FBDisplay:
    """Write directly to /dev/fb0. Resolution + bpp are read from sysfs.
    Supports 16-bit RGB565 and 32-bit RGBA — the two common Pi modes."""

    backend = "hdmi"

    def __init__(self):
        with open("/sys/class/graphics/fb0/virtual_size") as f:
            w, h = (int(x) for x in f.read().strip().split(","))
        with open("/sys/class/graphics/fb0/bits_per_pixel") as f:
            bpp = int(f.read().strip())
        with open("/sys/class/graphics/fb0/stride") as f:
            stride = int(f.read().strip())
        self.cfg = {"width": w, "height": h, "bpp": bpp, "stride": stride}
        self.fd = os.open("/dev/fb0", os.O_RDWR)
        # Hide the blinking text-mode cursor on tty1 so it doesn't blink
        # over our image. Best-effort — no big deal if it fails.
        try:
            with open("/dev/tty1", "wb") as t:
                t.write(b"\033[?25l")
        except OSError:
            pass

    def display(self, image):
        w, h, bpp = self.cfg["width"], self.cfg["height"], self.cfg["bpp"]
        if image.size != (w, h):
            image = image.resize((w, h))
        if bpp == 32:
            # BGRA in most Pi fb modes
            arr = np.array(image.convert("RGBA"), dtype=np.uint8)
            arr = arr[:, :, [2, 1, 0, 3]]
            data = arr.tobytes()
        elif bpp == 16:
            px = np.array(image.convert("RGB"), dtype=np.uint16)
            rgb565 = (
                ((px[:, :, 0] & 0xF8) << 8)
                | ((px[:, :, 1] & 0xFC) << 3)
                | ((px[:, :, 2] & 0xF8) >> 3)
            )
            data = rgb565.tobytes()
        else:
            raise RuntimeError(f"unsupported framebuffer bpp: {bpp}")
        os.lseek(self.fd, 0, os.SEEK_SET)
        os.write(self.fd, data)


# ---------------------------------------------------------------------------
# Metadata pipe parsing
# ---------------------------------------------------------------------------

ITEM_RE = re.compile(
    rb"<item><type>([0-9a-f]{8})</type><code>([0-9a-f]{8})</code>"
    rb"<length>(\d+)</length>(?:\s*<data[^>]*>([^<]*)</data>)?\s*</item>",
    re.MULTILINE,
)


def stream_items(pipe_path):
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


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def fmt_time(seconds):
    if seconds is None or seconds < 0:
        return "--:--"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def render(disp, state, fonts):
    w, h = disp.cfg["width"], disp.cfg["height"]
    img = Image.new("RGB", (w, h), (12, 12, 16))
    draw = ImageDraw.Draw(img)

    title = state.get("title", "").strip()
    artist = state.get("artist", "").strip()
    album = state.get("album", "").strip()
    art = state.get("art")
    pos, dur = state.get("position"), state.get("duration")

    if not title and not artist and not art:
        msg1 = "Alphasound"
        msg2 = "Waiting for music…"
        bbox = draw.textbbox((0, 0), msg1, font=fonts["xl"])
        draw.text(((w - bbox[2]) // 2, h // 2 - 40), msg1, fill=(220, 220, 220), font=fonts["xl"])
        bbox = draw.textbbox((0, 0), msg2, font=fonts["body"])
        draw.text(((w - bbox[2]) // 2, h // 2 + 10), msg2, fill=(140, 140, 140), font=fonts["body"])
        disp.display(img); return

    # Layout strategy depends on aspect ratio.
    landscape = w >= h * 1.4   # HDMI 16:9, big TFTs
    tall = h > w               # nothing yet, but be safe
    art_img = None
    if art:
        try:
            art_img = Image.open(io.BytesIO(art)).convert("RGB")
        except Exception:
            art_img = None

    if landscape and h >= 400:
        # Big screen layout — art on left, info on right, progress bottom
        art_size = h - 80
        if art_img:
            art_img.thumbnail((art_size, art_size))
            img.paste(art_img, (40, 40))
        text_x = 60 + (art_size if art_img else 0)
        text_w = w - text_x - 40
        y = 60
        if title:
            draw.text((text_x, y), title[:50], fill=(255, 255, 255), font=fonts["xl"]); y += 60
        if artist:
            draw.text((text_x, y), artist[:60], fill=(200, 200, 200), font=fonts["lg"]); y += 50
        if album:
            draw.text((text_x, y), album[:60], fill=(140, 140, 140), font=fonts["body"]); y += 40
        _draw_progress(draw, fonts, 40, h - 50, w - 80, pos, dur)

    elif w >= h - 20:
        # Squareish — art on top, text below
        info_h = max(70, h // 4)
        art_max = h - info_h - 8
        if art_img:
            art_img.thumbnail((w, art_max))
            x = (w - art_img.width) // 2
            img.paste(art_img, (x, 0))
            text_y = art_img.height + 8
        else:
            text_y = 8
        if title:
            draw.text((6, text_y), title[:40], fill=(255, 255, 255), font=fonts["title"]); text_y += 22
        if artist:
            draw.text((6, text_y), artist[:40], fill=(180, 180, 180), font=fonts["body"]); text_y += 18
        _draw_progress(draw, fonts, 6, h - 14, w - 12, pos, dur)

    else:
        # Wide-but-short panels (e.g. 240x135) — text only, no art
        y = 6
        if title:
            draw.text((6, y), title[:40], fill=(255, 255, 255), font=fonts["title"]); y += 24
        if artist:
            draw.text((6, y), artist[:40], fill=(180, 180, 180), font=fonts["body"]); y += 18
        if album:
            draw.text((6, y), album[:40], fill=(140, 140, 140), font=fonts["body"]); y += 18
        _draw_progress(draw, fonts, 6, h - 14, w - 12, pos, dur)

    disp.display(img)


def _draw_progress(draw, fonts, x, y, width, pos, dur):
    if not dur or dur <= 0:
        return
    pct = max(0.0, min(1.0, (pos or 0) / dur))
    bar_h = 4
    draw.rectangle((x, y, x + width, y + bar_h), fill=(40, 40, 50))
    draw.rectangle((x, y, x + int(width * pct), y + bar_h), fill=(120, 200, 255))
    label = f"{fmt_time(pos)}  /  {fmt_time(dur)}"
    draw.text((x, y - 14), label, fill=(140, 140, 160), font=fonts["small"])


def load_fonts():
    candidates = [
        "/usr/share/fonts/noto/NotoSans-Bold.ttf",
        "/usr/share/fonts/TTF/NotoSans-Bold.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/TTF/NotoSans-Regular.ttf",
    ]
    bold = next((p for p in candidates if "Bold" in p and os.path.exists(p)), None)
    reg = next((p for p in candidates if "Regular" in p and os.path.exists(p)), None)
    if bold and reg:
        return {
            "xl":    ImageFont.truetype(bold, 36),
            "lg":    ImageFont.truetype(bold, 24),
            "title": ImageFont.truetype(bold, 18),
            "body":  ImageFont.truetype(reg, 14),
            "small": ImageFont.truetype(reg, 11),
        }
    f = ImageFont.load_default()
    return {"xl": f, "lg": f, "title": f, "body": f, "small": f}


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def main():
    device_name = os.environ.get("ALPHASOUND_DISPLAY", "pirate-audio")

    if device_name == "hdmi":
        if not os.path.exists("/dev/fb0"):
            print("ALPHASOUND_DISPLAY=hdmi but /dev/fb0 doesn't exist", file=sys.stderr)
            sys.exit(1)
        disp = FBDisplay()
        print(f"display: hdmi ({disp.cfg['width']}x{disp.cfg['height']} @ {disp.cfg['bpp']}bpp)",
              file=sys.stderr)
    elif device_name in DEVICES:
        cfg = DEVICES[device_name]
        disp = ST7789Display(cfg)
        print(f"display: {device_name} ({cfg['width']}x{cfg['height']})", file=sys.stderr)
    else:
        print(f"unknown display: {device_name}; supported: hdmi + {sorted(DEVICES)}",
              file=sys.stderr)
        sys.exit(1)

    pipe_path = "/tmp/shairport-sync-metadata"
    fonts = load_fonts()

    state = {}
    render(disp, state, fonts)

    for _ in range(60):
        if os.path.exists(pipe_path):
            break
        time.sleep(1)
    else:
        print("metadata pipe never appeared", file=sys.stderr)
        sys.exit(1)

    # 'prgr' is "start/current/end" RTP frame counts at 44100 Hz.
    rtp_start = rtp_end = None
    rtp_received_at = None
    last_render = 0.0
    last_progress_render = 0.0

    for code, payload in stream_items(pipe_path):
        changed = False
        if code == "minm":
            state["title"] = payload.decode("utf-8", errors="replace"); changed = True
        elif code == "asar":
            state["artist"] = payload.decode("utf-8", errors="replace"); changed = True
        elif code == "asal":
            state["album"] = payload.decode("utf-8", errors="replace"); changed = True
        elif code == "PICT":
            state["art"] = payload; changed = True
        elif code == "prgr":
            try:
                start_s, _cur, end_s = payload.decode().split("/")
                rtp_start = int(start_s)
                rtp_end = int(end_s)
                rtp_received_at = time.time()
                state["duration"] = (rtp_end - rtp_start) / 44100
            except Exception:
                pass
        elif code == "pend":
            state = {}; rtp_start = rtp_end = None; changed = True

        # Update elapsed every render even without metadata events
        if rtp_start is not None and rtp_end is not None and rtp_received_at:
            state["position"] = max(0.0, time.time() - rtp_received_at)

        now = time.time()
        # Throttle: redraw immediately on metadata change, otherwise
        # tick the progress bar every second.
        if changed and now - last_render >= 0.4:
            try:
                render(disp, state, fonts)
                last_render = now
                last_progress_render = now
            except Exception as e:
                print(f"render failed: {e}", file=sys.stderr)
        elif now - last_progress_render >= 1.0 and "duration" in state:
            try:
                render(disp, state, fonts)
                last_progress_render = now
            except Exception as e:
                print(f"render failed: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
