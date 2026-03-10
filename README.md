# Alphasound

A tiny Raspberry Pi image that turns your Pi into an AirPlay and Bluetooth audio receiver for your car stereo. Based on [Alpine Linux](https://alpinelinux.org/), [shairport-sync](https://github.com/mikebrady/shairport-sync), and [BlueALSA](https://github.com/Arkq/bluez-alsa).

## What it does

- Creates a WiFi access point with **no internet gateway** — your phone connects to it for AirPlay while cellular handles all data traffic
- Runs [shairport-sync](https://github.com/mikebrady/shairport-sync) as an AirPlay receiver, outputting audio to a DAC connected to your car's AUX input
- **Bluetooth A2DP** receiver for Android and other non-Apple devices — auto-pairs with no PIN
- **Runs entirely from RAM** (Alpine diskless mode) — the SD card is never written to, so it survives hard power cuts when you turn off the ignition
- Boots in seconds on a Pi Zero 2 W
- Image size ~100MB compressed

## Hardware

- **Raspberry Pi Zero 2 W** (recommended) or Pi 3/4/5
- **DAC** — the Pi's built-in 3.5mm jack is noisy. Use a HAT DAC (Pimoroni pHAT DAC) or USB DAC
- **Micro SD card** (1GB+)
- **USB power** from a switched 12V line via a 12V-to-USB adapter
- **3.5mm cable** from DAC to car AUX input

## Quick start

1. Download the latest image from [Releases](../../releases)
2. Flash to an SD card with [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
3. Edit `alphasound.txt` on the SD card to set your WiFi name, country code, etc.
4. If using a HAT DAC, uncomment the overlay line in `usercfg.txt`
5. Insert into Pi, start the car
6. Connect to the `Alphasound` WiFi on your phone
7. Select `Alphasound` as an AirPlay output (Apple) or Bluetooth audio device (Android)

## Configuration

Edit `alphasound.txt` on the SD card:

```ini
ALPHASOUND_SSID=Alphasound
ALPHASOUND_NAME=Alphasound
ALPHASOUND_CHANNEL=11
ALPHASOUND_COUNTRY=NZ
ALPHASOUND_OUTPUT_DEVICE=hw:0
ALPHASOUND_VOLUME_MAX_DB=-3.00
ALPHASOUND_BLUETOOTH=yes
```

For DAC setup, edit `usercfg.txt`:

```ini
dtoverlay=hifiberry-dac
```

## Development mode

Set `ALPHASOUND_MODE=DEV` in `alphasound.txt` with your home WiFi credentials to SSH in for debugging.

## Building

```bash
./build.sh
```

Requires: Docker, curl, losetup, parted, xz

## How it works

Alpine Linux runs in "diskless" mode — the entire OS loads into RAM at boot. An apkovl overlay applies our configuration, and packages are installed from a local cache on the SD card (no internet needed). The SD card is only read at boot, never written to, making it inherently safe for hard power cuts.

## Credits

- [shairport-sync](https://github.com/mikebrady/shairport-sync) by Mike Brady
- [BlueALSA](https://github.com/Arkq/bluez-alsa) for Bluetooth A2DP audio
- [Alpine Linux](https://alpinelinux.org/)

## License

AGPL-3.0
