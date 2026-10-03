#!/usr/bin/env bash
#
# select-platform.sh - Prompt for the target platform and set UNTUYAOS3_PLATFORM,
#                       then list the firmware files under
#                       custom-firmware/<platform>/ and let the user pick one,
#                       saving its path in UNTUYAOS3_FIRMWARE.
#
# To set the variables in your CURRENT shell, source the script:
#
#     source ./select-platform.sh      # or:  . ./select-platform.sh
#
# Running it normally (./select-platform.sh) sets the variables only inside the
# script's own process, so they won't survive after the script exits.
#
# Sourcing-safe: restores shell options on the way out and never exits your
# shell (handles end-of-input instead of looping forever).

# Snapshot caller's shell options so we can restore them afterwards.
__UNT_OPTS="$(set +o)"
set -u

# Resolve the project root (the parent of this script's scripts/ directory) so
# custom-firmware/ is found from any cwd.
__UNT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# --- Choose the platform -----------------------------------------------------
echo "Select target platform:"
echo "  [1] T1"
echo "  [2] BK7231N"
echo "  [3] RTL8720CF"

__UNT_PLATFORM=""
while [ -z "$__UNT_PLATFORM" ]; do
    printf 'Enter choice [1-3]: '
    if ! read -r __UNT_CHOICE; then
        printf '\nNo input received; platform not set.\n' >&2
        break
    fi
    case "$__UNT_CHOICE" in
        1) __UNT_PLATFORM="T1" ;;
        2) __UNT_PLATFORM="BK7231N" ;;
        3) __UNT_PLATFORM="RTL8720CF" ;;
        *) echo "Invalid choice: '$__UNT_CHOICE'. Please enter 1, 2 or 3." ;;
    esac
done

if [ -n "$__UNT_PLATFORM" ]; then
    export UNTUYAOS3_PLATFORM="$__UNT_PLATFORM"

    # --- Choose a firmware file for the selected platform --------------------
    __UNT_FW_DIR="${__UNT_DIR}/custom-firmware/${__UNT_PLATFORM}"

    # Collect regular files in the platform's firmware directory. Without a
    # match the glob stays literal, so the -f test filters it out (array empty).
    __UNT_FW_FILES=()
    for __UNT_F in "${__UNT_FW_DIR}"/*; do
        [ -f "$__UNT_F" ] && __UNT_FW_FILES+=("$__UNT_F")
    done

    if [ "${#__UNT_FW_FILES[@]}" -eq 0 ]; then
        # No firmware available is fatal: print the message and tear down the
        # whole process chain (closes the wrapper and the caller's shell too).
        printf 'No custom firmware could be found for %s.  Please add a valid `UG` file and try again.\n' \
            "$UNTUYAOS3_PLATFORM" >&2
        exit 1
    else
        echo
        echo "Select firmware for ${__UNT_PLATFORM}:"
        __UNT_I=1
        for __UNT_F in "${__UNT_FW_FILES[@]}"; do
            printf '  [%d] %s\n' "$__UNT_I" "$(basename "$__UNT_F")"
            __UNT_I=$((__UNT_I + 1))
        done

        __UNT_FW=""
        __UNT_MAX=${#__UNT_FW_FILES[@]}
        while [ -z "$__UNT_FW" ]; do
            printf 'Enter choice [1-%d]: ' "$__UNT_MAX"
            if ! read -r __UNT_CHOICE; then
                printf '\nNo input received; UNTUYAOS3_FIRMWARE not set.\n' >&2
                break
            fi
            if printf '%s' "$__UNT_CHOICE" | grep -Eq '^[0-9]+$' \
                && [ "$__UNT_CHOICE" -ge 1 ] && [ "$__UNT_CHOICE" -le "$__UNT_MAX" ]; then
                __UNT_FW="${__UNT_FW_FILES[$((__UNT_CHOICE - 1))]}"
            else
                echo "Invalid choice: '$__UNT_CHOICE'. Please enter 1-${__UNT_MAX}."
            fi
        done

        if [ -n "$__UNT_FW" ]; then
            export UNTUYAOS3_FIRMWARE="$__UNT_FW"

            # --- Validate the firmware's magic bytes per platform ------------
            # Each platform checks LEN bytes starting at byte offset OFF against
            # an expected lowercase-hex signature.
            case "$UNTUYAOS3_PLATFORM" in
                T1)        __UNT_OFF=0;  __UNT_LEN=4;  __UNT_MAGIC="4d4d4d00" ;;   # bytes 0-4
                BK7231N)   __UNT_OFF=0;  __UNT_LEN=4;  __UNT_MAGIC="55aa55aa" ;;   # bytes 0-4
                RTL8720CF) __UNT_OFF=32; __UNT_LEN=16; __UNT_MAGIC="68513ef83e396b12ba059a900f36b6d3" ;;  # bytes 32-48
                *)         __UNT_OFF=0;  __UNT_LEN=0;  __UNT_MAGIC="" ;;
            esac

            if [ -n "$__UNT_MAGIC" ]; then
                # Read LEN bytes at offset OFF as lowercase hex (empty if short).
                __UNT_HEAD="$(od -An -v -tx1 -j "$__UNT_OFF" -N "$__UNT_LEN" \
                              "$UNTUYAOS3_FIRMWARE" 2>/dev/null | tr -d ' \n')"
                if [ "$__UNT_HEAD" != "$__UNT_MAGIC" ]; then
                    __UNT_INVALID=1
                fi
            fi
        fi
    fi
fi

# Restore caller's shell options and clean up (sourcing-safe).
eval "$__UNT_OPTS"
unset __UNT_OPTS __UNT_DIR __UNT_PLATFORM __UNT_CHOICE \
      __UNT_FW_DIR __UNT_FW_FILES __UNT_F __UNT_I __UNT_FW __UNT_MAX \
      __UNT_OFF __UNT_LEN __UNT_MAGIC __UNT_HEAD 2>/dev/null

# Invalid firmware is fatal. Print the message and `exit` so the whole process
# chain is torn down: because the scripts run in a single process when sourced,
# this closes the wrapper and the caller's shell too, not just this script.
if [ "${__UNT_INVALID:-0}" = 1 ]; then
    printf 'The custom firmware you selected is not valid, you must supply a valid `UG` file for %s\n' \
        "$UNTUYAOS3_PLATFORM" >&2
    exit 1
fi

unset __UNT_INVALID 2>/dev/null
