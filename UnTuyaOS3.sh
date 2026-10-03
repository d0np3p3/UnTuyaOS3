#!/usr/bin/env bash
#
# UnTuyaOS3.sh - Top-level wrapper. Sources, in order:
#   1. install-requirements.sh  (install python/pip, create & activate the
#                                UnTuyaOS3 environment)
#   2. select-platform.sh       (choose T1 / BK7231N / RTL8720CF -> UNTUYAOS3_PLATFORM)
#   3. connect.sh               (scan for and connect to the matching open SSID)
#
# Then, if every step succeeded, it runs scripts/ap-ota.py with the selected
# firmware ($UNTUYAOS3_FIRMWARE) as the first argument, while still connected.
#
# Before exiting (success or failure), it disconnects the interface connect.sh
# joined (UNTUYAOS3_IFACE) via `iw`, but only if it is still connected to the
# SSID that was joined (UNTUYAOS3_SSID), leaving other links untouched.
#
# This is the entry point; run it directly (it performs every step itself,
# including the OTA upload, so it does not need to be sourced):
#
#     sudo ./UnTuyaOS3.sh         # run the full flow
#     sudo ./UnTuyaOS3.sh -v      # verbose: per-frame TX/RX logging in ap-ota.py
#

# Detect sourced vs executed (top level) so a failing step can return from a
# sourced caller or exit when executed.
if (return 0 2>/dev/null); then _UNTUYAOS3_SOURCED=1; else _UNTUYAOS3_SOURCED=0; fi

# Parse flags. -v / --verbose turns on per-frame TX/RX logging in ap-ota.py;
# without it, ap-ota.py shows a progress bar instead. -h / -? / --help prints
# usage and stops.
_UNTUYAOS3_VERBOSE=""
_UNTUYAOS3_HELP=0
for _arg in "$@"; do
    case "$_arg" in
        -h|-\?|--help) _UNTUYAOS3_HELP=1 ;;
        -v|--verbose) _UNTUYAOS3_VERBOSE="-v" ;;
    esac
done

if [ "$_UNTUYAOS3_HELP" -eq 1 ]; then
    cat <<'EOF'
Usage: ./UnTuyaOS3.sh [options]

Options:
  -h, -?, --help     show this help and exit
  -v, --verbose      enable verbose logging
EOF
    unset _UNTUYAOS3_VERBOSE _UNTUYAOS3_HELP _arg
    if [ "$_UNTUYAOS3_SOURCED" = 1 ]; then
        unset _UNTUYAOS3_SOURCED
        return 0
    fi
    unset _UNTUYAOS3_SOURCED
    exit 0
fi

# Clear positional parameters so the sourced steps don't inherit this flag
# (connect.sh reads $1 as an optional interface name).
set --

# Resolve the directory this script lives in, so sourcing works from any cwd.
# ${BASH_SOURCE[0]} is the path to this file even when it is being sourced.
_UNTUYAOS3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Snapshot the caller's shell options so the sourced steps (which run
# `set -eu` etc.) can't leave those flags changed in this shell afterwards.
# `set +o` prints a reusable series of `set -o/+o <name>` commands.
_UNTUYAOS3_OPTS="$(set +o)"

_UNTUYAOS3_RC=0
for _step in install-requirements.sh select-platform.sh connect.sh; do
    _script="${_UNTUYAOS3_DIR}/scripts/${_step}"
    if [ ! -f "$_script" ]; then
        printf 'UnTuyaOS3: missing script: %s\n' "$_script" >&2
        _UNTUYAOS3_RC=1
        break
    fi
    printf '\n===== UnTuyaOS3: %s =====\n' "$_step"
    # shellcheck disable=SC1090
    . "$_script"
    _UNTUYAOS3_RC=$?
    # Restore the caller's options after each step so flags don't leak forward.
    eval "$_UNTUYAOS3_OPTS"
    # A nonzero return (e.g. invalid firmware) stops the run and propagates.
    if [ "$_UNTUYAOS3_RC" -ne 0 ]; then
        break
    fi
done

# After all the bash steps succeed, run the AP OTA Python script with the
# selected firmware as its first argument. This runs while still connected to
# the AP (before the disconnect below). Skipped if any step above failed.
if [ "$_UNTUYAOS3_RC" -eq 0 ]; then
    _UNTUYAOS3_OTA="${_UNTUYAOS3_DIR}/scripts/ap-ota.py"
    if [ ! -f "$_UNTUYAOS3_OTA" ]; then
        printf 'UnTuyaOS3: missing script: %s\n' "$_UNTUYAOS3_OTA" >&2
        _UNTUYAOS3_RC=1
    else
        _UNTUYAOS3_PY="$(command -v python3 || command -v python)"
        printf '\n===== UnTuyaOS3: ap-ota.py =====\n'
        # Pass -v through as the second argument only when requested.
        if [ -n "$_UNTUYAOS3_VERBOSE" ]; then
            "$_UNTUYAOS3_PY" "$_UNTUYAOS3_OTA" "${UNTUYAOS3_FIRMWARE:-}" "$_UNTUYAOS3_VERBOSE"
        else
            "$_UNTUYAOS3_PY" "$_UNTUYAOS3_OTA" "${UNTUYAOS3_FIRMWARE:-}"
        fi
        _UNTUYAOS3_RC=$?
    fi
    unset _UNTUYAOS3_OTA _UNTUYAOS3_PY
fi

unset _UNTUYAOS3_DIR _UNTUYAOS3_OPTS _step _script _UNTUYAOS3_VERBOSE _UNTUYAOS3_HELP _arg

# Before exiting, leave the interface that connect.sh joined up but disconnected
# (radio unblocked, link up, not associated). connect.sh exports UNTUYAOS3_IFACE
# only after it successfully associates.
if [ -n "${UNTUYAOS3_IFACE:-}" ] && command -v iw >/dev/null 2>&1; then
    _UNTUYAOS3_SUDO=""
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        _UNTUYAOS3_SUDO="sudo"
    fi
    printf 'Leaving %s up but disconnected...\n' "$UNTUYAOS3_IFACE"
    command -v rfkill >/dev/null 2>&1 && $_UNTUYAOS3_SUDO rfkill unblock wifi 2>/dev/null
    $_UNTUYAOS3_SUDO ip link set "$UNTUYAOS3_IFACE" up 2>/dev/null
    $_UNTUYAOS3_SUDO iw dev "$UNTUYAOS3_IFACE" disconnect 2>/dev/null
    # Drop the IP obtained for the OTA so the interface is left clean.
    $_UNTUYAOS3_SUDO ip addr flush dev "$UNTUYAOS3_IFACE" 2>/dev/null
    unset _UNTUYAOS3_SUDO
fi

# Propagate the final status: return to a sourced caller, exit when executed.
if [ "$_UNTUYAOS3_SOURCED" = 1 ]; then
    unset _UNTUYAOS3_SOURCED
    return "$_UNTUYAOS3_RC"
fi
_UNTUYAOS3_EXIT="$_UNTUYAOS3_RC"
unset _UNTUYAOS3_SOURCED _UNTUYAOS3_RC
exit "$_UNTUYAOS3_EXIT"
