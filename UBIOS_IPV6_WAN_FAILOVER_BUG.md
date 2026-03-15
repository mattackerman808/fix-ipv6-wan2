# IPv6 broken on secondary WAN due to WAN failover mangle chain

## Summary

On a dual-WAN UniFi gateway, IPv6 traffic sourced from WAN2 (secondary WAN) addresses — including prefix-delegated subnets — is silently dropped because the `UBIOS_WF_GROUP_1_SINGLE` ip6tables mangle chain forces all new IPv6 connections out the primary WAN regardless of source address. This causes IPv6 to be completely non-functional on any VLAN policy-routed to WAN2.

## Environment

- **Device:** UniFi Dream Machine (unifi808org)
- **Firmware:** UniFi OS (ubios-udapi-server present)
- **WAN1 (eth9):** AT&T — primary WAN
- **WAN2 (eth8):** Xfinity via UCI cable modem — secondary WAN
- **Guest VLAN 42 (br42):** Policy-routed to WAN2
- **WAN2 IPv6:** DHCPv6 address + prefix delegation (/64 on br42)

## Problem

The `UBIOS_WF_GROUP_1_SINGLE` chain in the `mangle` table (ip6tables) unconditionally marks all new IPv6 connections with the primary WAN's fwmark (`0x1a0000` / eth9), overriding any source-based routing rules:

```
Chain UBIOS_WF_GROUP_1_SINGLE
1  RETURN     ! state NEW
2  RETURN     udp dpt:53 LOCAL
3  RETURN     tcp dpt:53 LOCAL
4  MARK       ::/0 → ::/0   mark 0x0/0x7e0000 → MARK xset 0x1a0000/0x7e0000  ← forces ALL to WAN1
5  CONNMARK   save
6  RETURN
```

The kernel's initial routing decision correctly uses source-based rules to send WAN2-sourced traffic out eth8. However, after the mangle OUTPUT chain sets fwmark `0x1a0000`, the kernel re-routes the packet using the fwmark-based rule (`from all fwmark 0x1a0000/0x7e0000 lookup 201.eth9`), which has higher priority than the source-based rules. The packet exits eth9 (AT&T) with a Comcast source address and is dropped by the upstream ISP's ingress filtering (BCP38).

### Packet flow (broken)

```
1. Application sends IPv6 packet
   src: 2001:558:x:x (Comcast DHCPv6 addr) or 2601:647:x:x (Comcast PD prefix)
   dst: 2607:f8b0:x:x (Google)

2. Kernel routing decision: src-based rule → table 202.eth8 → via eth8 ✓

3. Mangle OUTPUT: UBIOS_WF_GROUP_1_SINGLE sets fwmark 0x1a0000 (eth9)

4. Kernel re-routes: fwmark rule (priority 32503) → table 201.eth9 → via eth9 ✗

5. Packet exits eth9 (AT&T) with Comcast source address → dropped by AT&T (BCP38)
```

### Debugging evidence

tcpdump confirmed packets were egressing eth9 (AT&T) despite `ip -6 route get` showing eth8:

```
$ sudo tcpdump -i any -n src 2001:558:6045:21:2532:1c19:41f7:8e0e and icmp6
14:37:23.430390 eth9  Out IP6 2001:558:6045:21:... > 2607:f8b0:4004:800::200e: ICMP6, echo request
14:37:24.470321 eth9  Out IP6 2001:558:6045:21:... > 2607:f8b0:4004:800::200e: ICMP6, echo request
```

`ip -6 route get` does not account for mangle rerouting, so it misleadingly shows the correct interface:

```
$ ip -6 route get 2607:f8b0:4004:800::200e from 2001:558:6045:21:2532:1c19:41f7:8e0e
2607:f8b0:... via fe80::21c:73ff:fe00:99 dev eth8 table 202.eth8 ← looks correct but isn't
```

## Expected behavior

IPv6 traffic sourced from WAN2's DHCPv6 address or prefix-delegated subnets should egress via WAN2, consistent with how IPv4 policy routing and source-based routing work. The WAN failover chain should respect source-based routing for traffic that already has a deterministic WAN assignment based on its source address.

## Workaround

Insert mangle rules before the catch-all to mark WAN2-sourced traffic with the WAN2 fwmark (`0x1c0000`), preventing the catch-all from overriding the routing:

```bash
# Mark PD prefix traffic for WAN2
ip6tables -t mangle -I UBIOS_WF_GROUP_1_SINGLE 4 \
  -s 2601:647:4d7e:e30::/64 -m mark --mark 0x0/0x7e0000 \
  -j MARK --set-xmark 0x1c0000/0x7e0000

# Mark WAN2 address traffic for WAN2
ip6tables -t mangle -I UBIOS_WF_GROUP_1_SINGLE 4 \
  -s 2001:558:6045:21:2532:1c19:41f7:8e0e/128 -m mark --mark 0x0/0x7e0000 \
  -j MARK --set-xmark 0x1c0000/0x7e0000

# Also need a routing rule for the PD prefix
ip -6 rule add from 2601:647:4d7e:e30::/64 lookup 202.eth8 priority 32504
```

These rules do not survive reprovision. An automated script is available at:
https://github.com/mattackerman808/fix-ipv6-wan2

## Suggested fix

The `UBIOS_WF_GROUP_1_SINGLE` chain should either:

1. **Skip traffic with WAN2 source addresses** — add RETURN rules before the catch-all for traffic sourced from WAN2's DHCPv6 address and any prefix-delegated subnets, or
2. **Mark WAN2-sourced traffic with the WAN2 fwmark** — the approach used in the workaround above, or
3. **Not apply WAN failover to IPv6 at all when source-based routing rules exist** — if ip6 rules already determine the correct egress for a source address, the mangle chain should not override that decision

Additionally, the controller should automatically add `ip -6 rule` entries for prefix-delegated subnets assigned to VLANs that are policy-routed to WAN2, similar to how it already adds rules for the WAN2 interface's own addresses (rule 32504/32505 in `ip -6 rule show`).
