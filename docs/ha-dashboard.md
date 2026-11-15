# Home Assistant: network health dashboard

One page for the network, hosts, power and services:
[`services/homeassistant/dashboards/network-health.yaml`](../services/homeassistant/dashboards/network-health.yaml).
Built-in cards only (no HACS), so nothing extra to install or keep updated.

| Section | Shows | Source |
|---|---|---|
| Problems | Only the checks that are **not** up, plus "N / M checks up" | Uptime Kuma |
| Hosts | anubis, odin, vidar, mimir up/down; odin CPU, memory, disk; gateway CPU | Uptime Kuma, System Monitor, UniFi |
| Network & DNS | Internet, both DNS servers, AdGuard queries and blocked %, filtering switches | Uptime Kuma, AdGuard Home |
| Power | Both UPSes: status, battery, runtime, load | Network UPS Tools |
| Services | HA, certificate, Forgejo, Jellyfin, Seerr, Sonarr, Radarr, Prowlarr, SABnzbd, qBittorrent | Uptime Kuma |
| Downloads | Usenet and torrent speed and queue | SABnzbd, qBittorrent |
| Last 24 hours | Battery, CPU, and every check's up/down history | all of the above |

Service health comes from **Uptime Kuma on vidar**, so the dashboard shows the
same checks that alert your phone, and Kuma keeps alerting when odin (and so
HA) is down.

## 1. Uptime Kuma monitors

The runbook's acceptance checks created *Server*, *Gateway*, *Internet*,
*DNS (odin)*, *DNS (vidar)*, *Home Assistant* and *Certificate*. Add these, with
exactly these names (HA builds the entity IDs from them):

| Monitor | Type | Target |
|---|---|---|
| NAS | Ping | `10.0.40.20` |
| Forgejo | HTTP(s) – Keyword | `https://git.home.foxhound.nexus/user/login`, keyword `Forgejo` |
| Jellyfin | HTTP(s) – Keyword | `http://10.0.40.20:8096/health`, keyword `Healthy` |
| Seerr | HTTP(s) | `http://10.0.40.20:5055/api/v1/status` |
| Sonarr | HTTP(s) | `http://10.0.40.20:8989/ping` |
| Radarr | HTTP(s) | `http://10.0.40.20:7878/ping` |
| Prowlarr | HTTP(s) | `http://10.0.40.20:9696/ping` |
| SABnzbd | HTTP(s) | `http://10.0.40.20:8081/api?mode=version` |
| qBittorrent | HTTP(s) | `http://10.0.40.20:8080/` (only answers while the VPN is up) |

Then **Settings → API Keys → Add** in Kuma; store the key in Dashlane.

## 2. Integrations in Home Assistant

*Settings → Devices & services → Add integration.* After adding each one, open
the device and **rename it as shown, accepting "rename entity IDs"**, so the
IDs match the dashboard.

| Integration | Settings | Rename device to |
|---|---|---|
| Uptime Kuma | `http://10.0.40.11:3001`, the API key | (one device per monitor; keep the names) |
| Network UPS Tools | already added (go-live E2) | `UPS Office`, `UPS Closet` |
| System Monitor | add CPU, memory, and disk use for `/config` | `System Monitor` (default) |
| AdGuard Home | host `adguard`, port `80`, SSL off, your AdGuard login. HA reaches odin's AdGuard over their shared Docker network; vidar's AdGuard UI is loopback-only, so its health comes from the *DNS (vidar)* Kuma check | `AdGuard odin` |
| UniFi Network | host `10.0.40.1`, a local read-only UniFi user | gateway device: `anubis` |
| SABnzbd | `http://10.0.40.20:8081`, its API key | `SABnzbd` |
| qBittorrent | `http://10.0.40.20:8080`, its login | `qBittorrent` |

## 3. Add the dashboard

1. *Settings → Dashboards → Add dashboard → New dashboard from scratch*,
   title `Network health`, icon `mdi:lan`, *Show in sidebar* on.
2. Open it, **⋮ → Edit dashboard → ⋮ → Raw configuration editor**, replace
   everything with the contents of `network-health.yaml`, **Save**.
3. Check the entity IDs from odin (long-lived token from your HA profile →
   Security):

   ```bash
   cd ~/home-network && bash scripts/check-ha-entities.sh services/homeassistant/dashboards/network-health.yaml
   ```

   Each `MISSING` line lists similar existing entities. Fix it at the source
   (rename the device or Kuma monitor) or change the ID in the YAML, then paste
   again. Cards with a missing entity show a yellow warning until fixed.

The repo file is the source: change it there, commit, and paste it again
(the raw editor replaces the whole dashboard). Edits made in the UI are lost
on the next paste, so copy them back into the file first.

## 4. Optional

- **Phone home screen:** in the HA app, set this dashboard as the default for
  that device (*Settings → Companion app → Default dashboard*).
