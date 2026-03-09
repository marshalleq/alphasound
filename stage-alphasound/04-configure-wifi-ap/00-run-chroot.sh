#!/bin/bash -e
# Configure WiFi access point and DHCP server

# Install template and config files
install -m 644 files/hostapd.conf.template /etc/hostapd/hostapd.conf.template
install -m 644 files/dhcpd.conf /etc/dhcp/dhcpd.conf
install -m 644 files/isc-dhcp-server /etc/default/isc-dhcp-server

# Disable services from auto-starting (we control them via alphasound-init)
systemctl unmask hostapd
systemctl disable hostapd
systemctl disable isc-dhcp-server

# Disable services that interfere with AP mode
systemctl disable wpa_supplicant || true
systemctl disable systemd-timesyncd || true
