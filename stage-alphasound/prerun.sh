#!/bin/bash -e
# pi-gen prerun script for alphasound stage
# Copy rootfs from previous stage since pi-gen doesn't do this
# automatically for custom-named stages

if [ ! -d "${ROOTFS_DIR}" ] && [ -d "${PREV_ROOTFS_DIR}" ]; then
    mkdir -p "${ROOTFS_DIR}"
    rsync -aHAXx --delete "${PREV_ROOTFS_DIR}/" "${ROOTFS_DIR}/"
fi
