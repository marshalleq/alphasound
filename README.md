# Alphasound

A ready-to-burn Raspberry Pi image that turns your Pi into an AirPlay receiver for your car stereo. Based on [shairport-sync](https://github.com/mikebrady/shairport-sync)'s [car install guide](https://github.com/mikebrady/shairport-sync/blob/master/CAR%20INSTALL.md), fully automated with a read-only root filesystem for robustness.

## What it does

- Creates a WiFi access point with **no internet gateway** — your phone connects to it for AirPlay while cellular handles all data traffic (Spotify, Apple Music, YouTube, etc.)
- Runs [shairport-sync](https://github.com/mikebrady/shairport-sync) as an AirPlay 2 receiver, outputting audio to a USB/HAT DAC connected to your car's AUX input
- Boots to a **read-only filesystem** so it survives hard power cuts when you turn off the ignition — no graceful shutdown needed
- Starts up in ~35 seconds on a Pi Zero 2 W

## Hardware you need

- **Raspberry Pi Zero 2 W** (recommended) or Pi 3/4/5
- **DAC** — the Pi's built-in 3.5mm jack is noisy. Recommended options:
  - [Pimoroni pHAT DAC](https://shop.pimoroni.com/products/phat-dac) (HAT, sits on top of the Pi)
  - Any USB DAC dongle
- **Micro SD card** (8GB+)
- **USB power** from a switched 12V line (turns on/off with ignition) via a 12V-to-USB adapter
- **3.5mm cable** from DAC to your car's AUX input

## Quick start

1. Download the latest image from [Releases](../../releases)
2. Flash it to an SD card using [Raspberry Pi Imager](https://www.raspberrypi.com/software/) or `dd`
3. Insert into your Pi, wire it up, start the car
4. On your iPhone/iPad, connect to the WiFi network (default: `Alphasound`)
5. Select `Alphasound` as an AirPlay output in any audio app

## Configuration

Before flashing, you can mount the boot partition and edit `alphasound.txt` to customise:

```ini
# WiFi network name (SSID) your phone connects to
ALPHASOUND_SSID=Alphasound

# AirPlay device name shown on your phone
ALPHASOUND_NAME=Alphasound

# WiFi channel (1-11)
ALPHASOUND_CHANNEL=11

# Country code for WiFi regulatory domain
ALPHASOUND_COUNTRY=NZ

# ALSA output device — "hw:0" for HAT DAC, "hw:1" for USB DAC
# Use "default" if unsure
ALPHASOUND_OUTPUT_DEVICE=hw:0

# DAC overlay for config.txt (leave empty for USB DACs)
# Common values: hifiberry-dac (Pimoroni pHAT), hifiberry-dacplus
ALPHASOUND_DAC_OVERLAY=hifiberry-dac

# Max volume in dB (reduce if DAC overloads car input)
ALPHASOUND_VOLUME_MAX_DB=-3.00
```

## Updating your phone's data routing

When your phone connects to the Alphasound WiFi network, it should automatically keep using cellular for internet because the network has no gateway. On iOS this works out of the box. If you have issues:

- Make sure "Low Data Mode" is **off** for your cellular connection
- The Alphasound network deliberately has no DNS and no gateway configured

## Building locally

Requires Docker:

```bash
./build.sh
```

The image will be output to `deploy/`.

## How automated builds work

GitHub Actions builds a fresh image:
- On every push to `main`
- Weekly (to pick up shairport-sync and Raspberry Pi OS updates)

Images are published as GitHub Releases.

## Development mode

If you need to SSH in and make changes, mount the boot partition on another computer and edit `alphasound.txt`:

```ini
ALPHASOUND_MODE=DEV
```

In DEV mode, the Pi will connect to a regular WiFi network instead of creating an access point. Configure the network credentials in `alphasound.txt`:

```ini
ALPHASOUND_DEV_WIFI_SSID=YourHomeWifi
ALPHASOUND_DEV_WIFI_PASSWORD=YourPassword
```

SSH in with `ssh alphasound@alphasound.local` (default password: `alphasound`).

Set `ALPHASOUND_MODE=RUN` and reboot to return to car mode.

## Credits

- [shairport-sync](https://github.com/mikebrady/shairport-sync) by Mike Brady — the AirPlay engine
- [NQPTP](https://github.com/mikebrady/nqptp) — PTP clock for AirPlay 2
- [pi-gen](https://github.com/RPi-Distro/pi-gen) — official Raspberry Pi OS image builder
- [pi-gen-action](https://github.com/usimd/pi-gen-action) — GitHub Action for pi-gen

## License

AGPL-3.0
