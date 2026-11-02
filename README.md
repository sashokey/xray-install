> Clean Debian 13 (Trixie), root. Point the domain A record to the server; remove its AAAA record.

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/master/setup.sh -o setup.sh && bash setup.sh
```

Enter the domain and generate or enter a UUID. Save the displayed VLESS link. The script removes SSH and reboots after successful checks.

## Proxy server (slave)

Run [setup-proxy.sh](setup-proxy.sh) on the slave for `client -> slave -> main`.

```bash
wget -qO setup-proxy.sh https://raw.githubusercontent.com/sashokey/xray-install/master/setup-proxy.sh && bash setup-proxy.sh
```

Enter the slave domain, generate or enter a UUID, and paste the main VLESS link. Save the displayed slave link. The script removes SSH and reboots after successful checks.

## Tests

```bash
bash -n setup.sh setup-proxy.sh
python3 -m unittest discover -s tests -v
```

GitHub Actions runs the full suite in Debian 13. Local interactive-input and domain tests require the supported Bash 5 runtime; set `BASH_BIN` to select that interpreter. Other tests can run with macOS Bash 3.2. CI rejects an older Bash runtime instead of skipping those tests.

The suite executes installer functions and the actual Python configuration/link parsers with temporary files and controlled external-command boundaries. It does not install services, change networking, request certificates, remove SSH, or reboot a machine. Complete server provisioning still requires a disposable Debian 13 VM with the documented network prerequisites.

