# fix-ipv6-wan2

Fixes IPv6 routing on UniFi Dream Machine gateways with dual-WAN, and extends UniFi policy routes to IPv6 via MASQUERADE.

## Problems solved

### 1. IPv6 WAN failover hijacking

The UDM's WAN failover mangle chain (`UBIOS_WF_GROUP_1_SINGLE`) marks **all** new IPv6 connections with the primary WAN's fwmark. This overrides source-based routing rules, causing IPv6 traffic with WAN2 source addresses to egress the primary WAN where it gets dropped (wrong source prefix / BCP38).

This affects:
- Gateway-originated IPv6 traffic sourced from the WAN2 address
- Forwarded IPv6 traffic from VLANs using WAN2's delegated prefix (e.g., guest WiFi)

### 2. No IPv6 support for UniFi policy routes

UniFi policy-based routing (traffic routes) only handles IPv4. Devices routed to WAN2 via PBR still send IPv6 traffic out the primary WAN. Worse, if the device's IPv6 address comes from WAN1's prefix delegation, the traffic can't simply be rerouted — the source address belongs to the wrong ISP.

This script solves it with **NAT66 (IPv6 MASQUERADE)**: it discovers devices policy-routed to WAN2, forces their IPv6 through WAN2, and rewrites the source address to WAN2's IPv6 address. The result is full dual-stack policy routing — the device appears on the WAN2 ISP's network for both IPv4 and IPv6.

**Use case:** An Apple TV on the main LAN needs the Xfinity Stream app to work. Xfinity validates you're on their network by checking your source IP. UniFi PBR routes the Apple TV's IPv4 through WAN2 (Xfinity), and this script extends that to IPv6.

## How it works

The script:

1. Discovers the WAN2 interface's current global IPv6 address via DHCPv6
2. Discovers the prefix delegation assigned to the guest bridge (br42)
3. Reads the correct fwmark for WAN2 from `ip -6 rule show`
4. Inserts `ip6tables` mangle rules to mark WAN2-sourced traffic with the WAN2 fwmark, preventing the failover chain from hijacking it
5. Adds `ip -6 rule` entries so delegated prefix traffic uses the WAN2 routing table
6. **Auto-discovers devices** with UniFi PBR policy routes to WAN2 (from `hash:mac` ipsets)
7. **Appends IPv6 mangle rules** to PREROUTING (after the UBIOS chain) to force those devices' IPv6 through WAN2
8. **MASQUERADEs their IPv6 source** to WAN2's address in POSTROUTING
9. Cleans up stale rules from previous addresses/prefixes (handles DHCPv6 renewals)

Everything is auto-discovered — no hardcoded addresses, marks, or prefixes. Adding a device to a UniFi traffic route automatically enables IPv6 MASQUERADE for it.

### Why rules must be appended after UBIOS

The UBIOS mangle chain includes CONNMARK save/restore. Marks set **before** the chain get overwritten by the restore. By appending MAC-based rules **after** the UBIOS chain jump in PREROUTING, we get the last word on the fwmark. Additionally, `-m mac` cannot be used inside the UBIOS chain itself because the kernel rejects MAC matching in chains reachable from the OUTPUT hook.

## Install

Copy the script to the UDM gateway:

```bash
scp fix-ipv6-wan2.sh <gateway>:/tmp/
```

On the gateway:

```bash
cp /tmp/fix-ipv6-wan2.sh /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
chmod +x /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
```

Test it:

```bash
/etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
```

Add a cron job as a safety net for DHCPv6 renewals:

```bash
(crontab -l 2>/dev/null; echo "*/5 * * * * /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2 >/dev/null 2>&1") | crontab -
```

## Configuration

Environment variables (defaults shown):

| Variable | Default | Description |
|---|---|---|
| `WAN2_IFACE` | `eth8` | WAN2 network interface |
| `GUEST_BRIDGE` | `br42` | Bridge/VLAN interface with the delegated prefix |
| `WAN2_MACS` | *(empty)* | Extra MAC addresses to force IPv6 through WAN2 (in addition to auto-discovered PBR MACs) |

Example with custom interfaces:

```bash
WAN2_IFACE=eth4 GUEST_BRIDGE=br10 /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
```

### IPv6 policy routing via MASQUERADE

Devices with a UniFi **traffic route** (PBR) to WAN2 automatically get IPv6 MASQUERADE. The script reads the `hash:mac` ipsets from the `UBIOS_PREROUTING_PBR` chain to discover which MACs are policy-routed to WAN2.

```
Device on main LAN (IPv6 from WAN1 prefix):

  IPv4: UniFi PBR handles natively ✓
  IPv6: This script adds MASQUERADE ✓

Packet flow (IPv6):
  1. Device sends IPv6 packet (src = WAN1 prefix)
  2. PREROUTING mangle: UBIOS chain sets WAN1 mark
  3. PREROUTING mangle: Our appended rule overrides → WAN2 mark + NAT flag
  4. Routing: fwmark → WAN2 table → out WAN2 interface
  5. POSTROUTING nat: NAT flag → MASQUERADE → src rewritten to WAN2 address
  6. Remote server sees WAN2 ISP source ✓
```

To use: create a traffic route in the UniFi UI pointing the device to WAN2. The script picks up the MAC automatically on the next run.

To add MACs manually (without a UniFi PBR rule):

```bash
WAN2_MACS="AA:BB:CC:DD:EE:FF" /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
```

## Persistence

- `/etc/networkd-dispatcher/routable.d/` triggers the script when the WAN2 interface becomes routable (boot, link recovery)
- The cron job catches DHCPv6 renewals that change the WAN2 address or PD prefix
- UniFi firmware updates may wipe `/etc/networkd-dispatcher/`, so keep a backup copy on `/data/` or in this repo

## Context

Developed while debugging IPv6 on a dual-WAN UDM setup with:
- WAN1 (eth9): AT&T — primary
- WAN2 (eth8): Xfinity via UCI cable modem — backup, used for guest WiFi and Xfinity streaming app
- Guest WiFi on VLAN 42 (br42) policy-routed to WAN2
- Apple TV on main LAN policy-routed to WAN2 for Xfinity Stream app
