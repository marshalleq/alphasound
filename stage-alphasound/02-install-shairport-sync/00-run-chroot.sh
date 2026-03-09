#!/bin/bash -e
# Build and install shairport-sync with AirPlay 2 support

cd /tmp
git clone https://github.com/mikebrady/shairport-sync.git
cd shairport-sync
autoreconf -fi
./configure --sysconfdir=/etc \
    --with-alsa \
    --with-soxr \
    --with-avahi \
    --with-ssl=openssl \
    --with-systemd-startup \
    --with-airplay-2
make
make install

# Enable the service
systemctl enable shairport-sync

# Clean up build files
cd /
rm -rf /tmp/shairport-sync
