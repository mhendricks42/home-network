# Docker deployment runbook

## Scope and prerequisites

This implements the container layer in [the architecture](home-server-architecture.md).
Commands below run in a Bash shell on the **target Linux host**. Do not run them
on the Windows development machine. Keep an independent laptop clone.

Configure the gateway and network policy with the
[UCG Max runbook](ucg-max-runbook.md), coordinating its DNS cutover with section 4.

- Server: Debian, Docker Engine and Compose **2.24.4+**, SSH, `mountpoint`, and
  working host DNS/NTP. Pi: **64-bit** Raspberry Pi OS, Docker and Compose.
- Fixed addresses: server `10.0.40.10`, Pi `10.0.40.11`. The NAS and gateway
  addresses in the Caddyfile are `10.0.40.20` and `10.0.10.1`.
- Docker networks `172.28.0.0/24` and `172.29.0.0/24` must not overlap existing
  networks/VPNs. If changed, update Unbound ACL/address, AdGuard upstream, and
  Home Assistant `trusted_proxies` together.
- Install host security updates, key-only SSH, firewall, Tailscale, NUT and
  restic separately. The Compose stacks do **not** configure or replace these.
- The domain is `foxhound.nexus` on Cloudflare DNS (see the Caddy section).
  No publicly reachable port or public DNS A record is required for DNS-01.
- Image tags are explicit release pins, not immutable digests. Review release
  notes and resolve digests before a production rollout. Unbound's Debian
  packages and the selected Caddy plugin resolve at build time; retain built
  image digests if reproducible rebuilds are required.

### Firewall prerequisites (before startup)

Docker-published ports can bypass a host firewall's normal INPUT rules. Apply
the gateway policy and Docker forwarding rules, not just `ufw allow/deny`:

| Host | Allowed inbound |
|---|---|
| Server | TCP/UDP 53 from intended client networks; TCP 443 from Trusted and approved tailnet clients; SSH from admin devices |
| Pi | TCP/UDP 53 from intended client networks; TCP 3001 **only from `10.0.40.10`**; SSH from admin devices |

All app port mappings on the server bind to loopback. Caddy and NetAlertX use
host networking: Caddy is the only public HTTP entry point; NetAlertX explicitly
listens on loopback. Deny externally reachable NetAlertX ports 20211/20212 and
Caddy admin 2019 as defense in depth. Unbound and MQTT publish no ports.
Uptime Kuma's server-only backend port is the deliberate cross-host exception.
Its proxy is unavailable when the server fails, but Pi monitoring continues.

No HTTP port 80 is opened: Caddy obtains certificates through DNS-01 and serves
HTTPS only. Use explicit `https://` URLs. Leave router port forwarding/UPnP off.

## 1. Prepare both targets

Clone/copy this repository onto each target. The examples use `/srv` for state;
if changed, give the same root to `prepare.sh` and `DATA_ROOT` in `.env`.

```bash
cp .env.example .env
chmod 600 .env
# On the server:
sudo sh scripts/prepare.sh server /srv
# On the Pi, instead:
sudo sh scripts/prepare.sh pi /srv
```

Preparation preserves every existing file. It never formats/mounts disks,
overwrites application state, or generates replacement radio keys.
Edit `.env` on each target; never commit plaintext credentials.
The examples in Git contain no real passwords. SOPS/age decryption is a
separate deployment step; do not treat the gitignore as encryption.

### DNS on both nodes

Edit `/srv/adguard/config/AdGuardHome.yaml` while AdGuard is stopped:

1. Replace `REPLACE_WITH_BCRYPT_HASH` with a bcrypt password hash. One way to
   generate it interactively without putting a password in shell history:
   `docker run --rm -it caddy:2.11.7 caddy hash-password`.
2. Keep the hash inside YAML quotes if necessary; do **not** put it in `.env`
   (Compose interprets dollar signs). Restrict the file to root (`chmod 600`).
3. Add kids' device IPs as a more-specific client profile with local family
   blocklists, safe search, and desired blocked services. Their addresses and
   policy are not decided in the architecture, so no kids are guessed here.

Both nodes use the same file and 24-hour query/statistics retention to limit Pi
writes. The upstream is the fixed, Docker-only Unbound address, without a
public bootstrap/fallback resolver. Work has filtering disabled; Trusted and
Guest use the base filter; IoT uses filtering with no external safety service.
Further per-client lists/rules must be chosen explicitly. Local lists do not
prevent every encrypted-DNS bypass; gateway egress policy is still required.

The service wildcard resolves to `10.0.40.10`. Do not switch DHCP resolvers yet.
The DNS bindings intentionally target each LAN IP. Once Tailscale is configured,
add the server's actual Tailscale IP as an additional TCP/UDP 53 binding in a
local Compose override, and allow intended tailnet clients DNS in the ACL.
Remote split DNS otherwise cannot work; do not expose an unrestricted resolver.

## 2. Server credentials and application configuration

### MQTT

Preparation creates an empty password file. Populate all three accounts
interactively, using distinct passwords:

```bash
for user in homeassistant zigbee2mqtt frigate; do
  sudo docker run --rm -it \
    -v /srv/mqtt/config:/credentials \
    eclipse-mosquitto:2.0.22 mosquitto_passwd /credentials/passwords "$user"
done
sudo chown 1883:1883 /srv/mqtt/config/passwords
sudo chmod 600 /srv/mqtt/config/passwords
```

Set `MQTT_Z2M_PASSWORD` and `MQTT_FRIGATE_PASSWORD` in `.env` to those same
passwords. Keep HA's password in its integration storage/password manager.
The ACL allows each publisher its own topic tree; only HA and Zigbee2MQTT can
write Zigbee bridge requests. HA may send Frigate control messages.
Reload/restart Mosquitto after changing credentials.

### Forgejo

`/srv/forgejo/data/gitea/conf/app.ini` is prefilled for
`git.home.foxhound.nexus`. Registration and anonymous repository access are disabled.
SQLite, HTTPS Git and local storage are used; no Git SSH port is published.
Forgejo manages its generated signing/token material in this writable config.
After startup create an initial administrator:

```bash
sudo docker compose -f compose.server.yml exec --user 1000:1000 forgejo \
  forgejo --config /data/gitea/conf/app.ini admin user create \
  --username admin --email YOUR_EMAIL --admin --random-password \
  --must-change-password
```

Store the printed password securely and change it at first login.

### Caddy (`https` profile): Cloudflare DNS and Let's Encrypt

The domain is `foxhound.nexus`, registered and hosted on Cloudflare. Caddy
gets one Let's Encrypt wildcard certificate, `*.home.foxhound.nexus`, through
the DNS-01 challenge: it adds a temporary `_acme-challenge` TXT record using the
Cloudflare API, then removes it. Nothing is published: no public A records, no
open ports. Household and tailnet clients resolve the names only through the
AdGuard rewrite.

**Cloudflare dashboard (once):**

1. **DNS → Records:** create **no** `home` or `*.home` records. A public
   wildcard would expose internal names and addresses for no benefit.
2. **DNS → Records → Add CAA:** name `@`, tag *Only allow specific hostnames*
   (`issue`), CA `letsencrypt.org`; add the same with *Only allow wildcards*
   (`issuewild`). Other CAs can then never issue for the domain. (Caddy's
   ZeroSSL fallback is blocked too, which is intended.)
3. **DNS → Settings → DNSSEC:** enable. Cloudflare Registrar adds the DS
   record itself. Unbound validates it.
4. **My Profile → API Tokens → Create Token → Custom token:**
   - Permissions: **Zone · Zone · Read** and **Zone · DNS · Edit**.
   - Zone resources: **Include → Specific zone → `foxhound.nexus`**.
   - Client IP filtering: leave empty; the AT&T public IP can change.
   - TTL: no expiry. Caddy needs the token at every renewal, so an expired
     token silently breaks renewal ~60 days later. Rotate it yearly instead.
5. Verify the token without putting it in shell history:

   ```bash
   read -rs CF && curl -sS -H "Authorization: Bearer $CF" \
     https://api.cloudflare.com/client/v4/user/tokens/verify; unset CF
   ```

   Expect `"status":"active"`.

**Server `.env`:** `HOME_DOMAIN`, `CADDY_DNS_MODULE` and `DNS_PROVIDER` come
prefilled from `.env.example`. Set `ACME_EMAIL` (expiry notices) and
`DNS_API_TOKEN` (the token above). `.env` stays `chmod 600`.

The Caddyfile sends the challenge's DNS lookups to `1.1.1.1`/`1.0.0.1`. The
local AdGuard rewrite answers for `*.home.foxhound.nexus`, and the Cloudflare
module fails with `expected 1 zone, got 0` if it asks AdGuard. The Servers zone
allows outbound DNS (architecture §9.5), so no firewall change is needed.

Create two root-readable Caddy import files:
`/srv/caddy/config/esphome-users` and `/srv/caddy/config/alerts-users`.
Each contains `admin BCRYPT_HASH` on one line. Generate a **separate** password
with the interactive `caddy hash-password` command above. ESPHome and NetAlertX
are authenticated at the proxy. Other routes retain their own app login.

**First certificate:**

1. Start with `sudo sh scripts/start.sh server https` (plus other configured
   profiles). The first run builds Caddy with the Cloudflare module.
2. Watch `sudo docker compose -f compose.server.yml --profile https logs -f caddy`
   for `certificate obtained successfully` for `*.home.foxhound.nexus`.
   `HTTP 403`/`Invalid request headers` means a token or permission problem.
3. Let's Encrypt allows 5 identical certificates per week. If you need several
   attempts, add `ca https://acme-staging-v02.api.letsencrypt.org/directory`
   inside the `tls` block until it works, then remove it and delete
   `/srv/caddy/data/caddy/certificates/acme-staging*` before the real run.
4. From a Trusted client: open `https://ha.home.foxhound.nexus` and check the
   issuer is Let's Encrypt with no browser warning; an unconfigured name
   such as `https://nope.home.foxhound.nexus` returns 404.

**Renewal and upkeep:** Caddy renews automatically about a third of the way
before expiry and keeps the certificate in `/srv/caddy/data`. Add an Uptime
Kuma HTTPS monitor for `https://ha.home.foxhound.nexus` with *Certificate
Expiry Notification* on, so a failed renewal alerts before it breaks access.
To rotate the token: create a new one, update `DNS_API_TOKEN`, run
`sudo docker compose -f compose.server.yml --profile https up -d caddy`,
confirm the next renewal or restart logs no errors, then delete the old token.

Caddy runs on the host network to reach loopback backends without Docker socket
access or exposing them on the LAN. Its wildcard certificate covers only
`*.home.<domain>`; unknown names return 404. Frigate, UniFi and NAS backend
certificate verification is disabled intentionally for their local self-signed
certificates. Their network paths must remain trusted/restricted.

### Home Assistant and ESPHome

HA's initial config includes packages and UI-managed automations/scripts/scenes.
Keep `.storage` and the database in the writable `/srv/homeassistant/config`.
During HA onboarding, configure:

- MQTT at `mqtt:1883`, user `homeassistant`.
- Z-Wave JS at `ws://zwave:3000` after configuring the Z-Wave service.
- ESPHome integrations with device IPs and API encryption keys.
- NUT/UniFi/system monitoring and notifications after host/device setup.

HA/ESPHome use bridge networking to keep dashboards off the LAN. Multicast
discovery across that bridge/VLANs is not assumed: add devices by IP, set static
ESPHome addresses/use addresses, and test OTA. Initial ESPHome USB flashing is
a separate admin-laptop/device operation; no broad USB passthrough is provided.

## 3. Hardware profiles

### Radios (`radios`)

Set stable `ZIGBEE_DEVICE` and `ZWAVE_DEVICE` paths from
`/dev/serial/by-id/`, plus the actual `ZIGBEE_ADAPTER`. Set a long random
`Z2M_AUTH_TOKEN`. Do not enable the profile before attaching both radios.

Z2M starts with pairing closed and external JS disabled. It generates network
keys/PAN IDs on the first successful start; preserve `/srv/zigbee2mqtt/data`
and back up the coordinator before updates. Pair for short windows, using
install codes where supported.

Before adding Z-Wave devices, enable authentication in Z-Wave JS UI via an SSH
loopback tunnel (or a firewall-restricted admin session), select `/dev/zwave`,
generate/persist the S2 keys, enable the WebSocket server on 3000, and disable
its redundant MQTT gateway. Refuse S0 during inclusion. Neither S2 policy nor
controller firmware can be enforced by Compose; verify firmware 7.22.1+.

### Cameras (`cameras`)

Mount the recording disk at `/mnt/recordings` using its UUID. Create a marker
**only on the mounted disk**:

```bash
mountpoint -q /mnt/recordings && sudo touch /mnt/recordings/.homelab-recording-volume
```

`start.sh` rejects an unmounted directory. Compose separately requires the
existing marker file as a read-only bind mount: if the disk is absent on reboot,
Docker cannot create that mount and Frigate cannot start writing to the SSD.
Never create a marker in the bare, unmounted directory. Configure systemd/fstab
mount ordering so the disk is mounted before Docker restores the container.
The stack does not install those host units or recover a failed drive.

Set `DRI_DEVICE`, numeric `RENDER_GID` (`getent group render`) and ten
`FRIGATE_CAMERA_N_MAIN/SUB` RTSP URLs in `.env`. Use per-camera low-privilege
accounts, percent-encode credentials in URLs, and set the actual substreams
to 1280x720 / 5 fps or edit the detect dimensions. Test stream decoding.

The config uses VAAPI decoding, OpenVINO GPU inference, seven continuous days
and thirty days for alerts/detections, with no invented zones/masks. Disk
capacity depends on bitrate/events: measure it and tune retention. Port 5000,
RTSP and WebRTC are **not published**; use the authenticated UI on 8971 through
Caddy. WebRTC/direct restreaming would need a deliberate additional policy.
Recordings are on the HDD; snapshots/clips and Frigate's DB/config are under
`/srv/frigate` for backup.

### Device monitoring (`monitoring`)

NetAlertX requires host networking and scoped raw-network capabilities; it is
not privileged. Configure routed VLAN scans and AdGuard imports in its UI and
back up `/srv/netalertx/data`. ARP cannot scan across routers: use routed
ICMP/SNMP/controller plugins as applicable and grant only documented firewall
flows. Caddy adds authentication to the loopback dashboard.

## 4. Start and verify

```bash
# Pi:
sudo sh scripts/start.sh pi
# Server base services:
sudo sh scripts/start.sh server
# Add only configured profiles; HTTPS is optional until the domain is ready:
sudo sh scripts/start.sh server https radios cameras monitoring
```

`start.sh` checks placeholders, required profile credentials/devices, MQTT
accounts, and the recording mount before calling Compose. It cannot prove
passwords match, certify app settings, or validate remote hardware.
An omitted profile does not stop previously running containers in that profile;
use `docker compose ... --profile NAME stop SERVICE` deliberately.

For base-service onboarding without HTTPS, use SSH loopback tunnels such as
`ssh -L 8123:127.0.0.1:8123 ADMIN@10.0.40.10`.
For Z-Wave authentication setup use a separate 8091 tunnel before proxy access.

Acceptance checks on the real targets:

1. `docker compose -f compose.server.yml --profile '*' ps` and the Pi equivalent:
   check every enabled service, then inspect its logs for startup/config errors.
2. Query each DNS IP with both UDP and TCP; test public recursion, a blocked
   domain, DHCP `home.arpa`, and wildcard rewrites. Verify DNSSEC with a known
   broken-signed domain. Stop server DNS and confirm clients still use the Pi.
3. Validate Caddy with `docker compose -f compose.server.yml --profile https exec
   caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`.
   Test every configured HTTPS name and confirm unconfigured names return 404.
4. From another LAN host, confirm only DNS/443 are reachable on the server;
   MQTT/5000/5335/application dashboards must not be reachable directly.
   Confirm Kuma 3001 is reachable from the server but denied from clients.
5. Verify HA proxy login, MQTT authentication/ACL rejection, Zigbee closed
   pairing, Z-Wave S2, ESPHome encrypted API, GPU detection, all five camera
   recordings, and playback. Check free space and memory under load.
6. Create/login to Kuma **before granting its backend firewall access broadly**.
   Add server/gateway/internet/DNS/HTTPS monitors and a notification destination.
   Simulate server failure; verify an alert arrives independently from the Pi.
7. Only then change DHCP to advertise both DNS addresses. Verify reboot,
   missing-disk behavior, power-loss shutdown, backups and a restore.

Kuma monitors, NetAlertX integrations, HA integrations, Z-Wave keys/auth and
zones/masks need real devices/accounts and remain explicit first-run tasks,
not fabricated configuration.

## 5. Optional Forgejo runner (`actions`)

Actions is disabled by default. Enable it in Forgejo's deployed `app.ini`,
restart Forgejo, and obtain a **repository-scoped** runner registration token.
Register interactively; do not put the token in a command argument/history:

```bash
sudo docker compose -f compose.server.yml --profile actions run --rm --no-deps \
  runner forgejo-runner register --config /etc/runner.yaml
```

Use `http://forgejo:3000` as the internal instance URL and label `homelab:host`.
Enable only for trusted private repositories. Start with
`sudo sh scripts/start.sh server actions` (plus any other configured profiles).
Jobs execute **inside the runner container**, as non-root, without a Docker
socket or host SSH keys. This runner deliberately cannot administer hosts.
Ansible tools/credentials and nightly infrastructure drift checks belong to
the future host-provisioning layer, not this container-only implementation.
Add a dedicated isolated runner/tool image and scoped credentials when that
layer exists; never give arbitrary repository jobs the host Docker socket.

## 6. Updating, backup and recovery

- Keep `.env`, Caddy credential files, Mosquitto passwords and radio keys out
  of plaintext Git. Restrict Docker admin membership (it is root-equivalent).
- Containers write state under `/srv/<service>`. For HA, Z2M and Forgejo, the
  config is part of the writable app directory; do not replace that directory
  with a fresh checkout. The initial config copies are intentionally not
  synchronized automatically. Stop the app and apply reviewed changes from
  Git to the deployed file, preserving UI state and generated secrets.
- To change AdGuard declaratively, stop it, deploy the reviewed config to
  **both** nodes, start each separately and test resolution between changes.
- Before updates, stop stateful writers or use their supported export/backup
  tools. Capture `/srv` on **both** nodes, `.env` and the NAS/host config with
  encrypted backup tooling. Never assume a live SQLite file copy is consistent.
- Exclude bulk `/mnt/recordings` from backups; include Frigate config/database
  and clips/snapshots. Back up Z2M coordinator state and Z-Wave NVM/keys.
- No backup timer, NAS mount, restic repository initialization, Forgejo NAS
  mirror, notifications or restore automation is installed here. These are
  go-live prerequisites, not an implied feature of Compose volumes.
- Update explicit tags/plugin versions after release-note review; run local
  validation, pull/build on the target, and rerun acceptance checks. Restoring
  old images may require restoring pre-migration data too.
- Test quarterly restoration onto a clean host before claiming recoverability.
