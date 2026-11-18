# Home Assistant: network health dashboard

One page for the network, hosts, power and services:
[`services/homeassistant/dashboards/network-health.yaml`](../services/homeassistant/dashboards/network-health.yaml).
Built-in cards only (no HACS), so nothing extra to install or keep updated.

| Tab | Shows | Source |
|---|---|---|
| **Overview** | Green/red banner with the failing checks; hosts, core services and media apps as coloured tiles (green = up, red = down); power; download speeds | Uptime Kuma, NUT, SABnzbd, qBittorrent |
| **Resources** | CPU, RAM, disk and temperature gauges (°F) for odin, vidar and mimir; 24 h CPU and temperature graphs | System Monitor, Glances |
| **Network** | Gateway CPU/RAM, AdGuard, UPS battery and load, 24 h history of every check | UniFi, AdGuard, NUT, Uptime Kuma |

Each Kuma check is a pair of tiles with visibility conditions, so exactly one
shows: green while the check is `up`, red otherwise. Adding a check means
copying such a pair (and adding the key to the Problems banner's list).

Service health comes from **Uptime Kuma on vidar**, so the dashboard shows the
same checks that alert your phone, and Kuma keeps alerting when odin (and so
HA) is down.

## 1. Uptime Kuma monitors

The runbook's acceptance checks created *Server*, *Gateway*, *Internet*,
*DNS (odin)*, *DNS (vidar)*, *Home Assistant* and *Certificate*. Add these (names are
for Kuma's alerts; HA's entity IDs are set in step 2):

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

*Settings → Devices & services → Add integration.* Then name each device per
the [entity ID convention](naming-conventions.md#home-assistant-entity-ids):
open the device, **✎ → Name**, and accept **rename entity IDs**.

| Integration | Settings | Device name(s) → entity IDs |
|---|---|---|
| Uptime Kuma | `http://10.0.40.11:3001`, the API key | one device per monitor: `Kuma internet`, `Kuma anubis` (Gateway), `Kuma odin` (Server), `Kuma mimir` (NAS), `Kuma DNS odin`, `Kuma DNS vidar`, `Kuma Home Assistant`, `Kuma certificate`, `Kuma Forgejo`, `Kuma Jellyfin`, `Kuma Seerr`, `Kuma Sonarr`, `Kuma Radarr`, `Kuma Prowlarr`, `Kuma SABnzbd`, `Kuma qBittorrent` → `sensor.kuma_*_status` |
| Network UPS Tools | already added (go-live E2) | `UPS Office`, `UPS Closet` → `sensor.ups_office_*`. Enable *Battery runtime* (off by default) |
| System Monitor | add disk `/config` | `odin` → `sensor.odin_*`. Enable *Processor use*, *Memory usage*, *Disk usage /config* (off by default) |
| AdGuard Home | host `adguard`, port `80`, SSL off, your AdGuard login (HA reaches it over the shared Docker network; vidar's UI is loopback-only, so the *DNS vidar* Kuma check covers it) | `AdGuard odin` → `sensor.adguard_odin_*` |
| UniFi Network | host `10.0.40.1`, a local read-only UniFi user | gateway: `anubis` → `sensor.anubis_*` |
| SABnzbd | `http://10.0.40.20:8081`, its API key | `SABnzbd` → `sensor.sabnzbd_*` |
| Glances (twice) | host `10.0.40.11` and `10.0.40.20`, port `61208`, no SSL, no login. Set up first: vidar baseline §8, the `glances` service in `compose.nas.yml` | `vidar`, `mimir` → `sensor.vidar_*`, `sensor.mimir_*` (CPU, RAM, disks, temperatures) |
| qBittorrent | `http://10.0.40.20:8080`, its login | `qBittorrent` → `sensor.qbittorrent_*` |

If you have extra Kuma monitors (for example the Sonarr/Radarr/Prowlarr
*health* checks), name them `Kuma Sonarr health` etc.; the dashboard doesn't
use them, but the names stay consistent.

**Bulk alternative** to renaming device by device: export the entity list,
edit `new_entity_id` (and `"enable": true` for disabled ones), apply. On odin:

```bash
cd ~/home-network
read -rsp "HA long-lived token: " HA_TOKEN; echo; export HA_TOKEN
run() { sudo --preserve-env=HA_TOKEN docker compose -f compose.server.yml exec -T -e HA_TOKEN \
          homeassistant python3 - "$@" < scripts/ha-entities.py; }
run export                                   # writes /srv/homeassistant/config/ha-entities.json
# edit that file (or have it edited), then:
run apply --dry-run                          # shows every change, changes nothing
run apply
unset HA_TOKEN
```

Your installation's renames are already prepared in
[`services/homeassistant/entity-renames.json`](../services/homeassistant/entity-renames.json)
(generated from the 2026-11-15 export; Kuma renames come first so their old
names are free for the apps' own sensors). Use it instead of editing the export:
`sudo cp services/homeassistant/entity-renames.json /srv/homeassistant/config/ha-entities.json`,
then the dry run.

**HA doesn't rewrite automations** that use a renamed entity ID: update their
triggers (for example the UPS alert to `sensor.ups_office_status_data` /
`sensor.ups_closet_status_data`); *Settings → Repairs* lists broken ones.

The apply refuses the whole batch if a new ID is invalid, duplicated or already
taken. Display names stay as they are; the dashboard sets its own labels.

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
