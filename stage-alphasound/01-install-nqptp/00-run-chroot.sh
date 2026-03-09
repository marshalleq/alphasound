#!/bin/bash -e
# Install NQPTP (PTP clock implementation required for AirPlay 2)

cd /tmp
git clone https://github.com/mikebrady/nqptp.git
cd nqptp
autoreconf -fi
./configure --with-systemd-startup
make
make install

# Enable the service
systemctl enable nqptp

# Clean up build files
cd /
rm -rf /tmp/nqptp
