#!/bin/bash -e
# Remove build dependencies and clean up to slim the image
# shairport-sync and nqptp are already compiled and installed at this point

# Purge build-only packages (keep runtime deps, raspi-config, ssh, sudo)
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
    libavutil-dev \
    libavcodec-dev \
    libavformat-dev \
    libsystemd-dev \
    systemd-dev \
    cpp gcc g++ make dpkg-dev

# Remove orphaned packages pulled in as build deps
apt-get autoremove --purge -y

# Clean apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Strip installed binaries
strip /usr/local/bin/shairport-sync 2>/dev/null || true
strip /usr/local/bin/nqptp 2>/dev/null || true

# Remove docs, man pages, locale data we don't need
rm -rf /usr/share/doc/*
rm -rf /usr/share/man/*
rm -rf /usr/share/info/*
rm -rf /usr/share/locale/*
rm -rf /usr/share/i18n/*

# Remove leftover build artifacts and logs
rm -rf /tmp/* /var/tmp/*
rm -rf /var/log/*
rm -rf /var/cache/*
