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
#     sudo ./UnTuyaOS3.sh -i wlan1 -p BK7231N -f OpenBK7231N_UG_1.18.315.bin
#                                 # non-interactive, on a specific interface
#
# Set UNTUYAOS3_SKIP_INSTALL=1 to skip install-requirements.sh when the
# dependencies are already provided (e.g. inside the Docker image).
#

# Detect sourced vs executed (top level) so a failing step can return from a
# sourced caller or exit when executed.
if (return 0 2>/dev/null); then _UNTUYAOS3_SOURCED=1; else _UNTUYAOS3_SOURCED=0; fi

# Parse flags. -v / --verbose turns on per-frame TX/RX logging in ap-ota.py;
# without it, ap-ota.py shows a progress bar instead. -h / -? / --help prints
# usage and stops. -i / -p / -f preselect the Wi-Fi interface, platform and
# firmware; each step still prompts (or auto-detects) for anything not given.
_UNTUYAOS3_VERBOSE=""
_UNTUYAOS3_HELP=0
_UNTUYAOS3_BADARG=""
_UNTUYAOS3_IFACE_ARG=""
_UNTUYAOS3_PLATFORM_ARG=""
_UNTUYAOS3_FIRMWARE_ARG=""
while [ "$#" -gt 0 ]; do
    _arg="$1"
    shift
    case "$_arg" in
        -h|-\?|--help) _UNTUYAOS3_HELP=1 ;;
        -v|--verbose) _UNTUYAOS3_VERBOSE="-v" ;;
        -i|--interface|-p|--platform|-f|--firmware)
            if [ "$#" -eq 0 ] || [ -z "$1" ]; then
                _UNTUYAOS3_BADARG="option '$_arg' requires a value"
                break
            fi
            case "$_arg" in
                -i|--interface) _UNTUYAOS3_IFACE_ARG="$1" ;;
                -p|--platform)  _UNTUYAOS3_PLATFORM_ARG="$1" ;;
                -f|--firmware)  _UNTUYAOS3_FIRMWARE_ARG="$1" ;;
            esac
            shift
            ;;
        --interface=*) _UNTUYAOS3_IFACE_ARG="${_arg#*=}" ;;
        --platform=*)  _UNTUYAOS3_PLATFORM_ARG="${_arg#*=}" ;;
        --firmware=*)  _UNTUYAOS3_FIRMWARE_ARG="${_arg#*=}" ;;
        *) _UNTUYAOS3_BADARG="unknown option '$_arg'"; break ;;
    esac
done

# An invalid flag prints an error and stops with status 2 (usage error).
if [ -n "$_UNTUYAOS3_BADARG" ]; then
    printf 'UnTuyaOS3: %s (see --help)\n' "$_UNTUYAOS3_BADARG" >&2
    _UNTUYAOS3_HELP=2
fi

if [ "$_UNTUYAOS3_HELP" -ne 0 ]; then
    if [ "$_UNTUYAOS3_HELP" -eq 1 ]; then
        cat <<'EOF'
Usage: ./UnTuyaOS3.sh [options]

Options:
  -h, -?, --help             show this help and exit
  -v, --verbose              enable verbose logging
  -i, --interface IFACE      Wi-Fi interface to use (default: first found)
  -p, --platform PLATFORM    T1, BK7231N or RTL8720CF (skips the prompt)
  -f, --firmware FILE        firmware path, or a file name inside
                             custom-firmware/<platform>/ (skips the prompt)

Environment:
  UNTUYAOS3_SKIP_INSTALL=1   skip installing requirements (already provided)
EOF
        _UNTUYAOS3_EXIT=0
    else
        _UNTUYAOS3_EXIT=2
    fi
    unset _UNTUYAOS3_VERBOSE _UNTUYAOS3_HELP _UNTUYAOS3_BADARG _arg \
          _UNTUYAOS3_IFACE_ARG _UNTUYAOS3_PLATFORM_ARG _UNTUYAOS3_FIRMWARE_ARG
    if [ "$_UNTUYAOS3_SOURCED" = 1 ]; then
        unset _UNTUYAOS3_SOURCED
        return "$_UNTUYAOS3_EXIT"
    fi
    unset _UNTUYAOS3_SOURCED
    exit "$_UNTUYAOS3_EXIT"
fi
unset _UNTUYAOS3_BADARG

# Clear positional parameters; each sourced step below is handed exactly the
# arguments meant for it (select-platform.sh: [platform] [firmware],
# connect.sh: [iface]).
set --

# Resolve the directory this script lives in, so sourcing works from any cwd.
# ${BASH_SOURCE[0]} is the path to this file even when it is being sourced.
_UNTUYAOS3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Snapshot the caller's shell options so the sourced steps (which run
# `set -eu` etc.) can't leave those flags changed in this shell afterwards.
# `set +o` prints a reusable series of `set -o/+o <name>` commands.
_UNTUYAOS3_OPTS="$(set +o)"

# Snapshot /etc/resolv.conf (when it's a plain file) BEFORE we touch networking,
# so DNS can be restored at the end if the normal network manager doesn't
# repopulate it. Skipped when it's a symlink (e.g. the systemd-resolved stub).
_UNTUYAOS3_RESOLV_SNAP=""
if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
    _UNTUYAOS3_RESOLV_SNAP="$(mktemp 2>/dev/null)"
    [ -n "$_UNTUYAOS3_RESOLV_SNAP" ] && cat /etc/resolv.conf > "$_UNTUYAOS3_RESOLV_SNAP" 2>/dev/null
fi

# Skip installing requirements when they are already provided (Docker image).
_UNTUYAOS3_STEPS="install-requirements.sh select-platform.sh connect.sh"
if [ "${UNTUYAOS3_SKIP_INSTALL:-0}" = 1 ]; then
    _UNTUYAOS3_STEPS="select-platform.sh connect.sh"
fi

_UNTUYAOS3_RC=0
for _step in $_UNTUYAOS3_STEPS; do
    _script="${_UNTUYAOS3_DIR}/scripts/${_step}"
    if [ ! -f "$_script" ]; then
        printf 'UnTuyaOS3: missing script: %s\n' "$_script" >&2
        _UNTUYAOS3_RC=1
        break
    fi
    printf '\n===== UnTuyaOS3: %s =====\n' "$_step"
    case "$_step" in
        select-platform.sh) set -- "$_UNTUYAOS3_PLATFORM_ARG" "$_UNTUYAOS3_FIRMWARE_ARG" ;;
        connect.sh)         set -- "$_UNTUYAOS3_IFACE_ARG" ;;
        *)                  set -- ;;
    esac
    # shellcheck disable=SC1090
    . "$_script"
    _UNTUYAOS3_RC=$?
    set --
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

unset _UNTUYAOS3_DIR _UNTUYAOS3_OPTS _step _script _UNTUYAOS3_VERBOSE _UNTUYAOS3_HELP _arg \
      _UNTUYAOS3_STEPS _UNTUYAOS3_IFACE_ARG _UNTUYAOS3_PLATFORM_ARG _UNTUYAOS3_FIRMWARE_ARG

# Before exiting, restore normal networking on the interface connect.sh used.
# We took it off its usual network to join the device AP; if we just left it
# disconnected, the interface's DNS source is gone and /etc/resolv.conf ends up
# empty. Handing it back to the system network manager reconnects it to its
# configured network and repopulates DNS. connect.sh exports UNTUYAOS3_IFACE
# only after it successfully associates.
if [ -n "${UNTUYAOS3_IFACE:-}" ]; then
    _UNTUYAOS3_SUDO=""
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        _UNTUYAOS3_SUDO="sudo"
    fi
    command -v rfkill >/dev/null 2>&1 && $_UNTUYAOS3_SUDO rfkill unblock wifi 2>/dev/null

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dhcpcd 2>/dev/null; then
        # dhcpcd (with its wpa_supplicant hook) manages the interface: restarting
        # it drops the device AP, reconnects the normal network, and rewrites
        # /etc/resolv.conf with the real DNS servers.
        printf 'Restoring networking on %s (restarting dhcpcd)...\n' "$UNTUYAOS3_IFACE"
        $_UNTUYAOS3_SUDO iw dev "$UNTUYAOS3_IFACE" disconnect 2>/dev/null
        $_UNTUYAOS3_SUDO systemctl restart dhcpcd >/dev/null 2>&1
        sleep 3
    elif command -v NetworkManager >/dev/null 2>&1 && command -v nmcli >/dev/null 2>&1; then
        # NetworkManager: hand the device back to it to reconnect automatically.
        printf 'Restoring networking on %s (NetworkManager)...\n' "$UNTUYAOS3_IFACE"
        $_UNTUYAOS3_SUDO nmcli dev set "$UNTUYAOS3_IFACE" managed yes >/dev/null 2>&1
        $_UNTUYAOS3_SUDO nmcli dev connect "$UNTUYAOS3_IFACE" >/dev/null 2>&1
        sleep 3
    else
        # No known manager: leave the interface up but disconnected.
        printf 'Leaving %s up but disconnected...\n' "$UNTUYAOS3_IFACE"
        $_UNTUYAOS3_SUDO ip link set "$UNTUYAOS3_IFACE" up 2>/dev/null
        $_UNTUYAOS3_SUDO iw dev "$UNTUYAOS3_IFACE" disconnect 2>/dev/null
        $_UNTUYAOS3_SUDO ip addr flush dev "$UNTUYAOS3_IFACE" 2>/dev/null
    fi

    # Restore the exact pre-run /etc/resolv.conf as the final action. The file
    # is shared by ALL interfaces, so a DHCP client wiping it while we used Wi-Fi
    # also kills DNS on ethernet. Putting back the snapshot (captured when DNS
    # worked) restores every interface's servers regardless of what was written.
    if [ -n "$_UNTUYAOS3_RESOLV_SNAP" ]; then
        $_UNTUYAOS3_SUDO cp "$_UNTUYAOS3_RESOLV_SNAP" /etc/resolv.conf 2>/dev/null
    fi
    unset _UNTUYAOS3_SUDO
fi

# Remove the resolv.conf snapshot file.
[ -n "$_UNTUYAOS3_RESOLV_SNAP" ] && rm -f "$_UNTUYAOS3_RESOLV_SNAP" 2>/dev/null
unset _UNTUYAOS3_RESOLV_SNAP

# Propagate the final status: return to a sourced caller, exit when executed.
if [ "$_UNTUYAOS3_SOURCED" = 1 ]; then
    unset _UNTUYAOS3_SOURCED
    return "$_UNTUYAOS3_RC"
fi
_UNTUYAOS3_EXIT="$_UNTUYAOS3_RC"
unset _UNTUYAOS3_SOURCED _UNTUYAOS3_RC
exit "$_UNTUYAOS3_EXIT"
