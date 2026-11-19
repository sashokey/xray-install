import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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

    def test_nginx_packages_can_be_configured_with_kernel_ipv6_disabled(self):
        body = r'''
NETWORK_BACKEND=ifupdown
definition="$(declare -f install_packages; declare -f prepare_nginx_package || :)"
definition="${definition//\/etc\/nginx/$TEMP_DIR/nginx}"
definition="${definition//\/proc\/sys\/net\/ipv6/$TEMP_DIR/kernel-ipv6}"
eval "$definition"
apt-get() {
    case " $* " in
        *' install '*) [[ "$(readlink "$TEMP_DIR/nginx/sites-enabled/default")" == /dev/null ]] ;;
    esac
}
install_packages
'''
        for installer in ['setup.sh', 'setup-proxy.sh']:
            with self.subTest(installer=installer):
                result = self.run_function(installer, body)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_health_checks_leave_ssh_reachable(self):
        body = r'''
for function in preflight ask_inputs install_packages configure_network configure_bbr \
    check_domain_dns install_xray latest_version download_xray configure_nginx obtain_certificate write_xray_config \
    disable_unused_services remove_unused_packages check_main_address \
    probe_outbound validate_main_outbound print_client systemctl; do
    eval "$function() { :; }"
done
configure_firewall_and_updates() { touch "$TEMP_DIR/firewall-applied"; }
configure_updates() { touch "$TEMP_DIR/updates-configured"; }
verify_installation() { [[ "$failed_check" != service ]] || fail 'Unhealthy service.'; }
verify_chain() { [[ "$failed_check" != chain ]]; }
remove_ssh_and_reboot() { fail 'Unexpected SSH removal.'; }
main
'''
        for installer, check in [('setup.sh', 'service'), ('setup-proxy.sh', 'service'),
                                 ('setup-proxy.sh', 'chain')]:
            with self.subTest(installer=installer, check=check):
                result = self.run_function(installer, 'failed_check="$3"\n' + body, check)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn('Unexpected SSH removal.', result.stderr)
                self.assertFalse((self.directory / 'firewall-applied').exists())
                self.assertFalse((self.directory / 'updates-configured').exists())

    def test_ifupdown_preserves_directives_after_removed_ipv6_stanza(self):
        interfaces = self.directory / 'interfaces'
        interfaces.write_text(
            'iface eth0 inet6 \\\n'
            '    auto\n'
            'auto\n'
            '    privext 2\n'
            'rename ens3=eth0\n'
            'no-auto-down eth0\n'
            'no-scripts eth0\n'
            '# Do not continue this comment \\\n'
            'iface eth0 inet static\n'
            '    address 192.0.2.10/24\n'
            '    description Test interface \\\n'
            '    # Continued description text\n'
            '    dns-name\\\n'
            'servers 192.0.2.53\n'
            'iface eth0 inet6 auto\n'
            'auto ens4=ipv6alias\n'
            'iface ipv6alias inet6 auto\n'
        )
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\ntest "$1" = --interfaces && test -s "$2" && test "$3" = --list\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(interfaces.read_text().splitlines(), [
            'auto eth0', 'rename ens3=eth0', 'no-auto-down eth0', 'no-scripts eth0',
            '# Do not continue this comment \\',
            'iface eth0 inet static', '    address 192.0.2.10/24',
            '    description Test interface \\', '    # Continued description text',
            '    dns-nameservers 8.8.8.8 8.8.4.4 1.1.1.1', '',
        ])

    def test_ifupdown_validates_included_templates_before_their_use(self):
        (self.directory / 'interfaces').write_text(
            'source templates\\ with\\ spaces\n'
            'auto eth0\n'
            'iface eth0 inet inherits base\n'
            '    address 192.0.2.10/24\n'
        )
        (self.directory / 'templates with spaces').write_text('iface base inet6 auto\niface base inet static')
        ifquery = self.directory / 'ifquery'
        ifquery.write_text(
            '#!/usr/bin/env python3\n'
            'from pathlib import Path\n'
            'import shlex\n'
            'import sys\n'
            'assert sys.argv[1] == "--interfaces" and sys.argv[3:] == ["--list"]\n'
            'lines = Path(sys.argv[2]).read_text().splitlines()\n'
            'assert lines[0].startswith("source /")\n'
            'include = Path(shlex.split(lines[0])[1]).read_text()\n'
            'assert "iface base inet static" in include.splitlines()\n'
            'assert "iface eth0 inet inherits base" in lines\n'
        )
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ifupdown_keeps_original_files_on_include_diagnostics(self):
        interfaces = self.directory / 'interfaces'
        original = 'iface eth0 inet static\n    address 192.0.2.10/24\n'
        interfaces.write_text(original)
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\nprintf "Included file: misplaced option\\n" >&2\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(interfaces.read_text(), original)

    def test_ifupdown_validates_hotplug_selection_before_writing_files(self):
        interfaces = self.directory / 'interfaces'
        original = ('iface eth0 inet static\n    address 192.0.2.10/24\n'
                    'allow-hotplug /eth*\niface eth1 inet6 auto\n')
        interfaces.write_text(original)
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\ncase " $* " in *" --allow=hotplug "*) exit 1 ;; esac\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(interfaces.read_text(), original)

    def test_ifupdown_rejects_unresolved_mapping_for_an_activated_interface(self):
        interfaces = self.directory / 'interfaces'
        original = ('auto ens4=role\nmapping role\n    script /usr/local/sbin/fixture\n'
                    'iface eth0 inet static\n    address 192.0.2.10/24\niface wan6 inet6 auto\n')
        interfaces.write_text(original)
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\nprintf "ens4\\n"\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(interfaces.read_text(), original)

    def test_ifupdown_preserves_literal_mapping_patterns(self):
        interfaces = self.directory / 'interfaces'
        interfaces.write_text('auto ens4=role1\nmapping role\\*\n    script /usr/local/sbin/fixture\n'
                              'iface role1 inet static\n    address 192.0.2.10/24\niface wan6 inet6 auto\n')
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\nprintf "ens4\\n"\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mapping role\\*\n', interfaces.read_text())

    def test_ifupdown_uses_the_logical_alias_to_check_mappings(self):
        interfaces = self.directory / 'interfaces'
        interfaces.write_text('auto /ens*=role1\nmapping ens4\n    script /usr/local/sbin/fixture\n'
                              'iface role1 inet static\n    address 192.0.2.10/24\niface wan6 inet6 auto\n')
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\nprintf "ens4\\n"\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('auto /ens*=role1\n', interfaces.read_text())

    def test_ifupdown_keeps_an_original_selection_needed_for_mapping(self):
        interfaces = self.directory / 'interfaces'
        original = ('auto ens4\nmapping ens4\n    script /usr/local/sbin/fixture\n'
                    'iface role1 inet static\n    address 192.0.2.10/24\niface ens4 inet6 auto\n')
        interfaces.write_text(original)
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\nif grep -qx "auto ens4" "$2"; then printf "ens4\\n"; fi\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(interfaces.read_text(), original)

    def test_ifupdown_preserves_ipv4_selection_after_rename(self):
        interfaces = self.directory / 'interfaces'
        selector = '/@(ens4|eno1)' if sys.platform == 'linux' else '/ens*'
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\nexit 0\n')
        ifquery.chmod(0o700)
        for implicit, rename_source in ((False, selector), (True, selector), (True, 'ens4')):
            with self.subTest(implicit=implicit, rename_source=rename_source):
                declarations = f'rename ens4=ens4 {rename_source}=wan4\niface ens4 inet6 auto\n'
                declarations = declarations + '    auto\n' if implicit else 'auto ens4\n' + declarations
                interfaces.write_text(declarations + 'iface wan4 inet static\n    address 192.0.2.10/24\n')
                result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('auto ens4\n', interfaces.read_text())
                self.assertNotIn('inet6', interfaces.read_text())

    def test_ifupdown_keeps_ipv4_hotplug_when_removing_its_ipv6_alias(self):
        interfaces = self.directory / 'interfaces'
        interfaces.write_text('allow-hotplug ens4=wan6\niface ens4 inet static\n'
                              '    address 192.0.2.10/24\niface wan6 inet6 auto\n')
        ifquery = self.directory / 'ifquery'
        ifquery.write_text('#!/bin/sh\nexit 0\n')
        ifquery.chmod(0o700)
        result = self.run_function('setup-proxy.sh', '''
export PATH="$TEMP_DIR:$PATH"
python3() { command python3 - "$TEMP_DIR/interfaces" "$3"; }
configure_ifupdown
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('allow-hotplug ens4\n', interfaces.read_text())
        self.assertNotIn('inet6', interfaces.read_text())

    def test_dns_failure_is_distinct_from_an_absent_aaaa_record(self):
        body = '''
PROJECT_DOMAIN=server.example
dig() {
    case "$*" in
        *' A '*) printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\\nserver.example. 60 IN A 192.0.2.10\\n' ;;
        *' AAAA '*)
            printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 2\\n' "$aaaa_status"
            if [[ "$aaaa_status" == NOERROR && "$aaaa_present" == yes ]]; then
                printf 'server.example. 60 IN AAAA 2001:db8::10\\n'
            fi
            ;;
        *) return 98 ;;
    esac
}
aaaa_status="$3" aaaa_present="$4"
check_domain_dns
'''
        for installer in ['setup.sh', 'setup-proxy.sh']:
            for status, present, exit_code in [('NOERROR', 'no', 0), ('NOERROR', 'yes', 1),
                                               ('SERVFAIL', 'no', 1), ('NXDOMAIN', 'no', 1)]:
                with self.subTest(installer=installer, status=status, present=present):
                    result = self.run_function(installer, body, status, present)
                    self.assertEqual(result.returncode, exit_code, result.stderr)

    def test_slave_keeps_the_installed_cloud_init_yaml_dependency(self):
        body = r'''
NETWORK_BACKEND=ifupdown
dpkg-query() {
    case "$3" in
        cloud-init|python3-yaml) printf installed ;;
        *) return 1 ;;
    esac
}
apt-get() { printf 'Unexpected purge: %s\n' "$*"; return 97; }
remove_unused_packages
'''
        result = self.run_function('setup-proxy.sh', body)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_slave_rejects_an_incompatible_outbound_before_network_changes(self):
        result = self.run_function('setup-proxy.sh', r'''
preflight() { :; }
ask_inputs() { :; }
install_packages() { :; }
latest_version() { :; }
download_xray() { :; }
validate_main_outbound() { return 1; }
configure_network() { printf 'Network changes started.\n'; exit 97; }
main
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn('Network changes started.', result.stdout)

    def test_netplan_and_resolver_failures_restore_the_previous_configuration(self):
        body = r'''
NETWORK_BACKEND=netplan
STATE_DIR="$TEMP_DIR/state"
mkdir -p "$TEMP_DIR/etc" "$TEMP_DIR/netplan-config"
ln -s "$TEMP_DIR/netplan-config" "$TEMP_DIR/etc/netplan"
printf 'original\n' > "$TEMP_DIR/original.yaml"
ln -s "$TEMP_DIR/original.yaml" "$TEMP_DIR/etc/netplan/50-cloud.yaml"
printf 'resolvers\n' > "$TEMP_DIR/etc/resolv.conf"
definition="$(declare -f configure_network)"
definition="${definition//\/etc\//$TEMP_DIR/etc/}"
definition="${definition//\/var\/$TEMP_DIR/var/}"
eval "$definition"
python3() { printf 'rewritten\n' > "${2:-$TEMP_DIR/etc/netplan}/50-cloud.yaml"; }
netplan() {
    if [[ "$1" == apply ]]; then
        [[ "$failure" == dns ]] || grep -qx original "$TEMP_DIR/etc/netplan/50-cloud.yaml"
    fi
}
getent() { return 1; }
ip() { :; }
failure="$3"
configure_network
'''
        for installer in ['setup.sh', 'setup-proxy.sh']:
            for failure in ('apply', 'dns'):
                with self.subTest(installer=installer, failure=failure):
                    case_dir = self.directory / f'{installer}-{failure}'
                    case_dir.mkdir()
                    result = self.run_function(installer, 'TEMP_DIR="$TEMP_DIR/$4"\n' + body, failure, case_dir.name)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn('the original configuration was restored.', result.stderr)
                    self.assertTrue((case_dir / 'etc/netplan').is_symlink())
                    self.assertTrue((case_dir / 'etc/netplan/50-cloud.yaml').is_symlink())
                    self.assertEqual((case_dir / 'original.yaml').read_text(), 'original\n')
                    self.assertEqual((case_dir / 'etc/netplan/50-cloud.yaml').read_text(), 'original\n')
                    self.assertEqual((case_dir / 'etc/resolv.conf').read_text(), 'resolvers\n')
                    self.assertFalse((case_dir / 'etc/cloud/cloud.cfg.d/99-xray-network.cfg').exists())

    def test_ifupdown_write_failure_restores_original_files(self):
        result = self.run_function('setup-proxy.sh', r'''
NETWORK_BACKEND=ifupdown
STATE_DIR="$TEMP_DIR/state"
mkdir -p "$TEMP_DIR/etc/network"
printf 'original\n' > "$TEMP_DIR/etc/network/interfaces"
printf 'resolvers\n' > "$TEMP_DIR/etc/resolv.conf"
definition="$(declare -f configure_network)"
definition="${definition//\/etc\//$TEMP_DIR/etc/}"
definition="${definition//\/var\/$TEMP_DIR/var/}"
eval "$definition"
configure_ifupdown() {
    printf 'partially changed\n' > "$TEMP_DIR/etc/network/interfaces"
    return 2
}
configure_network
''')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual((self.directory / 'etc/network/interfaces').read_text(), 'original\n')

    def test_firewall_verification_failure_restores_the_previous_rules_and_file(self):
        body = r'''
NETWORK_BACKEND=ifupdown
printf 'original firewall\n' > "$TEMP_DIR/firewall.conf"
definition="$(declare -f configure_firewall_and_updates)"
definition="${definition//\/etc\/nftables.conf/$TEMP_DIR/firewall.conf}"
eval "$definition"
systemctl() { :; }
configure_updates() { return 1; }
failure="$3"
nft() {
    case "$*" in
        '--check --file '*) ;;
        'list ruleset') printf 'original rules\n' ;;
        'list chain '*)
            [[ "$failure" == updates ]] && printf 'policy drop;\n'
            ;;
        '--file '*) cat "$2" > "$TEMP_DIR/active-rules" ;;
        *) return 97 ;;
    esac
}
configure_firewall_and_updates
'''
        for installer in ['setup.sh', 'setup-proxy.sh']:
            for failure in ('firewall', 'updates'):
                with self.subTest(installer=installer, failure=failure):
                    result = self.run_function(installer, body, failure)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual((self.directory / 'firewall.conf').read_text(), 'original firewall\n')
                    self.assertEqual((self.directory / 'active-rules').read_text(), 'flush ruleset\noriginal rules\n')

    def test_daily_update_reboots_only_after_a_successful_target_upgrade(self):
        body = r'''
TEMP_DIR="$(mktemp -d "$TEMP_DIR/daily.XXXXXXXX")"
STATE_DIR="$TEMP_DIR/state"
RELEASE_ROOT="$TEMP_DIR/xray"
mkdir -p "$STATE_DIR" "$RELEASE_ROOT/releases/1" "$RELEASE_ROOT/releases/2"
printf 'server.example\n' > "$STATE_DIR/domain"
printf '#!/bin/bash\nexit 0\n' > "$RELEASE_ROOT/releases/1/xray"
cp "$RELEASE_ROOT/releases/1/xray" "$RELEASE_ROOT/releases/2/xray"
chmod +x "$RELEASE_ROOT/releases/"*/xray
printf '%s' "$4" > "$TEMP_DIR/nginx-version"
lock_setup() { printf 'event: lock\n'; }
validate_domain() { return 0; }
function /usr/local/bin/xray { printf 'Xray 1\n'; }
dpkg() { [[ "$1" == --compare-versions && "$3" == gt && "$2" > "$4" ]]; }
dpkg-query() {
    [[ "$*" == '-W -f=${Version} nginx' ]] || return 99
    [[ -s "$TEMP_DIR/nginx-version" ]] || return 1
    cat "$TEMP_DIR/nginx-version"
}
check_fallback() { return 0; }
verify_chain() {
    if [[ "$xray_result" == chain-fail && -f "$TEMP_DIR/candidate-active" ]]; then
        return 1
    fi
}
readlink() { printf '%s/releases/1\n' "$RELEASE_ROOT"; }
download_xray() { [[ "$xray_result" != download-fail ]]; }
switch_release() {
    printf 'event: release %s\n' "${1##*/}"
    if [[ "${1##*/}" == 2 ]]; then
        touch "$TEMP_DIR/candidate-active"
    else
        rm -f "$TEMP_DIR/candidate-active"
    fi
}
restart_xray_checked() {
    printf 'event: restart xray\n'
    if [[ "$xray_result" == rollback && ! -e "$TEMP_DIR/retried" ]]; then
        touch "$TEMP_DIR/retried"
        return 1
    fi
}
apt-get() {
    case " $* " in
        *' update '*)
            printf 'event: apt update\n'
            if [[ "$apt_result" == external-upgrade ]]; then
                printf '%s' "$simulated_nginx_version" > "$TEMP_DIR/nginx-version"
            fi
            [[ "$apt_result" != update-fail ]]
            ;;
        *' upgrade '*)
            local option hook='' previous_version
            printf 'event: apt upgrade\n'
            [[ "$DEBIAN_FRONTEND" == noninteractive && "$*" == *'--force-confold'* && "$*" == *'--with-new-pkgs'* ]] || return 99
            case " $* " in *' -y '* | *' --assume-yes '*) ;; *) return 99 ;; esac
            for option in "$@"; do
                case "$option" in DPkg::Pre-Install-Pkgs::=*) hook="${option#*=}" ;; esac
            done
            if [[ -n "$hook" ]]; then
                [[ "$*" == *"DPkg::Tools::options::${hook%% *}::Version=2"* ]] || return 99
                previous_version="$(cat "$TEMP_DIR/nginx-version")"
                {
                    printf 'VERSION 2\nAPT::Get::Assume-Yes=1\n\n'
                    printf 'curl 1 < 2 /var/cache/apt/archives/curl.deb\n'
                    if [[ -n "$simulated_nginx_version" && "$previous_version" != "$simulated_nginx_version" ]]; then
                        printf 'nginx %s < %s /var/cache/apt/archives/nginx.deb\n' "${previous_version:--}" "$simulated_nginx_version"
                    fi
                } | /bin/sh -c "$hook"
            fi
            printf '%s' "$simulated_nginx_version" > "$TEMP_DIR/nginx-version"
            [[ "$apt_result" != upgrade-fail ]]
            ;;
        *) return 99 ;;
    esac
}
systemctl() { printf 'event: systemctl %s\n' "$*"; }
xray_version="$3"
latest_version() { XRAY_VERSION="$xray_version"; }
simulated_nginx_version="$5"
apt_result="$6"
xray_result="$7"
'''
        current = ['lock']
        xray = ['release 2', 'restart xray']
        apt = ['apt update', 'apt upgrade']
        reboot = ['systemctl reboot']
        for installer in ['setup.sh', 'setup-proxy.sh']:
            for version, before, after, apt_result, xray_result, status, actions in [
                ('1', '1', '1', 'ok', 'ok', 0, apt),
                ('1', '', '', 'ok', 'ok', 0, apt),
                ('1', '', '2', 'ok', 'ok', 0, apt),
                ('1', '1', '2', 'external-upgrade', 'ok', 0, apt),
                ('1', '1', '2', 'ok', 'ok', 0, apt + reboot),
                ('2', '1', '1', 'ok', 'ok', 0, xray + apt + reboot),
                ('2', '1', '2', 'ok', 'ok', 0, xray + apt + reboot),
                ('1', '1', '2', 'update-fail', 'ok', 1, apt[:1]),
                ('1', '1', '2', 'upgrade-fail', 'ok', 1, apt),
                ('2', '1', '2', 'upgrade-fail', 'ok', 1, xray + apt + reboot),
                ('2', '1', '2', 'ok', 'download-fail', 1, apt + reboot),
                ('2', '1', '1', 'ok', 'rollback', 1, xray + ['release 1', 'restart xray'] + apt),
            ]:
                with self.subTest(installer=installer, version=version, before=before, after=after,
                                  apt_result=apt_result, xray_result=xray_result):
                    result = self.run_function(installer, body + '\nmain --update', version, before, after,
                                               apt_result, xray_result)
                    events = [line.removeprefix('event: ') for line in result.stdout.splitlines()
                              if line.startswith('event: ')]
                    self.assertEqual(events, current + actions, result.stdout + result.stderr)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)

        result = self.run_function('setup-proxy.sh', body + '''
main --update &
if wait "$!"; then
    exit 93
fi
if [[ -e "$STATE_DIR/rejected-version" ]]; then
    exit 94
fi
xray_result=ok
main --update
''', '2', '1', '1', 'ok', 'chain-fail')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count('event: release 2\n'), 2)
        self.assertIn('event: release 1\n', result.stdout)
        self.assertIn('event: systemctl reboot\n', result.stdout)

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
        links.append(base.replace('main.example', '[2001:db8::10]'))
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
                result = self.run_function(installer, '''
PROJECT_DOMAIN=slave.example
VLESS_CLIENT_UUID="$3"
python3() {
    for argument in "$@"; do
        [[ "$argument" != "$VLESS_CLIENT_UUID" ]] || return 92
    done
    command python3 "$@" || return
    return 91
}
write_xray_config
''', UUID)
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
