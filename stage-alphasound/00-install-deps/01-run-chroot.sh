#!/bin/bash -e
# Install build dependencies for shairport-sync and nqptp
# These are installed explicitly here rather than via 00-packages so we can
# use --no-install-recommends and confirm they're available

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    git \
    pkgconf \
    autoconf \
    automake \
    libtool \
    libpopt-dev \
    libconfig-dev \
    libasound2-dev \
    libavahi-client-dev \
    libssl-dev \
    libsoxr-dev \
    libplist-dev \
    libsodium-dev \
    uuid-dev \
    libgcrypt-dev \
    xxd \
    libplist-utils \
    libavutil-dev \
    libavcodec-dev \
    libavformat-dev \
    libsystemd-dev

# Verify pkg-config can find systemd
echo "=== Checking pkg-config for systemd ==="
pkg-config --modversion systemd || echo "WARNING: systemd.pc not found"
pkg-config --modversion libsystemd || echo "WARNING: libsystemd.pc not found"
