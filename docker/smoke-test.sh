#!/usr/bin/env bash
#
# smoke-test.sh - Basic checks on a built UnTuyaOS3 image that need no Wi-Fi:
# the CLI starts, the compiled Python dependencies import, and the bundled
# firmware passes selection for every platform. Used by the Docker image
# workflow; also handy locally.
#
#     docker/smoke-test.sh [image]      # default image: untuyaos3

set -eu

IMAGE="${1:-untuyaos3}"

step() { printf '\n==> %s\n' "$*"; }

step "--help"
docker run --rm "$IMAGE" --help

step "unknown option is rejected"
rc=0
docker run --rm "$IMAGE" --bogus || rc=$?
[ "$rc" -eq 2 ] || { echo "expected exit status 2, got ${rc}" >&2; exit 1; }

step "Python dependencies import"
docker run --rm --entrypoint python3 "$IMAGE" \
    -c 'import sslpsk3, Crypto.Cipher.AES, datastruct; print("ok")'

step "bundled firmware passes selection"
docker run --rm --entrypoint bash "$IMAGE" -c '
    set -u
    for dir in custom-firmware/*/; do
        platform="$(basename "$dir")"
        for fw in "$dir"*; do
            [ -f "$fw" ] || continue
            ( . scripts/select-platform.sh "$platform" "$(basename "$fw")" >/dev/null ) \
                || { echo "failed: $fw" >&2; exit 1; }
            echo "ok: $fw"
        done
    done
'

step "all smoke tests passed"
