import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH_BIN', shutil.which('bash') or '/bin/bash')
UUID = '01234567-89ab-cdef-0123-456789abcdef'
MODERN_BASH = int(subprocess.check_output([BASH, '-c', 'printf %s "${BASH_VERSINFO[0]}"'], text=True)) >= 5
if os.environ.get('CI') and not MODERN_BASH:
    raise RuntimeError('CI requires the supported Debian 13 Bash 5 runtime.')


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='xray-tests-')
        self.addCleanup(self.work.cleanup)
        self.directory = Path(self.work.name)

    def run_function(self, installer, body, *args, stdin=None):
        script = 'source "$1"\ntrap - EXIT ERR\nTEMP_DIR="$2"\n' + body
        return subprocess.run([BASH, '-c', script, 'test', str(ROOT / installer), str(self.directory), *args], input=stdin, text=True, capture_output=True, timeout=15)

    def parse(self, link):
        result = self.run_function('setup-proxy.sh', 'PROJECT_DOMAIN=slave.example\nparse_main_link "$TEMP_DIR/outbound.json" 3<<< "$3"', link)
        target = self.directory / 'outbound.json'
        return result, json.loads(target.read_text()) if target.exists() else None

    def test_sourcing_installers_does_not_run_setup(self):
        for installer in ['setup.sh', 'setup-proxy.sh']:
            with self.subTest(installer=installer):
                result = self.run_function(installer, 'printf ready')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'ready')
                self.assertEqual(list(self.directory.iterdir()), [])

    @unittest.skipUnless(MODERN_BASH, 'Domain and interactive input checks require the supported Debian Bash 5 runtime')
    def test_domain_validation_accepts_only_dns_labels(self):
        for installer in ['setup.sh', 'setup-proxy.sh']:
            for domain, valid in [('main.example', True), ('one-two.example', True), ('xn--bcher-kva.example', True), ('localhost', False), ('a..example', False), ('-a.example', False), ('a-.example', False), ('https://main.example', False), ('a.example/path', False), ('a.123', False), ('a' * 64 + '.example', False)]:
                with self.subTest(installer=installer, domain=domain):
                    result = self.run_function(installer, 'if validate_domain "$3"; then printf valid; else printf invalid; fi', domain)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, 'valid' if valid else 'invalid')

    @unittest.skipUnless(MODERN_BASH, 'Interactive input checks require the supported Debian Bash 5 runtime')
    def test_main_input_rejects_repeated_trailing_domain_dots(self):
        result = self.run_function('setup.sh', 'ask_inputs\nprintf "DOMAIN=%s\\nUUID=%s\\n" "$PROJECT_DOMAIN" "$VLESS_CLIENT_UUID"', stdin='main.example..\nmain.example\nn\n' + UUID + '\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DOMAIN=main.example\n', result.stdout)
        self.assertNotIn('DOMAIN=main.example.\n', result.stdout)

    @unittest.skipUnless(MODERN_BASH, 'Interactive input checks require the supported Debian Bash 5 runtime')
    def test_proxy_input_rejects_repeated_trailing_domain_dots(self):
        link = 'vless://' + UUID + '@main.example:443?security=tls&flow=xtls-rprx-vision&alpn=h2&fp=firefox'
        result = self.run_function('setup-proxy.sh', 'ask_inputs\nprintf "DOMAIN=%s\\n" "$PROJECT_DOMAIN"', stdin='slave.example..\nslave.example\nn\n' + UUID + '\n' + link + '\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DOMAIN=slave.example\n', result.stdout)
        self.assertNotIn('DOMAIN=slave.example.\n', result.stdout)

    def test_uuid_validation_rejects_malformed_identity(self):
        for installer in ['setup.sh', 'setup-proxy.sh']:
            for value, valid in [(UUID, True), (UUID.upper(), True), (UUID + '-extra', False), (UUID.replace('-', ''), False), ('not-a-uuid', False)]:
                with self.subTest(installer=installer, value=value):
                    result = self.run_function(installer, 'if validate_uuid "$3"; then printf valid; else printf invalid; fi', value)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, 'valid' if valid else 'invalid')

    def test_printed_main_link_round_trips_into_the_proxy_outbound(self):
        result = self.run_function('setup.sh', 'PROJECT_DOMAIN=main.example\nVLESS_CLIENT_UUID="$3"\nprint_client', UUID)
        self.assertEqual(result.returncode, 0, result.stderr)
        link = next(line for line in result.stdout.splitlines() if line.startswith('vless://'))
        uri = urlsplit(link)
        self.assertEqual((uri.username, uri.hostname, uri.port), (UUID, 'main.example', 443))
        self.assertEqual(parse_qs(uri.query), {'flow': ['xtls-rprx-vision'], 'security': ['tls'], 'alpn': ['h2'], 'fp': ['firefox']})
        parsed, outbound = self.parse(link)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        self.assertEqual(outbound['settings']['vnext'], [{'address': 'main.example', 'port': 443, 'users': [{'id': UUID, 'encryption': 'none', 'flow': 'xtls-rprx-vision'}]}])
        self.assertEqual(outbound['streamSettings']['tlsSettings'], {'serverName': 'main.example', 'alpn': ['h2'], 'fingerprint': 'firefox', 'allowInsecure': False})
        self.assertEqual(outbound['mux'], {'enabled': False})

    def test_proxy_link_accepts_explicit_sni_alpn_and_ipv4_address(self):
        result, outbound = self.parse('vless://' + UUID.upper() + '@192.0.2.10:8443?security=tls&flow=xtls-rprx-vision&type=raw&sni=MAIN.EXAMPLE.&alpn=h2%2Chttp%2F1.1&fp=chrome')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outbound['settings']['vnext'][0]['address'], '192.0.2.10')
        self.assertEqual(outbound['settings']['vnext'][0]['port'], 8443)
        self.assertEqual(outbound['settings']['vnext'][0]['users'][0]['id'], UUID)
        self.assertEqual(outbound['streamSettings']['tlsSettings'], {'serverName': 'main.example', 'alpn': ['h2', 'http/1.1'], 'fingerprint': 'chrome', 'allowInsecure': False})

    def test_proxy_link_rejects_repeated_trailing_hostname_dots(self):
        for host, sni in [('main.example..', ''), ('main.example...', ''), ('main.example', '&sni=main.example..')]:
            with self.subTest(host=host, sni=sni):
                target = self.directory / 'outbound.json'
                if target.exists():
                    target.unlink()
                result, outbound = self.parse('vless://' + UUID + '@' + host + ':443?security=tls&flow=xtls-rprx-vision' + sni)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(outbound)

    def test_proxy_link_rejects_invalid_or_unsupported_connections(self):
        base = 'vless://' + UUID + '@main.example:443?security=tls&flow=xtls-rprx-vision'
        links = [base.replace('vless:', 'https:'), base.replace(UUID, 'invalid'), base.replace(':443?', ':0?'), base.replace(':443?', ':65536?'), base + '&security=tls', base + '&allowInsecure=1', base + '&type=ws', base + '&unknown=value', base.replace('security=tls', 'security=none'), base.replace('xtls-rprx-vision', 'none'), base + '&sni=bad%ZZ', base + '&alpn=h3', base.replace('main.example', 'slave.example'), base.replace('main.example', '-bad.example')]
        for link in links:
            with self.subTest(link=link):
                target = self.directory / 'outbound.json'
                if target.exists():
                    target.unlink()
                result, outbound = self.parse(link)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(outbound)
                self.assertIn('ERROR:', result.stderr)

    def test_generated_configs_keep_tls_fallback_and_selected_outbound(self):
        for installer in ['setup.sh', 'setup-proxy.sh']:
            with self.subTest(installer=installer):
                main = {'tag': 'main', 'protocol': 'vless', 'settings': {'vnext': [{'address': 'main.example', 'port': 443, 'users': [{'id': UUID, 'encryption': 'none', 'flow': 'xtls-rprx-vision'}]}]}}
                (self.directory / 'main-outbound.json').write_text(json.dumps(main))
                result = self.run_function(installer, 'PROJECT_DOMAIN=slave.example\nVLESS_CLIENT_UUID="$3"\npython3() { command python3 "$@"; return 91; }\nwrite_xray_config', UUID)
                self.assertEqual(result.returncode, 91, result.stderr)
                config = json.loads((self.directory / 'config.json').read_text())
                inbound = config['inbounds'][0]
                self.assertEqual((inbound['listen'], inbound['port'], inbound['protocol']), ('0.0.0.0', 443, 'vless'))
                self.assertEqual(inbound['settings'], {'clients': [{'id': UUID, 'flow': 'xtls-rprx-vision'}], 'decryption': 'none', 'fallbacks': [{'dest': '127.0.0.1:8080'}]})
                self.assertEqual(inbound['streamSettings']['tlsSettings']['certificates'], [{'certificateFile': '/etc/letsencrypt/live/slave.example/fullchain.pem', 'keyFile': '/etc/letsencrypt/live/slave.example/privkey.pem'}])
                self.assertEqual(inbound['streamSettings']['tlsSettings']['alpn'], ['h2'])
                self.assertEqual(config['dns']['queryStrategy'], 'UseIPv4')
                self.assertEqual(config['routing']['rules'], [])
                self.assertEqual(config['outbounds'], [main] if installer == 'setup-proxy.sh' else [{'protocol': 'freedom', 'tag': 'direct', 'settings': {'domainStrategy': 'UseIPv4'}}])

    def test_latest_version_rejects_unstable_or_malformed_metadata(self):
        for installer in ['setup.sh', 'setup-proxy.sh']:
            for metadata, expected in [({'tag_name': 'v26.10.1', 'draft': False, 'prerelease': False}, '26.10.1'), ({'tag_name': 'v26.10.1', 'draft': True}, None), ({'tag_name': 'v26.10.1', 'prerelease': True}, None), ({'tag_name': 'nightly'}, None)]:
                with self.subTest(installer=installer, metadata=metadata):
                    result = self.run_function(installer, 'metadata="$3"\ncurl() { printf %s "$metadata" > "$TEMP_DIR/release.json"; }\nlatest_version\nprintf "VERSION=%s" "$XRAY_VERSION"', json.dumps(metadata))
                    if expected:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, 'VERSION=' + expected)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn('VERSION=', result.stdout)


if __name__ == '__main__':
    unittest.main()
