# Alphasound

A tiny Raspberry Pi image that turns your Pi into an AirPlay and Bluetooth audio receiver for your car stereo. Based on [Alpine Linux](https://alpinelinux.org/), [shairport-sync](https://github.com/mikebrady/shairport-sync), and [BlueALSA](https://github.com/Arkq/bluez-alsa).

## What it does

- Creates a **WPA2-protected** WiFi access point with **no internet gateway** — your phone connects to it for AirPlay while cellular handles all data traffic
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
ALPHASOUND_PASSPHRASE=alphasound
ALPHASOUND_NAME=Alphasound
ALPHASOUND_CHANNEL=11
ALPHASOUND_COUNTRY=NZ
ALPHASOUND_OUTPUT_DEVICE=hw:0
ALPHASOUND_VOLUME_MAX_DB=-3.00
ALPHASOUND_BLUETOOTH=yes
ALPHASOUND_ROOT_PASSWORD=alphasound
```

**Change `ALPHASOUND_PASSPHRASE` and `ALPHASOUND_ROOT_PASSWORD` before driving** — both default to well-known values.

For DAC setup, edit `usercfg.txt`:

```ini
dtoverlay=hifiberry-dac
```

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

## On-device updates

The device runs a minimal web UI on `http://10.0.10.1` (basic auth: `root` / `ALPHASOUND_ROOT_PASSWORD`). Once installed in a hard-to-reach spot, you can update without pulling the SD card:

1. Connect a phone or laptop to the `Alphasound` WiFi
2. Download the new `alphasound.apkovl.tar.gz` from [Releases](../../releases)
3. Open `http://10.0.10.1/`, sign in
4. Pick the file, hit **Upload & reboot**
5. Wait ~30 seconds, reconnect to the AP

The device keeps the previous apkovl as `.bak`. If a new apkovl fails to boot to the "ready" state 3 times in a row, an early-boot service automatically restores the backup. The web UI also exposes manual **Restart** and **Roll back to backup** buttons.

### Serial console

The image enables `enable_uart=1` so a USB-TTL adapter on GPIO 14 (TX) / 15 (RX) at 115200 baud gives you a login prompt without a monitor or keyboard. Bluetooth keeps the PL011 UART, so A2DP is unaffected.

## Building

```bash
./build.sh
```

Requires Linux (loop devices + `mkfs.vfat`), plus: Docker, curl, parted, dosfstools, xz-utils. Runs sudo for `losetup`/`mount`. Output lands in `deploy/alphasound.img.xz`.

`build.sh` is the single source of truth for image builds. The GitHub Actions release workflow (`.github/workflows/build.yml`) just installs the dependencies and runs `./build.sh` — so what you build locally matches what gets released. Don't add inline build logic to the workflow; put it in `build.sh`.

## How it works

Alpine Linux runs in "diskless" mode — the entire OS loads into RAM at boot. The build script bakes a complete rootfs (Alpine base + our packages + configs) into a single apkovl tarball, which is extracted to the in-memory rootfs at boot. The SD card boot partition only stores: the kernel + initramfs + modloop, the apkovl, and a small `persist/` directory for SSH host keys, Bluetooth pairings, and user config (`alphasound.txt`, `authorized_keys`). It's read on every boot and only written when you update or pair a new BT device.

## Credits

- [shairport-sync](https://github.com/mikebrady/shairport-sync) by Mike Brady
- [BlueALSA](https://github.com/Arkq/bluez-alsa) for Bluetooth A2DP audio
- [Alpine Linux](https://alpinelinux.org/)

## License

AGPL-3.0
