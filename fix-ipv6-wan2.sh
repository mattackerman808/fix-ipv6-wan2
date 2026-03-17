#!/bin/bash
# fix-ipv6-wan2.sh
#
# Copyright (c) 2026 Matthew Ackerman <matt@808.org>
# Licensed under the MIT License. See LICENSE file for details.
#
# Ensures IPv6 traffic that should use WAN2 (Xfinity) actually routes out
# the correct interface instead of being hijacked by UDM WAN failover.
#
# Problem: The UBIOS_WF_GROUP_1_SINGLE mangle chain marks all new IPv6
# connections for the primary WAN (ATT/eth9). This overrides source-based
# routing AND static routes, causing WAN2 IPv6 traffic to go out ATT
# where it's dropped. The CONNMARK save/restore in the UBIOS chain means
# rules must be appended AFTER the chain, not inserted before it.
#
# Solution:
#   - Source/dest mangle rules in UBIOS chain (before catch-all) for
#     WAN2-sourced traffic and static routes
#   - MAC-based rules appended to ip6tables PREROUTING (after UBIOS chain)
#     to force IPv6 through WAN2 with MASQUERADE for devices that have
#     UniFi PBR policy routes to WAN2 (auto-discovered from ipsets)
#   - IPv4 is handled by UniFi PBR natively; only IPv6 needs the script
#
# Install:
#   cp fix-ipv6-wan2.sh /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
#   chmod +x /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
#   # Optional cron safety net for DHCPv6 renewals:
#   crontab -e  # add: */5 * * * * /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2

set -uo pipefail

WAN2_IFACE="${WAN2_IFACE:-eth8}"
GUEST_BRIDGE="${GUEST_BRIDGE:-br42}"
WAN2_MACS="${WAN2_MACS:-}"  # Extra MACs to force through WAN2 (in addition to auto-discovered PBR MACs)
MANGLE_CHAIN="UBIOS_WF_GROUP_1_SINGLE"
ROUTE_TABLE="202.${WAN2_IFACE}"
RULE_PRIORITY="32504"
MARK_MASK="0x7e0000"
NAT6_FLAG="0x1"  # Bit flag to identify IPv6 NAT traffic in POSTROUTING
LOG_TAG="fix-ipv6-wan2"

log() { logger -t "$LOG_TAG" "$1"; echo "$1"; }

# When called by networkd-dispatcher, only act on WAN2 becoming routable
if [ -n "${IFACE:-}" ] && [ "$IFACE" != "$WAN2_IFACE" ]; then
    exit 0
fi

# --- Discover WAN2 fwmark ---
WAN2_MARK=$(ip -6 rule show | grep "lookup ${ROUTE_TABLE}" | grep fwmark | head -1 | sed -n 's/.*fwmark \(0x[0-9a-f]*\).*/\1/p')
if [ -z "$WAN2_MARK" ]; then
    log "ERROR: Could not determine WAN2 fwmark for ${ROUTE_TABLE}"
    exit 1
fi

# --- Compute NAT6 combined marks ---
# Sets both the WAN2 routing mark and the NAT6 flag in a single --set-xmark
NAT6_COMBINED_MARK=$(printf "0x%x" $(( ${WAN2_MARK} | ${NAT6_FLAG} )))
NAT6_COMBINED_MASK=$(printf "0x%x" $(( ${MARK_MASK} | ${NAT6_FLAG} )))

# --- Auto-discover MACs from UniFi PBR policy routes to WAN2 ---
# Parses the UBIOS_PREROUTING_PBR chain for rules that route to WAN2 (by NFLOG
# prefix containing the WAN2 interface), then reads MAC entries from the
# corresponding hash:mac ipsets. This way adding a device to PBR in the UniFi
# UI automatically enables IPv6 MASQUERADE for it.
PBR_MACS=""
while read -r setname; do
    [ -z "$setname" ] && continue
    if ipset list "$setname" -t 2>/dev/null | grep -q "Type: hash:mac"; then
        while read -r mac; do
            PBR_MACS="$PBR_MACS $mac"
        done < <(ipset list "$setname" 2>/dev/null | grep -oP '[0-9A-F]{2}(:[0-9A-F]{2}){5}')
    fi
done < <(iptables -t mangle -S UBIOS_PREROUTING_PBR 2>/dev/null | \
    grep "NFLOG.*${WAN2_IFACE}" | \
    grep -oP '(?<=--match-set )\S+' | \
    grep -v UBIOS_local_network | \
    sort -u)

# Merge PBR-discovered MACs with manually configured ones
ALL_WAN2_MACS=$(echo "$PBR_MACS $WAN2_MACS" | tr ' ' '\n' | sort -uf | xargs)

# --- Discover WAN2 global IPv6 address ---
WAN2_ADDR=$(ip -6 addr show dev "$WAN2_IFACE" scope global dynamic | grep -oP '(?<=inet6 )\S+(?=/128)' | head -1)

# --- Discover PD prefix on guest bridge ---
# Use the kernel route for the connected network, which gives the exact prefix
PD_CIDR=$(ip -6 route show dev "$GUEST_BRIDGE" proto kernel | grep -oP '\S+::/\d+' | head -1)

# --- Discover static routes via WAN2 ---
# Find destination prefixes of non-default, non-connected routes using WAN2.
# These are typically added via the UniFi API or manually.
STATIC_DSTS=()
while IFS= read -r prefix; do
    [ -n "$prefix" ] && STATIC_DSTS+=("$prefix")
done < <(ip -6 route show dev "$WAN2_IFACE" | \
    grep -v -E "^default|^::/0|^fe80|^ff0|proto kernel|proto ra|proto dhcp|^unreachable" | \
    awk '{print $1}')

if [ -z "$WAN2_ADDR" ] && [ -z "$PD_CIDR" ] && [ ${#STATIC_DSTS[@]} -eq 0 ] && [ -z "$ALL_WAN2_MACS" ]; then
    log "WARN: No IPv6 addresses on ${WAN2_IFACE}/${GUEST_BRIDGE}, no static routes, and no WAN2 MACs — nothing to do"
    exit 0
fi

log "WAN2=${WAN2_IFACE} mark=${WAN2_MARK} addr=${WAN2_ADDR:-none} pd=${PD_CIDR:-none} static_routes=${#STATIC_DSTS[@]} wan2_macs=${ALL_WAN2_MACS:-none}"

# --- Mangle rules (UBIOS chain) ---
# Find the catch-all mark rule that assigns traffic to primary WAN
CATCHALL_LINE=$(ip6tables -t mangle -L "$MANGLE_CHAIN" -n --line-numbers 2>/dev/null | grep "^[0-9].*MARK.*::/0.*::/0.*MARK xset" | tail -1 | awk '{print $1}')
if [ -z "$CATCHALL_LINE" ]; then
    log "ERROR: Could not find catch-all mark rule in ${MANGLE_CHAIN}"
    exit 1
fi

add_mangle_rule() {
    local src="$1" desc="$2"
    if ip6tables -t mangle -C "$MANGLE_CHAIN" -s "$src" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}" 2>/dev/null; then
        log "  mangle ${desc}: ok (exists)"
        return 0
    fi
    # Remove stale rules for this source (address may have changed)
    while ip6tables -t mangle -D "$MANGLE_CHAIN" -s "$src" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}" 2>/dev/null; do :; done
    # Recalculate catchall line in case removals shifted it
    CATCHALL_LINE=$(ip6tables -t mangle -L "$MANGLE_CHAIN" -n --line-numbers | grep "^[0-9].*MARK.*::/0.*::/0.*MARK xset" | tail -1 | awk '{print $1}')
    ip6tables -t mangle -I "$MANGLE_CHAIN" "$CATCHALL_LINE" -s "$src" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}"
    log "  mangle ${desc}: added"
}

add_dst_mangle_rule() {
    local dst="$1" desc="$2"
    if ip6tables -t mangle -C "$MANGLE_CHAIN" -d "$dst" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}" 2>/dev/null; then
        log "  mangle ${desc}: ok (exists)"
        return 0
    fi
    # Recalculate catchall line in case prior insertions shifted it
    CATCHALL_LINE=$(ip6tables -t mangle -L "$MANGLE_CHAIN" -n --line-numbers | grep "^[0-9].*MARK.*::/0.*::/0.*MARK xset" | tail -1 | awk '{print $1}')
    ip6tables -t mangle -I "$MANGLE_CHAIN" "$CATCHALL_LINE" -d "$dst" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}"
    log "  mangle ${desc}: added"
}

# Clean up stale mangle rules (old WAN2 addresses no longer on the interface)
cleanup_stale_mangle() {
    local current_sources=()
    if [ -n "${WAN2_ADDR:-}" ]; then
        current_sources+=("${WAN2_ADDR}/128")
        current_sources+=("${WAN2_ADDR}")
    fi
    [ -n "${PD_CIDR:-}" ] && current_sources+=("$PD_CIDR")

    local stale_sources=()
    while read -r src; do
        [ -z "$src" ] && continue
        [ "$src" = "::/0" ] && continue
        local found=false
        for cs in "${current_sources[@]}"; do
            [ "$src" = "$cs" ] && found=true
        done
        if [ "$found" = false ]; then
            stale_sources+=("$src")
        fi
    done < <(ip6tables -t mangle -L "$MANGLE_CHAIN" -n | grep "MARK.*${WAN2_MARK}" | grep -v " ::/0 .* ::/0 " | awk '{print $3}')

    for src in "${stale_sources[@]}"; do
        log "  mangle cleanup: removing stale rule for ${src}"
        ip6tables -t mangle -D "$MANGLE_CHAIN" -s "$src" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}" 2>/dev/null || true
    done
}

cleanup_stale_mangle

# Clean up stale destination-based mangle rules (static routes that were removed)
cleanup_stale_dst_mangle() {
    local stale_dsts=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local dst
        dst=$(echo "$line" | grep -oP '(?<=-d )\S+')
        [ -z "$dst" ] && continue
        local found=false
        for cd in "${STATIC_DSTS[@]+"${STATIC_DSTS[@]}"}"; do
            [ "$dst" = "$cd" ] && found=true
        done
        if [ "$found" = false ]; then
            stale_dsts+=("$dst")
        fi
    done < <(ip6tables -t mangle -S "$MANGLE_CHAIN" 2>/dev/null | grep -- "-d " | grep -v -- "-s " | grep -v -- "--mac-source" | grep "${WAN2_MARK}")

    for dst in "${stale_dsts[@]+"${stale_dsts[@]}"}"; do
        log "  mangle dst cleanup: removing stale rule for ${dst}"
        ip6tables -t mangle -D "$MANGLE_CHAIN" -d "$dst" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}" 2>/dev/null || true
    done
}

cleanup_stale_dst_mangle

if [ -n "$PD_CIDR" ]; then
    add_mangle_rule "$PD_CIDR" "pd-prefix"
fi
if [ -n "$WAN2_ADDR" ]; then
    add_mangle_rule "${WAN2_ADDR}/128" "wan2-addr"
fi

for dst in "${STATIC_DSTS[@]+"${STATIC_DSTS[@]}"}"; do
    add_dst_mangle_rule "$dst" "static-${dst}"
done

# --- IPv6 MAC-based WAN2 forcing (PREROUTING, after UBIOS chain) ---
# Auto-discovered PBR MACs + manually configured MACs get their IPv6 forced
# through WAN2 with MASQUERADE. Rules are appended to ip6tables PREROUTING
# so they run AFTER the UBIOS chain (whose CONNMARK restore would overwrite
# marks inserted before it). IPv4 is handled by UniFi PBR natively.

# Clean up old per-destination NAT6 rules from PREROUTING (legacy format)
while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | grep -q -- "-d " || continue
    local_mac=$(echo "$line" | grep -oP '(?<=--mac-source )\S+')
    local_xmark=$(echo "$line" | grep -oP '(?<=--set-xmark )\S+')
    local_dst=$(echo "$line" | grep -oP '(?<=-d )\S+')
    [ -z "$local_mac" ] && continue
    log "  wan2-mac cleanup: removing legacy per-dest rule mac=${local_mac} dst=${local_dst}"
    ip6tables -t mangle -D PREROUTING \
        -d "$local_dst" -m mac --mac-source "$local_mac" \
        -j MARK --set-xmark "$local_xmark" 2>/dev/null || true
done < <(ip6tables -t mangle -S PREROUTING 2>/dev/null | grep -- "--mac-source" | grep -- "-d ")

# Clean up stale IPv6 MAC rules (MACs no longer in PBR or manual config)
while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | grep -q -- "-d " && continue
    mac=$(echo "$line" | grep -oP '(?<=--mac-source )\S+')
    xmark=$(echo "$line" | grep -oP '(?<=--set-xmark )\S+')
    [ -z "$mac" ] && continue
    found=false
    for m in $ALL_WAN2_MACS; do
        if [ "$(echo "$m" | tr '[:upper:]' '[:lower:]')" = "$(echo "$mac" | tr '[:upper:]' '[:lower:]')" ]; then
            found=true
        fi
    done
    if [ "$found" = false ]; then
        log "  wan2-mac cleanup: removing stale ipv6 rule for ${mac}"
        ip6tables -t mangle -D PREROUTING \
            -m mac --mac-source "$mac" \
            -j MARK --set-xmark "$xmark" 2>/dev/null || true
    fi
done < <(ip6tables -t mangle -S PREROUTING 2>/dev/null | grep -- "--mac-source" | grep -v -- "-d ")

# Clean up stale IPv4 MAC rules (leftover from before PBR handled IPv4)
while IFS= read -r line; do
    [ -z "$line" ] && continue
    mac=$(echo "$line" | grep -oP '(?<=--mac-source )\S+')
    xmark=$(echo "$line" | grep -oP '(?<=--set-xmark )\S+')
    [ -z "$mac" ] && continue
    log "  wan2-mac cleanup: removing legacy ipv4 rule for ${mac}"
    iptables -t mangle -D PREROUTING \
        -m mac --mac-source "$mac" \
        -j MARK --set-xmark "$xmark" 2>/dev/null || true
done < <(iptables -t mangle -S PREROUTING 2>/dev/null | grep -- "--mac-source")

# Add/verify IPv6 MAC-based rules (appended after UBIOS chain)
if [ -n "$ALL_WAN2_MACS" ]; then
    for mac in $ALL_WAN2_MACS; do
        if ip6tables -t mangle -C PREROUTING \
            -m mac --mac-source "$mac" \
            -j MARK --set-xmark "${NAT6_COMBINED_MARK}/${NAT6_COMBINED_MASK}" 2>/dev/null; then
            log "  wan2-mac ipv6 ${mac}: ok (exists)"
        else
            ip6tables -t mangle -A PREROUTING \
                -m mac --mac-source "$mac" \
                -j MARK --set-xmark "${NAT6_COMBINED_MARK}/${NAT6_COMBINED_MASK}"
            log "  wan2-mac ipv6 ${mac}: added"
        fi
    done
fi

# --- IPv6 MASQUERADE (rewrite source to WAN2 address) ---
if [ -n "$ALL_WAN2_MACS" ]; then
    if ! ip6tables -t nat -C POSTROUTING -o "$WAN2_IFACE" \
        -m mark --mark "${NAT6_FLAG}/${NAT6_FLAG}" \
        -j MASQUERADE 2>/dev/null; then
        ip6tables -t nat -A POSTROUTING -o "$WAN2_IFACE" \
            -m mark --mark "${NAT6_FLAG}/${NAT6_FLAG}" \
            -j MASQUERADE
        log "  nat6 postrouting: added"
    else
        log "  nat6 postrouting: ok (exists)"
    fi
else
    # Clean up POSTROUTING rule if no WAN2 MACs configured
    if ip6tables -t nat -D POSTROUTING -o "$WAN2_IFACE" \
        -m mark --mark "${NAT6_FLAG}/${NAT6_FLAG}" \
        -j MASQUERADE 2>/dev/null; then
        log "  nat6 postrouting: removed (no longer needed)"
    fi
fi

# --- Routing rules ---
add_route_rule() {
    local from="$1" desc="$2"
    if ip -6 rule show | grep -q "from ${from} lookup ${ROUTE_TABLE}"; then
        log "  route ${desc}: ok (exists)"
    else
        ip -6 rule add from "$from" lookup "$ROUTE_TABLE" priority "$RULE_PRIORITY"
        log "  route ${desc}: added"
    fi
}

if [ -n "$PD_CIDR" ]; then
    add_route_rule "$PD_CIDR" "pd-prefix"
fi

# Clean up stale route rules (old PD prefixes)
ip -6 rule show | grep "priority ${RULE_PRIORITY}" | grep "lookup ${ROUTE_TABLE}" | while read -r line; do
    rule_from=$(echo "$line" | sed -n 's/.*from \(\S*\) lookup.*/\1/p')
    case "$rule_from" in
        "$PD_CIDR"|"$WAN2_ADDR"|"${WAN2_ADDR}/128") ;;
        *)
            # Check if this source is still valid
            if ! ip -6 addr show dev "$WAN2_IFACE" | grep -q "${rule_from%/*}" && \
               ! ip -6 addr show dev "$GUEST_BRIDGE" | grep -q "${rule_from%/*}"; then
                log "  route cleanup: removing stale rule for ${rule_from}"
                ip -6 rule del from "$rule_from" lookup "$ROUTE_TABLE" priority "$RULE_PRIORITY" 2>/dev/null || true
            fi
            ;;
    esac
done

log "Complete."
