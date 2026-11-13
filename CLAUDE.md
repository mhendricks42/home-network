# home-network: notes for Claude

Read before answering. Owner works on `main` directly (commit and push there).
Docs are the source of truth; check them before answering from memory.

## Hosts (themed names, see docs/naming-conventions.md)
| Name | What | IP | Notes |
|---|---|---|---|
| anubis | UCG Max gateway | 10.0.40.1 on VLAN 40 | Answers VLAN 40 only on .40.1 (not its Mgmt 10.0.10.1). No LAN NTP. Local auto-backups `/data/unifi/data/backup/autobackup/*.unf`, ~monthly |
| odin | HP ProDesk, Ubuntu, Docker (`compose.server.yml`) | 10.0.40.10 | Caddy, AdGuard+Unbound, HA, Frigate, etc. NUT server for office UPS `ups0` |
| vidar | Pi 3B+, **native, no Docker** (docs/vidar-baseline.md) | 10.0.40.11 | DNS 2, NTP 2, Uptime Kuma, NUT server for closet UPS `closet` |
| mimir | Ugreen NAS, UGOS | 10.0.40.20 | Media stack (`media-stack/`), restic REST server (`compose.nas.yml`, :8000) |

VLANs: Mgmt 10, Trusted 20 (Mostly-Harmless), Work 30 (The-Forge), Servers 40,
IoT-Local 50 (Alfheim), IoT-Cloud 55 (Niflheim), Cameras 60 (no internet), Guest 70 (Mead-Hall).
Firewall policies Z1–Z33 in docs/network-architecture.md §9. An empty destination means **Any**.

## Services and access
- Domain `foxhound.nexus` on Cloudflare; Caddy wildcard `*.home.foxhound.nexus` → 10.0.40.10 (AdGuard rewrite).
  Media apps proxied via the `(media)` snippet to `MEDIA_IP`.
- HA 2026.10: proxy settings are UI-only (`.storage/http`), trusted proxy `172.28.0.1`. No `http:` YAML.
  Packages in `services/homeassistant/packages/` must be copied by hand to `/srv/homeassistant/config/packages/`.
  Webhook IDs live in HA `secrets.yaml` (`seerr_webhook_id`, `radarr_/sonarr_/prowlarr_webhook_id`; all must exist).
  Phone notify: `notify.mobile_app_matt_s_samsung_galaxy`.
- Docker networks on odin: default 172.28.0.0/24, resolver 172.29.0.0/24 (Unbound 172.29.0.2).
- Media stack images are pinned by tag in `media-stack/docker-compose.yml`; update by bumping the tag, never in-app.

## Power (docs/go-live.md E2)
- odin `ups.conf`: `ignorelb`, LB at 50% charge or 900 s runtime.
- UGOS never logs in to NUT, so it ignores FSD. odin powers the NAS off over SSH
  (`/etc/nut/upssched-cmd`: `nas-off` after 5 min on battery; `shutdown-all` is odin's SHUTDOWNCMD).
  UGOS timer 10 min = backstop only. Wake-on-LAN: 3 min after ONLINE and `wake-nas.service` at every odin boot.
- `upsmon -c fsd` power-cycles the UPS outlets (that's what restarts everything). Warn the household.
- UGOS alert times showed +1 h: likely a fixed-offset time zone in UGOS, not a setting.

## Backups (docs/go-live.md E3)
- restic → REST server on mimir, `--append-only --private-repos`; user = path = hostname (`/odin/`, `/vidar/`).
- Nightly timers: odin 03:30 (stops all containers; first pulls UniFi `.unf` into `/srv/unifi-backup`), vidar 04:00.
- Prune monthly **from the NAS by hand** (repo password is never stored on the NAS). USB copy monthly.

## Gotchas learned the hard way
- NUT passwords: letters and digits only (`#` starts a comment). UGOS requires UPS name `ups0`, user `monuser`/`secret`.
- `upsd` needs the network-online drop-in or it listens on 127.0.0.1 only after reboot.
- BGW320 hijacks DNS to 192.168.0.254 when its upstream is down; Unbound has `private-address` + `serve-expired`.
- Docker `create_user`/password prompts need `-it`. Generated config must not leave placeholders (`HOST`).
- Secrets go in Dashlane; read them with `read -rs`, never into chat or shell history. Don't put the owner's email in external requests.
- Host files (NUT upssched, systemd units) live in `services/nut/` and `services/restic/`; install them from the repo, docs point there.

## Checks
`bash -n scripts/*.sh`, `sh -n services/nut/upssched-cmd`, `sh scripts/test-start.sh`, `docker compose -f compose.server.yml --profile '*' config -q`,
`cd media-stack && go vet ./... && go test ./...`.
