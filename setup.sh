#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export XRAY_LOCATION_ASSET=/usr/local/share/xray

XRAY_VERSION=""
RELEASE_ROOT="/usr/local/lib/xray"
STATE_DIR="/var/lib/xray-setup"
PROJECT_DOMAIN=""
VLESS_CLIENT_UUID=""
TEMP_DIR=""

fail() {
    printf '\nERROR: %s\n' "$1" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$1"
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT
trap 'printf "\nERROR: Setup stopped at line %s. Check the error above before retrying.\n" "$LINENO" >&2' ERR

validate_domain() {
    local label
    local -a labels
    [[ ${#1} -le 253 && "$1" == *.* ]] || return 1
    IFS='.' read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
    [[ "${labels[-1]}" =~ [a-z] ]]
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

ask_inputs() {
    local choice
    while true; do
        read -r -p 'Enter domain: ' PROJECT_DOMAIN || fail 'Input closed.'
        PROJECT_DOMAIN="${PROJECT_DOMAIN,,}"
        PROJECT_DOMAIN="${PROJECT_DOMAIN%.}"
        if validate_domain "$PROJECT_DOMAIN"; then
            break
        fi
        printf 'Enter a valid domain without a URL scheme or path.\n'
    done
    while true; do
        read -r -p 'Generate a new UUID? [Y/n]: ' choice || fail 'Input closed.'
        case "${choice,,}" in
            ''|y|yes)
                VLESS_CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid)"
                break
                ;;
            n|no)
                read -r -p 'Enter existing UUID: ' VLESS_CLIENT_UUID || fail 'Input closed.'
                if validate_uuid "$VLESS_CLIENT_UUID"; then
                    VLESS_CLIENT_UUID="${VLESS_CLIENT_UUID,,}"
                    break
                fi
                printf 'Invalid UUID. Try again.\n'
                ;;
            *) printf 'Answer with y or n.\n' ;;
        esac
    done
}

preflight() {
    [[ "$EUID" -eq 0 ]] || fail 'Run this script as root.'
    [[ -f /etc/os-release ]] || fail 'Cannot identify the operating system.'
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" == 13 ]] || fail 'Debian 13 is required.'
    [[ -d /run/systemd/system ]] || fail 'systemd is required.'
    [[ -f /etc/default/grub ]] || fail 'A GRUB-based image is required.'
    local program
    for program in netplan update-grub ip systemctl python3 flock; do
        command -v "$program" >/dev/null || fail "Required command is missing: $program"
    done
    systemctl is-active --quiet systemd-networkd || fail 'This installer requires Netplan with systemd-networkd.'
    [[ -n "$(ip -4 route show default)" ]] || fail 'An IPv4 default route is required.'
    case "$(uname -m)" in
        x86_64|aarch64) ;;
        *) fail 'Supported architectures: x86_64 and aarch64.' ;;
    esac
    lock_setup
}

lock_setup() {
    [[ "$EUID" -eq 0 ]] || fail 'Run this script as root.'
    install -d -m 700 "$STATE_DIR"
    exec 9>"$STATE_DIR/setup.lock"
    flock -n 9 || fail 'Another setup process is running.'
    TEMP_DIR="$(mktemp -d /tmp/xray-setup.XXXXXXXX)"
}

install_packages() {
    apt-get -o Acquire::ForceIPv4=true update
    apt-get -o DPkg::Lock::Timeout=-1 -o Acquire::ForceIPv4=true install -y --no-install-recommends \
        nginx certbot curl ca-certificates python3 python3-yaml unzip openssl \
        dnsutils kmod cron nftables
}

configure_network() {
    local backup_dir sysctl_file
    backup_dir="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$backup_dir"
    cp -a /etc/netplan "$backup_dir/netplan"
    cp -a /etc/resolv.conf "$backup_dir/resolv.conf"
    install -d -m 755 /etc/cloud/cloud.cfg.d /etc/default/grub.d
    if [[ -f /var/lib/cloud/scripts/per-instance/002_onboot ]] && \
        grep -q 'netplan-ipv6-gw-jammy-nohook.sh' /var/lib/cloud/scripts/per-instance/002_onboot; then
        cp -a /var/lib/cloud/scripts/per-instance/002_onboot "$backup_dir/002_onboot"
        chmod 600 /var/lib/cloud/scripts/per-instance/002_onboot
        for sysctl_file in /etc/sysctl.d/99-no-ra-default-*.conf; do
            [[ -f "$sysctl_file" ]] || continue
            if ! grep -Ev '^[[:space:]]*(#|$|net\.ipv6\.)' "$sysctl_file" | grep -q .; then
                cp -a "$sysctl_file" "$backup_dir/"
                rm "$sysctl_file"
            fi
        done
    fi
    printf 'network:\n  config: disabled\nmanage_resolv_conf: false\n' \
        > /etc/cloud/cloud.cfg.d/99-xray-network.cfg
    chmod 644 /etc/cloud/cloud.cfg.d/99-xray-network.cfg
    python3 - <<'PY'
import ipaddress
from pathlib import Path
import yaml

resolvers = ["8.8.8.8", "8.8.4.4", "1.1.1.1"]
paths = sorted(Path("/etc/netplan").glob("*.yaml"))
if not paths:
    raise SystemExit("No Netplan configuration found.")

def ipv6(value):
    try:
        return ipaddress.ip_interface(str(value)).version == 6
    except ValueError:
        return False

changes = []
for path in paths:
    data = yaml.safe_load(path.read_text()) or {}
    network = data.get("network", {})
    if network.get("renderer", "networkd") != "networkd":
        raise SystemExit("Only the networkd renderer is supported.")
    for section in ("ethernets", "bonds", "bridges", "vlans", "wifis"):
        for device in network.get(section, {}).values():
            if device.get("renderer", "networkd") != "networkd":
                raise SystemExit("Only the networkd renderer is supported.")
            device["dhcp6"] = False
            device["accept-ra"] = False
            device["link-local"] = ["ipv4"]
            for key in ("gateway6", "ipv6-address-generation", "ipv6-address-token", "ipv6-privacy", "ra-overrides", "dhcp6-overrides"):
                device.pop(key, None)
            if "addresses" in device:
                device["addresses"] = [address for address in device["addresses"] if not ipv6(next(iter(address)) if isinstance(address, dict) else address)]
            if "routes" in device:
                device["routes"] = [route for route in device["routes"] if not any(ipv6(route.get(key, "")) for key in ("to", "via", "from"))]
            if "routing-policy" in device:
                device["routing-policy"] = [rule for rule in device["routing-policy"] if not any(ipv6(rule.get(key, "")) for key in ("to", "from"))]
            if device.get("dhcp4"):
                overrides = device.setdefault("dhcp4-overrides", {})
                overrides["use-dns"] = False
                overrides["use-domains"] = False
            device["nameservers"] = {"addresses": resolvers}
    changes.append((path, yaml.safe_dump(data, sort_keys=False)))
for path, text in changes:
    path.write_text(text)
    path.chmod(0o600)
PY
    if ! netplan generate; then
        cp -a "$backup_dir/netplan/." /etc/netplan/
        fail 'Netplan validation failed; the original Netplan files were restored.'
    fi
    netplan apply
    if [[ "$(systemctl show systemd-resolved -p LoadState --value)" != not-found ]]; then
        systemctl disable --now systemd-resolved
        systemctl mask systemd-resolved
    fi
    rm -f /etc/resolv.conf
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\noptions timeout:1 attempts:2\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    cat > /etc/sysctl.d/99-xray-ipv4.conf <<'EOF'
-net.ipv6.conf.all.disable_ipv6=1
-net.ipv6.conf.default.disable_ipv6=1
EOF
    chmod 644 /etc/sysctl.d/99-xray-ipv4.conf
    if [[ -d /proc/sys/net/ipv6 ]]; then
        sysctl -p /etc/sysctl.d/99-xray-ipv4.conf
    fi
    cat > /etc/default/grub.d/99-xray-ipv4.cfg <<'EOF'
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:-} ipv6.disable=1"
EOF
    chmod 644 /etc/default/grub.d/99-xray-ipv4.cfg
    update-grub
    ip -4 route get 8.8.8.8 >/dev/null
    getent ahostsv4 github.com >/dev/null
    [[ -z "$(ip -6 -o address show)" ]] || fail 'IPv6 addresses are still present.'
    [[ "$(awk '/^nameserver / {print $2}' /etc/resolv.conf)" == $'8.8.8.8\n8.8.4.4\n1.1.1.1' ]] || fail 'Unexpected DNS servers in resolv.conf.'
}

check_domain_dns() {
    local records
    records="$(dig +time=1 +tries=1 +noall +answer A "$PROJECT_DOMAIN" | awk '$4 == "A" {print $5}')"
    [[ -n "$records" ]] || fail "No public A record found for $PROJECT_DOMAIN."
    records="$(dig +time=1 +tries=1 +noall +answer AAAA "$PROJECT_DOMAIN" | awk '$4 == "AAAA" {print $5}')"
    [[ -z "$records" ]] || fail 'Remove the domain AAAA record before using this IPv4-only server.'
}

latest_version() {
    curl -4 --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 60 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$TEMP_DIR/release.json"
    XRAY_VERSION="$(python3 - "$TEMP_DIR/release.json" <<'PY'
import json
import re
import sys

release = json.load(open(sys.argv[1]))
tag = release.get("tag_name", "")
if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
    raise SystemExit("Invalid stable release metadata.")
print(tag[1:])
PY
    )"
}

download_xray() {
    local arch archive expected
    case "$(uname -m)" in
        x86_64) arch=64 ;;
        aarch64) arch=arm64-v8a ;;
    esac
    archive="Xray-linux-$arch.zip"
    curl -4 --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 300 \
        "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/$archive" -o "$TEMP_DIR/$archive"
    curl -4 --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 60 \
        "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/$archive.dgst" -o "$TEMP_DIR/$archive.dgst"
    expected="$(awk '$1 == "SHA2-256=" {print $2}' "$TEMP_DIR/$archive.dgst")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'The release has no valid SHA-256 checksum.'
    printf '%s  %s\n' "$expected" "$TEMP_DIR/$archive" | sha256sum -c -
    unzip -qo "$TEMP_DIR/$archive" -d "$TEMP_DIR/xray"
    [[ "$("$TEMP_DIR/xray/xray" version | awk 'NR == 1 {print $2}')" == "$XRAY_VERSION" ]] || fail 'The binary version does not match the release.'
    install -d -m 755 "$RELEASE_ROOT/releases/$XRAY_VERSION"
    install -m 755 "$TEMP_DIR/xray/xray" "$RELEASE_ROOT/releases/$XRAY_VERSION/xray"
    install -m 644 "$TEMP_DIR/xray/geoip.dat" "$TEMP_DIR/xray/geosite.dat" "$RELEASE_ROOT/releases/$XRAY_VERSION/"
}

switch_release() {
    ln -s "$1" "$RELEASE_ROOT/current.next.$$" || return
    mv -Tf "$RELEASE_ROOT/current.next.$$" "$RELEASE_ROOT/current"
}

install_xray() {
    latest_version
    download_xray
    switch_release "$RELEASE_ROOT/releases/$XRAY_VERSION"
    install -d -m 755 /usr/local/bin /usr/local/share /usr/local/etc/xray
    ln -sfnT "$RELEASE_ROOT/current/xray" /usr/local/bin/xray
    ln -sfnT "$RELEASE_ROOT/current" /usr/local/share/xray
}

check_fallback() {
    local status
    status="$(curl -4 --noproxy '*' --silent --show-error --http2 --connect-timeout 2 --max-time 5 \
        --resolve "$PROJECT_DOMAIN:443:127.0.0.1" "https://$PROJECT_DOMAIN/" \
        -o "$TEMP_DIR/fallback.html" -w '%{http_code}')" || return
    [[ "$status" == 403 ]] && grep -q '<title>403 Forbidden</title>' "$TEMP_DIR/fallback.html"
}

wait_for_xray() {
    local attempt
    for ((attempt = 0; attempt < 10; attempt++)); do
        if systemctl is-active --quiet xray && check_fallback; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

restart_xray_checked() {
    systemctl reset-failed xray || return
    systemctl restart xray || return
    wait_for_xray
}

update_xray() {
    local installed previous candidate
    [[ -f "$STATE_DIR/domain" ]] || fail 'No installed domain found.'
    PROJECT_DOMAIN="$(cat "$STATE_DIR/domain")"
    validate_domain "$PROJECT_DOMAIN" || fail 'Invalid installed domain.'
    latest_version
    installed="$(/usr/local/bin/xray version | awk 'NR == 1 {print $2}')"
    if ! dpkg --compare-versions "$XRAY_VERSION" gt "$installed"; then
        printf 'Xray %s is current; no restart needed.\n' "$installed"
        return
    fi
    if [[ -f "$STATE_DIR/rejected-version" && "$(cat "$STATE_DIR/rejected-version")" == "$XRAY_VERSION" ]]; then
        fail "Xray $XRAY_VERSION failed an earlier update; waiting for a newer release."
    fi
    check_fallback || fail 'The current service is unhealthy; update cancelled.'
    previous="$(readlink -f "$RELEASE_ROOT/current")"
    [[ -x "$previous/xray" ]] || fail 'No working release available for rollback.'
    download_xray
    candidate="$RELEASE_ROOT/releases/$XRAY_VERSION"
    if ! XRAY_LOCATION_ASSET="$candidate" "$candidate/xray" run -test -config /usr/local/etc/xray/config.json; then
        printf '%s\n' "$XRAY_VERSION" > "$STATE_DIR/rejected-version"
        fail 'The new release rejected the configuration; the running service was not changed.'
    fi
    switch_release "$candidate"
    if restart_xray_checked; then
        rm -f "$STATE_DIR/rejected-version"
        printf 'Xray updated from %s to %s.\n' "$installed" "$XRAY_VERSION"
    else
        switch_release "$previous"
        printf '%s\n' "$XRAY_VERSION" > "$STATE_DIR/rejected-version"
        restart_xray_checked || fail 'Update and rollback failed; console access is required.'
        fail "Xray $XRAY_VERSION failed its health check; restored $installed."
    fi
}

configure_updates() {
    install -d -m 755 /usr/local/sbin
    install -m 700 "${BASH_SOURCE[0]}" /usr/local/sbin/xray-setup.new
    mv -f /usr/local/sbin/xray-setup.new /usr/local/sbin/xray-setup
    printf '%s\n' "$PROJECT_DOMAIN" > "$STATE_DIR/domain"
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n@daily root /usr/local/sbin/xray-setup --update 2>&1 | /usr/bin/logger -t xray-update\n' > /etc/cron.d/xray-update
    chmod 644 /etc/cron.d/xray-update
    systemctl enable --now cron
}

disable_unused_services() {
    local unit bridges
    if [[ -f /etc/udev/rules.d/99-os-vol-auto.rules ]]; then
        chmod 644 /etc/udev/rules.d/99-os-vol-auto.rules
    fi
    local -a units=(cloud-init-hotplugd.socket cloud-init-hotplugd.service uuidd.socket uuidd.service apt-listchanges.timer man-db.timer)
    if command -v ovs-vsctl >/dev/null && ! grep -rqE '^[[:space:]]*openvswitch:' /etc/netplan; then
        if bridges="$(ovs-vsctl --timeout=5 list-br 2>/dev/null)" && [[ -z "$bridges" ]]; then
            units+=(openvswitch-switch.service ovs-record-hostname.service ovs-vswitchd.service ovsdb-server.service)
        fi
    fi
    for unit in "${units[@]}"; do
        if [[ "$(systemctl show "$unit" -p LoadState --value)" != not-found ]]; then
            systemctl disable --now "$unit"
            systemctl mask "$unit"
        fi
    done
}

configure_nginx() {
    install -d -m 755 /var/www/xray-acme/.well-known/acme-challenge
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        rm /etc/nginx/sites-enabled/default
    fi
    cat > /etc/nginx/sites-available/xray <<EOF
server {
    listen 0.0.0.0:80;
    server_name $PROJECT_DOMAIN;
    access_log off;
    error_log /var/log/nginx/error.log crit;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/xray-acme;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
server {
    listen 127.0.0.1:8080;
    http2 on;
    server_name $PROJECT_DOMAIN;
    access_log off;
    error_log /var/log/nginx/error.log crit;
    location / {
        return 403;
    }
}
EOF
    chmod 644 /etc/nginx/sites-available/xray
    ln -sfn /etc/nginx/sites-available/xray /etc/nginx/sites-enabled/xray
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    local token
    token="$(cat /proc/sys/kernel/random/uuid)"
    printf '%s' "$token" > "/var/www/xray-acme/.well-known/acme-challenge/$token"
    chmod 644 "/var/www/xray-acme/.well-known/acme-challenge/$token"
    [[ "$(curl -4 --noproxy '*' --fail --silent --show-error --max-time 15 "http://$PROJECT_DOMAIN/.well-known/acme-challenge/$token")" == "$token" ]] || fail 'The domain does not reach this server on port 80.'
    rm "/var/www/xray-acme/.well-known/acme-challenge/$token"
}

obtain_certificate() {
    certbot certonly --webroot -w /var/www/xray-acme \
        --non-interactive --agree-tos --register-unsafely-without-email \
        --keep-until-expiring --cert-name "$PROJECT_DOMAIN" -d "$PROJECT_DOMAIN"
    systemctl enable --now certbot.timer
}

write_xray_config() {
    python3 - "$PROJECT_DOMAIN" "$VLESS_CLIENT_UUID" "$TEMP_DIR/config.json" <<'PY'
import json
from pathlib import Path
import sys

domain, client_id, target = sys.argv[1:]
config = {
    "log": {"loglevel": "none"},
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": 443,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": client_id, "flow": "xtls-rprx-vision"}],
            "decryption": "none",
            "fallbacks": [{"dest": "127.0.0.1:8080"}]
        },
        "streamSettings": {
            "network": "raw",
            "security": "tls",
            "tlsSettings": {
                "alpn": ["h2"],
                "certificates": [{
                    "certificateFile": f"/etc/letsencrypt/live/{domain}/fullchain.pem",
                    "keyFile": f"/etc/letsencrypt/live/{domain}/privkey.pem"
                }]
            }
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
    }],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "dns": {
        "servers": [
            {"address": address, "timeoutMs": 500}
            for addresses in (("8.8.8.8", "8.8.4.4"), ("1.1.1.1", "1.0.0.1"))
            for address in [*(f"https+local://{ip}/dns-query" for ip in addresses), *addresses]
        ],
        "queryStrategy": "UseIPv4"
    },
    "routing": {
        "rules": [
            {"type": "field", "domain": ["geosite:category-gov-ru", "domain:ru", "domain:xn--p1ai"], "outboundTag": "block"},
            {"type": "field", "ip": ["geoip:ru"], "outboundTag": "block"}
        ],
        "domainStrategy": "IPIfNonMatch"
    }
}
Path(target).write_text(json.dumps(config, indent=2) + "\n")
PY
    /usr/local/bin/xray run -test -config "$TEMP_DIR/config.json"
    install -m 600 "$TEMP_DIR/config.json" /usr/local/etc/xray/config.json
    cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
RestartSec=1
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/xray.service
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
}

configure_bbr() {
    modprobe tcp_bbr
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
    chmod 644 /etc/sysctl.d/99-bbr.conf
    sysctl -p /etc/sysctl.d/99-bbr.conf
}

configure_firewall() {
    cat > "$TEMP_DIR/nftables.conf" <<'EOF'
flush ruleset
table inet xray {
    chain input {
        type filter hook input priority filter; policy drop;
        meta nfproto ipv6 drop
        iifname "lo" accept
        ct state invalid drop
        ct state established,related accept
        udp sport 67 udp dport 68 accept
        icmp type { destination-unreachable, time-exceeded, parameter-problem, echo-request } accept
        tcp dport { 80, 443 } accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
        meta nfproto ipv6 drop
    }
}
EOF
    nft --check --file "$TEMP_DIR/nftables.conf"
    install -m 600 "$TEMP_DIR/nftables.conf" /etc/nftables.conf
    nft --file /etc/nftables.conf
    systemctl enable --now nftables
}

verify_installation() {
    local service
    for service in nginx xray certbot.timer cron nftables; do
        systemctl is-active --quiet "$service" || fail "Required service is inactive: $service"
        systemctl is-enabled --quiet "$service" || fail "Required service is disabled: $service"
    done
    nft list chain inet xray input | grep -F 'policy drop;' >/dev/null
    nft list chain inet xray forward | grep -F 'policy drop;' >/dev/null
    [[ -z "$(ip -6 -o address show)" ]] || fail 'IPv6 addresses are still present.'
    [[ "$(awk '/^nameserver / {print $2}' /etc/resolv.conf)" == $'8.8.8.8\n8.8.4.4\n1.1.1.1' ]] || fail 'Unexpected DNS servers.'
    [[ ! -L /etc/resolv.conf ]] || fail 'resolv.conf must be a static file.'
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'BBR is not active.'
    [[ "$(sysctl -n net.core.default_qdisc)" == fq ]] || fail 'The default qdisc is not fq.'
    wait_for_xray || fail 'The HTTPS fallback did not return the default Nginx 403 page with valid TLS.'
    if grep -qw 'ipv6.disable=1' /proc/cmdline; then
        [[ -n "$(ss -H -4 -ltn 'sport = :443')" ]] || fail 'Xray is not listening on IPv4 port 443.'
        [[ -z "$(ss -H -6 -lntup)" ]] || fail 'IPv6 listening sockets are still present.'
    else
        [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]] || fail 'Runtime IPv6 disable is missing.'
        [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" == 1 ]] || fail 'Runtime IPv6 disable is missing for new interfaces.'
    fi
    grep -q 'ipv6.disable=1' /boot/grub/grub.cfg || fail 'The persistent IPv6 disable setting is missing.'
}

print_client() {
    printf '\nUUID: %s\n' "$VLESS_CLIENT_UUID"
    printf '\nClient connection:\n'
    printf 'vless://%s@%s:443?flow=xtls-rprx-vision&security=tls&alpn=h2&fp=firefox\n' \
        "$VLESS_CLIENT_UUID" "$PROJECT_DOMAIN"
}

remove_ssh_and_reboot() {
    step 'Removing the SSH server'
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl stop sshd-unix-local.socket 2>/dev/null || true
    apt-get -o DPkg::Lock::Timeout=-1 purge -y openssh-server openssh-sftp-server
    install -d -m 755 /etc/systemd/system-generators
    ln -sfn /dev/null /etc/systemd/system-generators/systemd-ssh-generator
    systemctl mask ssh.service sshd.service ssh.socket sshd-unix-local.socket
    if dpkg-query -W -f='${db:Status-Status}\n' openssh-server 2>/dev/null | grep -qx installed; then
        fail 'The SSH server is still installed.'
    fi
    [[ -z "$(ss -H -ltn 'sport = :22')" ]] || fail 'Port 22 is still listening.'
    printf '\nSetup verified. SSH removed. Rebooting in 10 seconds.\n'
    systemd-run --unit=xray-setup-reboot --on-active=10s /usr/bin/systemctl reboot
    print_client
}

main() {
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == --update ) ]] || fail 'Usage: setup.sh [--update]'
    if [[ "${1:-}" == --update ]]; then
        lock_setup
        update_xray
        return
    fi
    preflight
    ask_inputs
    step 'Installing packages'
    install_packages
    step 'Configuring IPv4-only networking and DNS'
    configure_network
    configure_bbr
    check_domain_dns
    step 'Downloading and verifying Xray'
    install_xray
    step 'Configuring Nginx and checking the ACME path'
    configure_nginx
    step 'Obtaining the TLS certificate'
    obtain_certificate
    step 'Writing and starting the Xray configuration'
    write_xray_config
    configure_updates
    step 'Disabling unused services'
    disable_unused_services
    step 'Allowing inbound HTTP and HTTPS only'
    configure_firewall
    step 'Verifying the installation before removing SSH'
    verify_installation
    print_client
    remove_ssh_and_reboot
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
