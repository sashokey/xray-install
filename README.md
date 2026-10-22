> Clean Debian 13 (Trixie), root. Point the domain A record to the server; remove its AAAA record.

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/master/setup.sh -o setup.sh && bash setup.sh
```

Enter the domain and generate or enter a UUID. Save the displayed VLESS link. The script removes SSH and reboots after successful checks.

## Proxy server (slave)

Run [setup-proxy.sh](setup-proxy.sh) on the slave for `client -> slave -> main`.

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/master/setup-proxy.sh -o setup-proxy.sh && bash setup-proxy.sh
```

Enter the slave domain, generate or enter a UUID, and paste the main VLESS link. Save the displayed slave link. The script removes SSH and reboots after successful checks.
