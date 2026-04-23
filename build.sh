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

# Variant selector. "home" = full-featured (default), "car" = stripped
# for fastest boot — no display stack, no Python, no Roon prerequisites,
# no CEC, minimal package footprint so the apkovl extract at boot is
# smaller and less userland needs to come up. Build CI invokes us once
# per variant and publishes both .img.xz + .apkovl.tar.gz files.
VARIANT="${VARIANT:-home}"
case "$VARIANT" in
    home|car) ;;
    *) echo "Unknown VARIANT='$VARIANT' (expected home or car)"; exit 1 ;;
esac
echo "Variant: ${VARIANT}"

PACKAGES_COMMON="alpine-base shairport-sync hostapd dnsmasq avahi openssh \
          bluez bluez-alsa bluez-alsa-utils bluez-alsa-openrc alsa-utils \
          wpa_supplicant jq \
          lighttpd"

if [ "$VARIANT" = "home" ]; then
    # Home adds: Pirate Audio / Adafruit SPI display + HDMI rendering
    # (Python stack), HDMI-CEC (v4l-utils + avahi-tools for DACP mDNS),
    # Roon Bridge prereqs (gcompat + bzip2).
    PACKAGES="$PACKAGES_COMMON avahi-tools \
              python3 py3-pillow py3-numpy py3-libgpiod font-noto \
              v4l-utils \
              gcompat bzip2"
else
    PACKAGES="$PACKAGES_COMMON"
fi

# Runlevels: sysinit + shutdown are critical. sysinit mounts devfs and the
# modloop squashfs (which provides /lib/modules — without this the WiFi
# driver never loads). shutdown lets openrc tear down cleanly. Our apkovl
# replaces /etc/runlevels wholesale, so if we don't list these here, they
# won't be enabled.
SYSINIT_SVCS="devfs dmesg hwdrivers mdev modloop alphasound-clock"
# hwclock excluded: Pi has no battery-backed RTC, so the service just
# logs errors trying to talk to /dev/rtc on every boot.
# syslog excluded: this appliance logs to /dev/console via alphasound.start
# and to stderr via OpenRC; persistent syslog to /var/log/messages isn't
# useful when the rootfs is tmpfs (wiped on every reboot) and saves ~1s.
BOOT_SVCS_COMMON="bootmisc hostname modules sysctl alphasound-rollback alphasound-persist alphasound-features alphasound-audio"
if [ "$VARIANT" = "home" ]; then
    BOOT_SVCS="$BOOT_SVCS_COMMON alphasound-splash"
else
    # Car variant skips the splash binary entirely — no display hardware
    # is assumed, and boot speed is the priority.
    BOOT_SVCS="$BOOT_SVCS_COMMON"
fi
DEFAULT_SVCS="networking shairport-sync avahi-daemon bluetooth bluealsa local sshd lighttpd"
SHUTDOWN_SVCS="killprocs mount-ro savecache"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/.work"
MOUNT_DIR="${WORK_DIR}/mnt"
CHROOT_DIR="${WORK_DIR}/chroot-${VARIANT}"
APKOVL_FILE="${WORK_DIR}/alphasound-${VARIANT}.apkovl.tar.gz"
OUTPUT_DIR="${SCRIPT_DIR}/deploy"
OUTPUT_IMAGE="${OUTPUT_DIR}/alphasound-${VARIANT}.img"

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
    -e VARIANT="${VARIANT}" \
    "alpine:${ALPINE_VERSION}" \
    sh -ec "
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main' > /etc/apk/repositories
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community' >> /etc/apk/repositories
        apk update
        # Host-container tooling: C compiler (+ Linux UAPI headers for
        # spidev.h) for the boot splash, plus Python+PIL+Noto to
        # pre-render its splash image. These don't land in the chroot
        # — they stay in the ephemeral build image. Car variant skips
        # the splash so it doesn't need gcc/PIL/font-noto either.
        if [ \"\$VARIANT\" = home ]; then
            apk add --no-cache gcc musl-dev linux-headers python3 py3-pillow font-noto
        fi

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
        # /sbin/init: force-install our pre-OpenRC wrapper. The overlay
        # tar extraction *should* replace Alpine's openrc-init symlink
        # with a regular file but GNU tar's behaviour with symlinks
        # varies — install overwrites unconditionally. Kernel runs this
        # as PID 1; it must exist as an executable regular file.
        rm -f /chroot/sbin/init
        install -m 0755 /overlay/sbin/init /chroot/sbin/init
        echo '--- /sbin/init installed: ---'
        ls -la /chroot/sbin/init
        head -3 /chroot/sbin/init

        # Web UI scripts must be executable for lighttpd's mod_cgi to run them
        chmod +x /chroot/var/www/cgi-bin/*

        # Ensure everything under /usr/local/bin/ is runnable (shipped
        # executables like alphasound-display.py and the checkpoint
        # helper called from init scripts).
        chmod +x /chroot/usr/local/bin/* 2>/dev/null || true

        # Boot splash: compile the C binary and pre-render its image.
        # Binary lands in /usr/local/bin, image bytes in /usr/share.
        # Skipped for the car variant since it has no display hardware.
        if [ \"\$VARIANT\" = home ]; then
            echo '--- building alphasound-splash ---'
            mkdir -p /chroot/usr/local/bin /chroot/usr/share/alphasound-splash
            gcc -O2 -Wall -o /chroot/usr/local/bin/alphasound-splash /splash/alphasound-splash.c
            python3 /splash/gen-splash.py /chroot/usr/share/alphasound-splash/splash.raw
        fi

        # Enable OpenRC parallel service startup so the default runlevel
        # uses all four cores instead of one. Covers both the commented
        # default and the no-match case (append if missing).
        sed -i 's|^#*rc_parallel=.*|rc_parallel=\"YES\"|' /chroot/etc/rc.conf
        grep -q '^rc_parallel=' /chroot/etc/rc.conf \
            || echo 'rc_parallel=\"YES\"' >> /chroot/etc/rc.conf

        # IPv6 is disabled at the kernel level (cmdline ipv6.disable=1),
        # so any sysctl entry under net.ipv6.* generates 'unknown key'
        # errors at boot. Strip those lines from every sysctl config
        # location any Alpine package might use.
        find /chroot/etc/sysctl.conf /chroot/etc/sysctl.d \
             /chroot/usr/lib/sysctl.d /chroot/lib/sysctl.d \
             /chroot/run/sysctl.d \
             -type f 2>/dev/null \
            | xargs -r sed -i '/\\.ipv6\\./d'

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

        # Back-date everything in the chroot to epoch 0 so OpenRC's
        # mtime-based dependency-graph checks don't flag files as
        # 'from the future' on a Pi with no RTC.
        #
        # OpenRC's functions.sh lives under /usr/libexec/rc/sh/ on
        # current Alpine (symlinked from /etc/init.d/), and other
        # scripts it sources live scattered under /usr and /lib. The
        # exact set varies by version — easier to back-date the whole
        # chroot than to chase specific paths as the package layout
        # moves around. Regular files first, then symlinks (need -h
        # to operate on the link itself, not its target).
        find /chroot -xdev -type f -exec touch    -t 197001010000 {} + 2>/dev/null || true
        find /chroot -xdev -type l -exec touch -h -t 197001010000 {} + 2>/dev/null || true

        # Drop apk's download cache and other cruft to keep the apkovl small
        rm -rf /chroot/var/cache/apk/* /chroot/tmp/* 2>/dev/null || true

        echo '--- chroot ready ---'
    "

# --- Strip display/Roon artefacts for the car variant ---
# These files are shipped via our overlay unconditionally so that the
# home variant's build is simple; for car we delete them post-overlay
# so they don't inflate the apkovl and so the init system doesn't try
# to start services whose binaries have been removed. Roon goes too —
# gcompat+bzip2 are absent from the car PACKAGES list so RoonBridge
# could never extract or run anyway; its CGI buttons would just error.
if [ "$VARIANT" = "car" ]; then
    echo "Stripping display/Roon files for car variant..."
    $SUDO rm -f  "${CHROOT_DIR}/usr/local/bin/alphasound-display.py"
    $SUDO rm -f  "${CHROOT_DIR}/usr/local/bin/alphasound-splash"
    $SUDO rm -rf "${CHROOT_DIR}/usr/share/alphasound-splash"
    $SUDO rm -f  "${CHROOT_DIR}/etc/init.d/alphasound-display"
    $SUDO rm -f  "${CHROOT_DIR}/etc/init.d/alphasound-splash"
    $SUDO rm -f  "${CHROOT_DIR}/etc/init.d/alphasound-roon"
    $SUDO rm -f  "${CHROOT_DIR}/var/www/cgi-bin/setbrightness"
    $SUDO rm -f  "${CHROOT_DIR}/var/www/cgi-bin/install-roon"
    $SUDO rm -f  "${CHROOT_DIR}/var/www/cgi-bin/uninstall-roon"
    # alphasound-splash isn't in BOOT_SVCS for car, so the runlevel
    # symlink was never created — nothing to clean up there.
fi

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
# Flat 2 GB FAT32 partition. Alphasound runs entirely from a tmpfs
# extracted from the apkovl at boot, so nothing about runtime depends
# on how much disk we allocate — SD space is only needed for updates
# (in-flight .new file + preserved .bak), persistent state (SSH host
# keys, Bluetooth pairings, optional RoonBridge tarball), and future
# headroom. xz compresses the unused partition space to almost nothing,
# so a bigger image on disk is "free" in terms of download size; only
# flash time grows by a few seconds. Calculated size is still used as
# a floor in case Alpine's tarball ever outgrows 2 GB.
IMG_SIZE_MB=2048
CALCULATED_IMG_SIZE_MB=$(( (TARBALL_SIZE + APKOVL_SIZE + 64*1024*1024) / 1024 / 1024 + 1 ))
[ "$CALCULATED_IMG_SIZE_MB" -gt "$IMG_SIZE_MB" ] && IMG_SIZE_MB=$CALCULATED_IMG_SIZE_MB
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

# Disable IPv6 at the kernel level. We're a single-interface AirPlay +
# Bluetooth appliance — nothing we run benefits from v6, and it just
# generates log noise when services try to bind to :: on an interface
# that never gets a v6 address.
$SUDO sed -i 's/$/ ipv6.disable=1/' "${MOUNT_DIR}/cmdline.txt"

# Preload snd_bcm2835 in initramfs (append to the existing modules=).
# The kernel audio driver takes 1-2s to initialise and register the
# ALSA card; doing it in initramfs rather than waiting for OpenRC's
# `modules` service in the boot runlevel removes that wait from the
# critical path. Falls back cleanly on other Alpine kernels that
# don't know the module.
$SUDO sed -i 's/modules=\([^ ]*\)/modules=\1,snd_bcm2835/' "${MOUNT_DIR}/cmdline.txt"

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
cp "${APKOVL_FILE}" "${OUTPUT_DIR}/alphasound-${VARIANT}.apkovl.tar.gz"

echo ""
echo "=== Build complete ==="
ls -lh "${OUTPUT_IMAGE}.xz" "${OUTPUT_DIR}/alphasound-${VARIANT}.apkovl.tar.gz"
