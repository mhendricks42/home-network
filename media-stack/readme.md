# media-stack

The media automation stack for the NAS (`mimir`, `10.0.40.20`) in
[home-network](../README.md). It runs on Linux with Docker. Remote access comes
from home-network's Tailscale subnet router on `oden`, and HTTPS names
(`jellyfin.home.foxhound.nexus` and friends) from oden's Caddy, so this stack
runs neither.

One base Compose file holds the services. Thin overlays add secrets, GPU and
autoheal behavior:

```
./stack.sh use linux
```

---

## Contents

- [What this runs](#what-this-runs)
- [Architecture](#architecture)
- [How the overlays work](#how-the-overlays-work)
- [Anime baseline](#anime-baseline)
- [Professional deployment CLI](#professional-deployment-cli)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Secrets](#secrets)
- [Setup](#setup-linux-production)
- [First-run configuration](#first-run-configuration)
- [Everyday commands](#everyday-commands)
- [The two things that break this stack](#the-two-things-that-break-this-stack)
- [Security model](#security-model)
- [Updates](#updates)
- [Troubleshooting](#troubleshooting)
- [Legal](#legal)

---

## What this runs

| Service | Port | Role |
|---|---|---|
| Gluetun | — | VPN tunnel. Owns the network namespace qBittorrent runs in. |
| qBittorrent | 8080 | Secondary torrent client. No network of its own. |
| SABnzbd | 8081 | Primary Usenet download client. Downloads NZBs from your Usenet provider. |
| Prowlarr | 9696 | Indexer manager. Configure once, syncs to Sonarr and Radarr. |
| Sonarr | 8989 | TV. Monitors series, grabs episodes, renames and upgrades. |
| Radarr | 7878 | Movies. Same, for films. |
| Bazarr | 6767 | Subtitles, per language profile. |
| Recyclarr | — | On-demand TRaSH Guides sync for Sonarr and Radarr quality profiles and custom formats. |
| Jellyfin | 8096 | Media server. Scans, transcodes, streams. |
| ErsatzTV | 8409 | Pseudo-live TV channels and guide data from the local library. |
| Seerr | 5055 | Request UI for the household. |

Seerr is the merged successor to Overseerr and Jellyseerr. Readarr is deliberately absent — the project was archived in 2025.

## Architecture

```
                       Seerr
                         │
                  Sonarr / Radarr ────► Prowlarr ────► NZB and torrent indexers
                    │        │
                    │        └────► qBittorrent inside Gluetun ────► VPN ────► swarm
                    └─────────────► SABnzbd ────► Usenet provider
                         │
                 /data  (one filesystem)
                         │
                     Jellyfin
                         │
                    ErsatzTV
                       │
              TVs, phones, browsers
```

Two network domains live on one host and never talk over the network the way you might expect:

**Gluetun's namespace** contains qBittorrent via `network_mode: service:gluetun`. qBittorrent has no interfaces of its own, so if the tunnel drops it has nowhere to send packets. This is a structural kill switch rather than a setting that can be misconfigured.

**The `medianet` bridge** contains everything else. Sonarr and Radarr prefer SABnzbd at `sabnzbd:8080` for Usenet downloads, and keep qBittorrent at `gluetun:8080` as the secondary torrent client. The arr apps never join the swarm, so they do not need the tunnel.

**`/data`** is the handoff. SABnzbd writes to `/data/usenet`, qBittorrent writes to `/data/torrents`, Sonarr and Radarr import into `/data/media`, Jellyfin reads the finished library, and ErsatzTV reads the same media tree to build pseudo-live channels. Coordination happens over the bridge and files move through the shared filesystem. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the cited system map, lifecycle diagrams, and subsystem deep-dives.

## How the overlays work

Docker Compose reads the `COMPOSE_FILE` variable from `.env`. Set it there and plain `docker compose up -d` picks up the right overlays with no flags:

```
COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/secrets.yml
COMPOSE_PROJECT_NAME=media
```

`stack.sh use linux` only copies `env/linux.env.example` over `.env`. The base file has no `container_name`; refer to services by their Compose name (`docker compose logs sonarr`).

### GPU overlays are opt-in

They are separate files rather than commented blocks, because a `devices:` entry pointing at a device that does not exist prevents the container from starting. Append one only after confirming the hardware:

```bash
ls -la /dev/dri                                # Intel: must list renderD128
COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/secrets.yml:compose/gpu-intel.yml
```


## Anime baseline

The default bootstrap includes dedicated `/data/media/anime` storage, Sonarr
absolute-number naming and root-based `seriesType` reconciliation, the current
Recyclarr v8 anime profile, Seerr's anime root/profile override, and a Jellyfin
Anime library with backdrop generation disabled.

```bash
./stack.sh setup-data
source ./scripts/set-env.sh
./stack.sh bootstrap
./stack.sh audit-anime
```

See [the anime baseline guide](docs/ANIME_BASELINE.md) for validated corrections,
existing-series migration, Bazarr's intentionally manual profile configuration,
chapter-segment automation, and Direct Play verification.

## Professional deployment CLI

The Go-based `media-stack` CLI adds desired state, environment discovery,
reviewable plans, stale-plan rejection, resumable operation journals, guided
profiles, adoption, and guarded maintenance commands while retaining
`stack.sh` as the execution adapter.

Build and test:

```bash
go test ./...
go build -o media-stack ./cmd/media-stack
```

Create a new desired-state file:

```bash
./media-stack configure --profile recommended --platform linux \
  --name home-media --data-root /data --write media-stack.yaml
./media-stack plan --state media-stack.yaml
./media-stack install --state media-stack.yaml
```

`install` saves a reviewable plan but does not apply it unless both `--apply`
and `--yes` are supplied. For an existing deployment, use the non-mutating
migration helper:

```bash
./scripts/migrate-deployment.sh
```

See [the existing-deployment migration guide](docs/MIGRATING_TO_DEPLOYMENT_CLI.md)
for backups, adoption, plan review, apply/resume, maintenance, and rollback
steps. [`media-stack.example.yaml`](media-stack.example.yaml) documents the
desired-state shape.

## Repository layout

```
.
├── ARCHITECTURE.md             # cited architecture and onboarding guide
├── docker-compose.yml          # platform-neutral service graph
├── compose/                    # target, secret, and optional GPU overlays
│   ├── linux.yml
│   ├── secrets.yml
│   └── gpu-intel.yml / gpu-nvidia.yml
├── env/                        # copyable non-secret target templates
│   └── linux.env.example
├── scripts/                    # bootstrap and host setup automation
│   ├── bootstrap.sh
│   ├── bootstrap-seerr.sh
│   └── set-env.sh
├── docs/                       # migration, image policy, and history
├── cmd/media-stack/            # professional deployment CLI entry point
├── internal/                   # desired state, discovery, plans, workflow, adapters
├── media-stack.example.yaml    # non-secret desired-state example
├── config/                     # ignored generated application state
├── indexers.example.json       # declarative Prowlarr indexer example
├── recyclarr.example.yml       # declarative TRaSH profile baseline
├── stack.sh                    # operator lifecycle wrapper
└── .gitignore
```

`config/` and `.env` are gitignored. `.env` holds non-secret deployment settings such as paths, ports, and project name. Secrets are supplied from the shell environment or a secret manager at runtime. `config/` holds databases, API keys, and session tokens, so it also stays out of version control.

## Prerequisites

Docker Engine 24+ with the Compose plugin. A Usenet provider account for SABnzbd, plus NZB indexer accounts such as OZnzb, DrunkenSlug, or NZBGeek if you use private indexers. A VPN account is still needed for the secondary torrent path; this repo assumes NordVPN. Note that Nord's consumer service does not offer port forwarding, so torrent seeding will rely on outbound connections only.

On the NAS: any Linux with with Docker, Bash, curl, jq, and Python 3. An Intel CPU with QuickSync if you expect to transcode.

## Secrets

Do not put NordVPN, UI, or indexer credentials in `.env`. The active `.env` file is only for non-secret deployment settings such as paths, project name, port binding, restart policy, timezone, and LAN subnet.

Secrets are session environment variables. The guided helper prompts for them and sets them only in the current shell:

```bash
./stack.sh init-vpn
source ./scripts/set-env.sh
source ./scripts/set-env.sh --force   # replace values already set in this shell
```

Run `./stack.sh init-vpn` separately for NordVPN credentials. The session helper prompts for:

- `QBIT_PASS` for bootstrap automation
- `SABNZBD_USER` / `SABNZBD_PASS`
- optional `NZBGEEK_API_KEY` and `NZBPLANET_API_KEY` for enabled private indexers in `indexers.json`
- `SAB_SERVER_HOST` / `SAB_SERVER_USER` / `SAB_SERVER_PASS` for the primary Usenet provider
- optional `SAB_BACKUP_SERVER_HOST` / `SAB_BACKUP_SERVER_USER` / `SAB_BACKUP_SERVER_PASS` for a backup or block account
- `SONARR_USER` / `SONARR_PASS`
- `RADARR_USER` / `RADARR_PASS`
- `PROWLARR_USER` / `PROWLARR_PASS`
- `BAZARR_USER` / `BAZARR_PASS`
- `JELLYFIN_USER` / `JELLYFIN_PASS`, plus optional `MOONBASE_TMDB_API_KEY` and `MOONBASE_MDBLIST_API_KEY` integration secrets
- `SEERR_EMAIL` for the Seerr administrator linked to Jellyfin

The Bash helper must be sourced, not executed, because only a sourced script can export variables into your current shell. Closing the terminal clears these session secrets. For production, inject the same variables from a secret manager instead of typing them interactively.

## Setup: Linux (production)

Set these in `.env` for home-network: `BIND_ADDR=10.0.40.20` (the NAS; oden's Caddy proxies to it) and `LAN_SUBNET=10.0.0.0/16` (all home VLANs, so Gluetun lets Caddy and clients get replies from qBittorrent).

**1. Create the data tree.** One filesystem, three subfolders:

```bash
sudo mkdir -p /data/{usenet/incomplete,usenet/complete/tv,usenet/complete/movies,torrents/incomplete,media/tv,media/movies}
sudo chown -R "$USER":"$USER" /data
```

If media lives on a separate drive, mount that drive *at* `/data`. Do not symlink or bind-mount subfolders in from elsewhere — that defeats hardlinks and the failure is silent.

**2. Configure.**

```bash
git clone https://github.com/mhendricks42/home-network && cd home-network/media-stack
./stack.sh use linux
$EDITOR .env          # set non-secret values
source ./scripts/set-env.sh
mkdir -p config/seerr && sudo chown -R 1000:1000 config/seerr
```

`init-vpn` stores the Nord OpenVPN credentials in ignored files with no trailing newline and restrictive Linux permissions. Seerr always runs as UID/GID 1000:1000 regardless of `PUID`/`PGID`, so its config directory needs that ownership explicitly. NAS platforms may attach inherited ACLs that override ordinary mode bits; if `ls -ld config/seerr` ends with `+` and Seerr reports `EACCES`, run `sudo setfacl -Rb config/seerr`, restore ownership with `sudo chown -R 1000:1000 config/seerr`, and restrict modes with `sudo chmod -R u+rwX,g+rX,o-rwx config/seerr`. Keep the same terminal open after `set-env.sh`; the remaining bootstrap secrets live only in that shell session.

**3. Check the merged file before starting.** This catches typos and missing variables without creating anything:

```bash
./stack.sh config | less
```

**4. Start, generate app configs, then bootstrap.** The first `up` creates each application's config files and API keys. `setup-data` creates missing shared-data directories with the configured `PUID` and `PGID`; it never changes ownership of existing directories or media. `bootstrap` then configures UI logins, SABnzbd paths, qBittorrent paths/seeding limits, Prowlarr app links, download clients, and root folders.

```bash
./stack.sh up
./stack.sh setup-data
./stack.sh bootstrap
./stack.sh audit-anime
./stack.sh doctor
./stack.sh verify
```

`verify` compares the host's public IP against the one Gluetun sees. If they match, stop and fix it — the tunnel is not carrying qBittorrent's traffic.

## First-run configuration

Order matters — doing it in this sequence avoids re-entering things.

**1. Run bootstrap after first startup.** Run `up` once before `bootstrap`; the apps need to create their `config/` files and API keys first. Bootstrap then configures UI logins, SABnzbd paths and provider servers, qBittorrent paths/seeding limits, Prowlarr app links, Sonarr episode naming and media management, Sonarr/Radarr download clients, Jellyfin server settings, and root folders.

On a fresh installation, bootstrap configures forms authentication for qBittorrent, SABnzbd, Sonarr, Radarr, Prowlarr, and Bazarr. It initializes the Jellyfin administrator from `JELLYFIN_USER` / `JELLYFIN_PASS`, applies the Jellyfin baseline, installs and configures the pinned Moonbase server plugin for Moonfin, then configures Seerr from that Jellyfin administrator using `SEERR_EMAIL` and verifies Seerr's API key. Passwords are only read from runtime environment variables; qBittorrent uses a salted PBKDF2 hash and Bazarr uses its documented MD5 password hash in their local configuration. No temporary password or manual Web UI configuration is needed. Passwords must be at least six characters long.

```bash
source ./scripts/set-env.sh
./stack.sh bootstrap
```

After bootstrap, Prowlarr syncs indexers to Sonarr and Radarr. SABnzbd is the primary download client and qBittorrent is the secondary fallback:

```text
SABnzbd host: sabnzbd
SABnzbd port: 8080
SABnzbd categories: tv, movies
qBittorrent host: gluetun
qBittorrent port: 8080
Sonarr category: tv
Radarr category: movies
Usenet path: /data/usenet
Torrent path: /data/torrents
```

Radarr download clients are baselined too: SABnzbd uses `movies`, priority `1`, completed download handling on, and default movie priorities; qBittorrent uses `movies`, post-import category `movies-imported`, priority `2`, completed download handling off, and default movie priorities.

Sonarr media management is also baselined from the current dev config: episode renaming is enabled, hardlinks are enabled, proper/repack upgrades are preferred, season folders are `Season {season:00}`, specials go under `Specials`, and anime names include series year, season/episode, absolute number, custom formats, quality, media info, and release group.

Jellyfin is baselined during bootstrap too: the server name defaults to `Media Stack` unless `JELLYFIN_SERVER_NAME` is set, `Movies` points at `/data/media/movies`, `Shows` points at `/data/media/tv`, Live TV gets the ErsatzTV M3U tuner `http://ersatztv:8409/iptv/channels.m3u`, and guide data gets the ErsatzTV XMLTV feed `http://ersatztv:8409/iptv/xmltv.xml`.

For more than two SABnzbd servers, inject `SAB_SERVERS_JSON` from your secret manager instead of using the interactive helper. It accepts either an array or an object with a `servers` array. Each server needs `host`, `username`, and `password`; optional fields include `name`, `displayName`, `port`, `connections`, `ssl`, `enable`, `priority`, `optional`, `required`, `retention`, and `sslVerify`.

**2. Configure Prowlarr indexers.** Copy the example and edit it before bootstrap. Bootstrap imports `indexers.json` after creating Prowlarr's Sonarr/Radarr links; entries disabled in the file or missing their optional `env:` key are skipped. To rerun the idempotent importer after changing indexers or setting an API key:

```bash
cp indexers.example.json indexers.json
$EDITOR indexers.json
./stack.sh import-indexers
./stack.sh import-indexers indexers.json --dry-run
```

For private indexer credentials, put environment references in `indexers.json` instead of clear-text secrets:

```json
{
  "indexers": [
    {
      "schemaName": "Some Private Tracker",
      "name": "Some Private Tracker",
      "enable": true,
      "fields": {
        "username": "env:TRACKER_USER",
        "password": "env:TRACKER_PASS"
      }
    }
  ]
}
```

**3. Confirm root folders and hardlinks.** Bootstrap creates Sonarr root folder `/data/media/tv` and Radarr root folder `/data/media/movies`. Under Media Management, confirm **Use Hardlinks instead of Copy** is enabled.

**4. Quality profiles.** Sync them from [TRaSH Guides](https://trash-guides.info/) instead of hand-tuning custom formats:

```bash
./stack.sh sync-profiles --preview
./stack.sh sync-profiles
```

The first run copies `recyclarr.example.yml` to `config/recyclarr/recyclarr.yml`, then applies it. Bootstrap also synchronizes this validated v8 baseline before configuring Seerr. The shipped file syncs a 1080p WEB profile and `[Anime] Remux-1080p` with TRaSH's required custom formats and scores. Edit `config/recyclarr/recyclarr.yml` to add optional v8 `custom_format_groups`, then re-run. Do not use obsolete `include: template:` examples from older Recyclarr releases.

The wrappers read the Sonarr and Radarr API keys out of `config/` and inject them as environment variables, so no key is ever written into the Recyclarr config.

The negative scores on Anime Raws and Anime LQ Groups are what actually keeps unsubbed and low-quality anime releases out of the library; the profile's minimum format score rejects them rather than merely depranking them. Recyclarr owns the formats and profiles it manages, so anything you created by hand under the same names is overwritten — run `--preview` first.

[Buildarr](https://github.com/buildarr/buildarr) covers the same ground if you want indexers and naming schemes declarative too.

**5. Jellyfin and Moonbase** (`:8096`). Bootstrap creates the `Movies` and `Shows` libraries, sets the server name, and adds ErsatzTV as an M3U tuner with XMLTV guide data. It also merges the official Moonbase catalog into Jellyfin's repository list, installs the `MOONBASE_VERSION` pinned in `.env`, restarts Jellyfin when installation state changes, merges the Moonbase plugin configuration, and verifies `/Moonfin/Ping`. Moonbase settings sync and the Seerr integration default to enabled; the server-to-server URLs default to `http://seerr:5055` and `http://jellyfin:8096`. Set `MOONBASE_ENABLED=false` to skip plugin management, or change the `MOONBASE_*` values in `.env` before bootstrap. Optional TMDB and MDBList keys come from the current shell, never `.env`. After Seerr is configured, bootstrap requests Moonbase webhook reprovisioning. Then in Sonarr and Radarr, Settings → Connect → add Jellyfin so imports trigger an immediate scan.

**6. ErsatzTV** (`:8409`). Add `/data/media` as a local media source, or connect ErsatzTV to Jellyfin if you prefer it to read Jellyfin libraries and metadata. Create collections or smart collections, then create channels and schedules. ErsatzTV exposes M3U tuner and XMLTV guide URLs, and bootstrap adds those URLs to Jellyfin Live TV.

Typical internal URLs look like this:

```text
ErsatzTV UI: http://ersatztv:8409
Host UI: http://localhost:8409
Jellyfin tuner URL: http://ersatztv:8409/iptv/channels.m3u
Jellyfin guide URL: http://ersatztv:8409/iptv/xmltv.xml
```

Use ErsatzTV for lean-back channels: shuffled sitcom blocks, network-themed schedules, non-consecutive episodes, marathons, or always-running pseudo-cable channels.

**7. Bazarr** last. Point it at Sonarr and Radarr, create a language profile, let it backfill.

**8. Seerr** is auto-configured by bootstrap: API keys are read from Sonarr and Radarr config, the `Sonarr`/`Radarr` servers use the Docker hostnames `sonarr:8989` and `radarr:7878`, scan/sync is enabled, and the TRaSH quality profiles are selected. After bootstrap restarts Seerr, it will be ready to request content. Log in with your Jellyfin administrator account (configured in `JELLYFIN_USER`/`JELLYFIN_PASS`), or use the email in `SEERR_EMAIL` if auto-initialization is disabled.

**9. Prove the pipeline with one title.** Add a single show, watch it go from grab to Jellyfin, then confirm the hardlink:

```bash
df -h /data                                    # note usage
ls -l /data/torrents/<file> /data/media/tv/<file>   # link count should be 2
df -h /data                                    # usage should barely move
```

For a direct container check, use semicolons between shell commands:

```bash
docker compose exec -T sonarr sh -lc 'rm -f /data/torrents/hltest.txt /data/media/tv/hltest.txt; echo test > /data/torrents/hltest.txt; ln /data/torrents/hltest.txt /data/media/tv/hltest.txt; stat -c "%h links: %n" /data/torrents/hltest.txt /data/media/tv/hltest.txt; rm -f /data/torrents/hltest.txt /data/media/tv/hltest.txt'
```

If usage jumped by the file size, hardlinks are not working. Fix that before adding anything else.

## Everyday commands

```bash
./stack.sh up                 # start
./stack.sh ps                 # status
source ./scripts/set-env.sh   # prompt for session env vars
./stack.sh setup-data         # create /data/usenet, /data/torrents, and media folders
./stack.sh bootstrap          # configure authentication, apps, clients, Moonbase, Jellyfin, and Seerr
./stack.sh audit-anime        # verify Sonarr and Seerr anime routing
./stack.sh import-indexers    # import local indexers.json into Prowlarr
./stack.sh sync-profiles      # sync TRaSH quality profiles and custom formats
./stack.sh doctor             # check Docker, data paths, hardlinks, APIs, and Gluetun
./stack.sh logs sonarr        # follow one service
./stack.sh restart gluetun    # restart one service
./stack.sh config             # print merged compose
./stack.sh verify             # confirm the VPN is carrying torrent traffic
./stack.sh pull               # update images, recreate, prune
./stack.sh backup             # stop, archive config/ and .env, start
./stack.sh down               # stop and remove
```

Backups and logs are not redacted. Treat backup archives as sensitive because they include `config/`, which can contain app API keys, database files, and session tokens. Be thoughtful when sharing `logs` output from real services.

### Reset For Testing

To recreate containers without deleting images or app configuration:

```bash
docker compose down
docker compose up -d
```

To test a true first-run bootstrap while keeping images, remove only app state:

```bash
docker compose down
rm -rf config
source ./scripts/set-env.sh
docker compose up -d
./stack.sh setup-data
./stack.sh bootstrap
./stack.sh doctor
```

Do not use `docker compose down --rmi all` unless you intentionally want to remove downloaded images.

## The two things that break this stack

Almost every problem people hit is one of these.

### Hardlinks need one filesystem

Sonarr and Radarr mount **all** of `/data`, not just the media folders. That is not an oversight. Import creates a hardlink so the file appears in both the download folder and the library, consuming space once, letting the download keep seeding independently. Hardlinks only work within a single filesystem.

Mount downloads and media as two separate volumes and the container sees two filesystems. Hardlinks fail, imports fall back to copies, and **nothing reports an error**. If imports are slow and disk usage spikes during them, this is why.

### Path consistency across containers

Every service must see the same host directory at the same container path. If qBittorrent reports a finished file at `/downloads/x.mkv` but Sonarr expects `/data/torrents/x.mkv`, the import fails with "path does not exist" while the file sits right there. The base compose mounts `${DATA_ROOT}:/data` uniformly for exactly this reason. Do not "simplify" it per service.

## Security model

Three paths cross the network edge. Two are outbound-initiated; one is refused.

```
qBittorrent ──► Gluetun ──► VPN exit ──► swarm        (sees the VPN's IP)
your phone  ──► Tailscale ──► oden (subnet router) ──► NAS   (home-network)
internet    ──► router ──╫──  server                   (0 ports forwarded)
```

**This repository does not configure router port forwarding.** Service ports bind to `BIND_ADDR` (the NAS's LAN address); home-network's zone firewall decides who reaches them, and oden's Caddy is the normal way in. Bootstrap enables application authentication rather than relying on network placement alone.

Worth being precise about scope: Gluetun controls where qBittorrent's traffic *exits*. It does not isolate it laterally. Gluetun sits on `medianet`, so a compromised qBittorrent can reach Sonarr and Jellyfin on the bridge. The tunnel is a privacy control, not a containment boundary.

### Hardening already applied

- `no-new-privileges:true` on application services except the network-control container Gluetun
- Jellyfin's media mount is read-only
- No Docker socket mounted anywhere
- LinuxServer application images receive `PUID`/`PGID`; Recyclarr has an explicit user, while Gluetun retains the privileges needed for network control

`cap_drop: ALL` is deliberately omitted. The LinuxServer images use s6-overlay and need `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, and `FOWNER` to start; shipping it enabled would break the stack on first run. Gluetun has an active local health endpoint check, so qBittorrent's `condition: service_healthy` gates startup on VPN health. This branch has no active CI workflow, so validate the overlays manually with `./stack.sh config`.

### What to avoid adding

**Avoid mounting `/var/run/docker.sock`.** Watchtower, Portainer, and some dashboards ask for it. Anything holding that socket can start a privileged container mounting `/`, and is therefore root on the host. The optional autoheal overlay is a narrowly scoped exception: it is disabled by default, watches only labeled services, and still carries host-root-equivalent risk even with a `:ro` mount. See [the Linux systemd and autoheal guide](docs/LINUX_SYSTEMD_SERVICE.md) before enabling it.

**Think twice about FlareSolverr.** It is a headless Chromium that visits indexer sites and executes whatever JavaScript they serve. Add it only if an indexer genuinely requires it, and remove it when it does not.

## Updates

```bash
./stack.sh pull
```

With `latest` tags, `pull` can update immediately to newer upstream images. If you prefer deterministic upgrades, pin explicit tags in `docker-compose.yml` and update on your schedule.

Version floors worth knowing:

- **Jellyfin ≥ 10.11.7** — two critical RCEs below this, one unauthenticated (CVE-2026-35033) and one a path traversal to root (CVE-2026-35031).
- **Seerr ≥ 3.1.0** — unauthenticated account registration bypass on Plex-configured instances (CVE-2026-27707).
- **qBittorrent ≥ 5.0.1** — 14 years of ignored SSL certificate validation errors (CVE-2024-51774).

Back up before upgrading. `./stack.sh backup` stops the stack, archives `config/` and deployment files, and starts it again. Restoring is a matter of extracting the archive over a fresh clone.

## Troubleshooting

**Bootstrap says `QBIT_PASS` or other UI variables are missing.** Session variables do not survive closing the terminal. Run `source ./scripts/set-env.sh` in the same shell before `./stack.sh bootstrap`. Use `--force` if you intentionally need to replace previously entered values.

**Prowlarr rejects the configured login after bootstrap.** Run `source ./scripts/set-env.sh --force`, enter the intended Prowlarr credentials, then rerun `./stack.sh bootstrap`. Bootstrap recreates the Forms user, restarts Prowlarr, and verifies the login redirect before continuing.

**qBittorrent works on the NAS but not through Caddy or another VLAN.** Gluetun's firewall is dropping return traffic. `LAN_SUBNET` in `.env` must cover the home VLANs (`10.0.0.0/16`).

**SABnzbd cannot download from Usenet.** Rerun `source ./scripts/set-env.sh --force`, set the `SAB_SERVER_*` provider values, then rerun bootstrap. Provider server credentials are read from the shell and written into SABnzbd's local config, not committed to this repo.

**ErsatzTV opens but Jellyfin has no channels.** ErsatzTV creates channels, but Jellyfin does not discover them automatically. In Jellyfin, add an M3U tuner using `http://ersatztv:8409/iptv/channels.m3u`, then add XMLTV guide data from `http://ersatztv:8409/iptv/xmltv.xml` and refresh guide data.

**`verify` reports matching IPs.** qBittorrent is not in Gluetun's namespace. Check that `network_mode: "service:gluetun"` survived any local edits, and that `./stack.sh config` still shows it.

**Imports are slow and disk usage spikes.** Hardlinks are failing. Confirm `/data` is one filesystem and that both Sonarr and qBittorrent mount `${DATA_ROOT}` at `/data`.

**"Path does not exist" on import.** Path mismatch between the download client's reported path and what Sonarr expects. Both must be `/data/torrents/...`.

**qBittorrent web UI returns "Unauthorized."** qBittorrent 5.x validates the Host header. Set the WebUI's alternative hostname allowlist, or reach it via the address it expects.

**qBittorrent does not start, or `doctor` / `verify` reports that Gluetun is not healthy.** qBittorrent waits for Gluetun's local health endpoint. Repeated failures usually indicate a bad VPN server, failed tunnel, or unavailable Gluetun health server. Check `./stack.sh logs gluetun` before changing anything else.

**Gluetun logs show `AUTH_FAILED`.** The VPN provider rejected `secrets/openvpn_user` or `secrets/openvpn_password`. For NordVPN, use the manual/service credentials for OpenVPN, not necessarily the email/password you use for the website or app. Rerun `./stack.sh init-vpn`, recreate Gluetun, then run `verify` again. Do not create these files with `echo`; its trailing newline becomes part of the credential.

## Linux service and reboot recovery

After completing and verifying the initial Linux deployment, install it as a
systemd-managed service:

```bash
./stack.sh install-service
```

The installer generates a unit for the current checkout and a Docker service
drop-in that requires both the checkout/config path and `DATA_ROOT` to be
mounted before Docker restores containers. It enables normal `systemctl`
lifecycle control.

An optional autoheal overlay adds application health checks and restarts only
explicitly labeled unhealthy containers:

```bash
./stack.sh install-service --enable-autoheal
```

Autoheal requires the Docker socket and therefore has host-root-equivalent
access even though the socket is mounted `:ro`. It is disabled by default. Read
[the Linux systemd and autoheal guide](docs/LINUX_SYSTEMD_SERVICE.md) for the
threat model, custom paths, reboot test, NAS power recovery, troubleshooting,
and uninstall steps.

## Legal

This is general-purpose automation. It searches indexes, talks to a download client, renames files, and serves a library. There is nothing infringing about any of that, and there are entirely legitimate uses: organising your own disc rips, managing public-domain and Creative Commons material, keeping self-produced media sorted.

What you point the indexers at is your responsibility. This repo ships an editable `indexers.example.json` with example public indexer definitions and can import the enabled entries into Prowlarr; review and change that file for your own lawful use before importing it. Check the law where you live.