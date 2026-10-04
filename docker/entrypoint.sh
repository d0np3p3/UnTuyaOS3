#!/usr/bin/env bash
#
# entrypoint.sh - Container entry point. Hands over to UnTuyaOS3.sh with all
# arguments, optionally waiting first for a Wi-Fi interface to show up (in
# isolated mode the host moves one into the container after it starts).
#
# UNTUYAOS3_IFACE_WAIT sets how many seconds to wait (default 0: don't wait;
# docker/run-isolated.sh sets it).

set -u

first_wifi_iface() {
    iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}'
}

_wait="${UNTUYAOS3_IFACE_WAIT:-0}"
if [ "$_wait" -gt 0 ] && [ -z "$(first_wifi_iface)" ]; then
    printf 'Waiting up to %ss for a Wi-Fi interface to be attached' "$_wait"
    _i=0
    while [ -z "$(first_wifi_iface)" ] && [ "$_i" -lt "$_wait" ]; do
        printf '.'
        sleep 1
        _i=$((_i + 1))
    done
    printf '\n'
fi

exec /app/UnTuyaOS3.sh "$@"
