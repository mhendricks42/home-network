# Naming conventions

Things with an identity (hardware, Wi-Fi networks, app instances) get themed
names. Things you type, or that describe a function, stay plain.

## 1. Themed or plain

| Themed | Plain |
|---|---|
| Physical hosts and devices: servers, NAS, gateway, switches, APs, PCs, UPSes | Service addresses: `ha.`, `frigate.`, `git.`, `dns.`, `status.` … `.home.foxhound.nexus` |
| Wi-Fi SSIDs | Networks, VLANs and firewall zones: Mgmt, Trusted, Work, Servers, IoT-Local, IoT-Cloud, Cameras, Guest, Lab |
| App instance names (what an app calls itself) | Cameras: location only |
| Disk and volume labels | Repo files and folders, Compose services, `.env` variables, service accounts, firewall objects, policy and decision IDs |

## 2. Rules for themed names

1. **Themes:** Greek, Norse, Egyptian, space, the *Alien* films, *The
   Hitchhiker's Guide to the Galaxy*, Warhammer 40k, cyberpunk/*Neuromancer*,
   hacker culture. Any theme can be used for anything.
2. **Hostnames:** lowercase `a–z`, `0–9`, `-`; start with a letter; at most 15
   characters (the Windows limit); no accents (Mímir → `mimir`).
3. **SSIDs:** Title-Case-With-Hyphens, ASCII only, no spaces or apostrophes.
4. **One name everywhere:** OS hostname, UniFi client alias, DHCP reservation,
   `name.home.arpa`, SSH `Host` alias, and a label on the device.
5. **Unique and never reused.** Retired names stay retired so old logs and
   backups stay unambiguous.
6. **Prefer a name that hints at the job** (a guardian for the gateway, a
   survivor for the backup node). A guideline, not a hard rule.
7. **No clash with a plain name:** no host called `frigate`, `git`, `dns` etc.
8. **Register it here first:** add the name to the inventory before using it.

## 3. Plain conventions

| Item | Convention | Example |
|---|---|---|
| Docs and scripts | `kebab-case` | `ucg-max-runbook.md`, `test-start.sh` |
| Compose services, `/srv` folders | lowercase, `-` if needed | `uptime-kuma`, `/srv/uptime-kuma` |
| Compose files | `compose.<role>.yml` (role, not hostname) | `compose.server.yml`, `compose.nas.yml` |
| `.env` variables | `UPPER_SNAKE` | `DNS_API_TOKEN` |
| UniFi address/port objects | `UPPER_SNAKE` | `DNS_NODES`, `ADMIN_CLIENTS` |
| Firewall policies, decisions | `Z<n>`, `D-N<n>`, `D-S<n>` | `Z27`, `D-N14` |
| Service accounts | name of the service | `homeassistant`, `netalertx` |
| Cameras | location; `snake_case` in Frigate, `cam-<location>` as hostname | `driveway`, `cam-driveway` |

## 4. Inventory

| Device | Name | Theme | Why |
|---|---|---|---|
| Home server (HP ProDesk) | `odin` | Norse | The all-father; runs everything |
| Raspberry Pi 3B+ | `vidar` | Norse | Survives Ragnarök: the node that keeps going when the server is down |
| Ugreen NAS | `mimir` | Norse | Mímir's well of knowledge; it stores everything |
| UCG Max gateway | `anubis` | Egyptian | Guardian of the gateway who weighs what may pass |
| Wi-Fi: Trusted | `Mostly-Harmless` | Hitchhiker's | |
| Wi-Fi: Work | `The-Forge` | Warhammer 40k | |
| Wi-Fi: IoT-Local | `Alfheim` | Norse | |
| Wi-Fi: IoT-Cloud | `Niflheim` | Norse | The realm of mist: the cloud |
| Wi-Fi: Guest | `Mead-Hall` | Norse | Where guests are received |

**Not yet named** (suggestions, adopt by moving them into the table above):
core switch `yggdrasil`, office switch `bifrost`, U7 Pro `voyager`, U7 Lite
`pioneer`, desk PC `wintermute`, admin laptop `zero-cool`, closet UPS `atlas`,
office UPS `hyperion`, recording disk `nostromo`, Home Assistant instance
`Deep Thought`.

## 5. Renaming a device

1. Add the new name to the inventory (rule 8).
2. Set the OS hostname (`sudo hostnamectl set-hostname NAME` on Linux;
   *Settings → System → About → Rename this PC* on Windows) and reboot.
3. UniFi: rename the client alias and its DHCP reservation; renew its lease.
4. Check `dig @10.0.40.10 NAME.home.arpa +short` returns its address.
5. SSH: update `Host` aliases in `~/.ssh/config` on admin devices. For an admin
   device, the comment at the end of its key line in each host's
   `~/.ssh/authorized_keys` names the old device; edit it to match.
6. Update docs that name the device, and its Dashlane item titles.
