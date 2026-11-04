# UCG Max configuration runbook

## Scope and stop conditions

Manual setup of the UCG Max, its UniFi switches and APs for the
[network architecture](network-architecture.md). Deploy server/Pi services with
the [Docker runbook](runbook.md); this document does not provision those hosts.
Run network changes on site from a **wired admin laptop**, not over Tailscale.

UI labels vary by UniFi OS/Network release. Record both versions and use the
zone-based firewall UI, not legacy LAN IN/LAN LOCAL recipes. Verify the
resulting policy and rule order rather than relying on a particular menu label.

Do not cut over household devices until these gates pass:

- Choose and record the BGW320 WAN mode (architecture pending decision P1).
  Section 2 covers either option; passthrough is not assumed approved.
- Both DNS nodes answer independently before advertising them through DHCP.
- Identify admin device MACs/IPs, camera MACs/IPs, the actual BGW320 subnet,
  and the physical WAN/LAN port assignments. Do not guess them.
- Verify chrony on the server and Pi serves NTP (Docker runbook, Time
  service), conditional DNS forwarding, and IPv6 isolation as described below.
  The UCG Max does not serve NTP to the LAN.
- Choose a Guest bandwidth limit before enabling Guest; no limit was decided.
- Proxy acceptance checks need Caddy's `foxhound.nexus` certificate first
  (Docker runbook, Caddy section).

Wi-Fi decision: separate Work (**The-Forge**) and IoT-Cloud (**Niflheim**) SSIDs replace PPSK to
preserve WPA3/6 GHz on the Trusted SSID (**Mostly-Harmless**). PPSK is not compatible with WPA3/6 GHz. Do not
implement the old three-SSID/PPSK plan.

## 1. Prepare a recovery path and initialize locally

1. Save this runbook, the IP plan, BGW320 device access code, local administrator
   credentials and a known-good backup somewhere usable without household DNS
   or internet. Treat backup files as secrets.
2. Photograph/label cables. Record the UCG WAN MAC from the actual assigned WAN
   interface, not an assumed chassis MAC.
3. Initially connect only BGW320 -> UCG WAN and laptop -> UCG LAN. Leave the
   office's second trunk disconnected throughout adoption.
4. Open the gateway's local setup page using its current LAN address. Use
   Advanced/local setup and create a unique local administrator; no UI account
   or remote management is required. If the installed release does not offer
   local setup, stop and check its supported local-management procedure.
5. Disable UniFi remote access, analytics/optional telemetry, automatic updates,
   UPnP/NAT-PMP and any WAN-facing management. Leave port forwarding, DMZ,
   VPN server, exit node and dynamic DNS unconfigured. Do not confuse BGW320
   passthrough with exposing an internal host through UCG port forwarding.
6. Install reviewed stable updates during this maintenance window. Export a
   baseline backup; record OS/Network versions and the local login address.
7. Before adopting switches/APs, move the Default LAN off `192.168.1.0/24`.
   Use a temporary, non-overlapping recovery subnet (for example
   `10.0.99.0/24`, gateway `10.0.99.1`, **only after checking for conflicts**).
   Renew the laptop lease and sign in again at the new address.

The Default network is normally the untagged/VLAN 1 network. Renaming it
"Mgmt" or changing its subnet does **not** make it VLAN 10. Create an actual
VLAN 10 below. The temporary Default LAN is a recovery aid, not a ninth
production trust zone; remove it from production ports after migration.

## 2. Configure BGW320 and WAN

Keep the BGW320's own LAN separate from every UCG LAN. Record its real address,
subnet and configuration backup/screenshots before changes. Disable its Wi-Fi
and UPnP; no household clients remain on it.

### If P1 selects IP passthrough

1. In the BGW320 local UI, open **Firewall > IP Passthrough**, select allocation
   mode **Passthrough**, mode **DHCPS-fixed**, and the UCG's actual WAN MAC.
   Do not select a camera, switch, or laptop.
2. Save; renew/restart the WAN connection as required by the BGW320. Keep UCG
   IPv4 WAN on DHCP. Do not configure PPPoE, clone an unrelated MAC, or remove
   the BGW320/ONT from the fiber path.
3. Confirm the UCG receives the expected public IPv4 address, has a default
   route and can reach the internet. Passthrough is not a transparent bridge:
   the BGW320 management subnet still needs blocking from clients.

### If P1 selects double NAT

Leave BGW320 routing enabled; UCG WAN uses DHCP and receives a BGW320 LAN
address. Accept that Tailscale may relay more often. Do not "fix" this by
adding inbound forwards or placing a server in the BGW320 DMZ.

For either mode:

- Set the service rate to the actual 1 Gbps plan where required. Start without
  Smart Queues; do not add a throughput bottleneck without a measured need.
- Leave WAN DNS on a working independent resolver during bootstrap. Never
  make successful gateway startup depend solely on containers not yet running.
  This is gateway bootstrap traffic, not permission for clients to bypass DNS.
- Keep unsolicited WAN -> LAN and WAN -> Gateway traffic denied, apart from
  required system return/control traffic. Check this again after firewall edits.
- Test public DNS/IP connectivity and record the WAN address, link rate and
  actual BGW320 subnet for `ISP_LAN` (Z16/Z17).

## 3. Create networks, leases and address objects

Under **Settings > Networks**, create gateway-routed networks with these
literal VLAN IDs, not VLAN-only/third-party-router networks. Disable automatic
network isolation options that would conflict with explicit zone exceptions;
section 5 supplies the isolation. Leave future Lab VLAN 80 uncreated.

| VLAN / network | Gateway and mask | DHCP |
|---|---|---|
| 10 Mgmt | `10.0.10.1/24` | Infrastructure reservations |
| 20 Trusted | `10.0.20.1/24` | Enabled |
| 30 Work | `10.0.30.1/24` | Enabled |
| 40 Servers | `10.0.40.1/24` | Infrastructure reservations |
| 50 IoT-Local | `10.0.50.1/24` | Enabled |
| 55 IoT-Cloud | `10.0.55.1/24` | Enabled |
| 60 Cameras | `10.0.60.1/24` | Camera reservations |
| 70 Guest | `10.0.70.1/24` | Enabled |

Use `.100-.199` as an initial dynamic pool on each subnet, checking existing
leases/static addresses first. Keep infrastructure/static assignments outside
that pool; reservations must use the device's actual MAC. "Reservations" in
the architecture is an address-management policy, not proof that UniFi rejects
unknown DHCP clients. Keep unused ports disabled.

- Reserve server `10.0.40.10`, Pi `10.0.40.11`, NAS `10.0.40.20`; if a host uses
  OS-static addressing instead, exclude its address from dynamic allocation and
  still document its name/MAC/IP. Never assign the same address to two devices.
- Reserve switch/AP addresses in Mgmt and camera addresses in Cameras; record
  those assignments before creating rules/configuring Frigate.
- Reserve Trusted admin device addresses. Account for private/randomized MAC
  behavior so those reservations continue matching. An IP allowlist is not
  strong device authentication; protect admin credentials separately.
- Set DHCP domain to `home.arpa` for Mgmt/Trusted/Work/Servers/Guest,
  `iot.home.arpa` for both IoT networks, and `cam.home.arpa` for Cameras.
- Once section 6 passes, set **manual DHCP DNS** on every network except
  Cameras to only `10.0.40.10`, `10.0.40.11`. Do not add a public "third DNS".
  Cameras get no DNS server (architecture §9.5).
- Set DHCP NTP (option 42) on every network to `10.0.40.10`, `10.0.40.11`
  **only after** section 6 proves both answer. Manually set each camera's NTP
  server to `10.0.40.10`; cameras often ignore option 42.
- Point UniFi devices at the same servers: in the Network application's NTP
  setting choose manual and enter `10.0.40.10`, `10.0.40.11`. Mgmt has no
  internet NTP (Z22), so switches/APs otherwise drift.

Create reusable address/port objects using the UI's supported groups:

| Object | Members |
|---|---|
| `DNS_NODES` | `10.0.40.10`, `10.0.40.11` |
| `SERVER` | `10.0.40.10` |
| `NAS` | `10.0.40.20` |
| `ADMIN_CLIENTS` | Recorded Trusted admin `/32` addresses only |
| `ISP_LAN` | Actual BGW320 LAN subnet |
| `DNS_PORTS` | TCP/UDP 53, UDP 123 (Z1–Z4: DNS and NTP to `DNS_NODES`) |
| `DNS_BYPASS_PORTS` | TCP/UDP 53 and 853 (includes DoQ) |
| `GW_ADMIN_PORTS` | TCP/UDP 22, 53, 80, 443, 853 (Z13) |
| `CAMERA_PORTS` | TCP 554, 80, 443 (Z12; confirm the ONVIF port) |
| `IOT_GW_PORTS` | UDP 67, 5353 (Z20, used with Match Opposite) |
| `CAM_GW_PORTS` | UDP 67 (Z21, used with Match Opposite) |

## 4. Adopt devices and apply port profiles

Adopt one device at a time on the temporary LAN; wait for provisioning before
the next change. Leave device SSH disabled unless needed; if enabled, use
separate recorded credentials and an admin-only rule.

Create these port profiles (native = untagged ingress/egress network):

| Profile | Native network | Allowed tagged VLANs |
|---|---|---|
| Gateway/core uplink | Mgmt 10 | 20, 30, 40, 50, 55, 60, 70 |
| Office trunk | Mgmt 10 | 20, 30, 40, 50, 55, 70 |
| AP trunk | Mgmt 10 | 20, 30, 50, 55, 70 |
| Server/Pi/NAS access | Servers 40 | None |
| Desk PC access | Trusted 20 | None |
| Camera access | Cameras 60 | None |
| Recovery (temporary) | Default recovery LAN | None |

The office trunk needs 50/55/70 as well as 20/30/40 because the upstairs AP
serves those SSIDs. Do not use the architecture's old abbreviated tag list.
Use explicit tag allowlists instead of "Allow All". No native Mgmt SSID exists.

1. Configure a spare physical UCG LAN port as Recovery. Keep the laptop there.
2. Apply Gateway/core uplink on the UCG LAN uplink and core port 13. Core port 13
   PoE is **off**. Let switches/APs obtain Mgmt addresses on the native network;
   do not also force a tagged management VLAN override without a tested need.
3. Core port 14 and office port 1: Office trunk, **PoE off** at core port 14
   (office switch has its own AC adapter).
4. Core port 15 and office port 5: AP trunk; enable suitable PoE for each AP.
5. Core ports 1-5: Camera access/PoE. Core port 6: Server/Pi/NAS access/PoE
   for the Pi HAT. Office ports 2/3: Server/Pi/NAS access; port 4: Desk PC.
6. Reconnect the laptop through Trusted and verify its admin access after
   section 5. Keep local recovery available until acceptance passes.
7. After the single trunk is stable, configure core port 16 and office port 6
   with Office trunk, core PoE off. Set the core as spanning-tree root with
   lower bridge priority than the office switch. Enable RSTP; do not mark
   inter-switch links as edge ports or enable BPDU guard on them.
8. Connect the second cable only then. Verify one redundant path is blocked,
   disconnect the active link, and confirm failover. Do not configure an
   unsupported link aggregation or connect two unmanaged parallel links.
9. Disable unused ports. After acceptance, disable the Recovery port and
   remove the temporary LAN from all production port profiles. If the Default
   network cannot be deleted, leave it unused, isolated and without clients.

## 5. Build the zone firewall before moving clients

The zones, the defaults relied on and the final policy set (Z1–Z24) are in
[architecture §9](network-architecture.md#9-firewall-and-zone-policy). Enter them
from that table; don't keep a second copy here.

1. Screenshot the default zone matrix and record the UniFi Network version.
2. Create custom zones **Trusted, Mgmt, Servers, IoT-Local, Cameras, Work,
   IoT-Cloud** and assign one network to each. Assign only **Guest** to
   Hotspot: Hotspot requires a portal click before internet. Leave
   Internal, VPN and DMZ without production networks.
3. Screenshot the matrix again and compare it with architecture §9.1. Every
   custom zone should show Block All to the other internal zones and Allow All
   to External and Gateway. If any cell differs, **stop** and update §9.4
   before continuing.
4. Create the address/port objects from section 3, then Z1–Z22 and Z25–Z32 in ID order.
   Create Z13, Z23 and Z24 **disabled**; Z13 is enabled one lease time after
   the DNS cutover (section 6, step 5). Enable logging on Z14, Z15, Z18 and Z19.
5. Before enabling Z13, confirm the admin laptop's address is in `ADMIN_CLIENTS`
   and keep the Recovery port connected: Z13 is the policy that can lock you
   out of the gateway UI.
6. If Match Opposite is missing for a field, use the two-policy fallback in
   §9.4 and put the Allow above the Block.
7. Don't edit or reorder UniFi's built-in policies. Custom policies sit above
   them.

Boundaries the zone firewall can't enforce:

- Servers share VLAN 40. Server ↔ Pi (Kuma TCP 3001) and NAS traffic is
  switched, not routed; use the host/Docker firewalls from the Docker runbook.
  The same applies to devices inside IoT-Local or Cameras.
- Tailscale subnet traffic is SNATed to `10.0.40.10`, so UniFi sees remote
  users as `SERVER`. Tailnet ACLs separate admins from family; UniFi can't.
- Caddy proxies `unifi.home.<domain>` to the gateway. That connection comes from
  `SERVER`, so every proxy user can reach the UniFi login page; the local
  UniFi login remains mandatory. If admin-only access is required, add proxy
  authentication before enabling that route.
- No IoT → MQTT 1883 or HA 8123 allow is needed: those services are
  loopback/internal. Wall panels use Z23 (TCP 443 through Caddy).
- Z8/Z9 allow Trusted to start any connection to IoT devices. IoT devices still
  can't start connections back; casting that needs the device to connect to the
  phone (e.g., DLNA pull) won't work and needs a specific, inventoried exception.

## 6. Verify DNS and time, then change DHCP

1. Complete both DNS deployments using the Docker runbook. From a test client,
   query **each** resolver for public names, a known blocked name, DHCP names,
   reverse lookups and the configured HTTPS wildcard (once the domain exists).
2. The AdGuard template forwards `home.arpa` and private PTR lookups to
   `10.0.40.1`, the gateway's Servers-VLAN address. (The gateway doesn't answer
   DNS from VLAN 40 on its Mgmt address `10.0.10.1`.) Test it directly from a resolver host and confirm it
   answers locally for reservations in all configured DHCP domains. Do not
   configure gateway DNS upstream exclusively to AdGuard if unknown local
   names would loop back. Fix forwarding/records before claiming this works.
3. Test NTP on both servers from a client, for example on Windows:
   `w32tm /stripchart /computer:10.0.40.10 /samples:3 /dataonly`, then `.11`.
   Repeat from a temporary Cameras test port (Z25) and an IoT-Local port (Z3).
   `sudo chronyc clients` on each host shows the test clients.
4. If either server doesn't answer, check its ufw UDP 123 rule and
   `chronyc tracking` before changing gateway policies. Never give offline
   cameras or IoT devices internet to fix time.
5. Set DHCP DNS/NTP as in section 3 only after their tests pass. Renew leases
   and inspect actual client DNS, search domain and gateway settings. Clients
   may use either advertised resolver, not just DNS 1. Enable Z13 only after
   one full DHCP lease time (UniFi default: 24 hours), once Trusted clients
   have renewed: until then some still use gateway DNS, which Z13 blocks.
6. Stop server DNS briefly and query public/local names through ordinary
   client resolution; confirm Pi queries in its logs. Restore, then test the
   other direction. Do not delete data or stop both resolvers together.

Keep AdGuard's encrypted-DNS lists and Firefox canary enabled. This blocks
known providers, **not all DoH over HTTPS, VPNs or hard-coded HTTPS endpoints**.
Do not claim Z14/Z15 prevent every bypass or break Work HTTPS with speculative
TLS interception.

## 7. Configure Wi-Fi and mDNS

Create these SSIDs with distinct strong passwords and no PPSK. Only Mead-Hall shows a portal (the Hotspot zone requires a click-through):

| SSID | Network | Bands | Security |
|---|---|---|---|
| Mostly-Harmless | Trusted 20 | 2.4/5/6 GHz (6 GHz on downstairs U7 Pro only) | WPA3 |
| The-Forge | Work 30 | 2.4/5 GHz | WPA2/WPA3 transition |
| Alfheim | IoT-Local 50 | 2.4 GHz initially | WPA2/WPA3 transition |
| Niflheim | IoT-Cloud 55 | 2.4 GHz initially | WPA2/WPA3 transition |
| Mead-Hall | Guest 70 | 2.4/5 GHz | WPA2/WPA3 transition |

Verify the installed AP/firmware supports this SSID count on each band. Do not
downgrade Mostly-Harmless's 6 GHz security for an older client; record any needed
compatibility decision first. Add 5 GHz to Alfheim only for a device that needs it.

- Enable Guest Wi-Fi client isolation and apply the chosen per-client rate
  limit. Verify Guest isolation across APs and wired ports as well as within
  one AP; use supported switch/network isolation for any wired Guest ports.
  Keep such ports disabled until that test passes.
- Print the Mead-Hall (Guest) QR code only after confirming its VLAN mapping.
- Disable broad automatic mDNS reflection. Select **Trusted and IoT-Local
  only** in the gateway mDNS proxy. Exclude Mgmt, Work, Servers, IoT-Cloud,
  Cameras and Guest. Verify both permitted and forbidden discovery.
- If the installed mDNS implementation needs firewall exceptions, scope them
  to that service and these two networks, not a general inter-VLAN allow.
- Keep radio/channel settings conservative initially; check country, coverage
  and interference on site before tuning. Do not enable IoT client isolation
  indiscriminately where it would break border routers/local control.

## 8. Enable IPv6 without bypassing segmentation

IPv6 is required on Trusted, Servers and IoT-Local for the baseline. Stage it
after IPv4 rules work; an IPv4-only test is not completion of this design.

1. Enable WAN DHCPv6 prefix delegation using the size actually supplied
   through the BGW320. Do not guess `/56`, reuse one `/64` on multiple LANs,
   or assume IPv4 passthrough guarantees usable IPv6 delegation.
2. Assign a distinct delegated `/64` to each of Trusted, Servers and IoT-Local;
   enable SLAAC/router advertisements. Keep it disabled on other VLANs unless
   the architecture is explicitly changed. WAN IPv6 alone is not LAN IPv6.
3. Confirm Z14, Z18, Z19 and Z20 are set to IP version **Both**, and that the
   zone defaults block unsolicited inbound IPv6 just as for IPv4. A global
   address on IoT-Local is not permission for internet access.
4. Preserve essential ICMPv6 (including neighbor/router discovery and Packet
   Too Big), multicast listener discovery and required DHCPv6 control traffic.
   Do not block all ICMPv6; do not enable broad multicast forwarding.
5. Do not advertise an unfiltered gateway/ISP IPv6 DNS resolver via RA/RDNSS
   or DHCPv6. The current DNS services bind IPv4 LAN addresses. Verify clients
   use the advertised IPv4 resolvers even for AAAA queries; if the firmware
   cannot avoid an alternate IPv6 resolver, resolve that configuration gap
   before enabling production IPv6.
6. Test IPv6 internet on Trusted/Servers, denied IPv6 internet on IoT-Local,
   denied cross-zone paths, DNS bypass denial and actual Matter/Thread pairing.
   If delegation fails, document the blocker and keep deployment staged rather
   than declaring IPv6/Matter complete.

## 9. Cutover and acceptance checklist

Enable IDS/IPS in **detect** mode first. After a week reviewing events and
allowlist needs, change to prevention and repeat throughput/application tests.
Enable local alerts/logging for IDS and Z18/Z19; review volume and retention so
blocked IoT chatter does not exhaust storage. Remote push/email/HA alerts are
not proven by an entry in the UniFi event log; test the selected delivery path.

Move one test endpoint, then devices VLAN by VLAN (IoT, Cameras, Work), retaining
a working wired Trusted admin connection. Export a backup at each stable stage.

| Test location | Required result |
|---|---|
| Every VLAN | Correct lease/subnet; both DNS nodes work over UDP and TCP (Cameras: DNS denied by design) |
| Trusted, Guest, IoT-Cloud | Public DNS TCP/UDP 53 and 853 denied, including gateway DNS for non-admins; approved DNS works. Work may use external DNS (exempt) |
| DNS nodes | External authoritative TCP/UDP 53 succeeds; `home.arpa`/PTR forwarding works |
| Trusted admin / non-admin | Admin reaches gateway 443 and SSH hosts; non-admin cannot directly manage gateway/SSH |
| Trusted | Proxy TCP 443 and NAS TCP 445 work; Work and Cameras denied |
| Work / IoT-Cloud / Guest | Intended internet works; Servers reachable only for DNS; household, gateway UI and each other denied |
| IoT-Local / Cameras | External IPv4 and applicable IPv6 denied and logged; NTP from `.10`/`.11` works (DNS too on IoT-Local); gateway UI/SSH denied; no client-initiated pivot |
| Server | Camera streams/ONVIF and IoT control work; arbitrary Trusted/Work access denied |
| Guest clients | Cannot reach each other, including across APs; rate limit measured |
| Trusted + IoT-Local | Intended mDNS discovery/control works; other VLANs see no reflected services |
| WAN / external mobile data | No unsolicited gateway/server exposure; Tailscale ACL admin/family behavior verified |
| Server outage | Pi DNS continues; on-site gateway login works by IP; remote access loss is expected |
| Trunk/PoE checks | Upstairs VLANs work; second-link RSTP failover works; correct PoE state; no loop |
| IPv6 + Matter | Section 8 tests pass, not merely successful IPv4 pings |

On Windows use `nslookup example.com 10.0.40.10`, repeat with `.11`;
`nslookup -vc example.com 10.0.40.10` checks TCP. Use
`Test-NetConnection 10.0.40.10 -Port 443` for permitted TCP flows. Test denied
flows against a known listening service and inspect rule counters/logs:
a closed port or failed ping alone does **not** prove firewall enforcement.
Repeat DNS and isolation tests with the host firewalls enabled.

## 10. Backup, recovery and temporary WAN

- Enable supported local scheduled Network configuration backups. Download
  backups off the gateway to the NAS **and** keep an encrypted independent
  laptop/offline copy. A backup stored only on the UCG is not recovery.
- Record the real NAS backup path, backup schedule, retention, export date,
  UniFi versions and restore credentials in the private operations inventory.
  Local-only management means no cloud backup is assumed. If automatic NAS
  copying is not available in the installed UI, arrange and test an explicit
  supported export/copy process; do not claim an unconfigured job exists.
- Before updates, export another backup and read release notes. Disable
  unattended firmware changes; update one infrastructure device at a time.
- Restore-test using a compatible spare/replacement or a planned on-site
  outage. Verify local login, VLANs, zones, port profiles, SSIDs, reservations
  and off-device backup access afterward. Do not factory-reset the only gateway
  just to test a backup during normal household use.
- If a rule locks out admin access, use the still-connected Recovery port
  during rollout, correct/disable the last policy and retest. After removing
  that port, follow the saved local recovery/restore procedure. Never reset
  switches/APs indiscriminately; try restoring controller connectivity first.
- For a fiber outage, use a phone hotspot **through an Ethernet-capable tether
  adapter/travel router** into a UCG port assigned as WAN2. The UCG Max is not
  assumed to accept direct phone USB tethering or join Wi-Fi as a WAN client.
  Keep this adapter available and test it before relying on the procedure.
- Configure WAN2 DHCP without overlapping LAN subnets; do not repurpose the
  production LAN uplink. Review WAN2 External policies, NAT, DNS and route
  failover. Test client access and Tailscale (cellular CGNAT may require relay).
  Restore primary WAN after fiber returns, remove temporary tethering, and
  disable WAN2 if no longer needed. This is manual recovery, not a purchased
  always-on backup circuit.

## References

- [Network architecture and pending decisions](network-architecture.md)
- [Docker prerequisites and service acceptance](runbook.md)
- [UniFi local management](https://help.ui.com/hc/en-us/articles/28457353760919-UniFi-Local-Management)
- [UniFi zone-based firewall](https://help.ui.com/hc/en-us/articles/115003173168)
- [UniFi IPv6 and prefix delegation](https://help.ui.com/hc/en-us/articles/115005868927-UniFi-Gateway-Static-IPv6-and-DHCPv6-Prefix-Delegation)

The IPv6 reference was retrieved while writing this runbook. Other UniFi help
pages were access-blocked; exact setup screens, firmware-specific features and
all hardware behavior still require on-site verification. No configuration has
been applied to the gateway by this repository.
