# Go-live: Tailscale, UPS shutdown and backups

Steps E1–E3 of the [deployment runbook](runbook.md#prerequisite-order). Run
them after the DNS cutover. E4 (final checks) is in the runbook, §4 check 7.

| Host | Role here |
|---|---|
| `odin` (10.0.40.10) | Tailscale subnet router; NUT server for the **office** UPS; restic client |
| `vidar` (10.0.40.11) | NUT server for the **closet** UPS; restic client |
| `mimir` (10.0.40.20, NAS) | NUT client of odin; restic REST server |

## E1. Tailscale (remote access)

Design: architecture §11. One subnet router (`odin`), Tailnet Lock on, no exit
node, family limited to DNS and HTTPS.

### 1. Install on odin

```bash
curl -fsSL https://tailscale.com/install.sh | sh     # adds Tailscale's apt repository
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' | \
  sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale up \
  --advertise-routes=10.0.40.1/32,10.0.40.10/32,10.0.40.20/32 \
  --accept-dns=false
```

Open the login link it prints and sign in with the account that will own the
tailnet (free Personal plan). `--accept-dns=false` keeps odin resolving through
the gateway, as step B3 requires.

### 2. Admin console (login.tailscale.com)

1. **Machines → odin → Edit route settings:** approve the three routes.
2. **Machines → odin → Disable key expiry.** Every other device keeps expiry.
3. **DNS:**
   - **Nameservers → Add → Custom:** `10.0.40.10`, *Restrict to domain* →
     `home.arpa`. Add it again for `home.foxhound.nexus`.
   - **Global nameservers:** `10.0.40.10`, with **Override local DNS** on, so
     devices away from home are filtered by AdGuard too.
4. **Access controls:** replace the **whole** default policy (its
   allow-everything grant and its Tailscale SSH block) with this. Put your
   login in `group:admins` and family members' logins in `group:family`:

   ```json
   {
     "groups": {
       "group:admins": ["you@example.com"],
       "group:family": []
     },
     "grants": [
       {"src": ["group:admins"], "dst": ["10.0.40.1/32"],  "ip": ["tcp:443"]},
       {"src": ["group:admins"], "dst": ["10.0.40.10/32"], "ip": ["tcp:22", "tcp:53", "udp:53", "tcp:443"]},
       {"src": ["group:admins"], "dst": ["10.0.40.20/32"], "ip": ["tcp:445", "tcp:9443"]},
       {"src": ["group:family"], "dst": ["10.0.40.10/32"], "ip": ["tcp:53", "udp:53", "tcp:443"]}
     ],
     "tests": [
       {"src": "you@example.com",
        "accept": ["10.0.40.1:443", "10.0.40.10:22", "10.0.40.10:443", "10.0.40.20:445"],
        "deny": ["10.0.40.10:8123", "10.0.40.20:8096"]}
     ]
   }
   ```

   Admins reach the gateway UI, odin (SSH, DNS, Caddy) and the NAS (SMB, web
   UI); family reach only DNS and Caddy. Anything not listed is denied. There's
   no `ssh` section: you use normal OpenSSH over the route, not Tailscale SSH.
   The `tests` run on every save and refuse a policy that breaks them; change
   `you@example.com` there too.

### 3. Firewall on odin

The B6 rules already allow DNS and HTTPS from `100.64.0.0/10`. Add SSH for the
tailnet (the ACL above limits it to admins):

```bash
sudo ufw allow in on tailscale0 to any port 22 proto tcp
```

### 4. Clients

Install Tailscale on your phone and admin laptop and sign in. Devices that live
on the LAN don't need *Accept routes* on a laptop; phones use the routes
automatically, which also works at home.

### 5. Tailnet Lock

Do this once at least two devices you trust are signed in (odin and your admin
laptop).

```bash
tailscale lock status          # on each trusted device: note its "tlpub:..." key
```

On odin:

```bash
sudo tailscale lock init --gen-disablements 3 --confirm tlpub:ODIN_KEY tlpub:LAPTOP_KEY
```

Save the three printed **disablement secrets** in Dashlane (one item,
`Tailnet Lock disablement`). They are the only way to turn the lock off if
every signing device is lost. From then on, a new device stays locked out until
a trusted device signs it:

```bash
tailscale lock status                     # shows the new device's nodekey:...
sudo tailscale lock sign nodekey:NEW_KEY
```

### 6. Check

From your phone **on mobile data** (Wi-Fi off), with Tailscale on:

| Test | Pass |
|---|---|
| `https://ha.home.foxhound.nexus` | Loads (done-when for E1) |
| An ad-heavy site | Ads blocked, so AdGuard is answering |
| `https://unifi.home.foxhound.nexus` (admin) | Loads |
| SSH from the laptop on another network: `ssh odin` | Works |
| A family account | Reaches HA through Caddy; SSH and the NAS are refused |

`tailscale ping odin` from a client should show a direct path after a few
pings; `via DERP` means relayed. Passthrough (D-N15) normally allows direct.

## E2. UPS shutdown (NUT)

Each host listens to the UPS that actually powers it:

| UPS | USB to | NUT role | Protects |
|---|---|---|---|
| Closet (APC BE600M1) | vidar | server (`closet`) | vidar shuts down cleanly. The gateway, switch, APs and cameras just run until the battery ends; they have no disks to corrupt |
| Office (CyberPower CP850PFCLCD) | odin | server (`ups0`, the name UGOS requires) | odin shuts the NAS down over SSH after 5 min on battery; odin itself at 50% charge, then the UPS power-cycles |

Make everything come back after a power cut:

- **odin:** BIOS → Power Management → *After Power Loss* (or *AC Power
  Recovery*): **Power On**.
- **NAS:** UGOS → power settings → *Restore power after outage*: on, and
  *Wake-on-LAN*: on.
- **vidar:** boots by itself when the switch's PoE returns.

Store each NUT password below in Dashlane as its own item. Generate them with **letters and digits only**: NUT treats `#` as the start of a comment and quotes, spaces and `\` need escaping.

### 1. vidar: closet UPS

```bash
sudo apt install -y nut
```

`/etc/nut/nut.conf`:

```text
MODE=netserver
```

`/etc/nut/ups.conf`:

```text
[closet]
  driver = usbhid-ups
  port = auto
  desc = "APC BE600M1 (closet)"
```

`/etc/nut/upsd.conf` (local, plus odin so Home Assistant can read it):

```text
LISTEN 127.0.0.1 3493
LISTEN 10.0.40.11 3493
```

`/etc/nut/upsd.users`:

```text
[upsmon]
  password = VIDAR_UPSMON_PASSWORD
  upsmon primary
```

`/etc/nut/upsmon.conf` (add or change these lines):

```text
MONITOR closet@localhost 1 upsmon VIDAR_UPSMON_PASSWORD primary
SHUTDOWNCMD "/sbin/shutdown -h +0"
```

```bash
sudo chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
# Start upsd only once the LAN address exists, or it listens on 127.0.0.1 only after a reboot.
sudo mkdir -p /etc/systemd/system/nut-server.service.d
printf '[Unit]\nWants=network-online.target\nAfter=network-online.target\n' | \
  sudo tee /etc/systemd/system/nut-server.service.d/network-online.conf
sudo systemctl daemon-reload
sudo systemctl restart nut-server nut-monitor
upsc closet@localhost ups.status      # OL = on line power
sudo ufw allow from 10.0.40.10 to any port 3493 proto tcp   # Home Assistant on odin
```

### 2. odin: office UPS, NAS as client

```bash
sudo apt install -y nut
```

Same files as vidar, with these differences:

`/etc/nut/ups.conf`. The UPS **must** be called `ups0`: UGOS only ever asks
for that name and offers no setting to change it.

```text
[ups0]
  driver = usbhid-ups
  port = auto
  desc = "CyberPower CP850PFCLCD (office)"
  # NUT raises low battery itself, early, instead of the UPS's own LB near empty.
  ignorelb
  override.battery.charge.low = 50
  override.battery.runtime.low = 900
```

`/etc/nut/upsd.conf`:

```text
LISTEN 127.0.0.1 3493
LISTEN 10.0.40.10 3493
```

`/etc/nut/upsd.users` (one account for odin itself, one with the fixed
credentials UGOS uses):

```text
[upsmon]
  password = ODIN_UPSMON_PASSWORD
  upsmon primary

[monuser]
  password = secret
  upsmon secondary
```

`monuser` / `secret` is well known, which is acceptable here: a secondary
account can only watch, not trigger a shutdown, and only the NAS and Home
Assistant may reach port 3493.

`/etc/nut/upsmon.conf`:

```text
MONITOR ups0@localhost 1 upsmon ODIN_UPSMON_PASSWORD primary
SHUTDOWNCMD "/etc/nut/upssched-cmd shutdown-all"
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONLINE SYSLOG+WALL+EXEC
NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC
```

The NAS shutdown and wake-up files live in the repo, in `services/nut/`:
`upssched.conf` (NAS off after 5 min on battery, wake it 3 min after mains
return), `upssched-cmd` (`shutdown-all` is odin's `SHUTDOWNCMD`: NAS first,
wait until it's off, then odin) and `wake-nas.service` (`upssched` misses an
outage odin slept through, and UGOS restores the NAS to its last state, off,
so odin also wakes it at every boot; harmless if it's already up).

**NAS shutdown key** (the key can do nothing but power the NAS off). On odin:

```bash
sudo ssh-keygen -t ed25519 -N '' -C odin-nut-nas-shutdown -f /etc/nut/nas_shutdown
sudo chown nut:nut /etc/nut/nas_shutdown
sudo sh -c 'ssh-keyscan -t ed25519 10.0.40.20 > /etc/nut/nas_known_hosts'
sudo cat /etc/nut/nas_shutdown.pub
```

On the NAS (UGOS → Control Panel → Terminal → SSH on), as `NAS_ADMIN`:

```bash
echo 'NAS_ADMIN ALL=(root) NOPASSWD: /sbin/poweroff' | sudo tee /etc/sudoers.d/nut-poweroff
sudo chmod 440 /etc/sudoers.d/nut-poweroff
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'command="sudo /sbin/poweroff",restrict PASTE_THE_PUB_KEY_HERE' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

A UGOS update can reset these; after updates, rerun the NAS test below.

**Install the files on odin** from the repo clone. The `sed` fills in your NAS
admin user and MAC (`ip neigh show 10.0.40.20` while the NAS is up), and the
`grep` refuses to continue if a placeholder is left:

```bash
sudo apt install -y wakeonlan
read -rp "NAS admin user: " U; read -rp "NAS MAC (aa:bb:cc:dd:ee:ff): " M
sed -e "s/NAS_ADMIN/$U/" -e "s/NAS_MAC/$M/" services/nut/upssched-cmd > /tmp/upssched-cmd
! grep -n 'NAS_' /tmp/upssched-cmd && \
  sudo install -m 750 -o root -g nut /tmp/upssched-cmd /etc/nut/upssched-cmd
sudo install -m 640 -o root -g nut services/nut/upssched.conf /etc/nut/upssched.conf
sudo install -m 644 services/nut/wake-nas.service /etc/systemd/system/wake-nas.service
sudo systemctl daemon-reload && sudo systemctl enable wake-nas.service
rm /tmp/upssched-cmd
```

```bash
sudo chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
sudo mkdir -p /etc/systemd/system/nut-server.service.d    # same network-online drop-in as vidar
printf '[Unit]\nWants=network-online.target\nAfter=network-online.target\n' | \
  sudo tee /etc/systemd/system/nut-server.service.d/network-online.conf
sudo systemctl daemon-reload
sudo systemctl restart nut-driver-enumerator nut-driver.target nut-server nut-monitor
upsc ups0@localhost ups.status
sudo ufw allow from 10.0.40.20 to any port 3493 proto tcp       # NAS
sudo ufw allow from 172.28.0.0/24 to any port 3493 proto tcp    # Home Assistant container
```

If the driver fails with a USB permission error on first install, unplug and
replug the UPS's USB cable, then restart `nut-driver.target`.

**NAS:** UGOS → UPS settings → network UPS client → server `10.0.40.10`,
**timed shutdown: 10 minutes** on battery (only a backstop if odin's SSH
shutdown fails; NUT acts at 5). There are no name or credential fields: UGOS queries `ups0` (it tries `STARTTLS`
first and carries on unencrypted when odin declines). Its status page should
show the UPS on line power. If it reports that the IP doesn't support NUT, run
`upsc ups0@10.0.40.10 ups.status` from the NAS; `Unknown UPS` means the name
on odin isn't `ups0`.

UGOS only reads the status and logs out; it never logs in as a NUT secondary,
so it ignores odin's shutdown signal. odin therefore powers it off over SSH:

| Outage | Result |
|---|---|
| Under 5 min | Nothing shuts down |
| Over 5 min, power back before 50% | odin powers the NAS off; odin stays up and wakes it 3 min after power returns |
| Reaches 50% | NAS already off (otherwise `shutdown-all` powers it off first); odin shuts down; the UPS cuts its outlets ~20 s later and restores them when mains are back; odin boots and wakes the NAS (`wake-nas.service`) |

Power returning after odin's shutdown has started changes nothing: the
shutdown finishes and the UPS still power-cycles, so everything restarts.

### 3. Home Assistant

*Add integration → Network UPS Tools* twice: host `10.0.40.10` (UPS `ups0`,
office) and `10.0.40.11` (UPS `closet`), no username needed for reading. Rename the status-data sensors to `sensor.ups_office_status_data` and
`sensor.ups_closet_status_data` (entity → ⚙ → Entity ID) so automations and
the test script use stable names; enable them first, they are off by default. Add an automation that
notifies you when either UPS reports *On battery*.

Test the alert without touching the UPS: create a long-lived access token
(HA profile → Security), then on odin run
`bash scripts/test-ups-alert.sh` (office) or
`bash scripts/test-ups-alert.sh sensor.ups_closet_status_data`. It sets HA's copy of
the status to on battery, low battery, then on line; expect the matching phone
notifications. The next NUT poll restores the real value.

### 4. Check

`upsmon -c fsd` runs the real low-battery sequence: the host shuts down and
then tells its UPS to switch its outlets off and back on. That power cycle is
what guarantees a clean restart after a real outage (otherwise a host whose
power never dropped would stay off), but during a test it reboots everything
on that UPS. Warn the household first.

| Test | Pass |
|---|---|
| `upsc ups0@10.0.40.10 ups.status` on the NAS, and the UGOS UPS page | `OL`; UGOS shows the UPS on line power |
| `sudo upsmon -c fsd` on vidar (simulated low battery). **Maintenance window only** | vidar shuts down, then the closet UPS cuts its outlets about 20 s later and restores them about 2 minutes after. The BGW320, gateway, core switch, U7 Pro and cameras reboot: internet, downstairs Wi-Fi and DNS are down for about 2–3 minutes. Everything, including vidar, comes back by itself |
| NAS shutdown: `sudo -u nut /etc/nut/upssched-cmd nas-off` on odin | NAS powers off; `journalctl -t upssched` shows *told mimir to power off* |
| Wake-on-LAN: with the NAS off, `sudo /etc/nut/upssched-cmd wake-nas` on odin | NAS boots within a minute |
| `sudo upsmon -c fsd` on odin. **Maintenance window** | The NAS powers off, then odin, then the office UPS power-cycles (odin, NAS, office switch, U7 Lite) about 20 s later; everything boots by itself. If the outlets never cut, the UPS ignores the command while on mains: check `upsc ups0 \| grep ups.delay` |
| Real test (E4): pull the office UPS plug | NAS shuts down at 5 min; odin at 50% charge (`watch upsc ups0`); the UPS cuts and, once plugged back in, restores power; both boot. Repeat once plugging back in at ~8 min: the NAS wakes 3 min later |

## E3. Backups (restic to the NAS)

restic encrypts on the client; the NAS only stores encrypted data. The NAS runs
restic's REST server in **append-only** mode: a compromised odin or vidar can add
backups but can't delete or overwrite old ones. Pruning happens on the NAS.

### 1. REST server on the NAS

From the repo clone on the NAS (`/volume1/appdata/home-network`):

```bash
sudo mkdir -p /volume1/backups/restic
sudo touch /volume1/backups/restic/.htpasswd     # create_user only adds to an existing file
docker run --rm -it --entrypoint create_user -v /volume1/backups/restic:/data \
  restic/rest-server:0.13.0 odin          # prompts twice for a password: store it in Dashlane
docker run --rm -it --entrypoint create_user -v /volume1/backups/restic:/data \
  restic/rest-server:0.13.0 vidar
sudo cut -d: -f1 /volume1/backups/restic/.htpasswd   # odin, vidar
docker compose -f compose.nas.yml up -d --force-recreate
```

`-it` matters: without a terminal the password prompt reads nothing and
`htpasswd` fails (`password too long`).

`--private-repos` (in `compose.nas.yml`) keeps each user in its own repository
(`/odin`, `/vidar`). If the NAS firewall is on, allow TCP 8000 from
`10.0.40.10` and `10.0.40.11` only.

The REST server speaks plain HTTP inside VLAN 40. The backup data is already
encrypted by restic; only the REST login crosses the wire in clear, and only on
the Servers VLAN.

### 2. Clients (odin and vidar)

On each host (the REST user and the repository path are both the hostname):

```bash
sudo apt install -y restic
sudo install -d -m 700 /root/.config/restic
H=$(hostname); echo "$H"                                   # must print odin or vidar
read -rsp "REST password for $H: " P; echo
printf 'RESTIC_REPOSITORY=rest:http://%s:%s@10.0.40.20:8000/%s/\nRESTIC_PASSWORD_FILE=/root/.config/restic/password\n' \
  "$H" "$P" "$H" | sudo tee /root/.config/restic/env >/dev/null; unset P
sudo tee /root/.config/restic/password >/dev/null      # paste the repository password, then Ctrl+D
sudo chmod 600 /root/.config/restic/env /root/.config/restic/password
sudo bash -c 'set -a; . /root/.config/restic/env; restic init'
```

`401 Unauthorized`: the REST user or password doesn't match step 1, or the
path isn't the user's own (`--private-repos` allows user `odin` only `/odin/`).
Check with `sudo sed 's/:[^:@]*@/:***@/' /root/.config/restic/env`.

Two different secrets: `REST_PASSWORD` (the REST server login from step 1) and
the **repository password**, which encrypts the data. Store both in Dashlane;
without the repository password the backups can't be restored.

**What gets backed up:**

| Host | Paths | Consistency |
|---|---|---|
| odin | `/srv`, `/etc`, the repo clone's `.env` | Containers are stopped during the backup (SQLite databases). vidar answers DNS meanwhile |
| vidar | `/opt/AdGuardHome/AdGuardHome.yaml`, `/opt/uptime-kuma/data`, `/etc` | Uptime Kuma is stopped during the backup |

`/mnt/recordings` (camera video) is never backed up.

The units live in the repo: `services/restic/odin/` and `services/restic/vidar/`
(`restic-backup.service` and `restic-backup.timer`). odin's backup stops all
containers (SQLite consistency) and restarts them even if the backup fails;
first it copies the gateway's auto-backups (about monthly, plus after firmware
updates) into `/srv/unifi-backup`, so restic carries them to the NAS. vidar
stops only Uptime Kuma. odin runs at 03:30 and vidar at 04:00, so the two DNS
nodes are never down together.

**UniFi copy, one-time setup on odin**, with SSH on in UniFi OS → Settings →
Control Plane → Console (password in Dashlane):

```bash
sudo ssh-keygen -t ed25519 -N '' -C odin-unifi-backup -f /root/.ssh/unifi_backup
sudo ssh-copy-id -i /root/.ssh/unifi_backup.pub root@10.0.40.1
```

A gateway firmware update can remove the key; check `ls -lt /srv/unifi-backup`
after updates and rerun `ssh-copy-id` if it stopped. Also turn on **Cloud
Backups** (UniFi OS → Settings → Backups) for an off-site copy, and download a
backup by hand after big network changes; the local ones are only monthly.

**Install on odin**, from the repo clone (`REPO_DIR` becomes the clone's path):

```bash
sed "s#REPO_DIR#$PWD#g" services/restic/odin/restic-backup.service | \
  sudo tee /etc/systemd/system/restic-backup.service >/dev/null
sudo install -m 644 services/restic/odin/restic-backup.timer /etc/systemd/system/
grep -n 'REPO_DIR' /etc/systemd/system/restic-backup.service || echo "paths filled in"
```

**Install on vidar** (no clone there): from an admin device's clone run
`scp services/restic/vidar/restic-backup.* vidar:/tmp/`, then on vidar
`sudo install -m 644 /tmp/restic-backup.service /tmp/restic-backup.timer /etc/systemd/system/`.

Then on both:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now restic-backup.timer
sudo systemctl start restic-backup.service      # first run now
sudo journalctl -u restic-backup -n 20 --no-pager
sudo bash -c 'set -a; . /root/.config/restic/env; restic snapshots'
```

### 3. Pruning (on the NAS, monthly)

Clients can't delete, so prune from the NAS with each repository's password:

```bash
for repo in odin vidar; do
  docker run --rm -it -v /volume1/backups/restic:/data restic/restic:0.17.3 \
    -r /data/$repo forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
done
```

### 4. Off-device copy (monthly)

Plug a USB disk into the NAS and copy the whole store (it's already encrypted):

```bash
rsync -a --delete /volume1/backups/restic/ /mnt/@usb/sdX1/restic/   # use the path UGOS shows for the disk
```

Keep that disk away from the house. UniFi backups travel inside odin's restic repository. Back up
the NAS's own shares to the same USB disk with UGOS's backup app.

### 5. Restore test (done-when for E3, and E4)

```bash
sudo bash -c 'set -a; . /root/.config/restic/env; restic restore latest --target /tmp/restore --include /srv/adguard/config'
sudo diff -r /srv/adguard/config /tmp/restore/srv/adguard/config && echo "restore OK"
sudo rm -r /tmp/restore
```

Repeat once a quarter, and once on a clean machine (architecture §16).
