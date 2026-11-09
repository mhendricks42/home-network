# vidar (Raspberry Pi) baseline

Greenfield, native install on **Raspberry Pi OS Lite 64-bit** with no Docker.
vidar is DNS 2, NTP 2 and the Uptime Kuma watcher, so it must keep working when
`odin` is down. Starting point: Imager-installed with user `matt` and SSH key
login, on its reserved address `10.0.40.11`.

Run everything as `matt` with `sudo`. Keep one SSH session open while you
change SSH or the firewall.

| Service | Install | Listens on |
|---|---|---|
| SSH | OS | `:22`, admin devices and `odin` only |
| chrony (NTP) | apt | UDP 123, home VLANs |
| Unbound (recursive DNS) | apt | `127.0.0.1:5335` only |
| AdGuard Home (filtering DNS) | pinned release binary | `10.0.40.11:53`; UI `127.0.0.1:8081` |
| Uptime Kuma | pinned git tag, Node.js | `10.0.40.11:3001`, `odin` only |

## 1. OS basics

```bash
sudo apt update && sudo apt full-upgrade -y
sudo hostnamectl set-hostname vidar
sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tvidar/' /etc/hosts
sudo timedatectl set-timezone America/New_York
sudo apt install -y unattended-upgrades dnsutils
sudo dpkg-reconfigure -plow unattended-upgrades     # answer Yes
```

**Host resolver:** vidar's own lookups go to the gateway, never to its own
AdGuard (it must boot and update without it). Find the connection name, then
pin DNS:

```bash
nmcli -t -f NAME connection show --active
sudo nmcli connection modify "Wired connection 1" ipv4.ignore-auto-dns yes ipv4.dns 10.0.40.1
sudo nmcli connection up "Wired connection 1"
resolvectl status 2>/dev/null || cat /etc/resolv.conf   # shows 10.0.40.1
```

**Unused radios off** (wired only; also saves power). Add to
`/boot/firmware/config.txt`, then reboot:

```text
dtoverlay=disable-wifi
dtoverlay=disable-bt
```

**SD-card wear:** keep the journal in RAM and avoid swap on the card.

```bash
sudo sed -i 's/^#\?Storage=.*/Storage=volatile/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
swapon --show                          # what swap exists
systemctl list-units --all '*swap*'    # which unit provides it
```

Raspberry Pi OS's `rpi-swap` defaults to **zram + file**: compressed RAM
(`/dev/zram0`) that can push idle pages to `/var/swap` on the card. Switch to
zram only, which never writes to the card and is plenty for this Pi:

```bash
sudo mkdir -p /etc/rpi/swap.conf.d
printf '[Main]\nMechanism=zram\n' | sudo tee /etc/rpi/swap.conf.d/90-zram-only.conf
sudo reboot
```

After the reboot, `swapon --show` lists only `/dev/zram0`,
`rpi-setup-loop@var-swap` is inactive, and `/var/swap` is gone (removed
automatically).

After the reboot, check the PoE HAT fan works (`vcgencmd measure_temp` stays
well under 70 °C under load).

## 2. SSH hardening

Follow the Docker runbook's **SSH access from admin devices**, step 4, on
vidar (`/etc/ssh/sshd_config.d/10-admin.conf`, then
`sudo sshd -t && sudo systemctl reload ssh`), and record vidar's host key
fingerprint in Dashlane (step 2).

## 3. Firewall

No Docker means every service goes through ufw's normal INPUT rules.
Replace `ADMIN_IP` with each `ADMIN_CLIENTS` address:

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from ADMIN_IP to any port 22 proto tcp
sudo ufw allow from 10.0.40.10 to any port 22 proto tcp      # ssh -J odin vidar (remote)
sudo ufw allow from 10.0.0.0/16 to any port 53               # DNS, TCP and UDP
sudo ufw allow from 10.0.0.0/16 to any port 123 proto udp    # NTP
sudo ufw allow from 10.0.40.10 to any port 3001 proto tcp    # Caddy → Uptime Kuma
sudo ufw enable
sudo ufw status verbose
```

## 4. chrony (NTP)

Follow the Docker runbook's **Time service** with `PEER` = `10.0.40.10`.

## 5. Unbound

```bash
sudo apt install -y unbound
sudo tee /etc/unbound/unbound.conf.d/homelab.conf >/dev/null <<'EOF'
server:
    interface: 127.0.0.1
    port: 5335
    access-control: 127.0.0.0/8 allow
    do-ip6: no
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    harden-dnssec-stripped: yes
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    msg-cache-size: 16m
    rrset-cache-size: 32m
    # Never accept private addresses in public answers (rebinding; ISP-box DNS hijack during outages).
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 100.64.0.0/10
    private-address: fd00::/8
    private-address: fe80::/10
    # Keep answering from the last good cache while upstream is unreachable (RFC 8767).
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-client-timeout: 1800
EOF
sudo unbound-checkconf && sudo systemctl restart unbound
systemctl list-unit-files | grep -q unbound-resolvconf && sudo systemctl disable --now unbound-resolvconf
dig @127.0.0.1 -p 5335 example.com +short                 # an IP
dig @127.0.0.1 -p 5335 dnssec-failed.org | grep status    # SERVFAIL
```

Debian's package already manages the DNSSEC root trust anchor. The
`unbound-resolvconf` line stops Unbound making itself the host resolver.

## 6. AdGuard Home

Install the same pinned release as `odin`, checking its checksum:

```bash
V=v0.107.79
cd /tmp
curl -fLO https://github.com/AdguardTeam/AdGuardHome/releases/download/$V/AdGuardHome_linux_arm64.tar.gz
curl -fLO https://github.com/AdguardTeam/AdGuardHome/releases/download/$V/checksums.txt
grep '/AdGuardHome_linux_arm64.tar.gz$' checksums.txt | sha256sum -c     # must say OK
sudo tar -C /opt -xzf AdGuardHome_linux_arm64.tar.gz
```

**Config:** start from the repo template. From an admin device's clone:
`scp services/adguard/AdGuardHome.yaml.example vidar:/tmp/AdGuardHome.yaml`,
then on vidar:

```bash
sudo install -m 600 -o root -g root /tmp/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml
sudo nano /opt/AdGuardHome/AdGuardHome.yaml
```

Make it match `odin`'s live file (bcrypt hash, client profiles, rules, lists),
except these vidar-only lines:

```yaml
http:
  address: 127.0.0.1:8081          # UI over SSH tunnel only
dns:
  bind_hosts: [10.0.40.11]
  upstream_dns:
    - 127.0.0.1:5335               # local Unbound (odin uses 172.29.0.2:5335)
    - "[/home.arpa/]10.0.40.1"
querylog:
  file_enabled: false              # keep the log in RAM (SD wear)
```

```bash
sudo /opt/AdGuardHome/AdGuardHome -s install    # systemd service, starts at boot
sudo /opt/AdGuardHome/AdGuardHome -s status
dig @10.0.40.11 example.com +short
dig @10.0.40.11 ha.home.foxhound.nexus +short   # 10.0.40.10
```

UI: `ssh -L 8082:127.0.0.1:8081 vidar`, then `http://localhost:8082`. Rerun
the Docker runbook's DNS acceptance checks against `10.0.40.11`.

## 7. Uptime Kuma

Debian 13's Node.js 20 meets Kuma 2's requirement (Node 20.4+). Install the
pinned tag as an unprivileged user:

```bash
sudo apt install -y nodejs npm git
node --version                                   # v20.4 or later
sudo useradd --system --home-dir /opt/uptime-kuma --shell /usr/sbin/nologin kuma
sudo git clone --depth 1 --branch 2.5.6 https://github.com/louislam/uptime-kuma.git /opt/uptime-kuma
sudo chown -R kuma:kuma /opt/uptime-kuma
cd /opt/uptime-kuma
sudo -u kuma npm ci --omit=dev                   # slow on a Pi 3B+ (10+ minutes)
sudo -u kuma npm run download-dist
```

Don't use `npm run setup`: it checks out the newest release, not the pin.

`/etc/systemd/system/uptime-kuma.service`:

```ini
[Unit]
Description=Uptime Kuma
After=network-online.target
Wants=network-online.target

[Service]
User=kuma
WorkingDirectory=/opt/uptime-kuma
Environment=UPTIME_KUMA_HOST=10.0.40.11
Environment=UPTIME_KUMA_PORT=3001
ExecStart=/usr/bin/node server/server.js
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=full
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now uptime-kuma
curl -sI http://10.0.40.11:3001 | head -1        # from odin: HTTP 302/200
```

Then open `https://status.home.foxhound.nexus` (Caddy on `odin` proxies to
it), create the admin account and add monitors (Docker runbook §4, check 6).

## 8. Check and back up

```bash
systemctl --failed                       # nothing listed
sudo ss -tulpn | grep -E ':(22|53|123|3001|5335|8081)\b'
```

Expect 53 on `10.0.40.11`, 5335 and 8081 on `127.0.0.1`, 3001 on
`10.0.40.11`. Reboot once and repeat. Then image the SD card (or SSD) so
vidar can be restored in minutes.

**Back up:** `/opt/AdGuardHome/AdGuardHome.yaml`, `/opt/uptime-kuma/data`,
`/etc/chrony/conf.d/`, `/etc/unbound/unbound.conf.d/`, `/etc/ssh/sshd_config.d/`.

## Updates

- OS: unattended-upgrades.
- AdGuard: repeat section 6's download with the new `V`, stop the service,
  extract over `/opt`, start it. Keep the same version as `odin`.
- Uptime Kuma: `sudo -u kuma git -C /opt/uptime-kuma fetch --depth 1 origin tag NEW`,
  `git checkout NEW`, `npm ci --omit=dev`, `npm run download-dist`, restart.
  Read its release notes first.
