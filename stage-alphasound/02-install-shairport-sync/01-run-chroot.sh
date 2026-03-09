#!/bin/bash -e
# Remove build dependencies and clean up to slim the image
# shairport-sync and nqptp are already compiled and installed at this point

# Purge build-only packages
apt-get purge -y \
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
    libsystemd-dev \
    systemd-dev \
    cpp gcc g++ make dpkg-dev

# Remove orphaned packages pulled in as build deps
apt-get autoremove -y

# Clean apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Remove cloud-init (installed by stage2, not needed in a car)
apt-get purge -y cloud-init || true
rm -rf /etc/cloud /var/lib/cloud

# Strip installed binaries
strip /usr/local/bin/shairport-sync 2>/dev/null || true
strip /usr/local/bin/nqptp 2>/dev/null || true

# Remove leftover build artifacts
rm -rf /tmp/* /var/tmp/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
rm -rf /var/log/*
