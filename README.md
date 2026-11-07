# home-network

Service configurations for the home server (`odin`, Ubuntu), the Raspberry Pi
(`vidar`) and the NAS (`mimir`) described in
[the architecture](docs/home-server-architecture.md). Develop on Windows; deploy
on the **Linux targets**, not Docker Desktop.

| Target | Default services | Optional profiles |
|---|---|---|
| Server | AdGuard Home, Unbound, Mosquitto, Home Assistant, ESPHome, Forgejo | `https`: Caddy; `radios`: Zigbee2MQTT + Z-Wave JS UI; `cameras`: Frigate; `monitoring`: NetAlertX; `actions`: Forgejo runner |
| Pi (vidar) | AdGuard Home, Unbound, Uptime Kuma (native, no Docker: [vidar baseline](docs/vidar-baseline.md)) | None |
| NAS (mimir) | Media stack in [`media-stack/`](media-stack/readme.md): Gluetun + qBittorrent, SABnzbd, Prowlarr, Sonarr, Radarr, Bazarr, Jellyfin, ErsatzTV, Seerr | `recyclarr` (on demand) |

Start with the [deployment runbook](docs/runbook.md). It covers required secrets,
first-run setup, DNS-provider selection, USB/GPU access, storage, firewall
prerequisites, and acceptance checks.

For gateway, VLAN, switch and Wi-Fi configuration, use the
[UCG Max runbook](docs/ucg-max-runbook.md). Names for hosts, SSIDs and repo
items follow the [naming conventions](docs/naming-conventions.md).

Local configuration checks (no Docker daemon required):

```powershell
.\scripts\validate.ps1
& 'C:\Program Files\Git\bin\bash.exe' scripts/test-start.sh
```

These checks are not container integration tests. An actual Linux deployment
must pass the runbook's acceptance checks before changing household DHCP/DNS.

Tailscale, UPS shutdown (NUT) and backups (restic) are manual host steps in
[go-live](docs/go-live.md). Ansible provisioning, SOPS and UniFi automation are
not implemented.
