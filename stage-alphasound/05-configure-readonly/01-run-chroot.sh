#!/bin/bash -e
# Configure services and read-only filesystem (runs in chroot)

# Enable alphasound init service
systemctl enable alphasound-init

# Create alphasound user for SSH access in dev mode
useradd -m -s /bin/bash alphasound || true
echo "alphasound:alphasound" | chpasswd
usermod -aG sudo alphasound

# Disable unnecessary services for faster boot
systemctl disable keyboard-setup || true
systemctl disable apt-daily.timer || true
systemctl disable apt-daily-upgrade.timer || true
systemctl disable man-db.timer || true

# Enable overlay filesystem for read-only root
# This uses raspi-config's non-interactive mode
raspi-config nonint do_overlayfs 0 || true

# Make /boot/firmware writable so users can edit alphasound.txt
# The overlay protects rootfs but boot partition stays writable
# (raspi-config may have made it read-only, so we undo that for /boot)
if grep -q "boot" /etc/fstab; then
    sed -i 's|\(/boot/firmware.*\)ro\(.*\)|\1rw\2|' /etc/fstab || true
fi
