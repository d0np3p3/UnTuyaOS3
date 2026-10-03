#!/usr/bin/env bash
#
# connect.sh - Scan for open (unencrypted) Wi-Fi networks whose SSID ends in
#              "-XXXX" (where XXXX are four hex characters), then connect to the
#              first match.
#
# Requires: iw, ip, and root privileges (scanning/connecting need CAP_NET_ADMIN).
#
# Sourcing-safe: when sourced it returns instead of exiting (so it never closes
# your shell), and it restores shell options and helper functions on the way out.
#
#     ./connect.sh [iface]        # run normally
#     source ./connect.sh [iface] # source into the current shell

# Detect sourced vs executed (must run at top level, not inside a function).
if (return 0 2>/dev/null); then __UNT_SOURCED=1; else __UNT_SOURCED=0; fi

# Snapshot caller's shell options so we can restore them afterwards.
__UNT_OPTS="$(set +o)"
set -u

SCAN_INTERVAL=1                      # seconds between scans / status dots
SSID_REGEX='-[0-9A-Fa-f]{4}$'        # ends with '-' + 4 hex chars
__UNT_IFACE_ARG="${1:-}"             # optional: wireless interface as first arg

die() { printf '\nerror: %s\n' "$*" >&2; }

# Parse one scan pass; args: <iface> <ssid-regex>. Prints matching open SSIDs.
scan_once() {
    iw dev "$1" scan 2>/dev/null | awk -v re="$2" '
        function flush() {
            if (ssid != "" && !enc && ssid ~ re) { print ssid; found=1 }
        }
        /^BSS /            { flush(); ssid=""; enc=0; next }
        /capability:/      { if (index($0, "Privacy")) enc=1; next }
        /^[ \t]*RSN:/      { enc=1; next }
        /^[ \t]*WPA:/      { enc=1; next }
        /^[ \t]*SSID:/ {
            sub(/^[ \t]*SSID:[ ]?/, "")   # preserve SSIDs containing spaces
            ssid=$0
            next
        }
        END { flush(); exit (found ? 0 : 1) }
    '
}

__connect_main() {
    local iface="$__UNT_IFACE_ARG"
    local match=""

    command -v iw >/dev/null 2>&1 || { die "'iw' not found in PATH"; return 1; }
    command -v ip >/dev/null 2>&1 || { die "'ip' not found in PATH"; return 1; }

    if [ "$(id -u)" -ne 0 ]; then
        die "must be run as root (scanning and connecting require elevated privileges)"
        return 1
    fi

    if [ -z "$iface" ]; then
        iface="$(iw dev | awk '$1=="Interface"{print $2; exit}')"
    fi
    [ -n "$iface" ] || { die "no wireless interface found (try: connect.sh <iface>)"; return 1; }

    # Make sure the interface is up so it can scan.
    ip link set "$iface" up 2>/dev/null

    printf 'Scanning on %s for open SmartLife AP\n' "$iface"

    while :; do
        match="$(scan_once "$iface" "$SSID_REGEX" | head -n 1)"
        [ -n "$match" ] && break
        printf '.'
        sleep "$SCAN_INTERVAL"
    done

    printf '\nFound open network: %s\n' "$match"

    # `iw connect` works for open (unencrypted) networks. `-w` waits for the
    # association to finish (or fail) so a real error is reported, not a race.
    # Note: iw's connect takes no `--` separator.
    printf 'Connecting...\n'
    iw dev "$iface" connect -w "$match" || { die "failed to associate with '$match'"; return 1; }

    # Record the interface and SSID we joined so the caller can scope a later
    # disconnect to exactly this link (and verify it's still the one connected).
    export UNTUYAOS3_IFACE="$iface"
    export UNTUYAOS3_SSID="$match"

    if command -v dhclient >/dev/null 2>&1; then
        dhclient -1 "$iface" >/dev/null 2>&1
    elif command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd "$iface" >/dev/null 2>&1
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i "$iface" -q >/dev/null 2>&1
    fi

    printf 'Connected to %s\n' "$match"
}

__connect_main
__UNT_RC=$?

# Restore caller's shell options and clean up helpers (sourcing-safe).
eval "$__UNT_OPTS"
unset __UNT_OPTS __UNT_IFACE_ARG
unset -f die scan_once 2>/dev/null
if [ "$__UNT_SOURCED" = 1 ]; then
    unset __UNT_SOURCED
    return "$__UNT_RC"
fi
unset __UNT_SOURCED
exit "$__UNT_RC"
