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

PACKAGES="alpine-base shairport-sync hostapd dnsmasq avahi openssh \
          bluez bluez-alsa bluez-alsa-utils bluez-alsa-openrc alsa-utils \
          wpa_supplicant jq busybox-extras \
          python3 py3-pillow py3-numpy py3-spidev py3-libgpiod font-noto"

# Runlevels: sysinit + shutdown are critical. sysinit mounts devfs and the
# modloop squashfs (which provides /lib/modules — without this the WiFi
# driver never loads). shutdown lets openrc tear down cleanly. Our apkovl
# replaces /etc/runlevels wholesale, so if we don't list these here, they
# won't be enabled.
SYSINIT_SVCS="devfs dmesg hwdrivers mdev modloop"
BOOT_SVCS="bootmisc hostname hwclock modules sysctl syslog alphasound-rollback alphasound-persist"
DEFAULT_SVCS="networking shairport-sync avahi-daemon bluetooth bluealsa local sshd"
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
    "alpine:${ALPINE_VERSION}" \
    sh -ec "
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main' > /etc/apk/repositories
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community' >> /etc/apk/repositories
        apk update

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

        # Web UI scripts must be executable for httpd to invoke them
        chmod +x /chroot/var/www/cgi-bin/*

        # busybox-extras puts its binary at /bin/busybox-extras and creates
        # symlinks like /usr/sbin/httpd -> /bin/busybox-extras. We don't
        # ship /bin in the apkovl (clobbers modloop), so move the binary
        # to /usr/bin and repoint every applet symlink.
        if [ -f /chroot/bin/busybox-extras ]; then
            echo 'relocating busybox-extras /bin -> /usr/bin'
            mv /chroot/bin/busybox-extras /chroot/usr/bin/busybox-extras
            find /chroot/usr -type l | while read -r f; do
                if [ \"\$(readlink \"\$f\")\" = '/bin/busybox-extras' ]; then
                    ln -sf /usr/bin/busybox-extras \"\$f\"
                    echo \"  repointed \$f\"
                fi
            done
        else
            echo 'no /chroot/bin/busybox-extras found, skipping relocation'
        fi

        # Version stamp for the web UI
        echo '${VERSION}' > /chroot/etc/alphasound-version

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
