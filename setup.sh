#!/usr/bin/env bash

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

PROJECT_DOMAIN=""
VLESS_CLIENT_UUID=""
RU_BLOCK_ENABLED=""
IPV6_DISABLE_ENABLED=""
STATIC_DNS_ENABLED=""
SSH_REMOVE_ENABLED=""
REBOOT_ENABLED=""

print_step() {
  printf '\n==> %s\n' "$1"
}

print_info() {
  printf '%s\n' "$1"
}

fail() {
  printf '\nERROR: %s\n' "$1" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run this script as root."
  fi
}

ask_ipv6_disable() {
  while true; do
    read -r -p "Disable IPv6? [y/N]: " choice
    choice="${choice,,}"
    case "$choice" in
      "y"|"yes")
        IPV6_DISABLE_ENABLED="yes"
        break
        ;;
      ""|"n"|"no")
        IPV6_DISABLE_ENABLED="no"
        break
        ;;
      *)
        print_info "Answer with y or n."
        ;;
    esac
  done
}

ask_static_dns() {
  while true; do
    read -r -p "Use static DNS instead of the default resolver? [y/N]: " choice
    choice="${choice,,}"
    case "$choice" in
      "y"|"yes")
        STATIC_DNS_ENABLED="yes"
        break
        ;;
      ""|"n"|"no")
        STATIC_DNS_ENABLED="no"
        break
        ;;
      *)
        print_info "Answer with y or n."
        ;;
    esac
  done
}

ask_remove_ssh() {
  while true; do
    read -r -p "Remove SSH server? [y/N]: " choice
    choice="${choice,,}"
    case "$choice" in
      "y"|"yes")
        SSH_REMOVE_ENABLED="yes"
        break
        ;;
      ""|"n"|"no")
        SSH_REMOVE_ENABLED="no"
        break
        ;;
      *)
        print_info "Answer with y or n."
        ;;
    esac
  done
}

ask_reboot() {
  while true; do
    read -r -p "Reboot at the end? [y/N]: " choice
    choice="${choice,,}"
    case "$choice" in
      "y"|"yes")
        REBOOT_ENABLED="yes"
        break
        ;;
      ""|"n"|"no")
        REBOOT_ENABLED="no"
        break
        ;;
      *)
        print_info "Answer with y or n."
        ;;
    esac
  done
}

ask_domain() {
  while true; do
    read -r -p "Enter domain: " PROJECT_DOMAIN
    PROJECT_DOMAIN="${PROJECT_DOMAIN,,}"
    PROJECT_DOMAIN="${PROJECT_DOMAIN#.}"
    PROJECT_DOMAIN="${PROJECT_DOMAIN%.}"
    if [[ -n "$PROJECT_DOMAIN" && "$PROJECT_DOMAIN" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]]; then
      break
    fi
    print_info "Invalid domain. Try again."
  done
}

generate_uuid() {
  if command -v xray >/dev/null 2>&1; then
    xray uuid
    return
  fi
  if [[ -x /usr/local/bin/xray ]]; then
    /usr/local/bin/xray uuid
    return
  fi
  if [[ -x /usr/bin/xray ]]; then
    /usr/bin/xray uuid
    return
  fi
  cat /proc/sys/kernel/random/uuid
}

ask_uuid() {
  while true; do
    read -r -p "Generate a new UUID? [Y/n]: " choice
    choice="${choice,,}"
    case "$choice" in
      ""|"y"|"yes")
        VLESS_CLIENT_UUID="$(generate_uuid)"
        print_info "Generated UUID: $VLESS_CLIENT_UUID"
        break
        ;;
      "n"|"no")
        read -r -p "Enter existing UUID: " VLESS_CLIENT_UUID
        if [[ "$VLESS_CLIENT_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
          break
        fi
        print_info "Invalid UUID. Try again."
        ;;
      *)
        print_info "Answer with y or n."
        ;;
    esac
  done
}

ask_ru_block() {
  while true; do
    read -r -p "Enable RU blocking rules? [y/N]: " choice
    choice="${choice,,}"
    case "$choice" in
      "y"|"yes")
        RU_BLOCK_ENABLED="yes"
        break
        ;;
      ""|"n"|"no")
        RU_BLOCK_ENABLED="no"
        break
        ;;
      *)
        print_info "Answer with y or n."
        ;;
    esac
  done
}

apt_install() {
  apt update -y
  apt upgrade -y -o Dpkg::Options::="--force-confold"
  apt install -y nginx certbot python3-certbot-nginx curl python3
}

disable_ipv6_in_grub() {
  local grub_file="/etc/default/grub"

  [[ -f "$grub_file" ]] || fail "GRUB config not found at $grub_file."

  if grep -Eq '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file"; then
    python3 - "$grub_file" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()

m = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', text, flags=re.M)
if not m:
    sys.exit(1)

value = m.group(1).strip()
parts = value.split()
if "ipv6.disable=1" not in parts:
    parts.append("ipv6.disable=1")
new_value = " ".join(parts)
text = re.sub(
    r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"',
    f'GRUB_CMDLINE_LINUX_DEFAULT="{new_value}"',
    text,
    flags=re.M
)

open(path, "w", encoding="utf-8").write(text)
PY
  else
    printf '\nGRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1"\n' >> "$grub_file"
  fi

  update-grub
}

prepare_nginx() {
  rm -f /etc/nginx/sites-available/default
  rm -f /etc/nginx/sites-enabled/default

  cat > "/etc/nginx/sites-available/$PROJECT_DOMAIN" <<EOF
server {
    listen 80;
    server_name $PROJECT_DOMAIN;

    return 301 https://\$host\$request_uri;
}

server {
    listen 127.0.0.1:8080;
    http2 on;
    server_name $PROJECT_DOMAIN;

    location / {
        deny all;
    }
}
EOF

  ln -sfn "/etc/nginx/sites-available/$PROJECT_DOMAIN" "/etc/nginx/sites-enabled/$PROJECT_DOMAIN"
  nginx -t
}

obtain_certificate() {
  certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --cert-name "$PROJECT_DOMAIN" \
    -d "$PROJECT_DOMAIN"
}

install_xray() {
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" -- install -u root
}

write_xray_config() {
  mkdir -p /usr/local/etc/xray

  if [[ "$RU_BLOCK_ENABLED" == "yes" ]]; then
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_CLIENT_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 8080
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "tls",
        "tlsSettings": {
          "alpn": "h2",
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/$PROJECT_DOMAIN/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/$PROJECT_DOMAIN/privkey.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:category-gov-ru",
          "domain:ru",
          "domain:xn--p1ai"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:ru"
        ],
        "outboundTag": "block"
      }
    ],
    "domainStrategy": "IPIfNonMatch"
  }
}
EOF
  else
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_CLIENT_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 8080
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "tls",
        "tlsSettings": {
          "alpn": "h2",
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/$PROJECT_DOMAIN/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/$PROJECT_DOMAIN/privkey.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
  fi
}

configure_dns() {
  systemctl stop systemd-resolved || true
  systemctl disable systemd-resolved || true
  rm -f /etc/resolv.conf
  printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
}

enable_bbr() {
  local sysctl_dir="/etc/sysctl.d"
  local sysctl_file="$sysctl_dir/99-bbr.conf"

  mkdir -p "$sysctl_dir"

  cat > "$sysctl_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
}

remove_ssh_server() {
  systemctl stop ssh 2>/dev/null || true
  systemctl stop sshd 2>/dev/null || true
  systemctl disable ssh 2>/dev/null || true
  systemctl disable sshd 2>/dev/null || true

  apt purge -y openssh-server openssh-sftp-server || true
  apt autoremove -y
}

final_output() {
  printf '\n'
  printf 'Setup finished.\n'
  printf 'Domain: %s\n' "$PROJECT_DOMAIN"
  printf 'UUID: %s\n' "$VLESS_CLIENT_UUID"
  printf 'RU blocking rules: %s\n' "$RU_BLOCK_ENABLED"
  printf 'IPv6 disable: %s\n' "$IPV6_DISABLE_ENABLED"
  printf 'Static DNS: %s\n' "$STATIC_DNS_ENABLED"
  printf 'SSH server removed: %s\n' "$SSH_REMOVE_ENABLED"
  printf 'Reboot at end: %s\n' "$REBOOT_ENABLED"
  printf 'Nginx config: /etc/nginx/sites-available/%s\n' "$PROJECT_DOMAIN"
  printf 'Xray config: /usr/local/etc/xray/config.json\n'
  printf 'Certificate path: /etc/letsencrypt/live/%s/\n' "$PROJECT_DOMAIN"
  printf 'BBR config: /etc/sysctl.d/99-bbr.conf\n'
  printf '\n'
  if [[ "$REBOOT_ENABLED" == "yes" ]]; then
    printf 'System will reboot now.\n'
  else
    printf 'Reboot is required. Reboot manually when ready.\n'
  fi
  if [[ "$SSH_REMOVE_ENABLED" == "yes" ]]; then
    printf 'SSH server was stopped, disabled, and removed.\n'
  else
    printf 'No services were restarted by this script.\n'
  fi
}

main() {
  require_root
  ask_ipv6_disable
  ask_static_dns
  ask_remove_ssh
  ask_domain
  ask_uuid
  ask_ru_block
  ask_reboot

  print_step "Installing packages"
  apt_install

  if [[ "$IPV6_DISABLE_ENABLED" == "yes" ]]; then
    print_step "Disabling IPv6 in GRUB"
    disable_ipv6_in_grub
  fi

  print_step "Preparing Nginx"
  prepare_nginx

  print_step "Obtaining TLS certificate"
  obtain_certificate

  print_step "Installing Xray"
  install_xray

  print_step "Writing Xray configuration"
  write_xray_config

  if [[ "$STATIC_DNS_ENABLED" == "yes" ]]; then
    print_step "Configuring static DNS"
    configure_dns
  fi

  print_step "Enabling BBR"
  enable_bbr

  if [[ "$SSH_REMOVE_ENABLED" == "yes" ]]; then
    print_step "Removing SSH server"
    remove_ssh_server
  fi

  final_output

  if [[ "$REBOOT_ENABLED" == "yes" ]]; then
    print_step "Rebooting"
    reboot
  fi
}

main "$@"