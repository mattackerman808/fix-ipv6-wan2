#!/bin/bash
# fix-ipv6-wan2.sh
#
# Ensures IPv6 traffic sourced from WAN2 (Xfinity) addresses routes out
# the correct interface instead of being hijacked by UDM WAN failover.
#
# Problem: The UBIOS_WF_GROUP_1_SINGLE mangle chain marks all new IPv6
# connections for the primary WAN (ATT/eth9). This overrides source-based
# routing, causing Xfinity-sourced IPv6 to go out ATT where it's dropped.
#
# Solution: Insert mangle rules to mark Xfinity-sourced traffic with the
# WAN2 fwmark, and add ip6 routing rules for delegated prefixes.
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
WAN2_ADDR=$(ip -6 addr show dev "$WAN2_IFACE" scope global -dynamic | grep -oP '(?<=inet6 )\S+(?=/128)' | head -1)

# --- Discover PD prefix on guest bridge ---
PD_CIDR=$(ip -6 addr show dev "$GUEST_BRIDGE" scope global -dynamic | grep -oP '\S+::/\d+' | head -1)

if [ -z "$WAN2_ADDR" ] && [ -z "$PD_CIDR" ]; then
    log "WARN: No IPv6 addresses found on ${WAN2_IFACE} or ${GUEST_BRIDGE}, nothing to do"
    exit 0
fi

log "WAN2=${WAN2_IFACE} mark=${WAN2_MARK} addr=${WAN2_ADDR:-none} pd=${PD_CIDR:-none}"

# --- Mangle rules ---
# Find the catch-all mark rule that assigns traffic to primary WAN
CATCHALL_LINE=$(ip6tables -t mangle -L "$MANGLE_CHAIN" -n --line-numbers 2>/dev/null | grep "prob-name.*wf-group.*single" | awk '{print $1}')
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
    CATCHALL_LINE=$(ip6tables -t mangle -L "$MANGLE_CHAIN" -n --line-numbers | grep "prob-name.*wf-group.*single" | awk '{print $1}')
    ip6tables -t mangle -I "$MANGLE_CHAIN" "$CATCHALL_LINE" -s "$src" -m mark --mark "0x0/${MARK_MASK}" -j MARK --set-xmark "${WAN2_MARK}/${MARK_MASK}"
    log "  mangle ${desc}: added"
}

# Clean up stale mangle rules (old WAN2 addresses no longer on the interface)
cleanup_stale_mangle() {
    local current_sources=()
    [ -n "$WAN2_ADDR" ] && current_sources+=("${WAN2_ADDR}/128")
    [ -n "$PD_CIDR" ] && current_sources+=("$PD_CIDR")

    ip6tables -t mangle -L "$MANGLE_CHAIN" -n --line-numbers | grep "MARK.*${WAN2_MARK}" | grep -v "prob-name" | while read -r line; do
        local src=$(echo "$line" | awk '{print $4}')
        [ "$src" = "::/0" ] && continue
        local found=false
        for cs in "${current_sources[@]}"; do
            [ "$src" = "$cs" ] && found=true
        done
        if [ "$found" = false ]; then
            local linenum=$(echo "$line" | awk '{print $1}')
            log "  mangle cleanup: removing stale rule for ${src}"
            ip6tables -t mangle -D "$MANGLE_CHAIN" "$linenum" 2>/dev/null || true
        fi
    done
}

cleanup_stale_mangle

if [ -n "$PD_CIDR" ]; then
    add_mangle_rule "$PD_CIDR" "pd-prefix"
fi
if [ -n "$WAN2_ADDR" ]; then
    add_mangle_rule "${WAN2_ADDR}/128" "wan2-addr"
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
