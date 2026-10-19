> Clean Debian 13 (Trixie), root. Point the domain A record to the server; remove its AAAA record.

```bash
curl -4fsSL https://raw.githubusercontent.com/sashokey/xray-install/main/setup.sh -o setup.sh && bash setup.sh
```

Enter the domain and generate or enter a UUID. Save the displayed VLESS link. The script removes SSH and reboots after successful checks.
