#!/bin/bash
# fix-ipv6-wan2.sh
#
# Ensures IPv6 traffic that should use WAN2 (Xfinity) actually routes out
# the correct interface instead of being hijacked by UDM WAN failover.
#
# Problem: The UBIOS_WF_GROUP_1_SINGLE mangle chain marks all new IPv6
# connections for the primary WAN (ATT/eth9). This overrides source-based
# routing AND static routes, causing WAN2 IPv6 traffic to go out ATT
# where it's dropped.
#
# Solution: Insert mangle rules to mark WAN2 traffic with the WAN2 fwmark:
#   - Source-based: WAN2 address and prefix-delegated subnets (-s rules)
#   - Destination-based: IPv6 static routes via WAN2 (-d rules)
# Also adds ip6 routing rules for delegated prefixes.
#
# Install:
#   cp fix-ipv6-wan2.sh /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
#   chmod +x /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2
#   # Optional cron safety net for DHCPv6 renewals:
#   crontab -e  # add: */5 * * * * /etc/networkd-dispatcher/routable.d/50-fix-ipv6-wan2

set -uo pipefail

WAN2_IFACE="${WAN2_IFACE:-eth8}"
GUEST_BRIDGE="${GUEST_BRIDGE:-br42}"
MANGLE_CHAIN="UBIOS_WF_GROUP_1_SINGLE"
ROUTE_TABLE="202.${WAN2_IFACE}"
RULE_PRIORITY="32504"
MARK_MASK="0x7e0000"
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

if [ -z "$WAN2_ADDR" ] && [ -z "$PD_CIDR" ] && [ ${#STATIC_DSTS[@]} -eq 0 ]; then
    log "WARN: No IPv6 addresses on ${WAN2_IFACE}/${GUEST_BRIDGE} and no static routes, nothing to do"
    exit 0
fi

log "WAN2=${WAN2_IFACE} mark=${WAN2_MARK} addr=${WAN2_ADDR:-none} pd=${PD_CIDR:-none} static_routes=${#STATIC_DSTS[@]}"

# --- Mangle rules ---
# Find the catch-all mark rule that assigns traffic to primary WAN
# Match the catch-all: a MARK rule with source ::/0 that sets a mark in the WAN mask range
# This covers both the original prob-name rule and manually restored versions
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
# Uses match-based deletion (-D with criteria) instead of line numbers to avoid
# accidentally deleting the wrong rule when line numbers shift.
cleanup_stale_mangle() {
    # Store both with and without CIDR suffix for matching against ip6tables output
    local current_sources=()
    if [ -n "${WAN2_ADDR:-}" ]; then
        current_sources+=("${WAN2_ADDR}/128")
        current_sources+=("${WAN2_ADDR}")
    fi
    [ -n "${PD_CIDR:-}" ] && current_sources+=("$PD_CIDR")

    # Collect stale sources first, then delete
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
# Uses ip6tables -S for reliable parsing of -d flags
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
    done < <(ip6tables -t mangle -S "$MANGLE_CHAIN" 2>/dev/null | grep -- "-d " | grep -v -- "-s " | grep "${WAN2_MARK}")

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
