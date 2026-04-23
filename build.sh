#!/bin/bash
set -euo pipefail

# Alphasound image builder — single source of truth for both local builds
# and the GitHub Actions release pipeline (.github/workflows/build.yml just
# installs deps and runs this script).
#
# Approach: build a complete Alpine rootfs in a chroot with all our
# packages installed, then ship that chroot as the apkovl. The Pi extracts
# the apkovl on top of the modloop at boot — every binary is already in
# place, so no `apk add` runs at boot. This sidesteps the offline-install
# fragility we were fighting (signed APKINDEX, dep resolution from a
# partial cache, etc.) by doing the install at build time when we have
# internet.
#
# Requires Linux (loop devices, mkfs.vfat) plus: docker, curl, parted,
# dosfstools, xz-utils. Local runs need sudo for losetup/mount.

ALPINE_VERSION="3.21"
ALPINE_RELEASE="3.21.6"
ALPINE_ARCH="aarch64"
ALPINE_TARBALL="alpine-rpi-${ALPINE_RELEASE}-${ALPINE_ARCH}.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ALPINE_TARBALL}"

PACKAGES="alpine-base shairport-sync hostapd dnsmasq avahi avahi-tools openssh \
          bluez bluez-alsa bluez-alsa-utils bluez-alsa-openrc alsa-utils \
          wpa_supplicant jq \
          lighttpd \
          python3 py3-pillow py3-numpy py3-libgpiod font-noto \
          v4l-utils \
          gcompat bzip2"

# Runlevels: sysinit + shutdown are critical. sysinit mounts devfs and the
# modloop squashfs (which provides /lib/modules — without this the WiFi
# driver never loads). shutdown lets openrc tear down cleanly. Our apkovl
# replaces /etc/runlevels wholesale, so if we don't list these here, they
# won't be enabled.
SYSINIT_SVCS="devfs dmesg hwdrivers mdev modloop alphasound-clock"
# hwclock excluded: Pi has no battery-backed RTC, so the service just
# logs errors trying to talk to /dev/rtc on every boot. We get our time
# from NTP once we're online (client mode) or from file-touch mtimes.
BOOT_SVCS="bootmisc hostname modules sysctl syslog alphasound-rollback alphasound-persist alphasound-features alphasound-splash"
DEFAULT_SVCS="networking shairport-sync avahi-daemon bluetooth bluealsa local sshd lighttpd"
SHUTDOWN_SVCS="killprocs mount-ro savecache"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/.work"
MOUNT_DIR="${WORK_DIR}/mnt"
CHROOT_DIR="${WORK_DIR}/chroot"
APKOVL_FILE="${WORK_DIR}/alphasound.apkovl.tar.gz"
OUTPUT_DIR="${SCRIPT_DIR}/deploy"
OUTPUT_IMAGE="${OUTPUT_DIR}/alphasound.img"

# Version stamp embedded in the apkovl so the web UI can show what's
# running. Prefer git describe if available; otherwise UTC date.
VERSION="${ALPHASOUND_VERSION:-$(git -C "${SCRIPT_DIR}" describe --tags --always --dirty 2>/dev/null || date -u +%Y%m%d-%H%M%S)}"
echo "Version: ${VERSION}"

SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

LOOP=""
cleanup() {
    echo "Cleaning up..."
    $SUDO umount "${MOUNT_DIR}" 2>/dev/null || true
    [ -n "${LOOP}" ] && $SUDO losetup -d "${LOOP}" 2>/dev/null || true
    $SUDO rm -rf "${CHROOT_DIR}" "${APKOVL_FILE}" "${WORK_DIR}/alpine-extract"
}
trap cleanup EXIT

echo "=== Alphasound Image Builder ==="
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

# --- Download Alpine RPi tarball ---
if [ ! -f "${WORK_DIR}/${ALPINE_TARBALL}" ]; then
    echo "Downloading Alpine Linux ${ALPINE_RELEASE}..."
    curl -L -o "${WORK_DIR}/${ALPINE_TARBALL}" "${ALPINE_URL}"
fi

# --- Build the chroot that becomes the apkovl ---
echo "Building chroot with packages installed..."
$SUDO rm -rf "${CHROOT_DIR}"
mkdir -p "${CHROOT_DIR}"
docker run --rm \
    -v "${CHROOT_DIR}:/chroot" \
    -v "${SCRIPT_DIR}/overlay:/overlay:ro" \
    -v "${SCRIPT_DIR}/splash:/splash:ro" \
    "alpine:${ALPINE_VERSION}" \
    sh -ec "
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main' > /etc/apk/repositories
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community' >> /etc/apk/repositories
        apk update
        # Host-container tooling: C compiler (+ Linux UAPI headers for
        # spidev.h) for the boot splash, plus Python+PIL+Noto to
        # pre-render its splash image. These don't land in the chroot
        # — they stay in the ephemeral build image.
        apk add --no-cache gcc musl-dev linux-headers python3 py3-pillow font-noto

        # apk --root reads /chroot/etc/apk/{repositories,keys}, NOT the
        # host's. So we initialise those in the chroot BEFORE installing.
        mkdir -p /chroot/etc/apk/keys
        cp /etc/apk/keys/* /chroot/etc/apk/keys/
        cat > /chroot/etc/apk/repositories << REPOS
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
REPOS

        # Install Alpine base + our packages into the chroot. The chroot
        # ends up with /usr/sbin/hostapd, /usr/sbin/sshd, /etc/init.d/*,
        # /var/lib/apk/installed populated, etc. — a complete rootfs.
        apk --root /chroot --initdb add --no-cache alpine-base ${PACKAGES}

        # Apply our overlay (configs, init scripts, web UI) on top. Treat
        # the overlay/ dir as a rootfs overlay — overlay/etc/X lands at
        # /chroot/etc/X, overlay/var/www/X at /chroot/var/www/X, etc.
        # alphasound.txt is excluded because it's a user-editable file
        # that lives on the FAT32 boot partition, not in the rootfs.
        ( cd /overlay && tar --exclude=alphasound.txt -cf - . ) \
            | tar -C /chroot -xf -

        echo alphasound > /chroot/etc/hostname

        # Runlevel symlinks (relative to chroot's /etc/init.d, not /chroot/etc/init.d)
        mkdir -p /chroot/etc/runlevels/sysinit \
                 /chroot/etc/runlevels/boot \
                 /chroot/etc/runlevels/default \
                 /chroot/etc/runlevels/shutdown
        for svc in ${SYSINIT_SVCS}; do
            ln -sf /etc/init.d/\$svc /chroot/etc/runlevels/sysinit/\$svc
        done
        for svc in ${BOOT_SVCS}; do
            ln -sf /etc/init.d/\$svc /chroot/etc/runlevels/boot/\$svc
        done
        for svc in ${DEFAULT_SVCS}; do
            ln -sf /etc/init.d/\$svc /chroot/etc/runlevels/default/\$svc
        done
        for svc in ${SHUTDOWN_SVCS}; do
            ln -sf /etc/init.d/\$svc /chroot/etc/runlevels/shutdown/\$svc
        done

        # Sanity check: list which init scripts actually exist so we can
        # tell from CI logs whether any expected service is missing.
        echo '--- /chroot/etc/init.d/ ---'
        ls /chroot/etc/init.d/ | sort
        echo '--- runlevels ---'
        for lvl in sysinit boot default shutdown; do
            echo \"[\$lvl]\"
            ls /chroot/etc/runlevels/\$lvl
        done

        echo '--- post-install fixups ---'

        # local.d scripts and our init.d services must be executable
        chmod +x /chroot/etc/local.d/*.start
        chmod +x /chroot/etc/init.d/alphasound-*
        # /sbin/init: our pre-OpenRC wrapper, shipped via the overlay,
        # replaces Alpine's openrc-init symlink. Must be executable or
        # the kernel can't run it as PID 1.
        chmod +x /chroot/sbin/init

        # Web UI scripts must be executable for lighttpd's mod_cgi to run them
        chmod +x /chroot/var/www/cgi-bin/*

        # Ensure everything under /usr/local/bin/ is runnable (shipped
        # executables like alphasound-display.py and the checkpoint
        # helper called from init scripts).
        chmod +x /chroot/usr/local/bin/* 2>/dev/null || true

        # Boot splash: compile the C binary and pre-render its image.
        # Binary lands in /usr/local/bin, image bytes in /usr/share.
        echo '--- building alphasound-splash ---'
        mkdir -p /chroot/usr/local/bin /chroot/usr/share/alphasound-splash
        gcc -O2 -Wall -o /chroot/usr/local/bin/alphasound-splash /splash/alphasound-splash.c
        python3 /splash/gen-splash.py /chroot/usr/share/alphasound-splash/splash.raw

        # Enable OpenRC parallel service startup so the default runlevel
        # uses all four cores instead of one. Covers both the commented
        # default and the no-match case (append if missing).
        sed -i 's|^#*rc_parallel=.*|rc_parallel=\"YES\"|' /chroot/etc/rc.conf
        grep -q '^rc_parallel=' /chroot/etc/rc.conf \
            || echo 'rc_parallel=\"YES\"' >> /chroot/etc/rc.conf

        # Bake a shairport-sync.conf matching the defaults in the shipped
        # alphasound.txt. At boot, alphasound.start generates the same
        # file from config; if the user hasn't edited anything, the two
        # match byte-for-byte and we skip the ~1s shairport-sync restart.
        # Output device hw:0,1 is the bcm2835 HDMI sub-device, which is
        # what auto-detection resolves to on a Pi Zero 2 W with no DAC.
        cat > /chroot/etc/shairport-sync.conf << 'SHAIRPORT_EOF'
general =
{
    name = \"Alphasound\";
    ignore_volume_control = \"yes\";
    volume_max_db = -3.00;
};

alsa =
{
    output_device = \"hw:0,1\";
};

metadata =
{
    enabled = \"yes\";
    include_cover_art = \"yes\";
    pipe_name = \"/tmp/shairport-sync-metadata\";
    pipe_timeout = 5000;
};
SHAIRPORT_EOF

        # Version stamps. alphasound-version is for display in the web UI.
        # alphasound-alpine-version is checked at update time to refuse
        # apkovls built against an incompatible Alpine major version
        # (the modloop from the .img.xz must match — we can't ship new
        # kernel modules in an apkovl).
        # alphasound-build-time is consumed by alphasound-clock to seed
        # the system clock on a Pi with no RTC — we read its contents
        # rather than its mtime so we can safely backdate everything
        # else to epoch 0 without losing this reference.
        echo '${VERSION}' > /chroot/etc/alphasound-version
        echo '${ALPINE_RELEASE}' > /chroot/etc/alphasound-alpine-version
        date -u '+%Y-%m-%d %H:%M:%S' > /chroot/etc/alphasound-build-time

        # Back-date OpenRC's dependency-graph inputs to epoch 0
        # (1970-01-01 00:00:00). The Pi has no RTC, so system clock
        # starts at epoch 0 + seconds-since-kernel-up; anything with
        # mtime > current boot-time reads as 'file from the future'
        # and triggers 'clock skew detected' + deptree regen. Epoch 0
        # is the only value guaranteed to be <= every possible
        # boot-time clock reading.
        #
        # Broad-brush /etc and /lib because OpenRC checks at least
        # /etc/init.d/*.sh (functions.sh in particular), /etc/conf.d,
        # /etc/runlevels, /etc/rc.conf, and various scripts under
        # /lib/rc — and the exact set varies by OpenRC version, so
        # rather than chase specific paths we cover the whole tree.
        # Regular files first, then symlinks (need -h; find handles
        # them separately to avoid dereferencing).
        find /chroot/etc /chroot/lib -type f -exec touch    -t 197001010000 {} + 2>/dev/null || true
        find /chroot/etc /chroot/lib -type l -exec touch -h -t 197001010000 {} + 2>/dev/null || true

        # Drop apk's download cache and other cruft to keep the apkovl small
        rm -rf /chroot/var/cache/apk/* /chroot/tmp/* 2>/dev/null || true

        echo '--- chroot ready ---'
    "

# --- Pack the chroot as the apkovl ---
# Only include directories that genuinely need overriding. Crucially we
# do NOT include /lib, /sbin, /bin: shipping those clobbers modloop's
# carefully-set-up versions of openrc helper scripts and breaks /run
# initialisation, which kills boot entirely. Anything we need from those
# paths must be relocated into /usr/* in the docker step before tarring.
echo "Packing apkovl from chroot..."
$SUDO tar czf "${APKOVL_FILE}" \
    --exclude='var/cache' \
    --exclude='var/log' \
    --exclude='var/tmp' \
    -C "${CHROOT_DIR}" \
    etc usr var root
APKOVL_SIZE=$(du -sb "${APKOVL_FILE}" | cut -f1)
echo "apkovl size: $(du -sh "${APKOVL_FILE}" | cut -f1)"

# --- Calculate image size ---
echo "Calculating image size..."
mkdir -p "${WORK_DIR}/alpine-extract"
tar xzf "${WORK_DIR}/${ALPINE_TARBALL}" -C "${WORK_DIR}/alpine-extract"
TARBALL_SIZE=$(du -sb "${WORK_DIR}/alpine-extract" | cut -f1)
# 64 MB headroom for FAT32 overhead and breathing room.
IMG_SIZE_MB=$(( (TARBALL_SIZE + APKOVL_SIZE + 64*1024*1024) / 1024 / 1024 + 1 ))
echo "Image size: ${IMG_SIZE_MB}MB"

# --- Create blank image with FAT32 partition ---
echo "Creating image..."
dd if=/dev/zero of="${OUTPUT_IMAGE}" bs=1M count=${IMG_SIZE_MB} status=none
parted -s "${OUTPUT_IMAGE}" mklabel msdos
parted -s "${OUTPUT_IMAGE}" mkpart primary fat32 1MiB 100%
parted -s "${OUTPUT_IMAGE}" set 1 boot on
parted -s "${OUTPUT_IMAGE}" set 1 lba on

# --- Loop, format, mount ---
$SUDO losetup -fP "${OUTPUT_IMAGE}"
LOOP=$($SUDO losetup -j "${OUTPUT_IMAGE}" | cut -d: -f1 | head -1)
echo "Loop device: ${LOOP}"
$SUDO mkfs.vfat -F 32 "${LOOP}p1" >/dev/null
mkdir -p "${MOUNT_DIR}"
$SUDO mount "${LOOP}p1" "${MOUNT_DIR}"

# --- Populate boot partition ---
echo "Extracting Alpine to boot partition..."
$SUDO tar xzf "${WORK_DIR}/${ALPINE_TARBALL}" -C "${MOUNT_DIR}/"

# Ship the pre-built apkovl. Alpine's diskless init extracts this to / on
# every boot, giving us a fully-installed system without running apk.
$SUDO cp "${APKOVL_FILE}" "${MOUNT_DIR}/alphasound.apkovl.tar.gz"

# usercfg.txt — read by RPi GPU firmware before Linux boots.
$SUDO tee "${MOUNT_DIR}/usercfg.txt" > /dev/null << 'EOF'
# Alphasound RPi config

# Minimise GPU memory for headless use
gpu_mem=16

# Enable audio
dtparam=audio=on

# Serial console for debugging on GPIO 14 (TX) / 15 (RX) at 115200 baud.
# Mini UART (ttyS0) on GPIO; PL011 stays wired to Bluetooth so A2DP is
# unaffected.
enable_uart=1

# HDMI audio: force HDMI mode (not DVI) so audio is sent over the cable,
# and force hotplug so a monitor with multiple inputs (or no monitor)
# doesn't trick the firmware into thinking there's no display.
hdmi_drive=2
hdmi_force_hotplug=1

# Enable SPI bus — required for the Pimoroni Pirate Audio LCD (and other
# SPI-attached displays). Harmless if you don't have one.
dtparam=spi=on

# DAC overlay — uncomment ONE line matching your audio hardware. Without
# any of these, audio comes out the Pi's HDMI (auto-detected). With one
# enabled, the DAC takes over as the primary audio device.
#
# dtoverlay=hifiberry-dac           # HiFiBerry DAC, Pirate Audio (all variants), IQaudIO Pi-DAC, JustBoom DAC HAT
# dtoverlay=hifiberry-dacplus       # HiFiBerry DAC+, DAC+ Pro, DAC+ Light, DAC+ Zero, DAC+ RTC, MiniAmp, Beocreate
# dtoverlay=hifiberry-dacplushd     # HiFiBerry DAC2 HD
# dtoverlay=hifiberry-digi          # HiFiBerry Digi+ (S/PDIF)
# dtoverlay=hifiberry-amp           # HiFiBerry Amp+, Amp2
# dtoverlay=iqaudio-dacplus         # IQaudIO DAC+, DAC+ Zero
# dtoverlay=iqaudio-digi-wm8804-audio  # IQaudIO Digi
# dtoverlay=allo-boss-dac-pcm512x-audio # Allo Boss DAC
# dtoverlay=audioinjector-wm8731-audio  # Audio Injector Stereo
# dtoverlay=googlevoicehat-soundcard    # Google AIY Voice HAT
EOF

# User-editable config lands at the SD card root.
$SUDO cp "${SCRIPT_DIR}/overlay/alphasound.txt" "${MOUNT_DIR}/alphasound.txt"

echo "Image contents:"
$SUDO ls -lh "${MOUNT_DIR}/"
echo "Used: $($SUDO du -sh "${MOUNT_DIR}/" | cut -f1) of ${IMG_SIZE_MB}MB"

# --- Finalise ---
echo "Finalising..."
sync
$SUDO umount "${MOUNT_DIR}"
$SUDO losetup -d "${LOOP}"
LOOP=""

echo "Compressing..."
xz -9 -T0 -f "${OUTPUT_IMAGE}"

# Also publish the bare apkovl alongside the full image so on-device
# updates can use it (web UI upload form). Much smaller than the .img.xz.
cp "${APKOVL_FILE}" "${OUTPUT_DIR}/alphasound.apkovl.tar.gz"

echo ""
echo "=== Build complete ==="
ls -lh "${OUTPUT_IMAGE}.xz" "${OUTPUT_DIR}/alphasound.apkovl.tar.gz"
