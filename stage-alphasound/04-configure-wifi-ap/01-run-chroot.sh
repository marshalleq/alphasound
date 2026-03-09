#!/bin/bash -e
# Configure WiFi AP services (runs in chroot)

# Disable services from auto-starting (we control them via alphasound-init)
systemctl unmask hostapd
systemctl disable hostapd
systemctl disable isc-dhcp-server

# Disable services that interfere with AP mode
systemctl disable wpa_supplicant || true
systemctl disable systemd-timesyncd || true
