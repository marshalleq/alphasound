#!/bin/bash -e
# Copy alphasound init script, service, and config into rootfs (runs on host)

install -m 755 files/alphasound-init "${ROOTFS_DIR}/usr/local/bin/alphasound-init"
install -m 644 files/alphasound-init.service "${ROOTFS_DIR}/etc/systemd/system/alphasound-init.service"

# Install default config to boot partition
mkdir -p "${ROOTFS_DIR}/boot/firmware"
install -m 644 files/alphasound.txt "${ROOTFS_DIR}/boot/firmware/alphasound.txt"
