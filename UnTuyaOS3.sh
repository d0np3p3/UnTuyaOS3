#!/usr/bin/env bash
#
# UnTuyaOS3.sh - Top-level wrapper. Sources, in order:
#   1. install-requirements.sh  (ensure iw, docker and docker-cli are installed
#                                and build the untuyaos3 container image)
#   2. select-platform.sh       (choose T1 / BK7231N / RTL8720CF -> UNTUYAOS3_PLATFORM)
#
# Then it starts the container and hands the Wi-Fi interface (its whole phy) into
# the container's network namespace. Inside, container-entry.sh connects to the
# device AP (connect.sh, DHCP included) and runs ap-ota.py with the selected
# firmware. When the container exits the interface returns to the host, and the
# host's network manager is told to reconnect it.
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

# Clear positional parameters so the sourced steps don't inherit our flags.
set --

# Resolve the directory this script lives in, so sourcing works from any cwd.
# ${BASH_SOURCE[0]} is the path to this file even when it is being sourced.
_UNTUYAOS3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Snapshot the caller's shell options so the sourced steps (which run
# `set -eu` etc.) can't leave those flags changed in this shell afterwards.
# `set +o` prints a reusable series of `set -o/+o <name>` commands.
_UNTUYAOS3_OPTS="$(set +o)"

_UNTUYAOS3_RC=0
for _step in install-requirements.sh select-platform.sh; do
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

# Pick the wireless interface (and its phy) to hand to the container.
_UNTUYAOS3_IFACE=""
_UNTUYAOS3_PHY=""
if [ "$_UNTUYAOS3_RC" -eq 0 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        printf 'UnTuyaOS3: must be run as root (moving the Wi-Fi interface requires it)\n' >&2
        _UNTUYAOS3_RC=1
    elif ! command -v iw >/dev/null 2>&1; then
        printf 'UnTuyaOS3: iw not found in PATH\n' >&2
        _UNTUYAOS3_RC=1
    else
        _UNTUYAOS3_IFACE="$(iw dev | awk '$1=="Interface"{print $2; exit}')"
        _UNTUYAOS3_PHY="$(iw dev "$_UNTUYAOS3_IFACE" info 2>/dev/null | awk '$1=="wiphy"{print "phy" $2; exit}')"
        if [ -z "$_UNTUYAOS3_IFACE" ] || [ -z "$_UNTUYAOS3_PHY" ]; then
            printf 'UnTuyaOS3: no wireless interface found\n' >&2
            printf '  If a previous run was interrupted the adapter may still be inside a container:\n' >&2
            printf '  run `docker rm -f $(docker ps -aq --filter name=untuyaos3-)`; if it stays missing, reboot.\n' >&2
            _UNTUYAOS3_IFACE=""
            _UNTUYAOS3_RC=1
        fi
    fi
fi

if [ "$_UNTUYAOS3_RC" -eq 0 ]; then
    _UNTUYAOS3_NAME="untuyaos3-$$"
    # The firmware lives under the project root, which is mounted at /untuyaos3.
    _UNTUYAOS3_FW="/untuyaos3/${UNTUYAOS3_FIRMWARE#"${_UNTUYAOS3_DIR}/"}"

    command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null

    printf '\n===== UnTuyaOS3: container (%s) =====\n' "$_UNTUYAOS3_IFACE"
    # --network none gives the container its own empty network namespace; the
    # Wi-Fi phy is moved into it below, so the host's routes and DNS are never
    # touched by the Tuya AP's DHCP lease. The container idles while we do that,
    # then the work runs via `docker exec`.
    if docker run -dt --name "$_UNTUYAOS3_NAME" --network none \
            --cap-add NET_ADMIN --cap-add NET_RAW \
            -v "${_UNTUYAOS3_DIR}:/untuyaos3:ro" "${UNTUYAOS3_IMAGE:-untuyaos3}" \
            sleep infinity >/dev/null; then
        _UNTUYAOS3_PID="$(docker inspect -f '{{.State.Pid}}' "$_UNTUYAOS3_NAME")"

        # Explicitly move the phy back to the host's namespace (pid 1) before the
        # container goes away, rather than relying on namespace teardown.
        _untuyaos3_release() {
            nsenter -t "$_UNTUYAOS3_PID" -n iw phy "$_UNTUYAOS3_PHY" set netns 1 2>/dev/null
            docker rm -f "$_UNTUYAOS3_NAME" >/dev/null 2>&1
        }
        trap '_untuyaos3_release' INT TERM

        if iw phy "$_UNTUYAOS3_PHY" set netns "$_UNTUYAOS3_PID"; then
            docker exec -t "$_UNTUYAOS3_NAME" bash /untuyaos3/scripts/container-entry.sh \
                "$_UNTUYAOS3_IFACE" "$_UNTUYAOS3_FW" ${_UNTUYAOS3_VERBOSE:+"$_UNTUYAOS3_VERBOSE"}
            _UNTUYAOS3_RC=$?
        else
            printf 'UnTuyaOS3: failed to move %s into the container\n' "$_UNTUYAOS3_PHY" >&2
            _UNTUYAOS3_RC=1
        fi
        trap - INT TERM
        _untuyaos3_release
        unset -f _untuyaos3_release
    else
        _UNTUYAOS3_RC=1
    fi

    # Wait for the interface to reappear before restoring networking on it.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        iw dev 2>/dev/null | grep -q "Interface $_UNTUYAOS3_IFACE" && break
        sleep 1
    done
fi

# Hand the interface back to the system network manager so it reconnects to its
# usual network.
if [ -n "$_UNTUYAOS3_IFACE" ]; then
    command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dhcpcd 2>/dev/null; then
        printf 'Restoring networking on %s (restarting dhcpcd)...\n' "$_UNTUYAOS3_IFACE"
        systemctl restart dhcpcd >/dev/null 2>&1
        sleep 3
    elif command -v NetworkManager >/dev/null 2>&1 && command -v nmcli >/dev/null 2>&1; then
        printf 'Restoring networking on %s (NetworkManager)...\n' "$_UNTUYAOS3_IFACE"
        nmcli dev set "$_UNTUYAOS3_IFACE" managed yes >/dev/null 2>&1
        nmcli dev connect "$_UNTUYAOS3_IFACE" >/dev/null 2>&1
        sleep 3
    else
        printf 'Leaving %s up but disconnected...\n' "$_UNTUYAOS3_IFACE"
        ip link set "$_UNTUYAOS3_IFACE" up 2>/dev/null
    fi
fi

unset _UNTUYAOS3_DIR _UNTUYAOS3_OPTS _UNTUYAOS3_VERBOSE _UNTUYAOS3_HELP \
      _UNTUYAOS3_IFACE _UNTUYAOS3_PHY _UNTUYAOS3_NAME _UNTUYAOS3_FW _UNTUYAOS3_PID _step _script _arg _

# Propagate the final status: return to a sourced caller, exit when executed.
if [ "$_UNTUYAOS3_SOURCED" = 1 ]; then
    unset _UNTUYAOS3_SOURCED
    return "$_UNTUYAOS3_RC"
fi
_UNTUYAOS3_EXIT="$_UNTUYAOS3_RC"
unset _UNTUYAOS3_SOURCED _UNTUYAOS3_RC
exit "$_UNTUYAOS3_EXIT"
