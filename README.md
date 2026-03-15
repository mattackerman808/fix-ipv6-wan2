# fix-ipv6-wan2

Fixes IPv6 routing on UniFi Dream Machine gateways with dual-WAN when the secondary WAN (WAN2) has IPv6 prefix delegation.

## Problem

The UDM's WAN failover mangle chain (`UBIOS_WF_GROUP_1_SINGLE`) marks **all** new IPv6 connections with the primary WAN's fwmark. This overrides source-based routing rules, causing IPv6 traffic with WAN2 source addresses to egress the primary WAN where it gets dropped (wrong source prefix / BCP38).

This affects:
- Gateway-originated IPv6 traffic sourced from the WAN2 address
- Forwarded IPv6 traffic from VLANs using WAN2's delegated prefix (e.g., guest WiFi)

## How it works

The script:

1. Discovers the WAN2 interface's current global IPv6 address via DHCPv6
2. Discovers the prefix delegation assigned to the guest bridge (br42)
3. Reads the correct fwmark for WAN2 from `ip -6 rule show`
4. Inserts `ip6tables` mangle rules to mark WAN2-sourced traffic with the WAN2 fwmark, preventing the failover chain from hijacking it
5. Adds `ip -6 rule` entries so delegated prefix traffic uses the WAN2 routing table
6. Cleans up stale rules from previous addresses/prefixes (handles DHCPv6 renewals)

Everything is auto-discovered — no hardcoded addresses, marks, or prefixes.

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

Example with custom interfaces:

```bash
WAN2_IFACE=eth4 GUEST_BRIDGE=br10 /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
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
