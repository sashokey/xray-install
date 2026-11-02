#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
declare -a PIDS=()

finish() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    nginx -s quit 2>/dev/null || true
    rm -rf -- "$WORK"
}

systemctl() {
    if [[ "$1" == restart && "$2" == nginx ]]; then
        if [[ -s /run/nginx.pid ]] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then
            nginx -s reload
        else
            nginx
        fi
    fi
}

source "$ROOT/setup.sh"
trap finish EXIT
TEMP_DIR="$WORK"
PROJECT_DOMAIN=main.example
VLESS_CLIENT_UUID=01234567-89ab-cdef-0123-456789abcdef
install_xray
printf '127.0.0.1 main.example slave.example\n' >> /etc/hosts
install -d -m 755 /etc/letsencrypt/live/main.example /etc/letsencrypt/live/slave.example
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=main.example \
    -addext subjectAltName=DNS:main.example,DNS:slave.example \
    -addext basicConstraints=critical,CA:TRUE \
    -keyout "$WORK/test-key.pem" -out "$WORK/test-cert.pem" 2>/dev/null
for domain in main.example slave.example; do
    install -m 600 "$WORK/test-key.pem" "/etc/letsencrypt/live/$domain/privkey.pem"
    install -m 644 "$WORK/test-cert.pem" "/etc/letsencrypt/live/$domain/fullchain.pem"
done
export CURL_CA_BUNDLE="$WORK/test-cert.pem"
configure_nginx
write_xray_config
cp /usr/local/etc/xray/config.json "$WORK/main.json"
python3 - "$WORK/main.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
config = json.loads(path.read_text())
config['log']['loglevel'] = 'debug'
path.write_text(json.dumps(config))
PY
print_client > "$WORK/main-link.txt"
/usr/local/bin/xray run -config "$WORK/main.json" > "$WORK/main.log" 2>&1 &
MAIN_PID=$!
PIDS+=("$MAIN_PID")
healthy=false
for attempt in {1..30}; do
    if check_fallback; then
        healthy=true
        break
    fi
    sleep 0.2
done
[[ "$healthy" == true ]]
printf 'Verified: real Nginx ACME path and Xray HTTPS fallback return the expected result.\n'

source "$ROOT/setup-proxy.sh"
trap finish EXIT
TEMP_DIR="$WORK"
PROJECT_DOMAIN=slave.example
VLESS_CLIENT_UUID=01234567-89ab-cdef-0123-456789abcdef
MAIN_LINK="$(grep '^vless://' "$WORK/main-link.txt")"
parse_main_link "$WORK/main-outbound.json" 3<<< "$MAIN_LINK"
write_xray_config
cp /usr/local/etc/xray/config.json "$WORK/slave.json"
print_client > "$WORK/slave-link.txt"
PROJECT_DOMAIN=client.example
SLAVE_LINK="$(grep '^vless://' "$WORK/slave-link.txt")"
parse_main_link "$WORK/client-outbound.json" 3<<< "$SLAVE_LINK"
python3 - "$WORK" <<'PY'
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
slave = json.loads((directory / 'slave.json').read_text())
slave['inbounds'][0]['listen'] = '127.0.0.1'
slave['inbounds'][0]['port'] = 2443
slave['log']['loglevel'] = 'debug'
trust = [{'certificateFile': str(directory / 'test-cert.pem'), 'usage': 'verify'}]
slave['outbounds'][0]['streamSettings']['tlsSettings']['certificates'] = trust
(directory / 'slave.json').write_text(json.dumps(slave))
outbound = json.loads((directory / 'client-outbound.json').read_text())
outbound['settings']['vnext'][0]['port'] = 2443
outbound['streamSettings']['tlsSettings']['certificates'] = trust
client = {'log': {'loglevel': 'debug'}, 'inbounds': [{'listen': '127.0.0.1', 'port': 10808, 'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': False}}], 'outbounds': [outbound]}
(directory / 'client.json').write_text(json.dumps(client))
(directory / 'site').mkdir()
(directory / 'site' / 'success').write_text('integration-ok')
PY
/usr/local/bin/xray run -test -config "$WORK/slave.json"
/usr/local/bin/xray run -test -config "$WORK/client.json"
/usr/local/bin/xray run -config "$WORK/slave.json" > "$WORK/slave.log" 2>&1 &
SLAVE_PID=$!
PIDS+=("$SLAVE_PID")
/usr/local/bin/xray run -config "$WORK/client.json" > "$WORK/client.log" 2>&1 &
PIDS+=("$!")
python3 -m http.server --bind 127.0.0.1 --directory "$WORK/site" 18080 > "$WORK/target.log" 2>&1 &
PIDS+=("$!")
passed=false
for attempt in {1..5}; do
    if body="$(curl --silent --show-error --fail --max-time 3 --noproxy '' --socks5-hostname 127.0.0.1:10808 http://127.0.0.1:18080/success 2>/dev/null)" && [[ "$body" == integration-ok ]]; then
        passed=true
        break
    fi
    sleep 0.2
done
if [[ "$passed" != true ]]; then
    curl --verbose --max-time 4 --noproxy '' --socks5-hostname 127.0.0.1:10808 http://127.0.0.1:18080/success || true
    cat "$WORK/main.log" "$WORK/slave.log" "$WORK/client.log" >&2
    exit 1
fi
kill "$SLAVE_PID"
wait "$SLAVE_PID" 2>/dev/null || true
if curl --silent --fail --max-time 4 --noproxy '' --socks5-hostname 127.0.0.1:10808 http://127.0.0.1:18080/success >/dev/null; then
    printf 'The client unexpectedly bypassed the stopped slave.\n' >&2
    exit 1
fi
printf 'Verified: real TLS/VLESS client -> slave -> main -> HTTP target, and stopping the slave breaks the route.\n'
