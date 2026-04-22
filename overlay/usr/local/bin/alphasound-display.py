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
import subprocess
import sys
import threading
import time
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFont

PWM_DUTY_PATH = "/sys/class/pwm/pwmchip0/pwm1/duty_cycle"

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


def _pwm_driving_backlight():
    """True iff the PWM1 channel is exported and enabled — indicating
    alphasound.start has taken over the backlight via hardware PWM."""
    try:
        with open("/sys/class/pwm/pwmchip0/pwm1/enable") as f:
            return f.read().strip() == "1"
    except OSError:
        return False


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
        # If hardware PWM is already driving the backlight pin (via
        # dtoverlay=pwm-2chan + sysfs setup in alphasound.start), leave
        # it alone — reclaiming the pin as GPIO would kill the PWM mux.
        # Otherwise, fall back to plain GPIO-high (full brightness).
        self._bl_via_pwm = _pwm_driving_backlight()
        if not self._bl_via_pwm:
            self.gpio.setup_output(self.bl_pin)
            self.gpio.set(self.bl_pin, True)
        self._saved_duty = None
        self._init_panel()

    def blank(self):
        """Cut the backlight (timeout). Panel content preserved."""
        if self._bl_via_pwm:
            try:
                with open(PWM_DUTY_PATH) as f:
                    self._saved_duty = f.read().strip()
                with open(PWM_DUTY_PATH, "w") as f:
                    f.write("0")
                return
            except OSError:
                pass
        try:
            self.gpio.set(self.bl_pin, False)
        except Exception:
            pass

    def unblank(self):
        if self._bl_via_pwm and self._saved_duty is not None:
            try:
                with open(PWM_DUTY_PATH, "w") as f:
                    f.write(self._saved_duty)
                return
            except OSError:
                pass
        try:
            self.gpio.set(self.bl_pin, True)
        except Exception:
            pass

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
        self._send(CMD_SLPOUT); time.sleep(0.12)
        self._send(CMD_MADCTL, self.cfg["madctl"])
        self._send(CMD_COLMOD, 0x55)  # 16-bit RGB565
        # Pimoroni-tuned porch / gate / VCOM / power / gamma. The chip's
        # power-on defaults give a noticeably flatter, dimmer image than
        # this sequence does on Pirate Audio — and usually on similar
        # ST7789 panels (Adafruit variants) too. If a panel looks off on
        # this block, its gamma (0xE0/0xE1) is the knob to reach for.
        self._send(0xB2, [0x0C, 0x0C, 0x00, 0x33, 0x33])   # PORCTRL
        self._send(0xB7, 0x35)                              # GCTRL
        self._send(0xBB, 0x19)                              # VCOMS
        self._send(0xC0, 0x2C)                              # LCMCTRL
        self._send(0xC2, 0x01)                              # VDVVRHEN
        self._send(0xC3, 0x12)                              # VRHS
        self._send(0xC4, 0x20)                              # VDVS
        self._send(0xC6, 0x0F)                              # FRCTRL2 60 Hz
        self._send(0xD0, [0xA4, 0xA1])                      # PWCTRL1
        self._send(0xE0, [0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B,
                          0x3F, 0x54, 0x4C, 0x18, 0x0D, 0x0B,
                          0x1F, 0x23])                      # PVGAMCTRL
        self._send(0xE1, [0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C,
                          0x3F, 0x44, 0x51, 0x2F, 0x1F, 0x1F,
                          0x20, 0x23])                      # NVGAMCTRL
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
        # Panel compensation. Applied here (not in render) because it
        # compensates for the panel, not the source.
        #   gamma 1.25  — counters the panel's lifted shadows (IPS black
        #                 level can't actually block backlight). Pulls
        #                 darks down; barely touches highlights.
        #   colour 1.35 — ST7789 + RGB565 looks desaturated otherwise.
        #   sharp  1.2  — recovers edge definition lost to 240×240 scale.
        arr = np.asarray(image, dtype=np.float32) / 255.0
        arr = arr ** 1.25
        image = Image.fromarray((arr * 255).clip(0, 255).astype(np.uint8))
        image = ImageEnhance.Color(image).enhance(1.35)
        image = ImageEnhance.Sharpness(image).enhance(1.2)

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

    def blank(self):
        """No hardware backlight to cut — just render solid black."""
        black = Image.new("RGB", (self.cfg["width"], self.cfg["height"]), (0, 0, 0))
        try:
            self.display(black)
        except Exception:
            pass

    def unblank(self):
        # Next render call from the main loop repaints.
        pass


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


def _dominant_dark_color(img, max_luminance=0.28):
    """Pick a dark, reasonably-common colour from the image to tint the
    text gradient with. Clamped below max_luminance so white text stays
    legible — if the whole album is bright we darken the dominant pick
    rather than letting the gradient wash out."""
    quant = img.resize((64, 64)).quantize(colors=8)
    palette = quant.getpalette()
    by_count = sorted(quant.getcolors() or [], reverse=True)
    for _, idx in by_count:
        r, g, b = palette[idx * 3:idx * 3 + 3]
        lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        if lum <= max_luminance:
            return (r, g, b)
    if by_count:
        _, idx = by_count[0]
        r, g, b = palette[idx * 3:idx * 3 + 3]
        lum = max((0.299 * r + 0.587 * g + 0.114 * b) / 255, 0.01)
        scale = max_luminance / lum
        return (int(r * scale), int(g * scale), int(b * scale))
    return (0, 0, 0)


def _fit_cover(img, w, h):
    """Scale img to cover a w×h box, centre-cropping any overflow."""
    iw, ih = img.size
    if iw * h > ih * w:
        nw, nh = max(w, int(iw * h / ih)), h
        img = img.resize((nw, nh))
        left = (nw - w) // 2
        return img.crop((left, 0, left + w, h))
    nw, nh = w, max(h, int(ih * w / iw))
    img = img.resize((nw, nh))
    top = (nh - h) // 2
    return img.crop((0, top, w, top + h))


def _bottom_gradient(width, height, color, peak_alpha=245):
    """Build an RGBA overlay, transparent at the top, `color` at
    `peak_alpha` opacity at the bottom. Gamma <1 pushes opacity up
    quickly so text in the middle of the band is still well-covered."""
    t = np.linspace(0, 1, height, dtype=np.float32) ** 0.85
    alpha = (t * peak_alpha).astype(np.uint8)
    arr = np.empty((height, width, 4), dtype=np.uint8)
    arr[:, :, 0] = color[0]
    arr[:, :, 1] = color[1]
    arr[:, :, 2] = color[2]
    arr[:, :, 3] = alpha[:, None]
    return Image.fromarray(arr, "RGBA")


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
        # Squareish — full-bleed art with a dominant-colour gradient
        # overlay at the bottom that the text sits in.
        gradient_h = int(h * 0.42)
        if art_img:
            bg = _fit_cover(art_img, w, h)
            img.paste(bg, (0, 0))
            tint = _dominant_dark_color(bg)
        else:
            tint = (0, 0, 0)
        overlay = _bottom_gradient(w, gradient_h, tint)
        img.paste(overlay, (0, h - gradient_h), overlay)

        text_y = h - gradient_h + 14
        if title:
            draw.text((10, text_y), title[:32], fill=(255, 255, 255), font=fonts["title"]); text_y += 24
        if artist:
            draw.text((10, text_y), artist[:34], fill=(225, 225, 225), font=fonts["body"])
        _draw_progress(draw, fonts, 8, h - 14, w - 16, pos, dur)

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


# ---------------------------------------------------------------------------
# HDMI-CEC remote control — only used when display=hdmi.
# ---------------------------------------------------------------------------
#
# Flow: TV sends CEC USER_CONTROL_PRESSED over the HDMI cable → cec-ctl
# decodes it → we translate the button to a DACP command → HTTP back to
# the phone that's streaming (the `acre`/`daid` metadata items let us
# do this without shairport-sync compile-time D-Bus support).
#
# DACP host:port is learned via mDNS (`_dacp._tcp` service named
# `iTunes_Ctrl_<daid>`).

CEC_TO_DACP = {
    "Play":          "play",
    "Pause":         "pause",
    "Stop":          "stop",
    "Play/Pause":    "playpause",
    "Fast forward":  "beginff",
    "Rewind":        "beginrew",
    "Skip forward":  "nextitem",
    "Skip backward": "previtem",
    "Next":          "nextitem",
    "Previous":      "previtem",
    "Volume up":     "volumeup",
    "Volume down":   "volumedown",
    "Mute":          "mutetoggle",
}

_UI_COMMAND_RE = re.compile(r"ui-command:\s*([^(]+?)\s*\(")


class CECListener:
    def __init__(self, state):
        self.state = state

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        # Claim a logical address so the TV sees us as a playback device.
        try:
            subprocess.run(["cec-ctl", "--playback"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=5)
        except FileNotFoundError:
            print("CEC: cec-ctl not installed, disabling", file=sys.stderr)
            return
        except Exception as e:
            print(f"CEC: cec-ctl --playback failed: {e}", file=sys.stderr)

        try:
            proc = subprocess.Popen(
                ["cec-ctl", "--monitor-all"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, bufsize=1,
            )
        except Exception as e:
            print(f"CEC: monitor failed to start: {e}", file=sys.stderr)
            return

        print("CEC: listening for remote buttons", file=sys.stderr)
        for line in proc.stdout:
            m = _UI_COMMAND_RE.search(line)
            if not m:
                continue
            button = m.group(1).strip()
            dacp_cmd = CEC_TO_DACP.get(button)
            if not dacp_cmd:
                continue
            self._send_dacp(button, dacp_cmd)

    def _send_dacp(self, button, command):
        acre = self.state.get("acre")
        daid = self.state.get("daid")
        if not acre or not daid:
            print(f"CEC: {button} ignored — no active AirPlay session",
                  file=sys.stderr)
            return

        addr, port = self._resolve_dacp(daid)
        if not addr:
            print(f"CEC: {button} — couldn't resolve iTunes_Ctrl_{daid}",
                  file=sys.stderr)
            return

        url = f"http://{addr}:{port}/ctrl-int/1/{command}"
        req = urllib.request.Request(url, headers={"Active-Remote": acre})
        try:
            urllib.request.urlopen(req, timeout=3).close()
            print(f"CEC: {button} -> {command}", file=sys.stderr)
        except Exception as e:
            print(f"CEC: {command} failed: {e}", file=sys.stderr)

    @staticmethod
    def _resolve_dacp(daid):
        try:
            result = subprocess.run(
                ["avahi-browse", "-rpt", "_dacp._tcp"],
                capture_output=True, text=True, timeout=3,
            )
        except Exception:
            return None, None
        target = f"iTunes_Ctrl_{daid}"
        for row in result.stdout.splitlines():
            # Resolved rows start with '=' and are semicolon-separated:
            # =;iface;proto;name;type;domain;host;addr;port;txt
            if not row.startswith("="):
                continue
            parts = row.split(";")
            if len(parts) >= 9 and parts[3] == target:
                return parts[7], parts[8]
        return None, None


class BlankController:
    """Blanks the display after N seconds of no metadata activity,
    unblanks on the first new event. Watchdog runs in a daemon thread
    so the main loop can stay blocked on the shairport pipe read."""

    def __init__(self, disp, timeout_sec):
        self.disp = disp
        self.timeout = int(timeout_sec or 0)
        self.last_activity = time.time()
        self.blanked = False
        self._lock = threading.Lock()

    def mark_activity(self):
        with self._lock:
            self.last_activity = time.time()
            if self.blanked:
                try:
                    self.disp.unblank()
                except Exception as e:
                    print(f"unblank failed: {e}", file=sys.stderr)
                self.blanked = False

    def _check(self):
        with self._lock:
            if self.blanked or self.timeout <= 0:
                return
            if time.time() - self.last_activity >= self.timeout:
                try:
                    self.disp.blank()
                    self.blanked = True
                    print(f"display: blanked after {self.timeout}s idle", file=sys.stderr)
                except Exception as e:
                    print(f"blank failed: {e}", file=sys.stderr)

    def start_watchdog(self):
        if self.timeout <= 0:
            return
        def loop():
            while True:
                time.sleep(min(5, max(1, self.timeout / 6)))
                self._check()
        threading.Thread(target=loop, daemon=True).start()


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

    blanker = BlankController(disp, os.environ.get("ALPHASOUND_DISPLAY_TIMEOUT", "0"))
    blanker.start_watchdog()

    state = {}
    if device_name == "hdmi":
        CECListener(state).start()

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
        blanker.mark_activity()
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
        elif code == "acre":
            # Active-Remote auth token for DACP calls (HDMI-CEC remote).
            state["acre"] = payload.decode("ascii", errors="replace")
        elif code == "daid":
            # DACP ID — part of the mDNS service name we look up.
            state["daid"] = payload.decode("ascii", errors="replace")
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
