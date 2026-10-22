#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export XRAY_LOCATION_ASSET=/usr/local/share/xray

XRAY_VERSION=""
RELEASE_ROOT="/usr/local/lib/xray"
STATE_DIR="/var/lib/xray-proxy-setup"
PROJECT_DOMAIN=""
VLESS_CLIENT_UUID=""
TEMP_DIR=""
NETWORK_BACKEND=""

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
    local choice main_link
    while true; do
        read -r -p 'Enter slave domain: ' PROJECT_DOMAIN || fail 'Input closed.'
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
    while true; do
        read -r -s -p 'Enter main VLESS link (hidden): ' main_link || fail 'Input closed.'
        printf '\n'
        if parse_main_link "$TEMP_DIR/main-outbound.json" 3<<< "$main_link"; then
            unset main_link
            break
        fi
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
    for program in update-grub ip systemctl python3 flock; do
        command -v "$program" >/dev/null || fail "Required command is missing: $program"
    done
    if command -v netplan >/dev/null && systemctl is-active --quiet systemd-networkd; then
        NETWORK_BACKEND=netplan
    elif command -v ifquery >/dev/null && systemctl is-active --quiet networking && [[ -f /etc/network/interfaces ]]; then
        NETWORK_BACKEND=ifupdown
    else
        fail 'An active ifupdown or Netplan/systemd-networkd configuration is required.'
    fi
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
    local -a packages=(nginx certbot curl ca-certificates python3 unzip openssl dnsutils kmod cron nftables)
    if [[ "$NETWORK_BACKEND" == netplan ]]; then
        packages+=(python3-yaml)
    fi
    apt-get -o Acquire::ForceIPv4=true update
    apt-get -o DPkg::Lock::Timeout=-1 -o Acquire::ForceIPv4=true install -y --no-install-recommends \
        "${packages[@]}"
}

remove_unused_packages() {
    local package
    local -a selected=()
    local -a candidates=(
        apt-listchanges bash-completion debian-faq doc-debian installation-report laptop-detect
        inetutils-telnet netcat-traditional reportbug python3-reportbug tasksel tasksel-data task-english
        man-db manpages groff-base ispell iamerican ibritish ienglish-common wamerican
        dictionaries-common emacsen-common vim vim-common vim-runtime vim-tiny
        xauth xdg-user-dirs wget haveged
    )
    if [[ "$NETWORK_BACKEND" == ifupdown ]]; then
        candidates+=(dhcpcd-base python3-yaml)
    fi
    for package in "${candidates[@]}"; do
        if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" == installed ]]; then
            selected+=("$package")
        fi
    done
    [[ ${#selected[@]} -gt 0 ]] || return 0
    LC_ALL=C apt-get -s --auto-remove purge -- "${selected[@]}" > "$TEMP_DIR/cleanup-plan"
    while read -r package; do
        case "$package" in
            apt|dpkg|bash|coreutils|systemd*|udev|dbus*|linux-*|grub*|initramfs-*|ifupdown|netplan.io|iproute2|openssh-*|qemu-guest-agent|console-setup*|keyboard-configuration|nano|nginx*|certbot|python3|python3-minimal|curl|ca-certificates|unzip|openssl|dnsutils|bind9-dnsutils|kmod|cron*|nftables)
                fail "Package cleanup would remove a required component: $package"
                ;;
        esac
    done < <(awk '$1 == "Remv" || $1 == "Purg" {print $2}' "$TEMP_DIR/cleanup-plan")
    apt-get -o DPkg::Lock::Timeout=-1 --auto-remove purge -y -- "${selected[@]}"
    for package in "${selected[@]}"; do
        if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" == installed ]]; then
            fail "An unused package is still installed: $package"
        fi
    done
}

configure_ifupdown() {
    python3 - /etc/network/interfaces "$TEMP_DIR/ifupdown.validation" <<'PY'
import glob
import re
import shlex
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
validation = Path(sys.argv[2])
contents = {}
pending = [root]

def words(line):
    text = line.strip()
    if not text or text.startswith('#'):
        return []
    first = text.split(None, 1)[0]
    if first in ('source', 'source-directory', 'iface', 'auto', 'mapping') or first.startswith('allow-'):
        return shlex.split(text, comments=True)
    return [first]

while pending:
    path = pending.pop(0).resolve()
    if path in contents:
        continue
    if not path.is_relative_to(root.parent):
        raise SystemExit('ERROR: ifupdown include files must stay inside /etc/network.')
    text = path.read_text(encoding='utf-8')
    contents[path] = text
    for line in text.splitlines():
        tokens = words(line)
        if not tokens or tokens[0] not in ('source', 'source-directory'):
            continue
        for pattern in tokens[1:]:
            pattern = str(path.parent / pattern) if not Path(pattern).is_absolute() else pattern
            for match in sorted(glob.glob(pattern)):
                entry = Path(match)
                if tokens[0] == 'source-directory' and entry.is_dir():
                    pending.extend(child for child in sorted(entry.iterdir()) if child.is_file() and re.fullmatch(r'[A-Za-z0-9_-]+', child.name))
                elif tokens[0] == 'source' and entry.is_file():
                    pending.append(entry)

families = {}
for text in contents.values():
    for line in text.splitlines():
        tokens = words(line)
        if tokens and tokens[0] == 'iface':
            if len(tokens) < 4:
                raise SystemExit('ERROR: Invalid ifupdown interface definition.')
            families.setdefault(tokens[1], set()).add(tokens[2])
            if tokens[2] == 'inet' and tokens[3] not in ('static', 'manual', 'loopback'):
                raise SystemExit('ERROR: This ifupdown image must use static IPv4; DHCP configurations require the Netplan backend.')
ipv6_only = {name for name, values in families.items() if values == {'inet6'}}
changes = {}
flattened = []

for path, text in contents.items():
    blocks = []
    for line in text.splitlines(keepends=True):
        tokens = words(line)
        begins = tokens and (tokens[0] in ('iface', 'source', 'source-directory', 'mapping', 'auto') or tokens[0].startswith('allow-'))
        if begins or not blocks:
            blocks.append([])
        blocks[-1].append(line)
    rewritten = []
    for block in blocks:
        tokens = words(block[0])
        if tokens and tokens[0] == 'iface':
            if tokens[2] == 'inet6':
                continue
            if tokens[2] == 'inet' and tokens[3] != 'loopback':
                block = [line for line in block if not re.match(r'^\s*dns-(?:nameservers|search|domain)\s', line)]
                while block and not block[-1].strip():
                    block.pop()
                block[-1] = block[-1].rstrip('\n') + '\n'
                block.append('    dns-nameservers 8.8.8.8 8.8.4.4 1.1.1.1\n\n')
        elif tokens and (tokens[0] == 'auto' or tokens[0].startswith('allow-')):
            names = [name for name in tokens[1:] if name not in ipv6_only]
            if names != tokens[1:]:
                block = ([tokens[0] + ' ' + ' '.join(names) + '\n'] if names else []) + block[1:]
        rewritten.extend(block)
        if tokens and tokens[0] in ('source', 'source-directory'):
            flattened.extend(block[1:])
        else:
            flattened.extend(block)
    changes[path] = ''.join(rewritten)

validation.write_text(''.join(flattened), encoding='utf-8')
check = subprocess.run(['ifquery', '--interfaces', str(validation), '--list'], text=True, capture_output=True)
if check.returncode:
    raise SystemExit('ERROR: ifquery rejected the configuration; original interface files were not changed.')
for path, text in changes.items():
    if text != contents[path]:
        path.write_text(text, encoding='utf-8')
PY
}

configure_network() {
    local backup_dir sysctl_file
    backup_dir="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$backup_dir"
    if [[ "$NETWORK_BACKEND" == netplan ]]; then
        cp -a /etc/netplan "$backup_dir/netplan"
    else
        cp -a /etc/network "$backup_dir/network"
    fi
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
    if [[ "$NETWORK_BACKEND" == netplan ]]; then
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
    else
        configure_ifupdown
    fi
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
    verify_chain || fail 'The current proxy chain is unhealthy; update cancelled.'
    previous="$(readlink -f "$RELEASE_ROOT/current")"
    [[ -x "$previous/xray" ]] || fail 'No working release available for rollback.'
    download_xray
    candidate="$RELEASE_ROOT/releases/$XRAY_VERSION"
    if ! XRAY_LOCATION_ASSET="$candidate" "$candidate/xray" run -test -config /usr/local/etc/xray/config.json; then
        printf '%s\n' "$XRAY_VERSION" > "$STATE_DIR/rejected-version"
        fail 'The new release rejected the configuration; the running service was not changed.'
    fi
    switch_release "$candidate"
    if restart_xray_checked && verify_chain; then
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
    install -m 700 "${BASH_SOURCE[0]}" /usr/local/sbin/xray-proxy-setup.new
    mv -f /usr/local/sbin/xray-proxy-setup.new /usr/local/sbin/xray-proxy-setup
    printf '%s\n' "$PROJECT_DOMAIN" > "$STATE_DIR/domain"
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n@daily root /usr/local/sbin/xray-proxy-setup --update 2>&1 | /usr/bin/logger -t xray-update\n' > /etc/cron.d/xray-update
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
    python3 - "$PROJECT_DOMAIN" "$VLESS_CLIENT_UUID" "$TEMP_DIR/main-outbound.json" "$TEMP_DIR/config.json" <<'PY'
import json
from pathlib import Path
import sys

domain, client_id, main_path, target = sys.argv[1:]
with open(main_path, encoding="utf-8") as source:
    main_outbound = json.load(source)
config = {
    "log": {"loglevel": "none"},
    "inbounds": [{
        "tag": "clients",
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
        main_outbound,
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
    if [[ "$NETWORK_BACKEND" == netplan ]]; then
        sed -i '/ct state established,related accept/a\        udp sport 67 udp dport 68 accept' "$TEMP_DIR/nftables.conf"
    fi
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
    apt-get -o DPkg::Lock::Timeout=-1 --auto-remove purge -y openssh-server openssh-sftp-server openssh-client
    install -d -m 755 /etc/systemd/system-generators
    ln -sfn /dev/null /etc/systemd/system-generators/systemd-ssh-generator
    systemctl mask ssh.service sshd.service ssh.socket sshd-unix-local.socket
    local package
    for package in openssh-server openssh-sftp-server openssh-client; do
        if dpkg-query -W -f='${db:Status-Status}\n' "$package" 2>/dev/null | grep -qx installed; then
            fail "An SSH package is still installed: $package"
        fi
    done
    [[ -z "$(ss -H -ltn 'sport = :22')" ]] || fail 'Port 22 is still listening.'
    printf '\nSetup verified. SSH removed. Rebooting in 10 seconds.\n'
    systemd-run --unit=xray-setup-reboot --on-active=10s /usr/bin/systemctl reboot
    print_client
}

parse_main_link() {
    python3 - "$1" "$PROJECT_DOMAIN" <<'PY'
import ipaddress
import json
import re
import sys
import uuid
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlsplit

def reject(message):
    raise ValueError(message)

def hostname(value):
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        labels = value.rstrip('.').lower().split('.')
        if len(value) > 253 or len(labels) < 2 or not re.search(r'[a-z]', labels[-1]):
            reject('Invalid main server hostname.')
        if any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels):
            reject('Invalid main server hostname.')
        return '.'.join(labels)

try:
    with open(3, encoding='utf-8', closefd=False) as source:
        link = source.read().strip()
    if len(link) > 8192 or re.search(r'\s', link) or re.search(r'%(?![0-9a-fA-F]{2})', link):
        reject('Invalid VLESS link encoding.')
    uri = urlsplit(link)
    if uri.scheme != 'vless' or not uri.username or not uri.hostname or uri.password is not None or uri.path not in ('', '/'):
        reject('Paste one complete vless:// link from setup.sh.')
    identity = unquote(uri.username, errors='strict')
    if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', identity):
        reject('The main link must contain a UUID.')
    identity = str(uuid.UUID(identity))
    address = hostname(uri.hostname)
    port = uri.port if uri.port is not None else 443
    if not 1 <= port <= 65535:
        reject('Invalid main server port.')
    pairs = parse_qsl(uri.query, keep_blank_values=True, strict_parsing=True, errors='strict', max_num_fields=32)
    params = dict(pairs)
    if len(params) != len(pairs):
        reject('Duplicate VLESS link parameters are not supported.')
    allowed = {'security', 'flow', 'alpn', 'fp', 'type', 'encryption', 'sni', 'headerType', 'allowInsecure'}
    if set(params) - allowed:
        reject('The link contains unsupported parameters. Use the TLS/Vision link from setup.sh.')
    if params.get('security') != 'tls' or params.get('flow') != 'xtls-rprx-vision':
        reject('Expected security=tls and flow=xtls-rprx-vision, as generated by setup.sh.')
    if params.get('type', 'tcp') not in ('tcp', 'raw') or params.get('headerType', 'none') != 'none':
        reject('Only TCP/RAW without an HTTP header is supported.')
    if params.get('encryption', 'none') != 'none' or params.get('allowInsecure', '0').lower() not in ('0', 'false'):
        reject('Use encryption=none and keep TLS certificate verification enabled.')
    server_name = hostname(params.get('sni', address))
    if address == sys.argv[2] and port == 443:
        reject('Main and slave must be different servers.')
    alpn = params.get('alpn', 'h2').split(',')
    if not alpn or any(value not in ('h2', 'http/1.1') for value in alpn):
        reject('Unsupported ALPN. Expected h2 or http/1.1.')
    fingerprint = params.get('fp', 'firefox')
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', fingerprint):
        reject('Invalid TLS fingerprint.')
    outbound = {
        'tag': 'main',
        'protocol': 'vless',
        'settings': {'vnext': [{
            'address': address, 'port': port,
            'users': [{'id': identity, 'encryption': 'none', 'flow': 'xtls-rprx-vision'}]
        }]},
        'streamSettings': {
            'network': 'raw', 'security': 'tls',
            'tlsSettings': {'serverName': server_name, 'alpn': alpn, 'fingerprint': fingerprint, 'allowInsecure': False}
        },
        'mux': {'enabled': False}
    }
    Path(sys.argv[1]).write_text(json.dumps(outbound, indent=2) + '\n', encoding='utf-8')
except (ValueError, UnicodeError) as error:
    print(f'ERROR: {error}', file=sys.stderr)
    sys.exit(1)
PY
}

probe_outbound() {
    python3 - "$1" "$2" "$TEMP_DIR" <<'PY'
import ipaddress
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

binary, source, parent = sys.argv[1:]
outbound = json.load(open(source, encoding='utf-8'))
with tempfile.TemporaryDirectory(prefix='probe-', dir=parent) as folder:
    folder = Path(folder)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    config = {
        'log': {'loglevel': 'error'},
        'inbounds': [{'listen': '127.0.0.1', 'port': port, 'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': False}}],
        'outbounds': [outbound]
    }
    path = folder / 'config.json'
    path.write_text(json.dumps(config), encoding='utf-8')
    path.chmod(0o600)
    process = None
    try:
        with (folder / 'xray.log').open('w+', encoding='utf-8') as log:
            subprocess.run([binary, 'run', '-test', '-config', str(path)], stdout=log, stderr=log, check=True, timeout=15)
            process = subprocess.Popen([binary, 'run', '-config', str(path)], stdout=log, stderr=log)
            for attempt in range(100):
                if process.poll() is not None:
                    raise RuntimeError('The temporary Xray client exited.')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError('The temporary Xray client did not start.')
            result = subprocess.run([
                'curl', '-4', '--fail', '--silent', '--show-error', '--noproxy', '',
                '--socks5-hostname', f'127.0.0.1:{port}', '--connect-timeout', '10', '--max-time', '25',
                'https://api.ipify.org'
            ], text=True, capture_output=True, timeout=30)
            if result.returncode:
                raise RuntimeError('The VLESS connection could not fetch https://api.ipify.org. Check main, TLS and connectivity.')
            address = ipaddress.ip_address(result.stdout.strip())
            if address.version != 4:
                raise RuntimeError('The main server did not return an IPv4 exit address.')
            print(address)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
PY
}

check_main_address() {
    python3 - "$TEMP_DIR/main-outbound.json" <<'PY'
import ipaddress
import json
import socket
import subprocess
import sys

with open(sys.argv[1], encoding='utf-8') as source:
    main = json.load(source)['settings']['vnext'][0]
try:
    addresses = {item[4][0] for item in socket.getaddrinfo(main['address'], main['port'], socket.AF_INET, socket.SOCK_STREAM)}
except OSError:
    raise SystemExit('ERROR: Main must resolve to a reachable IPv4 address.')
local = set()
for interface in json.loads(subprocess.check_output(['ip', '-j', '-4', 'address', 'show'])):
    local.update(address['local'] for address in interface.get('addr_info', []))
if addresses & local or any(ipaddress.ip_address(address).is_loopback for address in addresses):
    raise SystemExit('ERROR: The main address points to this slave; refusing a proxy loop.')
PY
}

prepare_probe_outbounds() {
    python3 - /usr/local/etc/xray/config.json "$PROJECT_DOMAIN" "$TEMP_DIR" <<'PY'
import json
import sys
from pathlib import Path

config_path, domain, folder = sys.argv[1:]
with open(config_path, encoding='utf-8') as source:
    config = json.load(source)
main = next(value for value in config['outbounds'] if value['tag'] == 'main')
inbound = next(value for value in config['inbounds'] if value.get('tag') == 'clients')
identity = inbound['settings']['clients'][0]['id']
slave = {
    'tag': 'slave', 'protocol': 'vless',
    'settings': {'vnext': [{'address': '127.0.0.1', 'port': inbound['port'], 'users': [
        {'id': identity, 'encryption': 'none', 'flow': 'xtls-rprx-vision'}
    ]}]},
    'streamSettings': {
        'network': 'raw', 'security': 'tls',
        'tlsSettings': {'serverName': domain, 'alpn': ['h2'], 'fingerprint': 'firefox', 'allowInsecure': False}
    },
    'mux': {'enabled': False}
}
for name, outbound in [('main', main), ('slave', slave)]:
    Path(folder, name + '-outbound.json').write_text(json.dumps(outbound, indent=2) + '\n', encoding='utf-8')
PY
}

verify_chain() {
    local direct_exit chained_exit
    prepare_probe_outbounds || return
    direct_exit="$(probe_outbound /usr/local/bin/xray "$TEMP_DIR/main-outbound.json")" || return
    chained_exit="$(probe_outbound /usr/local/bin/xray "$TEMP_DIR/slave-outbound.json")" || return
    [[ "$chained_exit" == "$direct_exit" ]] || { printf 'ERROR: Main and chained exit IPs differ.\n' >&2; return 1; }
    printf 'Verified client -> slave -> main.\n'
}

main() {
    [[ $# -eq 0 || ( $# -eq 1 && ( "$1" == --update || "$1" == --check ) ) ]] || fail 'Usage: setup-proxy.sh [--update | --check]'
    if [[ "${1:-}" == --update ]]; then
        lock_setup
        update_xray
        return
    fi
    if [[ "${1:-}" == --check ]]; then
        lock_setup
        [[ -f "$STATE_DIR/domain" ]] || fail 'No installed domain found.'
        PROJECT_DOMAIN="$(cat "$STATE_DIR/domain")"
        validate_domain "$PROJECT_DOMAIN" || fail 'Invalid installed domain.'
        verify_installation
        verify_chain || fail 'The proxy chain check failed.'
        return
    fi
    preflight
    ask_inputs
    step 'Installing packages'
    install_packages
    step 'Configuring IPv4-only networking and DNS'
    configure_network
    step 'Removing unused image packages'
    remove_unused_packages
    configure_bbr
    check_domain_dns
    check_main_address
    step 'Downloading and verifying Xray'
    install_xray
    step 'Checking the main VLESS connection before requesting a certificate'
    probe_outbound /usr/local/bin/xray "$TEMP_DIR/main-outbound.json" >/dev/null || fail 'The main VLESS connection failed; no certificate was requested.'
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
    verify_chain || fail 'The proxy chain check failed; SSH removal and reboot cancelled.'
    print_client
    remove_ssh_and_reboot
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
