#!/bin/bash -e
# Configure shairport-sync with sensible defaults
# These get overridden at boot time by /boot/firmware/alphasound.txt

cat > /etc/shairport-sync.conf << 'CONF'
// Shairport Sync configuration for Alphasound
// Runtime values are applied from /boot/firmware/alphasound.txt on each boot

general =
{
    name = "Alphasound";
    ignore_volume_control = "yes";
    volume_max_db = -3.00;
};

alsa =
{
    output_device = "hw:0";
};
CONF
