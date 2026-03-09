#!/bin/bash -e
# Copy WiFi AP config files into the rootfs (runs on host)

install -m 644 files/hostapd.conf.template "${ROOTFS_DIR}/etc/hostapd/hostapd.conf.template"
install -m 644 files/dhcpd.conf "${ROOTFS_DIR}/etc/dhcp/dhcpd.conf"
install -m 644 files/isc-dhcp-server "${ROOTFS_DIR}/etc/default/isc-dhcp-server"
