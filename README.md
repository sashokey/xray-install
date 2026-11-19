> Both servers require clean Debian 13 (Trixie), root, systemd, GRUB, an IPv4 default route, and the `curl`, `update-grub`, `ip`, `systemctl`, `python3`, and `flock` commands. Point each domain's A record to its server and remove the AAAA record. HTTP port 80 must reach each server for the ACME challenge.

Run the installers from the server console or over IPv4 SSH. They disable IPv6 during setup. The main server requires Netplan with `systemd-networkd`. Netplan settings must be persistent in `/etc/netplan`.

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/master/setup.sh -o setup.sh && bash setup.sh
```

Enter the domain and generate or enter a UUID. Save the displayed VLESS link. The script removes SSH and reboots after successful checks.

## Proxy server (slave)

Run [setup-proxy.sh](setup-proxy.sh) on the slave for `client -> slave -> main`. The slave supports Netplan with `systemd-networkd` or ifupdown with static IPv4.

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/master/setup-proxy.sh -o setup-proxy.sh && bash setup-proxy.sh
```

Enter the slave domain, generate or enter a UUID, and paste the main VLESS link. Save the displayed slave link. The script removes SSH and reboots after successful checks.

## Tests

```bash
bash -n setup.sh && bash -n setup-proxy.sh && bash -n tests/integration.sh
python3 -m unittest discover -s tests -v
```

GitHub Actions runs the full suite in Debian 13. Local interactive-input and domain tests require the supported Bash 5 runtime; set `BASH_BIN` to select that interpreter. Other tests can run with macOS Bash 3.2. CI rejects an older Bash runtime instead of skipping those tests.

The unit suite executes installer functions and the actual Python configuration/link parsers with temporary files and controlled external-command boundaries.

The separate integration job uses a disposable Debian 13 container. It runs the installer's real release download, checksum/version checks, Nginx configuration and ACME-path check, generated Xray configurations, HTTPS fallback, and a TLS/VLESS `client -> slave -> main -> https://example.com/` request. The test checks the public target directly first. Stopping either server must break the route. Restarting main must restore it. Test outbound trust settings include the temporary CA with certificate verification enabled. The slave listener/client endpoint uses a separate loopback port so both servers can run in one container. Systemd calls are controlled at the container boundary. Nginx and Xray processes handle the traffic.

CI does not change host networking or firewall rules, request a public certificate, remove SSH, or reboot. Complete server provisioning still requires a disposable Debian 13 VM with the prerequisites above.

