#!/usr/bin/env bash
#
# run-isolated.sh - Run UnTuyaOS3 in Docker with a Wi-Fi adapter handed over
#                   exclusively to the container ("isolated" mode).
#
# Wi-Fi adapters have no /dev node, so `--device` can't pass one through.
# Instead the adapter's phy is moved into the container's network namespace:
# it disappears from the host (so no host network manager can interfere) and
# the kernel hands it back automatically when the container exits.
#
# Run it as root ON the Docker host (the container PID must be local):
#
#     sudo docker/run-isolated.sh <iface> [UnTuyaOS3 options...]
#     sudo docker/run-isolated.sh wlan1 -p BK7231N
#
# UNTUYAOS3_IMAGE selects the image (default: untuyaos3, as built by
# `docker compose build`). UNTUYAOS3_FIRMWARE_DIR mounts a custom-firmware
# folder over the firmware bundled in the image.

set -u

IMAGE="${UNTUYAOS3_IMAGE:-untuyaos3}"
NAME="untuyaos3-isolated-$$"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    printf 'Usage: %s <iface> [UnTuyaOS3 options...]\n' "$0" >&2
    exit 2
fi
IFACE="$1"
shift

[ "$(id -u)" -eq 0 ] || die "must be run as root (moving a Wi-Fi phy needs root on the host)"
command -v iw >/dev/null 2>&1 || die "'iw' not found in PATH"
command -v docker >/dev/null 2>&1 || die "'docker' not found in PATH"
case "${DOCKER_HOST:-}" in
    ""|unix://*) ;;
    *) die "DOCKER_HOST points at a remote engine; run this script on the Docker host itself" ;;
esac

[ -r "/sys/class/net/${IFACE}/phy80211/name" ] || die "'${IFACE}' is not a wireless interface"
PHY="$(cat "/sys/class/net/${IFACE}/phy80211/name")"
iw phy "$PHY" info | grep -q 'set_wiphy_netns' \
    || die "the driver for ${IFACE} (${PHY}) can't be moved into a container; use host mode (compose.yaml) instead"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image '${IMAGE}' not found; build it first with: docker compose build"

printf 'Moving %s (%s) into the container; it returns to the host when the container exits.\n' \
    "$IFACE" "$PHY"

# Move the phy in the background once the container is running, while the
# foreground `docker run` stays attached to the terminal for the prompts.
(
    for _ in $(seq 1 60); do
        pid="$(docker inspect -f '{{.State.Pid}}' "$NAME" 2>/dev/null)"
        if [ -n "$pid" ] && [ "$pid" != 0 ]; then
            iw phy "$PHY" set netns "$pid" && exit 0
            printf 'error: failed to move %s into the container\n' "$PHY" >&2
            docker kill "$NAME" >/dev/null 2>&1
            exit 1
        fi
        sleep 0.5
    done
    printf 'error: container %s did not start\n' "$NAME" >&2
    exit 1
) &
MOVER=$!

TTY_FLAGS="-i"
[ -t 0 ] && [ -t 1 ] && TTY_FLAGS="-it"

DEVICE_FLAGS=""
[ -e /dev/rfkill ] && DEVICE_FLAGS="--device /dev/rfkill"

VOLUME_FLAGS=()
if [ -n "${UNTUYAOS3_FIRMWARE_DIR:-}" ]; then
    [ -d "$UNTUYAOS3_FIRMWARE_DIR" ] || die "UNTUYAOS3_FIRMWARE_DIR is not a directory: ${UNTUYAOS3_FIRMWARE_DIR}"
    VOLUME_FLAGS=(-v "$(cd "$UNTUYAOS3_FIRMWARE_DIR" && pwd):/app/custom-firmware:ro")
fi

# shellcheck disable=SC2086  # intentional word-splitting of the flag lists
docker run --rm $TTY_FLAGS --name "$NAME" \
    --network none \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    $DEVICE_FLAGS \
    "${VOLUME_FLAGS[@]}" \
    -e UNTUYAOS3_IFACE_WAIT=30 \
    "$IMAGE" "$@"
RC=$?

wait "$MOVER" 2>/dev/null
exit "$RC"
