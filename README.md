> Clean Debian 13 (Trixie), root. Point the domain A record to the server; remove its AAAA record.

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/master/setup.sh -o setup.sh && bash setup.sh
```

Enter the domain and generate or enter a UUID. Save the displayed VLESS link. The script removes SSH and reboots after successful checks.

## Proxy server (slave)

[setup-proxy.sh](setup-proxy.sh) performs the same system setup as [setup.sh](setup.sh) and builds the chain `client -> slave -> main`. The slave accepts VLESS + TLS + Vision connections and forwards allowed client traffic through the existing main VLESS link. Main does not need any changes.

Use a clean Debian 13 (Trixie) server as root, with GRUB and an IPv4 default route, on x86_64 or aarch64. The installer supports the image's native static IPv4 configuration through `ifupdown` and `networking.service`; no migration to Netplan is needed. Existing Netplan/systemd-networkd images are also supported. Point a separate domain A record to the slave and remove its AAAA record. TCP ports 80 and 443 must be reachable.

**After successful checks, the script removes SSH and reboots the slave in 10 seconds, just like setup.sh. Save the displayed VLESS link and retain access to the provider's console. Run this installer only on the slave.**

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/master/setup-proxy.sh -o setup-proxy.sh && bash setup-proxy.sh
```

Enter the slave domain, choose whether to generate a new client UUID or enter an existing one, and paste the main VLESS link produced by `setup.sh`. The main link input is hidden. Import the displayed slave VLESS link into your client.

The original setup behavior is retained:

- IPv4-only network configuration using the active backend, static DNS, disabled IPv6 in sysctl and GRUB, and network configuration backups. On ifupdown images, the existing static IPv4 addresses and routes are retained without cycling the interface; DHCP configurations use the Netplan backend.
- BBR congestion control and the `fq` queue discipline.
- Nginx for ACME on port 80 and the default 403 fallback; Xray VLESS + TLS + Vision on port 443.
- The same Xray DNS, traffic sniffing, and Russian domain/IP blocking rules.
- Daily Xray updates with configuration validation, health checks, and release rollback; the Certbot renewal timer.
- Disabling the same unused services and installing the same nftables rules, allowing new inbound TCP connections only on ports 80 and 443.
- Purging OpenSSH, masking its services and sockets, and scheduling the reboot after the installation checks pass.

Certificate issuance uses the same Certbot command as `setup.sh`. A clean installation obtains a new certificate for the slave domain. The original `--keep-until-expiring` behavior remains: Certbot may retain an existing certificate that is not due for renewal. There is no separate test-certificate reuse or restoration logic in this installer.

All allowed client traffic uses the main VLESS outbound; there is no direct fallback if main is unavailable. The installer checks main before certificate issuance and verifies the complete chain before removing SSH. Xray update checks also verify the chain before and after a release change.

After installation, run maintenance commands from the provider's console. Check the installation and connection chain:

```bash
/usr/local/sbin/xray-proxy-setup --check
```

Check for an Xray update manually:

```bash
/usr/local/sbin/xray-proxy-setup --update
```
