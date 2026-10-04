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
# Ends with '-' + 4 hex chars. Written out as explicit character classes rather
# than '-[0-9A-Fa-f]{4}$' because some awk builds don't honour {n} intervals.
SSID_REGEX='-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$'
__UNT_IFACE_ARG="${1:-}"             # optional: wireless interface as first arg

die() { printf '\nerror: %s\n' "$*" >&2; }

# Clear per-link DNS that a DHCP client may have registered for an interface,
# across the common resolvers (systemd-resolved and classic resolvconf).
clear_link_dns() {
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl revert "$1" >/dev/null 2>&1
        resolvectl flush-caches >/dev/null 2>&1
    fi
    if command -v resolvconf >/dev/null 2>&1; then
        resolvconf -d "$1.dhclient" >/dev/null 2>&1
        resolvconf -d "$1.udhcpc" >/dev/null 2>&1
        resolvconf -d "$1" >/dev/null 2>&1
    fi
}

# Parse scan output on stdin; arg: <ssid-regex>. Prints matching open SSIDs.
parse_scan() {
    awk -v re="$1" '
        function flush() {
            if (ssid != "" && !enc && ssid ~ re) { print ssid }
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
        END { flush() }
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
    # A mistyped interface would otherwise make the scan loop below retry forever.
    iw dev "$iface" info >/dev/null 2>&1 || { die "'$iface' is not a wireless interface"; return 1; }

    # Unblock the radio (rfkill soft-block) and bring the interface up. Both an
    # rfkill block and a DOWN link make scans fail with "Network is down (-100)".
    bring_up() {
        command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null
        ip link set "$1" up 2>/dev/null
    }
    bring_up "$iface"
    sleep 1

    printf 'Scanning on %s for an open SmartLife AP\n' "$iface"

    local raw rc scan_err_shown=0
    while :; do
        # Capture stdout+stderr and the exit code so a failing scan is visible
        # instead of silently looping (e.g. "Device or resource busy (-16)" when
        # another service manages the interface, or "Network is down (-100)").
        raw="$(iw dev "$iface" scan 2>&1)"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$scan_err_shown" -eq 0 ]; then
                printf '\niw scan on %s failed (exit %d): %s\n' "$iface" "$rc" \
                    "$(printf '%s' "$raw" | tr '\n' ' ' | sed 's/  */ /g')" >&2
                printf 'Bringing %s up and retrying' "$iface" >&2
                scan_err_shown=1
            else
                printf '.' >&2
            fi
            # The interface may be down or rfkill-blocked; try to recover before
            # the next scan attempt.
            bring_up "$iface"
            sleep "$SCAN_INTERVAL"
            continue
        fi
        match="$(printf '%s\n' "$raw" | parse_scan "$SSID_REGEX" | head -n 1)"
        [ -n "$match" ] && break
        printf '.'
        sleep "$SCAN_INTERVAL"
    done

    printf '\nFound open network: %s\n' "$match"

    # Ensure the interface is up but not currently associated before joining.
    bring_up "$iface"
    iw dev "$iface" disconnect 2>/dev/null

    # `iw connect` works for open (unencrypted) networks. `-w` waits for the
    # association to finish (or fail) so a real error is reported, not a race.
    # Note: iw's connect takes no `--` separator.
    printf 'Connecting...\n'
    iw dev "$iface" connect -w "$match" || { die "failed to associate with '$match'"; return 1; }

    # Record the interface and SSID we joined so the caller can scope a later
    # disconnect to exactly this link (and verify it's still the one connected).
    export UNTUYAOS3_IFACE="$iface"
    export UNTUYAOS3_SSID="$match"

    # Obtain an IP via DHCP, but preserve /etc/resolv.conf. The Tuya AP's lease
    # advertises a bogus DNS server that the DHCP client would write into the
    # global /etc/resolv.conf, breaking name resolution on every interface. So
    # snapshot resolv.conf, run a one-shot DHCP client (no lingering daemon to
    # re-clobber it), then restore it exactly - including if it was a symlink
    # (e.g. the systemd-resolved stub).
    local __UNT_RESOLV_WAS=""
    if [ -L /etc/resolv.conf ]; then
        __UNT_RESOLV_WAS="link:$(readlink /etc/resolv.conf)"
    elif [ -f /etc/resolv.conf ]; then
        __UNT_RESOLV_WAS="file:$(mktemp)"
        cat /etc/resolv.conf > "${__UNT_RESOLV_WAS#file:}" 2>/dev/null
    fi

    if command -v dhclient >/dev/null 2>&1; then
        dhclient -1 "$iface" >/dev/null 2>&1
        # Stop the dhclient daemon but keep the address (-x does not release),
        # so it can't renew and rewrite resolv.conf after we restore it.
        dhclient -x "$iface" >/dev/null 2>&1
    elif command -v dhcpcd >/dev/null 2>&1; then
        # -1 one-shot, -p keep the address after exit, --nohook resolv.conf so
        # dhcpcd never touches DNS at all.
        dhcpcd -1 -p --nohook resolv.conf "$iface" >/dev/null 2>&1
    elif command -v udhcpc >/dev/null 2>&1; then
        # -q quits once a lease is obtained (no lingering daemon).
        udhcpc -i "$iface" -q -n >/dev/null 2>&1
    fi

    # Restore resolv.conf to its exact pre-DHCP state (covers the plain-file
    # case where the DHCP client overwrote /etc/resolv.conf directly).
    case "$__UNT_RESOLV_WAS" in
        link:*) ln -sf "${__UNT_RESOLV_WAS#link:}" /etc/resolv.conf 2>/dev/null ;;
        file:*) cat "${__UNT_RESOLV_WAS#file:}" > /etc/resolv.conf 2>/dev/null
                rm -f "${__UNT_RESOLV_WAS#file:}" ;;
    esac

    # On systemd-resolved / resolvconf systems the DHCP client registers the
    # AP's DNS *per-link* through a channel the file restore above doesn't undo.
    # Clear this interface's DNS so the bogus server isn't used system-wide.
    clear_link_dns "$iface"

    printf 'Connected to %s\n' "$match"
}

__connect_main
__UNT_RC=$?

# Restore caller's shell options and clean up helpers (sourcing-safe).
eval "$__UNT_OPTS"
unset __UNT_OPTS __UNT_IFACE_ARG
unset -f die parse_scan bring_up clear_link_dns 2>/dev/null
if [ "$__UNT_SOURCED" = 1 ]; then
    unset __UNT_SOURCED
    return "$__UNT_RC"
fi
unset __UNT_SOURCED
exit "$__UNT_RC"
