#!/bin/bash
set -euo pipefail

# Alphasound image builder — single source of truth for both local builds
# and the GitHub Actions release pipeline (.github/workflows/build.yml just
# installs deps and runs this script).
#
# Approach: download the Alpine RPi *tarball* (not the disk image), build a
# fresh FAT32 image sized to fit the boot files + offline package cache,
# then drop our apkovl on top. Alpine boots diskless — packages from the
# cache get installed into RAM at first boot.
#
# Requires Linux (loop devices, mkfs.vfat) plus: docker, curl, parted,
# dosfstools, xz-utils. Local runs need sudo for losetup/mount.

ALPINE_VERSION="3.21"
ALPINE_RELEASE="3.21.6"
ALPINE_ARCH="aarch64"
ALPINE_TARBALL="alpine-rpi-${ALPINE_RELEASE}-${ALPINE_ARCH}.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ALPINE_TARBALL}"

# Packages fetched into the offline cache and listed in /etc/apk/world so
# they auto-install at first boot.
PACKAGES="alpine-base shairport-sync hostapd dnsmasq avahi openssh \
          bluez bluez-alsa bluez-alsa-utils bluez-alsa-openrc"

DEFAULT_SVCS="networking shairport-sync avahi-daemon bluetooth bluez-alsa local sshd"
BOOT_SVCS="hostname hwclock modules sysctl bootmisc syslog alphasound-install"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/.work"
MOUNT_DIR="${WORK_DIR}/mnt"
OUTPUT_DIR="${SCRIPT_DIR}/deploy"
OUTPUT_IMAGE="${OUTPUT_DIR}/alphasound.img"

SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

LOOP=""
cleanup() {
    echo "Cleaning up..."
    $SUDO umount "${MOUNT_DIR}" 2>/dev/null || true
    [ -n "${LOOP}" ] && $SUDO losetup -d "${LOOP}" 2>/dev/null || true
    rm -rf "${WORK_DIR}/cache" "${WORK_DIR}/keys" "${WORK_DIR}/overlay" "${WORK_DIR}/alpine-extract"
}
trap cleanup EXIT

echo "=== Alphasound Image Builder ==="
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

# --- Download Alpine RPi tarball ---
if [ ! -f "${WORK_DIR}/${ALPINE_TARBALL}" ]; then
    echo "Downloading Alpine Linux ${ALPINE_RELEASE}..."
    curl -L -o "${WORK_DIR}/${ALPINE_TARBALL}" "${ALPINE_URL}"
fi

# --- Fetch packages and build signed offline repository ---
# Without an APKINDEX in the local cache, apk at first boot has no way to
# resolve our packages and silently falls back to the online repos — which
# are unreachable in a car with no internet. So we build a real Alpine
# repository: APKINDEX.tar.gz signed with a freshly-generated key, and we
# ship the matching public key in the apkovl under /etc/apk/keys/.
echo "Fetching packages and building signed offline repo..."
rm -rf "${WORK_DIR}/cache" "${WORK_DIR}/keys"
mkdir -p "${WORK_DIR}/cache" "${WORK_DIR}/keys"
docker run --rm \
    -v "${WORK_DIR}/cache:/cache" \
    -v "${WORK_DIR}/keys:/keys" \
    --workdir /cache \
    "alpine:${ALPINE_VERSION}" \
    sh -c "
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main' > /etc/apk/repositories
        echo 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community' >> /etc/apk/repositories
        apk update
        apk add --no-cache abuild
        # -a: record key path in /etc/abuild.conf so abuild-sign finds it
        # -i: install the matching public key to /etc/apk/keys (so apk in
        #     this container would trust the index too, if we re-read it)
        # -n: no passphrase (we need non-interactive signing)
        abuild-keygen -a -i -n
        apk fetch -R -o /cache ${PACKAGES}
        apk index -o APKINDEX.tar.gz *.apk
        abuild-sign APKINDEX.tar.gz
        cp /etc/apk/keys/*.rsa.pub /keys/
    "
echo "Cached $(ls "${WORK_DIR}/cache/"*.apk | wc -l) packages, $(du -sh "${WORK_DIR}/cache/" | cut -f1)"

# --- Calculate image size ---
echo "Calculating image size..."
mkdir -p "${WORK_DIR}/alpine-extract"
tar xzf "${WORK_DIR}/${ALPINE_TARBALL}" -C "${WORK_DIR}/alpine-extract"
TARBALL_SIZE=$(du -sb "${WORK_DIR}/alpine-extract" | cut -f1)
CACHE_SIZE=$(du -sb "${WORK_DIR}/cache" | cut -f1)
# 64 MB headroom for FAT32 overhead, apkovl, and breathing room.
IMG_SIZE_MB=$(( (TARBALL_SIZE + CACHE_SIZE + 64*1024*1024) / 1024 / 1024 + 1 ))
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

echo "Copying offline package cache..."
$SUDO cp -r "${WORK_DIR}/cache" "${MOUNT_DIR}/cache"

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

# DAC overlay (uncomment and change for your DAC)
# dtoverlay=hifiberry-dac
EOF

# User-editable config lands at the SD card root.
$SUDO cp "${SCRIPT_DIR}/overlay/alphasound.txt" "${MOUNT_DIR}/alphasound.txt"

# --- Build apkovl overlay (applied to / on every boot) ---
echo "Building apkovl..."
OVERLAY_DIR="${WORK_DIR}/overlay"
mkdir -p "${OVERLAY_DIR}"
cp -a "${SCRIPT_DIR}/overlay/etc" "${OVERLAY_DIR}/"
echo "alphasound" > "${OVERLAY_DIR}/etc/hostname"

# APK repositories — local cache first, network as fallback.
mkdir -p "${OVERLAY_DIR}/etc/apk"
cat > "${OVERLAY_DIR}/etc/apk/repositories" << EOF
/media/mmcblk0p1/cache
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

# APK world — packages installed at first boot.
printf '%s\n' $PACKAGES > "${OVERLAY_DIR}/etc/apk/world"

# Cache symlink so apk reads from the SD card.
ln -sf /media/mmcblk0p1/cache "${OVERLAY_DIR}/etc/apk/cache"

# Trust the signing key for our local repo so apk will install from it.
mkdir -p "${OVERLAY_DIR}/etc/apk/keys"
cp "${WORK_DIR}/keys/"*.rsa.pub "${OVERLAY_DIR}/etc/apk/keys/"

# Runlevels.
mkdir -p "${OVERLAY_DIR}/etc/runlevels/default" "${OVERLAY_DIR}/etc/runlevels/boot"
for svc in $DEFAULT_SVCS; do
    ln -sf "/etc/init.d/${svc}" "${OVERLAY_DIR}/etc/runlevels/default/${svc}"
done
for svc in $BOOT_SVCS; do
    ln -sf "/etc/init.d/${svc}" "${OVERLAY_DIR}/etc/runlevels/boot/${svc}"
done

# local.d scripts and init.d services must be executable to run.
chmod +x "${OVERLAY_DIR}/etc/local.d/"*.start
chmod +x "${OVERLAY_DIR}/etc/init.d/"*

(cd "${OVERLAY_DIR}" && $SUDO tar czf "${MOUNT_DIR}/alphasound.apkovl.tar.gz" .)

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

echo ""
echo "=== Build complete ==="
ls -lh "${OUTPUT_IMAGE}.xz"
