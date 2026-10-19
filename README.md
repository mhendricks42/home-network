# Home server stack

Docker Compose and service configurations for the Debian server and Raspberry Pi
described in [the architecture](docs/home-server-architecture.md). Develop on
Windows; deploy on the **Linux targets**, not Docker Desktop.

| Target | Default services | Optional profiles |
|---|---|---|
| Server | AdGuard Home, Unbound, Mosquitto, Home Assistant, ESPHome, Forgejo | `https`: Caddy; `radios`: Zigbee2MQTT + Z-Wave JS UI; `cameras`: Frigate; `monitoring`: NetAlertX; `actions`: Forgejo runner |
| Pi | AdGuard Home, Unbound, Uptime Kuma | None |

Start with the [deployment runbook](docs/runbook.md). It covers required secrets,
first-run setup, DNS-provider selection, USB/GPU access, storage, firewall
prerequisites, and acceptance checks.

Local configuration checks (no Docker daemon required):

```powershell
.\scripts\validate.ps1
& 'C:\Program Files\Git\bin\bash.exe' scripts/test-start.sh
```

These checks are not container integration tests. An actual Linux deployment
must pass the runbook's acceptance checks before changing household DHCP/DNS.

Host provisioning, Tailscale, NUT, restic, SOPS integration, UniFi changes and
Ansible drift checks are **not implemented** by this Docker-only layer.
