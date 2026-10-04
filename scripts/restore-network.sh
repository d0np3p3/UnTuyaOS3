#!/usr/bin/env bash
#
# restore-network.sh - Hand a Wi-Fi interface back to the system network
#                      manager after UnTuyaOS3 used it, so it reconnects to its
#                      usual network and DNS is repopulated.
#
#     ./restore-network.sh <iface>
#
# Run on the host. UnTuyaOS3.sh calls it after a native run, and
# docker/run-isolated.sh after the container returns the interface. Inside a
# container the host's network manager is out of reach, so it only resets the
# interface and prints this command for the host instead.

IFACE="${1:?usage: restore-network.sh <iface>}"

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

command -v rfkill >/dev/null 2>&1 && $SUDO rfkill unblock wifi 2>/dev/null

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dhcpcd 2>/dev/null; then
    # dhcpcd (with its wpa_supplicant hook) manages the interface: restarting
    # it drops the device AP, reconnects the normal network, and rewrites
    # /etc/resolv.conf with the real DNS servers.
    printf 'Restoring networking on %s (restarting dhcpcd)...\n' "$IFACE"
    $SUDO iw dev "$IFACE" disconnect 2>/dev/null
    $SUDO systemctl restart dhcpcd >/dev/null 2>&1
    sleep 3
elif command -v NetworkManager >/dev/null 2>&1 && command -v nmcli >/dev/null 2>&1; then
    # NetworkManager: hand the device back to it to reconnect automatically.
    printf 'Restoring networking on %s (NetworkManager)...\n' "$IFACE"
    $SUDO nmcli dev set "$IFACE" managed yes >/dev/null 2>&1
    $SUDO nmcli dev connect "$IFACE" >/dev/null 2>&1
    sleep 3
else
    # No known manager: leave the interface up but disconnected.
    printf 'Leaving %s up but disconnected...\n' "$IFACE"
    $SUDO ip link set "$IFACE" up 2>/dev/null
    $SUDO iw dev "$IFACE" disconnect 2>/dev/null
    $SUDO ip addr flush dev "$IFACE" 2>/dev/null

    # docker/run-isolated.sh restores the interface on the host itself; with
    # host networking nobody does, so tell the user how.
    if [ -f /.dockerenv ] && [ "${UNTUYAOS3_HOST_RESTORES:-0}" != 1 ]; then
        printf 'If %s does not reconnect to its usual network by itself, run on the host:\n' "$IFACE"
        printf '    sudo scripts/restore-network.sh %s\n' "$IFACE"
    fi
fi
