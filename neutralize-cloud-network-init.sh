#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || {
  echo "Run as root"
  exit 1
}

IFACE="$(ip -o -4 route show default | awk '{print $5; exit}')"

[ -n "$IFACE" ] || {
  echo "No IPv4 default interface found"
  exit 1
}

MAC="$(cat "/sys/class/net/$IFACE/address")"
TS="$(date +%Y%m%d%H%M%S)"

echo "Interface: $IFACE"
echo "MAC: $MAC"

mkdir -p /etc/cloud/cloud.cfg.d

cat >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network:
  config: disabled
EOF

if [ -f /var/lib/cloud/scripts/per-instance/002_onboot ]; then
  cp -a /var/lib/cloud/scripts/per-instance/002_onboot "/var/lib/cloud/scripts/per-instance/002_onboot.bak.ipv6off.$TS"

  cat >/var/lib/cloud/scripts/per-instance/002_onboot <<'EOF'
#!/bin/sh
exit 0
EOF

  chmod 644 /var/lib/cloud/scripts/per-instance/002_onboot
fi

mkdir -p /etc/netplan

if [ -f /etc/netplan/50-cloud-init.yaml ]; then
  cp -a /etc/netplan/50-cloud-init.yaml "/etc/netplan/50-cloud-init.yaml.bak.ipv6off.$TS"
fi

cat >/etc/netplan/50-cloud-init.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      match:
        macaddress: $MAC
      set-name: $IFACE
      dhcp4: true
      dhcp6: false
      accept-ra: false
      link-local: []
      optional: true
EOF

chmod 600 /etc/netplan/50-cloud-init.yaml

netplan generate
netplan apply

echo
echo "Generated networkd config:"
cat "/run/systemd/network/10-netplan-$IFACE.network"

echo
echo "IPv4 routes:"
ip route

echo
echo "Systemd failed units:"
systemctl --failed

echo
echo "Done. Now edit /etc/default/grub manually and add ipv6.disable=1."
