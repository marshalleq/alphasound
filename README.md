# Alphasound

A tiny, drop-in Raspberry Pi image that turns any Pi into a wireless audio receiver — AirPlay + Bluetooth, with or without a screen, on any audio hardware you've got. Built on [Alpine Linux](https://alpinelinux.org/), [shairport-sync](https://github.com/mikebrady/shairport-sync), and [BlueALSA](https://github.com/Arkq/bluez-alsa).

**Two image variants, same config surface** — pick the one that matches how you'll install it:

### `alphasound-home.img.xz` — head-unit mode (home / desk)

Plug it into your HDMI TV or monitor, pick a DAC HAT (or don't — USB DAC / HDMI audio / onboard are all fine), and you get a full-screen now-playing UI with album art, artist, and track progress. Use it like a cheap Ropieee replacement on a monitor next to your stereo. **HDMI-CEC is active whenever `display=hdmi`** — press Play / Pause / Skip / Volume on the TV remote and it's relayed back to the streaming phone via DACP, so the person streaming gets actual Apple-remote behaviour without touching their device. Ships with the display stack (Python + PIL + libgpiod), HDMI-CEC, Roon Bridge prerequisites, the PWM brightness control, and the boot splash.

### `alphasound-car.img.xz` — behind-the-dash mode (car / invisible install)

No screen, no buttons, no monitor — just a DAC HAT wired straight to your car's speakers or line-in, boot time minimised, whole device hidden in the console. Especially good for **old cars with factory stereos you don't want to cut up**: the car keeps its original face and switches, but a HiFiBerry Amp2 / Pirate Audio Speakers / similar amplifier HAT *drives the speakers directly* and your phone streams AirPlay over the device's own WiFi. Your factory radio becomes optional — mechanical backup only. The `car` image strips out the display stack, HDMI-CEC, Roon, and the boot splash so the apkovl extracts faster and the Pi gets to the "ready to AirPlay" state as quickly as possible.

### Which one do I want?

| You want… | Pick |
|---|---|
| Album-art display on HDMI / Pirate Audio / Adafruit PiTFT | **home** |
| TV remote controlling the phone via HDMI-CEC | **home** |
| Roon Bridge endpoint | **home** |
| Fastest possible cold-boot on a Pi Zero 2 W, speakers only | **car** |
| Behind-the-dash retrofit with factory stereo bypassed | **car** |
| Desk / shelf install with DAC + amp but no screen | either works — `home` if you might plug a monitor in later, `car` for faster boot |

The DAC, (home-only) display, and output routing are all **independent toggles** — so "DAC HAT with no screen" and "no HAT, just HDMI output" and "everything at once" are all first-class combinations on the `home` image.

## Highlights

- **AirPlay + Bluetooth A2DP** in one device — Apple, Android, Linux, Windows clients all work. *Both variants.*
- **Audio HAT dropdown** in the web UI — pick HiFiBerry / Pirate Audio / IQaudIO / Allo / Audio Injector / Google AIY and the overlay is written to `usercfg.txt` for you. Independent of the display choice. *Both variants.*
- **Amplifier HATs**: HiFiBerry Amp2 / Pirate Audio Stereo Speakers and similar HATs drive passive speakers directly — perfect for retrofitting an old car where you want to bypass the factory head unit entirely. *Both variants.*
- **Optional display** *(home variant only)* — Pimoroni Pirate Audio (240×240 ST7789), Adafruit Mini PiTFT, or any HDMI monitor. Full-bleed album art with a dominant-colour gradient overlay, title / artist, live progress bar. PWM-dimmable backlight on Pirate Audio (slider in the web UI).
- **HDMI-CEC remote control** *(home variant only)* — TV remote relays to the streaming phone via DACP
- **Optional Roon Bridge endpoint** *(home variant only)* — one-tap install from the web UI when in client mode
- **Two network modes**, switchable from the web UI:
  - **Standalone** — broadcasts its own WPA2 WiFi (perfect for a car: phone connects, cellular still handles data)
  - **Client** — joins your home WiFi (useful at home for pulling updates, accessing SSH)
- **Web management UI** at `http://10.0.10.1` — change network mode, flip feature toggles, adjust brightness, push updates, restart, roll back
- **In-place updates** with auto-rollback — never pull the SD card again. Apkovls are version-checked against the running modloop so you can't install a binary-incompatible build
- **Toggle features off for faster boot** — disable Bluetooth, SSH, Roon, or the display from the web UI. Each unused subsystem off saves a few seconds; boot timer on the banner + web UI shows exactly what it buys you
- **Runs entirely from RAM** (Alpine diskless) — survives hard power cuts (ignition off, breaker trip, kid yanks the plug). The SD card is read-only at runtime
- Boots in seconds on a Pi Zero 2 W — noticeably faster on the `car` variant (smaller apkovl → faster tmpfs extract at boot)
- ~100 MB compressed image (`home`), smaller again for `car`

## Audio hardware

Pick your HAT in the web UI (Features → Audio HAT) — no more hand-editing `usercfg.txt`. The dropdown covers:

| Hardware | Overlay | Notes |
|---|---|---|
| **Pimoroni Pirate Audio** (Headphone Amp / Line-Out / Stereo Speakers) | `hifiberry-dac` | DAC + 240×240 LCD + 4 buttons. The Speakers variant drives 3W passive speakers directly. Pick *Pimoroni Pirate Audio* in the Display dropdown to also enable the screen. |
| **HiFiBerry DAC family** (DAC, DAC+, DAC+ Pro, DAC+ Zero, DAC2 HD, MiniAmp, Beocreate) | `hifiberry-dac` / `hifiberry-dacplus` / `hifiberry-dacplushd` | Studio-grade line output |
| **HiFiBerry Amp+ / Amp2** | `hifiberry-amp` | **Integrated class-D amplifier** — wire passive speakers straight in. Replaces the head unit entirely in a car retrofit. |
| **HiFiBerry Digi+** | `hifiberry-digi` | S/PDIF optical / coax out for digital home stereos |
| **IQaudIO Pi-DAC, DAC+ family** | `iqaudio-dacplus` | |
| **IQaudIO Digi** | `iqaudio-digi-wm8804-audio` | |
| **Allo Boss DAC** | `allo-boss-dac-pcm512x-audio` | |
| **Audio Injector Stereo**, **Google AIY Voice HAT** | `audioinjector-wm8731-audio`, `googlevoicehat-soundcard` | |
| **Any USB DAC** | *none* | No config — auto-detected, auto-preferred over HDMI |
| **HDMI audio** | *none* | Auto-fallback when nothing else is plugged in; force with the Audio output → *Force HDMI* option |

## Hardware (otherwise)

- **Raspberry Pi Zero 2 W** (recommended) or any Pi 3/4/5
- **Micro SD card** (1 GB+)
- **USB power** — for car installs, a switched 12V-to-USB adapter on a switched ignition line
- Cable to your stereo: 3.5mm / RCA / S/PDIF depending on your DAC

## Quick start

1. Download the right variant from [Releases](../../releases) — `alphasound-home.img.xz` for a display/CEC/Roon-capable install, `alphasound-car.img.xz` for the fastest-booting speakers-only install. If in doubt, start with `home`.
2. Flash to an SD card with [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (it handles `.xz` directly)
3. Edit `alphasound.txt` on the SD card to set your WiFi name, country code, etc.
4. Insert into Pi, power on (car ignition / desk USB)
5. Connect to the `Alphasound` WiFi on your phone
6. Open `http://10.0.10.1` → Features → pick your **Audio HAT** (if any), and on `home` your **Display** (if any) → **Apply & reboot**
7. Select `Alphasound` as an AirPlay output (Apple) or Bluetooth audio device (Android)

## Configuration

Most users do everything through the web UI (`http://10.0.10.1` on the device's own WiFi, or the assigned IP in client mode). If you want to pre-seed settings before first boot, edit `alphasound.txt` on the SD card:

```ini
ALPHASOUND_SSID=Alphasound
ALPHASOUND_PASSPHRASE=alphasound
ALPHASOUND_NAME=Alphasound
ALPHASOUND_CHANNEL=11
ALPHASOUND_COUNTRY=NZ
ALPHASOUND_DAC=none             # audio HAT overlay — see above table
ALPHASOUND_DISPLAY=none         # none | hdmi | pirate-audio | adafruit-*
ALPHASOUND_OUTPUT_DEVICE=auto   # auto | hdmi | hw:...
ALPHASOUND_DISPLAY_BRIGHTNESS=50  # 0-100, Pirate Audio backlight PWM
ALPHASOUND_VOLUME_MAX_DB=-3.00
ALPHASOUND_BLUETOOTH=yes
ALPHASOUND_ROOT_PASSWORD=alphasound
```

**Change `ALPHASOUND_PASSPHRASE` and `ALPHASOUND_ROOT_PASSWORD` before driving** — both default to well-known values, and the device exposes sshd on its own WiFi AP.

The web UI Features section owns `ALPHASOUND_DAC`, `ALPHASOUND_DISPLAY`, `ALPHASOUND_OUTPUT_DEVICE`, `ALPHASOUND_DISPLAY_BRIGHTNESS`, plus the Bluetooth / SSH / Roon toggles — Apply & reboot regenerates `usercfg.txt`'s alphasound-managed block with the correct dtoverlays. Manual edits above that block are preserved.

### Roon Bridge endpoint *(home variant only)*

If you have a [Roon](https://roonlabs.com/) subscription and a Roon Core running on your home network, Alphasound can act as a Roon Bridge endpoint:

1. Switch to client mode and join your home WiFi
2. Open the web UI → "Roon Bridge" → **Install Roon Bridge**. The device downloads ~50 MB from Roon's CDN and persists it to the SD card
3. Tick the **Roon Bridge endpoint** checkbox under Features → **Apply & reboot**
4. Open Roon on your phone/computer; the Alphasound endpoint should appear under Settings → Audio

Notes:
- Roon Bridge is closed-source, owned by Roon Labs. We don't bundle it; we just facilitate the download. You're agreeing to Roon's terms when you install it.
- Roon and AirPlay both grab the audio device exclusively, so only one will play at a time. If you only use Roon, disable AirPlay-related stuff in alphasound.txt to save boot time.
- Roon Bridge needs internet for licensing checks and to find your Roon Core, so it only runs when the device is in client mode.

### Display *(home variant only)*

The web UI's Features section has a Display dropdown. Pick one:

- **none** — display service doesn't run (saves boot time)
- **hdmi** — render to whatever monitor's plugged into the Pi's HDMI port. Takes over the console while running. Switch back to `none` from the web UI to get the console back on next boot.
- **pirate-audio**, **adafruit-1.3-tft** (240×240 ST7789), **adafruit-mini-pitft** (240×135 landscape) — small SPI displays, no monitor needed

What gets rendered (all backends):

- Album art (when the source provides it)
- Track title + artist + album
- Live progress bar with elapsed / total time
- Layout adapts to the screen — big-screen layout on HDMI (art on left, info large on right), compact on small SPI panels

Sources fed to the display today: AirPlay (via shairport-sync's metadata pipe). Bluetooth A2DP doesn't carry rich metadata so it doesn't show track info, just plays. Roon metadata isn't yet wired in (would need a Roon API extension — bigger piece of work).

## Development mode

Set `ALPHASOUND_MODE=DEV` in `alphasound.txt` with your home WiFi credentials so the Pi joins your network instead of broadcasting its own AP.

### SSH access

`sshd` runs in both `RUN` and `DEV` modes. Two ways to log in as root:

- **Password**: set `ALPHASOUND_ROOT_PASSWORD` in `alphasound.txt` (defaults to `alphasound`). **Change this** — the device exposes sshd on its open WiFi AP, and a known default password means anyone in range can log in.
- **Key**: drop a file named `authorized_keys` (your public key) onto the SD card's boot partition next to `alphasound.txt`. Set `ALPHASOUND_ROOT_PASSWORD=` (empty) to lock the password and force key-only auth.

Connect with:

- `DEV` mode: `ssh root@alphasound.local` (mDNS) or use the IP from your router.
- `RUN` mode: connect to the `Alphasound` AP and `ssh root@10.0.10.1`.

Host keys are persisted to the SD card on first boot, so subsequent boots reuse them — no "host key changed" warnings unless you re-flash.

## Web UI

The device runs a minimal web UI on `http://10.0.10.1` or `http://alphasound.local`. Sign in with the value of `ALPHASOUND_ROOT_PASSWORD` from `alphasound.txt`. Browser keychains save the credentials so subsequent visits are one tap. Once installed in a hard-to-reach spot, this is your primary admin interface:

- **Status** — version, uptime, IP, per-service health (auto-refreshes every 5s)
- **Network mode** — switch between Standalone (AP) and Client (joins existing WiFi)
- **Update from GitHub** — checks the Releases page and pulls the latest apkovl directly (client mode only — needs internet)
- **Update from file** — upload an apkovl downloaded to your phone/laptop
- **Manual actions** — Restart, Roll back to backup

### Mode toggle

- **Standalone (AP)** — the default. Broadcasts the `Alphasound` WPA2 network. Use this in the car.
- **Client** — joins a WiFi network you specify. Useful at home (the device can pull updates directly), for testing, or for fixed installs where there's already a network.

If client mode credentials are wrong, an early-boot check times out after 30s without a DHCP lease and falls back to AP for that boot — so a typo doesn't make the device unreachable.

### Updates

Two paths:

1. **Pull from GitHub** (client mode): hit "Check for updates", then "Download & install" if there's a newer release.
2. **Upload manually** (any mode): download `alphasound-home.apkovl.tar.gz` or `alphasound-car.apkovl.tar.gz` from [Releases](../../releases) (match the variant you flashed) onto your phone/laptop, then upload via the web UI.

Either path keeps the previous apkovl as `.bak`. If a new apkovl fails to boot to the "ready" state 3 times in a row, an early-boot service automatically restores the backup.

### Serial console

The image enables `enable_uart=1` so a USB-TTL adapter on GPIO 14 (TX) / 15 (RX) at 115200 baud gives you a login prompt without a monitor or keyboard. Bluetooth keeps the PL011 UART, so A2DP is unaffected.

## Building

```bash
./build.sh
```

Requires Linux (loop devices + `mkfs.vfat`), plus: Docker, curl, parted, dosfstools, xz-utils. Runs sudo for `losetup`/`mount`. Pass `VARIANT=home` (default, full feature set) or `VARIANT=car` (stripped for fastest boot — no display stack, no Python, no Roon). Output lands in `deploy/alphasound-${VARIANT}.img.xz`. CI runs both in sequence and publishes both on every release.

`build.sh` is the single source of truth for image builds. The GitHub Actions release workflow (`.github/workflows/build.yml`) just installs the dependencies and runs `./build.sh` — so what you build locally matches what gets released. Don't add inline build logic to the workflow; put it in `build.sh`.

## How it works

Alpine Linux runs in "diskless" mode — the entire OS loads into RAM at boot. The build script bakes a complete rootfs (Alpine base + our packages + configs) into a single apkovl tarball, which is extracted to the in-memory rootfs at boot. The SD card boot partition only stores: the kernel + initramfs + modloop, the apkovl, and a small `persist/` directory for SSH host keys, Bluetooth pairings, and user config (`alphasound.txt`, `authorized_keys`). It's read on every boot and only written when you update or pair a new BT device.

## Credits

- [shairport-sync](https://github.com/mikebrady/shairport-sync) by Mike Brady
- [BlueALSA](https://github.com/Arkq/bluez-alsa) for Bluetooth A2DP audio
- [Alpine Linux](https://alpinelinux.org/)

## License

AGPL-3.0
