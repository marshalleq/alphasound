#!/bin/bash
set -e

# Alphasound image builder
# Creates a Raspberry Pi SD card image based on Alpine Linux
# with shairport-sync, hostapd, and dnsmasq pre-configured

ALPINE_VERSION="3.21"
ALPINE_RELEASE="3.21.6"
ALPINE_ARCH="aarch64"
ALPINE_IMAGE="alpine-rpi-${ALPINE_RELEASE}-${ALPINE_ARCH}.img.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ALPINE_IMAGE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/.work"
MOUNT_DIR="${WORK_DIR}/mnt"
OUTPUT_DIR="${SCRIPT_DIR}/deploy"
OUTPUT_IMAGE="${OUTPUT_DIR}/alphasound.img"

REQUIRED_PKGS="shairport-sync hostapd dnsmasq avahi openssh"

cleanup() {
    echo "Cleaning up..."
    umount "${MOUNT_DIR}" 2>/dev/null || true
    losetup -D 2>/dev/null || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "=== Alphasound Image Builder ==="
echo ""

# Download Alpine RPi image
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
if [ ! -f "${WORK_DIR}/${ALPINE_IMAGE}" ]; then
    echo "Downloading Alpine Linux ${ALPINE_RELEASE}..."
    curl -L -o "${WORK_DIR}/${ALPINE_IMAGE}" "${ALPINE_URL}"
fi

# Decompress the image
echo "Decompressing image..."
gunzip -k -f "${WORK_DIR}/${ALPINE_IMAGE}"
IMG="${WORK_DIR}/alpine-rpi-${ALPINE_RELEASE}-${ALPINE_ARCH}.img"

# Expand the image to 512MB to fit our packages
echo "Expanding image..."
truncate -s 512M "${IMG}"

# Set up loop device and resize partition
echo "Setting up partitions..."
LOOP=$(losetup --show -fP "${IMG}")
echo "Loop device: ${LOOP}"

# Resize the FAT32 partition to fill the image
# The Alpine RPi image has a single FAT32 partition
echo ", +" | sfdisk -N 1 "${LOOP}" 2>/dev/null || true
partprobe "${LOOP}" 2>/dev/null || true
fatresize "${LOOP}p1" 2>/dev/null || dosfsck -a "${LOOP}p1" 2>/dev/null || true

# Mount the boot/root partition
mkdir -p "${MOUNT_DIR}"
mount "${LOOP}p1" "${MOUNT_DIR}"

echo "Partition mounted at ${MOUNT_DIR}"
echo "Contents:"
ls "${MOUNT_DIR}/"

# --- Create the apkovl overlay ---
echo ""
echo "Creating apkovl overlay..."

OVERLAY_DIR="${WORK_DIR}/overlay"
mkdir -p "${OVERLAY_DIR}/etc/apk"
mkdir -p "${OVERLAY_DIR}/etc/hostapd"
mkdir -p "${OVERLAY_DIR}/etc/dnsmasq.d"
mkdir -p "${OVERLAY_DIR}/etc/local.d"
mkdir -p "${OVERLAY_DIR}/etc/runlevels/default"
mkdir -p "${OVERLAY_DIR}/etc/conf.d"
mkdir -p "${OVERLAY_DIR}/etc/ssh"

# Hostname
echo "alphasound" > "${OVERLAY_DIR}/etc/hostname"

# APK repositories
cat > "${OVERLAY_DIR}/etc/apk/repositories" << EOF
/media/mmcblk0p1/apks
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

# APK world file (packages to install)
cat > "${OVERLAY_DIR}/etc/apk/world" << EOF
alpine-base
shairport-sync
hostapd
dnsmasq
avahi
openssh
EOF

# APK cache symlink (points to boot partition)
ln -sf /media/mmcblk0p1/cache "${OVERLAY_DIR}/etc/apk/cache"

# hostapd config template
cp "${SCRIPT_DIR}/overlay/etc/hostapd/hostapd.conf.template" \
   "${OVERLAY_DIR}/etc/hostapd/hostapd.conf.template"

# dnsmasq config
cp "${SCRIPT_DIR}/overlay/etc/dnsmasq.d/alphasound.conf" \
   "${OVERLAY_DIR}/etc/dnsmasq.d/alphasound.conf"

# shairport-sync config
cp "${SCRIPT_DIR}/overlay/etc/shairport-sync.conf" \
   "${OVERLAY_DIR}/etc/shairport-sync.conf"

# Alphasound init script (runs at boot via local.d)
cp "${SCRIPT_DIR}/overlay/etc/local.d/alphasound.start" \
   "${OVERLAY_DIR}/etc/local.d/alphasound.start"
chmod +x "${OVERLAY_DIR}/etc/local.d/alphasound.start"

# sshd config — key-only root login
cp "${SCRIPT_DIR}/overlay/etc/ssh/sshd_config" \
   "${OVERLAY_DIR}/etc/ssh/sshd_config"

# Enable services via runlevel symlinks
for svc in networking shairport-sync avahi-daemon local sshd; do
    ln -sf "/etc/init.d/${svc}" "${OVERLAY_DIR}/etc/runlevels/default/${svc}"
done
# Boot services
mkdir -p "${OVERLAY_DIR}/etc/runlevels/boot"
for svc in hostname hwclock modules sysctl bootmisc syslog; do
    ln -sf "/etc/init.d/${svc}" "${OVERLAY_DIR}/etc/runlevels/boot/${svc}"
done

# Create the apkovl tarball
echo "Packing apkovl..."
(cd "${OVERLAY_DIR}" && tar czf "${MOUNT_DIR}/alphasound.apkovl.tar.gz" .)

# --- Cache packages for offline boot ---
echo ""
echo "Caching packages for offline installation..."
mkdir -p "${MOUNT_DIR}/cache"

# Use Alpine Docker container to fetch packages for aarch64
docker run --rm \
    -v "${MOUNT_DIR}/cache:/cache" \
    "alpine:${ALPINE_VERSION}" \
    sh -c "
        apk update
        apk fetch -R -o /cache ${REQUIRED_PKGS}
        # Also fetch alpine-base deps that might be needed
        apk fetch -R -o /cache alpine-base
    "

echo "Cached packages:"
ls -lh "${MOUNT_DIR}/cache/" | head -20
echo "Total cache size: $(du -sh "${MOUNT_DIR}/cache/" | cut -f1)"

# --- Configure boot ---
echo ""
echo "Configuring boot..."

# usercfg.txt for DAC overlay and headless settings
cat > "${MOUNT_DIR}/usercfg.txt" << 'EOF'
# Alphasound RPi config
# This file is read by the RPi GPU firmware before Linux boots

# Minimise GPU memory for headless use
gpu_mem=16

# Enable audio
dtparam=audio=on

# Serial console for debugging on GPIO 14 (TX) / 15 (RX) at 115200 baud.
# On Pi 3/Zero 2 W this exposes the mini UART (ttyS0); the PL011 stays
# wired to Bluetooth so A2DP is unaffected.
enable_uart=1

# DAC overlay (uncomment and change for your DAC)
# dtoverlay=hifiberry-dac
EOF

# Copy alphasound user config
cp "${SCRIPT_DIR}/overlay/alphasound.txt" "${MOUNT_DIR}/alphasound.txt"

# --- Finalise ---
echo ""
echo "Finalising image..."

# Unmount
sync
umount "${MOUNT_DIR}"
losetup -d "${LOOP}"

# Copy to output
cp "${IMG}" "${OUTPUT_IMAGE}"

# Compress
echo "Compressing..."
xz -9 -T0 -f "${OUTPUT_IMAGE}"

echo ""
echo "=== Build complete ==="
echo "Image: ${OUTPUT_IMAGE}.xz"
ls -lh "${OUTPUT_IMAGE}.xz"
