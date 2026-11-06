# Docker deployment runbook

## Scope and prerequisites

This implements the container layer in [the architecture](home-server-architecture.md).
Commands below run in a Bash shell on the **target Linux host**. Do not run them
on the Windows development machine. Keep an independent laptop clone.

The network ([UCG Max runbook](ucg-max-runbook.md)) and this runbook depend on
each other. Do the steps below **in order**; each one lists what must already
be done. "UCG §n" is the UCG Max runbook; "§n" is this runbook.

**vidar (the Pi) is installed natively without Docker:** follow
[vidar baseline](vidar-baseline.md) for it. Pi steps below that use Docker
(`compose.pi.yml`, `prepare.sh pi`, `start.sh pi`, the Pi `DOCKER-USER` rules)
are superseded by that document.

### Prerequisite order

**A. Network foundation**

| # | Step | Where | Needs | Done when |
|---|---|---|---|---|
| A1 | Gateway local setup, WAN, final LAN subnet | UCG §1–2 | — | Gateway reachable by IP from the wired admin laptop |
| A2 | Create networks; reserve server `10.0.40.10`, Pi `10.0.40.11`, NAS `10.0.40.20` and admin devices (`ADMIN_CLIENTS`) by MAC | UCG §3 | A1, host MACs | Reservations recorded in the operations inventory |
| A3 | Adopt switches/APs; set port profiles: Pi on core port 6, server and NAS on office ports 2/3 (Servers access) | UCG §4 | A2 | Hosts' ports carry VLAN 40 untagged |
| A4 | Zone firewall Z1–Z22 and Z25–Z33, with **Z13 created disabled** | UCG §5 | A2 (the address objects use those IPs) | Matrix matches architecture §9 |

Z13 blocks gateway DNS for non-admin Trusted devices. Until D3, DHCP still
advertises the gateway as DNS, so enabling Z13 earlier would cut their name
lookups. It is enabled one DHCP lease time after D3.

**B. Hosts**

| # | Step | Where | Needs | Done when |
|---|---|---|---|---|
| B1 | NAS on `10.0.40.20`: HTTPS admin UI on, Ugreen cloud and UPnP off | NAS UI | A3 | `https://10.0.40.20:9443` loads from the admin laptop |
| B2 | Install OS: Ubuntu Server 26.04 LTS on the server, **64-bit** Raspberry Pi OS Lite on the Pi | Console | A3 | `ip -br addr` shows `.10` / `.11` |
| B3 | Host basics: security updates and unattended-upgrades, key-only SSH (SSH access from admin devices). Point each **host's own** resolver at its gateway `10.0.40.1`, not at AdGuard | Host | B2, A2 (admin device reservations) | `apt update` works; password SSH login is refused |
| B3a | chrony NTP server on both hosts (Time service) | Host | B3 | `chronyc tracking` shows `Leap status: Normal` on both |
| B4 | Docker Engine and Compose **2.24.4+** from Docker's apt repository; keep the default iptables backend | Host | B3 | `docker compose version` ≥ 2.24.4 |
| B5 | Check that `172.28.0.0/24` and `172.29.0.0/24` don't overlap any route or VPN | Host | B4 | `ip route` shows no overlap |
| B6 | Host firewall: ufw rules and `DOCKER-USER` rules, then enable (Firewall prerequisites, steps 1–2). Skip the `tailscale0` line until E1 | Host | A2 (`ADMIN_CLIENTS`), B3a, B4 | `iptables -L DOCKER-USER` ends in `DROP`; SSH still works from an admin device |

B3 keeps the hosts independent of their own containers: image pulls, the Caddy
build and reboots must work before (or without) AdGuard.

**C. Configuration before first start**

| # | Step | Where | Needs | Done when |
|---|---|---|---|---|
| C1 | Clone the repository; `cp .env.example .env`; run `prepare.sh` | §1 | B4 | `/srv` folders exist on both nodes |
| C2 | AdGuard admin bcrypt hash on both nodes | §1 "DNS on both nodes" | C1 | No `REPLACE` left in `AdGuardHome.yaml` |
| C3 | MQTT accounts and matching `.env` passwords; Forgejo config check | §2 | C1 | `start.sh server` passes its credential checks |
| C4 | *(https)* Cloudflare token, CAA, DNSSEC; `ACME_EMAIL`, `DNS_API_TOKEN`; Caddy basic-auth files | §2 Caddy | C1, B3 (outbound DNS/HTTPS) | Token verify returns `active`; both auth files exist |
| C5 | *(radios)* Both USB radios attached; `/dev/serial/by-id` paths and `Z2M_AUTH_TOKEN` in `.env` | §3 Radios | C1 | Both device paths exist |
| C6 | *(cameras)* Cameras configured offline and reserved on VLAN 60 (UCG §3); recording disk mounted by UUID with mount ordering before Docker; marker file; GPU and RTSP values in `.env` | §3 Cameras | A4 (Z12 lets the server reach cameras), C1 | `mountpoint /mnt/recordings` succeeds; `ffprobe -rtsp_transport tcp 'URL'` (from `apt install ffmpeg`) lists the streams for one camera |
| C7 | *(production)* Review release notes and resolve image digests | §2 intro note | C1 | Pinned versions accepted |

Profiles marked *(…)* are needed only when that profile is enabled.

**D. Start, accept, cut over**

| # | Step | Where | Needs | Done when |
|---|---|---|---|---|
| D1 | Start the Pi, then the server base, then each configured profile | §4 | B6, C2–C6 | `start.sh` succeeds; all containers running |
| D2 | Acceptance checks 1–6, plus the host-firewall tests (Firewall prerequisites, step 3) | §4 | D1, A4 (Trusted test clients need Z1/Z5) | Every check passes |
| D3 | DNS and NTP cutover: set DHCP DNS and NTP to `.10`/`.11`; set UniFi device NTP; **enable Z13 one lease time later** | UCG §6 | D2 checks 1–2, B3a | Clients show both resolvers; a camera shows correct time; Trusted non-admins can't use gateway DNS |
| D4 | Move devices VLAN by VLAN; IDS/IPS in detect mode | UCG §7–9 | D3 | UCG acceptance table passes |

**E. Go-live (after cutover)**

| # | Step | Where | Needs | Done when |
|---|---|---|---|---|
| E1 | Tailscale on the server host: advertise `10.0.40.1/32`, `10.0.40.10/32`, `10.0.40.20/32`; approve routes; Tailnet Lock; ACLs; split DNS → `10.0.40.10`; add the `tailscale0` ufw line | Architecture §11 | D1 (AdGuard answering), B6 | From mobile data, `https://ha.home.foxhound.nexus` loads |
| E2 | NUT: Pi as NUT server on the closet UPS; server and NAS as clients | Host | B6 (Pi TCP 3493 rule) | `upsc` works from the server; a pulled-plug test shuts hosts down cleanly |
| E3 | Backups: restic to the NAS, UniFi config export, off-device copy | §6, UCG §10 | B1, D1 | One restore completes on a clean target |
| E4 | Final checks: reboot, missing recording disk, power-loss shutdown, backup restore | §4 check 7 | E2, E3 | All pass; record the date |

### Notes

- If the Docker subnets change, update the Unbound ACL/address, AdGuard
  upstream and the Home Assistant trusted proxy (Settings → System → Network) together.
- Host security, SSH, firewall, Tailscale, NUT and restic are host jobs. The
  Compose stacks don't configure or replace them.
- The domain is `foxhound.nexus` on Cloudflare DNS (see the Caddy section).
  No publicly reachable port or public DNS A record is required for DNS-01.
- Image tags are explicit release pins, not immutable digests. Unbound's Debian
  packages and the Caddy plugin resolve at build time; retain built image
  digests if reproducible rebuilds are required.

### SSH access from admin devices (step B3)

Admins sign in with an **SSH key**, never a password. The private key lives
**only in Dashlane** (as a secure note), protected by its own passphrase. The
Dashlane CLI (`dcli`) loads it straight into the SSH agent for a limited time;
it is never written to disk. (Dashlane has no SSH agent of its own.)

Store these in Dashlane:

| Dashlane item | Type | Content |
|---|---|---|
| `homeserver-ssh` | Secure note | The private key (`id_ed25519`, OpenSSH format, passphrase-protected) |
| `SSH passphrase – homeserver-ssh` | Password | Its passphrase (Dashlane generator, 24+ characters) |
| `sudo – oden` / `sudo – vidar` | Password | Your Linux user's password on each host (used for `sudo`, not SSH) |
| `SSH host keys` | Secure note | Each host's key fingerprint, recorded from the console (step 2) |

#### 0. Install the Dashlane CLI (`dcli`) on the admin device

WSL or Linux (x86-64). Pin a release from
[Dashlane/dashlane-cli releases](https://github.com/Dashlane/dashlane-cli/releases)
and update it the same way:

```bash
V=v6.2642.0
curl -fL -o dcli "https://github.com/Dashlane/dashlane-cli/releases/download/$V/dcli-linux-x64"
chmod +x dcli && sudo mv dcli /usr/local/bin/dcli
dcli --version
```

First login registers this device (email, then the 2FA or emailed code, then
the master password). WSL has no OS keychain, so don't let `dcli` store the
master password; it asks for it when needed instead:

```bash
dcli configure save-master-password false
dcli sync
```

| When | Command |
|---|---|
| After adding or changing a Dashlane item elsewhere | `dcli sync` (it also syncs itself hourly) |
| After loading the SSH key, or leaving the desk | `dcli lock` |
| Retiring or losing the device | `dcli logout` here, and remove the device under Dashlane's account settings |

#### 1. Create the key and move it into Dashlane

On an admin device (WSL or Linux), in a temporary folder, with the Dashlane
passphrase when asked:

```bash
cd "$(mktemp -d)"
ssh-keygen -t ed25519 -a 100 -C "matt@DESKTOP-IJ99M1L" -f id_ed25519
cat id_ed25519        # copy into the Dashlane secure note `homeserver-ssh`
cp id_ed25519.pub ~/.ssh/id_ed25519.pub
dcli sync
dcli n homeserver-ssh | tr -d '\r' | ssh-keygen -y -f /dev/stdin   # prints the public key: the note is intact
shred -u id_ed25519   # the private key now exists only in Dashlane
```

Save the note with the `-----BEGIN` and `-----END` lines included.

**Each session**, load it into the agent for one hour (`dcli n` reads the note;
`tr` strips Windows line endings that would break the key):

```bash
ssh-add -l >/dev/null 2>&1; [ $? -eq 2 ] && eval "$(ssh-agent -s)"   # start an agent if none
ssh-add -t 1h <(dcli n homeserver-ssh | tr -d '\r')
```

When the hour ends, the agent forgets the key and `ssh` says
`Permission denied (publickey)`; run the `ssh-add` line again. Use a separate
key and note per admin device if you want to revoke one device without the
others (the `-C` comment names it).

#### 2. Record each host's fingerprint (console)

On the server and on the Pi, at the local console:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Save both lines in the Dashlane note. The first time you connect, `ssh` shows a
fingerprint: continue only if it matches. Later warnings that the host key
changed mean either a reinstall or someone in the middle; check before
accepting.

#### 3. Install the public key on each host

Password login is still on at this point. From the admin device:

```powershell
ssh-copy-id -i ~/.ssh/id_ed25519.pub matt@10.0.40.10
ssh-copy-id -i ~/.ssh/id_ed25519.pub matt@10.0.40.11
```

Repeat for every admin device. Check `ssh matt@10.0.40.10` now logs in
without asking for the Linux password.

#### 4. Turn off password login (both hosts)

Keep your current session open while you do this, so a mistake can't lock you
out. Create `/etc/ssh/sshd_config.d/10-admin.conf`:

```text
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin no
AllowUsers matt
MaxAuthTries 3
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
```

```bash
sudo sshd -t && sudo systemctl reload ssh
```

sshd uses the **first** value it reads, and files in `sshd_config.d` are read
in name order. `10-` therefore wins over files such as `50-cloud-init.conf`
that some images ship with `PasswordAuthentication yes`. Port forwarding stays
on: the tunnels below need it.

Check from a **new** window:

```powershell
ssh matt@10.0.40.10                                        # works with the key
ssh -o PubkeyAuthentication=no matt@10.0.40.10             # must fail: Permission denied (publickey)
```

The firewall already limits port 22 to `ADMIN_CLIENTS` (zone policy Z7 and
the host ufw rules, step B6), and to admins over Tailscale (ACL).

#### 5. Shortcuts on the admin device

Create `%USERPROFILE%\.ssh\config` (Windows) or `~/.ssh/config`:

```text
# Keep idle sessions alive through Wi-Fi and firewall idle timeouts.
Host *
  ServerAliveInterval 60
  ServerAliveCountMax 3

Host oden
  HostName 10.0.40.10
  User matt
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes

Host vidar
  HostName 10.0.40.11
  User matt
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes

# Admin UIs that are deliberately loopback-only on the server.
Host oden-tunnels
  HostName 10.0.40.10
  User matt
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  LocalForward 8123 127.0.0.1:8123
  LocalForward 8091 127.0.0.1:8091
  LocalForward 8081 127.0.0.1:8081
```

Then `ssh oden`, `ssh vidar`, or `ssh oden-tunnels` (and browse to
`http://localhost:8123`, `:8091` or `:8081`). The same entries work away from
home over Tailscale, because the server advertises `10.0.40.10/32`. The Pi is
reached from the server: `ssh -J oden vidar`. Host names follow
[naming conventions](naming-conventions.md).

For `sudo`, paste the host's password from Dashlane.

#### Lost device or key

From another admin device (or the console), delete that device's line from
`~/.ssh/authorized_keys` on each host. Each line ends with the `-C` comment
from step 1, which names the device. Remove its address from `ADMIN_CLIENTS`
and its Dashlane passphrase item. Keep at least two admin devices with keys,
plus console access (keyboard and monitor on the server; the Pi's SD card),
so losing one device never locks you out.

### Time service (step B3a)

The UCG Max does not serve NTP to LAN clients. chrony on the server and Pi
**hosts** serves time to every VLAN instead (architecture §10.1). It replaces
`systemd-timesyncd`, which only acts as a client.

On both hosts:

```bash
sudo apt install chrony        # removes systemd-timesyncd
```

Create `/etc/chrony/conf.d/homelab.conf`. On the server use `10.0.40.11` as
`PEER`; on the Pi use `10.0.40.10`:

```text
# NTS-authenticated upstream; the distribution's default pool stays as a fallback.
server time.cloudflare.com iburst nts
# The other node: keeps both in agreement if one loses upstream.
server PEER iburst
# Serve all home VLANs.
allow 10.0.0.0/16
# Keep serving during an internet outage; the server's RTC anchors the Pi.
local stratum 10 orphan
```

```bash
sudo systemctl restart chrony
chronyc sources -v      # time.cloudflare.com and the pool reachable (^* or ^+)
chronyc tracking        # Leap status: Normal
sudo chronyc -N authdata  # time.cloudflare.com shows NTS (needs root)
```

NTS (authenticated NTP) needs outbound TCP 4460 as well as UDP 123. The
Servers zone allows all outbound traffic, so no gateway policy is needed.
After the firewall (B6) is on, check from a Trusted Windows client:
`w32tm /stripchart /computer:10.0.40.10 /samples:3 /dataonly`, then `.11`.
`sudo chronyc clients` on each host lists who is using it.
### Firewall prerequisites (step B6)

Docker-published ports can bypass a host firewall's normal INPUT rules. Apply
the gateway policy and Docker forwarding rules, not just `ufw allow/deny`:

| Host | Allowed inbound |
|---|---|
| Server | TCP/UDP 53 and UDP 123 from intended client networks; TCP 443 from Trusted and approved tailnet clients; SSH from admin devices |
| Pi | TCP/UDP 53 and UDP 123 from intended client networks; TCP 3001 **only from `10.0.40.10`**; SSH from admin devices; TCP 3493 (NUT) from the server and NAS |

All app port mappings on the server bind to loopback. Caddy and NetAlertX use
host networking: Caddy is the only public HTTP entry point; NetAlertX explicitly
listens on loopback. Unbound and MQTT publish no ports.
Uptime Kuma's server-only backend port is the deliberate cross-host exception.
Its proxy is unavailable when the server fails, but Pi monitoring continues.

**Why two layers.** The gateway can't filter the Servers VLAN internally:
the server, Pi and NAS share `10.0.40.0/24`, so their traffic is switched, not
routed. Each host must enforce its own row above. On the host, there are two
paths:

- **Host-network services** (SSH, chrony NTP, Caddy 443, NUT, and loopback-only Caddy
  admin 2019 and NetAlertX 20211/20212) go through the INPUT chain, which
  `ufw` controls.
- **Docker-published ports** (AdGuard 53 on both nodes, Kuma 3001 on the Pi)
  are DNAT'd (their destination is rewritten to the container) and go through
  the FORWARD chain. `ufw allow/deny` never sees them. Docker sends that traffic
  through the `DOCKER-USER` chain first, which it never edits, so the rules
  go there.

Keep Docker's default iptables backend: these rules assume it. Ports bound to
`127.0.0.1` are unreachable from other hosts and need no rule.

#### 1. ufw base rules (INPUT)

Run this on the console, or in an SSH session with a second session open.
Add SSH **before** enabling, then check it from the second session.

Server (replace `ADMIN_IP` with each address in `ADMIN_CLIENTS`; repeat the
first line per admin device):

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from ADMIN_IP to any port 22 proto tcp
sudo ufw allow in on tailscale0 to any port 22 proto tcp     # Tailscale ACL limits this to admins
sudo ufw allow from 10.0.0.0/16 to any port 123 proto udp   # chrony NTP for all VLANs
sudo ufw allow from 10.0.0.0/16 to 10.0.40.10 port 443 proto tcp
sudo ufw allow from 100.64.0.0/10 to 10.0.40.10 port 443 proto tcp
```

Pi:

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from ADMIN_IP to any port 22 proto tcp
sudo ufw allow from 10.0.0.0/16 to any port 123 proto udp   # chrony NTP for all VLANs
sudo ufw allow from 10.0.40.10 to any port 3493 proto tcp   # NUT client: server
sudo ufw allow from 10.0.40.20 to any port 3493 proto tcp   # NUT client: NAS
```

Default deny already covers Caddy admin 2019 and NetAlertX 20211/20212; no
extra deny rules are needed. Port 80 stays closed (DNS-01, no redirects). The
tailnet line uses `tailscale0` because Tailscale ACLs, not source IPs, decide
which remote users may SSH. Add it only after Tailscale is installed.

#### 2. Docker forwarding rules (`DOCKER-USER`)

Append the block for that host to the **end** of `/etc/ufw/after.rules`, after
the existing `COMMIT`. `ufw` loads it at boot before Docker starts and
reloads it with `ufw reload`. Declaring `:DOCKER-USER` in the file replaces
the chain's contents on each load, so rules don't pile up.

Server:

```text
# Docker-published ports (AdGuard DNS) - see docs/runbook.md
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i docker0 -j RETURN
-A DOCKER-USER -i br-+ -j RETURN
-A DOCKER-USER -p udp -m conntrack --ctorigdstport 53 --ctdir ORIGINAL -s 10.0.0.0/16 -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 53 --ctdir ORIGINAL -s 10.0.0.0/16 -j RETURN
-A DOCKER-USER -p udp -m conntrack --ctorigdstport 53 --ctdir ORIGINAL -s 100.64.0.0/10 -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 53 --ctdir ORIGINAL -s 100.64.0.0/10 -j RETURN
-A DOCKER-USER -j DROP
COMMIT
```

Pi:

```text
# Docker-published ports (AdGuard DNS, Uptime Kuma) - see docs/runbook.md
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i docker0 -j RETURN
-A DOCKER-USER -i br-+ -j RETURN
-A DOCKER-USER -p udp -m conntrack --ctorigdstport 53 --ctdir ORIGINAL -s 10.0.0.0/16 -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 53 --ctdir ORIGINAL -s 10.0.0.0/16 -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 3001 --ctdir ORIGINAL -s 10.0.40.10 -j RETURN
-A DOCKER-USER -j DROP
COMMIT
```

What each line does:

| Rule | Reason |
|---|---|
| `RELATED,ESTABLISHED` | Replies to connections that are already allowed, including container traffic going out |
| `-i docker0`, `-i br-+` | Traffic that starts inside containers (Unbound recursion, HA → IoT, Frigate → cameras) isn't filtered here. Compose networks are named `br-<id>` |
| `--ctorigdstport` | Matches the port the client asked for (53/3001) before Docker rewrote it, so the rule doesn't depend on container IPs |
| `10.0.0.0/16` | All home VLANs. The gateway decides which zones may query DNS (architecture §9.4 Z1–Z4); this layer only stops anything else |
| `100.64.0.0/10` (server only) | Tailscale clients using split DNS through the `10.0.40.10/32` route. The Pi doesn't run Tailscale |
| `3001` from `10.0.40.10` (Pi only) | Caddy on the server proxies `status.home.<domain>`; nobody else reaches Kuma directly |
| `DROP` | Everything else forwarded to a container from outside |

The published ports bind IPv4 addresses only, so there's no IPv6 Docker
exposure to filter.

#### 3. Enable and check

```bash
sudo ufw enable                         # or: sudo ufw reload, if already enabled
sudo ufw status verbose
sudo iptables -L DOCKER-USER -v -n --line-numbers
```

Expect the rules above in `DOCKER-USER`, ending in `DROP`, and the ufw rules
from step 1. Then reboot once and run the last command again: the chain must
still be there after Docker starts.

Test after the stacks are running (section 4), because the drop counters only
move once there's traffic:

1. From a Trusted client: `nslookup example.com 10.0.40.10` and `... 10.0.40.11`
   both answer.
2. On the server: `curl -sI http://10.0.40.11:3001` answers.
3. **Same-subnet test** (the gap the gateway can't cover): temporarily set a
   spare core-switch port to the Servers access profile and plug in a laptop
   with a free `10.0.40.x` address. `curl -m 5 http://10.0.40.11:3001`,
   `curl -m 5 http://10.0.40.10:8123` and `nc -zv -w 5 10.0.40.10 2019` must
   all fail. The `DROP` counter in `DOCKER-USER` rises for the 3001 attempt.
   Return the port to its normal profile afterwards.
4. From that laptop or a Trusted client, `ssh` from a non-admin address fails;
   from an admin device it works.

If DNS from a VLAN stops working, check the `DOCKER-USER` counters before
changing gateway policies: a `DROP` count that grows with each query means
the source isn't covered by `10.0.0.0/16`.

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
The DNS bindings intentionally target each LAN IP. For remote access, the
server advertises `10.0.40.10/32` as a Tailscale subnet route and split DNS
points at `10.0.40.10`, so no extra binding is needed. Allow tailnet clients
only TCP/UDP 53 and TCP 443 on that address in the ACL.

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
After startup create an initial administrator. Forgejo reserves the name
`admin`, so pick another (for example your own name):

```bash
sudo docker compose -f compose.server.yml exec --user 1000:1000 forgejo \
  forgejo --config /data/gitea/conf/app.ini admin user create \
  --username YOUR_USERNAME --email YOUR_EMAIL --admin --random-password \
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
2. **CAA records (optional hardening):** a CAA record lists which certificate
   authorities may issue certificates for the domain; all others must refuse.
   In **DNS → Records → Add record**, add two records:

   | Type | Name | Flags | Tag | CA domain name |
   |---|---|---|---|---|
   | CAA | `@` | 0 | Only allow specific hostnames | `letsencrypt.org` |
   | CAA | `@` | 0 | Only allow wildcards | `letsencrypt.org` |

   The second one matters most: the certificate is a wildcard
   (`*.home.foxhound.nexus`). Check with `dig CAA foxhound.nexus +short`.
   Caddy falls back to ZeroSSL if Let's Encrypt fails; these records block
   that, so a failed renewal simply retries Let's Encrypt later.
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

Create two root-readable Caddy import files, `/srv/caddy/config/esphome-users`
and `/srv/caddy/config/ersatztv-users`, each containing `admin BCRYPT_HASH` on
one line. Generate each hash with the interactive `caddy hash-password` command
above, using a **different** password for each (ESPHome's dashboard can flash
device firmware; don't let a leaked TV password open it). ESPHome and ErsatzTV
are authenticated at the proxy because they have no login of their own. Every other
route uses its app's login.

**Media stack routes** (`qbittorrent.`, `sabnzbd.`, `prowlarr.`, `sonarr.`,
`radarr.`, `bazarr.`, `jellyfin.`, `seerr.`, `ersatztv.`) go to `MEDIA_IP`
(default the NAS, `10.0.40.20`), which must be the media stack's `BIND_ADDR`.
The stack itself is deployed from [`media-stack/`](../media-stack/readme.md) on
the NAS, with `BIND_ADDR=10.0.40.20` and `LAN_SUBNET=10.0.0.0/16` in its `.env`.
Set these in the apps so they work behind the proxy:

| App | Setting |
|---|---|
| qBittorrent | Web UI → enable **reverse proxy support**, trusted proxy `10.0.40.10`; add `qbittorrent.home.foxhound.nexus` to **Server domains** |
| SABnzbd | Config → Special → add `sabnzbd.home.foxhound.nexus` to `host_whitelist`; turn on a username/password |
| Bazarr, Prowlarr, Sonarr, Radarr | Settings → General → **Authentication: Forms**, required for all addresses |
| Jellyfin | Dashboard → Networking → **Known proxies** `10.0.40.10` |

If the NAS firewall is on, allow those ports from `10.0.40.10` only. NetAlertX can't sit behind proxy Basic auth (its UI sends its own
`Authorization` header), so turn on its password under **Settings → Security**
and change the default `123456`.

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

**Reverse-proxy settings are set in the UI, not YAML.** Since 2026.10, HA keeps
its `http` settings in `.storage/http`. A changed setting runs as a 5-minute
trial: unless you confirm it, HA restarts with the previous settings. Until
proxying is confirmed, requests through Caddy fail with `400: Bad Request`
(log: *"not set-up for reverse proxies"*). So onboard directly, not via Caddy:

1. From the admin laptop: `ssh -L 8123:127.0.0.1:8123 ADMIN@10.0.40.10`,
   then open `http://localhost:8123` and finish onboarding.
2. **Settings → System → Network:** enable *Use X-Forwarded-For* and add
   trusted proxy `172.28.0.1` (the Docker gateway Caddy's requests arrive
   from). Save, then **confirm** the change when HA asks; it reverts after
   5 minutes otherwise.
3. Open `https://ha.home.foxhound.nexus` and log in.

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

Mount the recording disk at `/mnt/recordings` using its UUID, so it mounts
before Docker at boot but a missing disk never stops the server from booting:

```bash
sudo blkid                                   # note the disk's UUID and TYPE
sudo mkdir -p /mnt/recordings
echo 'UUID=YOUR-UUID /mnt/recordings ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nAfter=mnt-recordings.mount\n' | sudo tee /etc/systemd/system/docker.service.d/recordings.conf
sudo systemctl daemon-reload && sudo mount -a && mountpoint /mnt/recordings
```

`nofail` lets the server (and its DNS) boot without the disk; `After=` only
orders Docker behind the mount, it doesn't make Docker depend on it. Use the
TYPE `blkid` shows if it isn't `ext4`.

Create a marker **only on the mounted disk**:

```bash
mountpoint -q /mnt/recordings && sudo touch /mnt/recordings/.homelab-recording-volume
```

`start.sh` rejects an unmounted directory. Compose separately requires the
existing marker file as a read-only bind mount: if the disk is absent on reboot,
Docker cannot create that mount and Frigate cannot start writing to the SSD.
Never create a marker in the bare, unmounted directory. The stack does not
recover a failed drive.

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
flows. Its own password protects the dashboard (see the Caddy section).

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

Acceptance checks on the real targets. Each says **where** to run it and what
counts as a pass. "Laptop" means a Trusted admin device using AdGuard for DNS.

**1. Everything is running** (oden, then vidar)

```bash
# oden: every container Up (healthy where it has a health check)
sudo docker compose -f compose.server.yml --profile '*' ps
sudo docker compose -f compose.server.yml --profile '*' logs --since 15m 2>&1 | grep -iE 'error|fatal|denied|refused' | head -40
# vidar (native, no Docker): every unit "active (running)"
systemctl --no-pager status chrony unbound AdGuardHome uptime-kuma | grep -E '●|Active:'
sudo journalctl -b -p err --no-pager | tail -20
```

Pass: nothing restarting or exited, and no repeating errors. One-off
startup warnings are fine.

**2. DNS on both nodes** (laptop, with `dig` from `dnsutils`). Run once with
`S=10.0.40.10`, then with `S=10.0.40.11`:

```bash
S=10.0.40.10
dig @$S example.com +short; dig @$S example.com +short +tcp   # an IP both times
dig @$S ad.doubleclick.net +short                             # 0.0.0.0 (blocked)
dig @$S "$(hostname).home.arpa" +short                        # this laptop's IP
dig @$S -x <laptop IP> +short                                 # its name (if the gateway publishes PTRs)
dig @$S anything.home.foxhound.nexus +short                   # 10.0.40.10
dig @$S dnssec-failed.org | grep status                       # SERVFAIL
```

Failover: with the laptop using both resolvers, stop AdGuard on oden
(`sudo docker compose -f compose.server.yml stop adguard`), then
`ipconfig /flushdns` and `Resolve-DnsName example.com -DnsOnly` in
PowerShell still answer. Start it again, then repeat with vidar
(`sudo systemctl stop AdGuardHome` / `start`). Never stop both.

**3. Caddy** (oden, then laptop)

```bash
sudo docker compose -f compose.server.yml --profile https exec caddy \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile      # "Valid configuration"
```

```bash
# laptop: every name answers over trusted HTTPS; the unknown one gets 404
for n in ha frigate z2m zwave esphome dns alerts git nas unifi status nope; do
  printf '%-8s ' $n; curl -s -o /dev/null -w '%{http_code}\n' https://$n.home.foxhound.nexus/
done
```

Pass: no certificate errors; `200`, `302` or `401` (ESPHome's proxy login)
for configured names; `502` only for a profile you haven't started; `404`
for `nope`.

**4. Nothing else is reachable** (laptop, then oden)

```bash
# laptop → oden: only 53 and 443 open (22 too from an admin device)
for p in 22 53 443 1883 2019 3000 5000 5335 6052 8080 8081 8091 8123 8971 20211; do
  nc -z -w 3 10.0.40.10 $p && echo "$p open" || echo "$p closed"
done
# laptop → vidar: 53 open, 3001 closed (22 from an admin device)
for p in 22 53 3001 5335 8081; do nc -z -w 3 10.0.40.11 $p && echo "$p open" || echo "$p closed"; done
```

```bash
# oden → vidar: Kuma reachable from the server only
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.40.11:3001/   # 200 or 302
```

Then the same-subnet test in **Firewall prerequisites, step 3** (a laptop on a
temporary Servers-VLAN port), because the gateway can't filter inside VLAN 40.

**5. Each service works** (oden unless noted)

| Check | How | Pass |
|---|---|---|
| HA login through Caddy | Laptop: `https://ha.home.foxhound.nexus`, log in | Dashboard loads; no `400` |
| MQTT rejects anonymous clients | `sudo docker compose -f compose.server.yml exec mqtt mosquitto_sub -h localhost -t '#' -C 1 -W 3` | `not authorised` |
| MQTT ACL | See below | Only the allowed publish arrives |
| Zigbee pairing closed | Z2M UI (`z2m.`) header | *Permit join* is off |
| Z-Wave S2 | Z-Wave JS UI (`zwave.`) → Control Panel → each secure device | Security shows **S2** (not S0 or None) |
| ESPHome encrypted API | HA → ESPHome integration; device YAML has `api: encryption: key:` | Device online in HA |
| GPU detection | Frigate UI → System → Detectors | `ov` detector listed with an inference speed (tens of ms) |
| Recordings | Frigate UI → Review/History, each camera | Every camera has segments from the last hour |
| Playback | Open one recording per camera | Plays without errors |
| Resources | `df -h / /srv /mnt/recordings; free -h; sudo docker stats --no-stream` with cameras running | Disks under 80 %; memory not swapping heavily |

MQTT ACL test: open two SSH sessions on oden. Passwords are read silently,
so they don't land in shell history.

```bash
# session A: listen as frigate
read -rs P; sudo docker compose -f compose.server.yml exec -T mqtt \
  mosquitto_sub -h localhost -u frigate -P "$P" -t 'frigate/#' -v
# session B: zigbee2mqtt may NOT write frigate topics; homeassistant may
read -rs P; sudo docker compose -f compose.server.yml exec -T mqtt \
  mosquitto_pub -h localhost -u zigbee2mqtt -P "$P" -t frigate/test/set -m blocked
read -rs P; sudo docker compose -f compose.server.yml exec -T mqtt \
  mosquitto_pub -h localhost -u homeassistant -P "$P" -t frigate/test/set -m allowed
```

Pass: session A prints only `frigate/test/set allowed`. Mosquitto drops a
forbidden publish silently, so absence is the result.

**6. Uptime Kuma alerts independently of oden** (vidar)

1. Open `https://status.home.foxhound.nexus` and **create the admin account
   straight away**: the first visitor becomes admin.
2. Kuma resolves names through vidar's own resolver (the gateway), which
   doesn't know the `home` names. Add the names it monitors to vidar's
   `/etc/hosts`:
   ```bash
   echo '10.0.40.10 ha.home.foxhound.nexus git.home.foxhound.nexus' | sudo tee -a /etc/hosts
   ```
3. Add monitors:

   | Monitor | Type | Target |
   |---|---|---|
   | Server | Ping | `10.0.40.10` |
   | Gateway | Ping | `10.0.40.1` |
   | Internet | Ping | `1.1.1.1` |
   | DNS (oden) | DNS | resolver `10.0.40.10`, name `example.com` |
   | DNS (vidar) | DNS | resolver `10.0.40.11`, name `example.com` |
   | Home Assistant | HTTP(s) | `https://ha.home.foxhound.nexus` |
   | Certificate | HTTP(s) | same, with *Certificate Expiry Notification* on |

4. Add a notification that **doesn't depend on oden** (for example Pushover,
   ntfy or email), not the HA webhook. Send its test message.
5. Simulate a server failure: unplug oden's network cable (or, from its
   console, `sudo ip link set enp3s0 down`). Within a few minutes the phone
   gets the *Server* and *Home Assistant* alerts from vidar, and DNS keeps
   working through vidar. Reconnect and confirm the *up* alerts.

**7. Cut over, then the final checks.** Only now change DHCP to advertise both
resolvers (step D3). After NUT and backups exist (E2, E3), run E4:

| Check | How | Pass |
|---|---|---|
| Reboot | `sudo reboot` oden, then vidar | Checks 1–3 pass again without manual fixes |
| Missing recording disk | `sudo docker compose -f compose.server.yml --profile cameras stop frigate`, `sudo umount /mnt/recordings`, then `sudo sh scripts/start.sh server cameras` | `start.sh` refuses with *Recording disk is not mounted*; nothing is written to the system disk. Remount and start again |
| Power loss | Unplug the UPS from the wall (E2's NUT setup) | Hosts shut down cleanly before the battery runs out and come back when power returns |
| Backup and restore | Restore one folder (e.g. `/srv/adguard/config`) from the backup into a temporary directory and compare with `diff -r` | No differences |

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
