#!/usr/bin/env bash
#
# container-entry.sh - Runs INSIDE the untuyaos3 container. Waits for the host
#                      to hand the Wi-Fi interface into the container's network
#                      namespace, connects to the device AP (DHCP happens here,
#                      so the host's DNS is never touched), then runs ap-ota.py.
#
# Usage: container-entry.sh <iface> <firmware> [-v]

iface="${1:?interface required}"
firmware="${2:?firmware required}"
verbose="${3:-}"

here="$(cd "$(dirname "$0")" && pwd)"

# The host moves the wireless phy into this namespace after the container starts.
for _ in $(seq 1 100); do
    ip link show "$iface" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! ip link show "$iface" >/dev/null 2>&1; then
    printf 'error: interface %s never appeared in the container\n' "$iface" >&2
    exit 1
fi

UNTUYAOS3_VERBOSE="$verbose" bash "$here/connect.sh" "$iface" || exit 1

printf '\n===== UnTuyaOS3: ap-ota.py =====\n'
exec python3 "$here/ap-ota.py" "$firmware" ${verbose:+"$verbose"}
