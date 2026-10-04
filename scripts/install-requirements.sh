#!/usr/bin/env bash
#
# install-requirements.sh - Ensure the host has what it needs to run UnTuyaOS3:
#                            iw, a Docker engine (docker / docker.io) and
#                            docker-cli (a hard requirement), then build the
#                            "untuyaos3" container image from scripts/Dockerfile
#                            if it isn't built.
#
# Everything Python related lives inside the container, so nothing Python is
# installed on the host.
#
# Sourcing-safe: when sourced it returns instead of exiting (so it never closes
# your shell) and restores shell options / helper functions on the way out.
#
#     ./install-requirements.sh
#     source ./install-requirements.sh

# Detect sourced vs executed (must run at top level, not inside a function).
if (return 0 2>/dev/null); then __UNT_SOURCED=1; else __UNT_SOURCED=0; fi

# Snapshot caller's shell options so we can restore them afterwards.
__UNT_OPTS="$(set +o)"
set -u

IMAGE="untuyaos3"
__UNT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

die() { printf 'error: %s\n' "$*" >&2; }

# Is a system package installed? Uses the detected package manager's own query.
# $1 = package manager id, $2 = package name.
pkg_installed() {
    case "$1" in
        apt)            dpkg -s "$2" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -q "$2"  >/dev/null 2>&1 ;;
        pacman)         pacman -Q "$2" >/dev/null 2>&1 ;;
        apk)            apk info -e "$2" >/dev/null 2>&1 ;;
        *)              return 1 ;;
    esac
}

# Is any package in a list installed? $1 = package manager id, $2 = package list.
any_pkg_installed() {
    local p
    for p in $2; do
        pkg_installed "$1" "$p" && return 0
    done
    return 1
}

# Install one or more system packages via the detected package manager.
# $1 = package manager id, remaining args = packages.
pm_install() {
    local pm="$1"; shift
    case "$pm" in
        apt)    $SUDO apt-get install -y "$@" ;;
        dnf)    $SUDO dnf install -y "$@" ;;
        yum)    $SUDO yum install -y "$@" ;;
        pacman) $SUDO pacman -S --noconfirm "$@" ;;
        zypper) $SUDO zypper install -y "$@" ;;
        apk)    $SUDO apk add "$@" ;;
    esac
}

__install_requirements_main() {
    # Run privileged package-manager commands via sudo unless already root.
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            die "not root and 'sudo' not available; re-run as root"
            return 1
        fi
    fi

    # --- Step 1: host packages -----------------------------------------------
    # Detect the package manager.
    local PM=""
    for PM in apt dnf yum pacman zypper apk; do
        # apt is detected by its apt-get binary; the rest match their own name.
        command -v "${PM/apt/apt-get}" >/dev/null 2>&1 && break
        PM=""
    done
    if [ -z "$PM" ]; then
        die "no supported package manager found (apt, dnf, yum, pacman, zypper, apk)"
        return 1
    fi

    # Package names for that manager. Each variable is a list of alternatives:
    # any one of them being installed satisfies the requirement, and the first
    # is what gets installed when none is present.
    local TOOLS="iw" ENGINE="" CLI=""
    case "$PM" in
        apt)         ENGINE="docker.io docker-ce";          CLI="docker-cli docker-ce-cli" ;;
        dnf|yum)     ENGINE="moby-engine docker-ce docker"; CLI="docker-cli docker-ce-cli" ;;
        pacman|apk)  ENGINE="docker";                       CLI="docker-cli" ;;
        zypper)      ENGINE="docker";                       CLI="docker-cli docker-ce-cli" ;;
    esac

    # Report whether a requirement is met and queue its first package if not.
    # $1 = label, $2 = list of alternative packages.
    local MISSING=""
    check_requirement() {
        if any_pkg_installed "$PM" "$2"; then
            echo "    already installed: $1"
        else
            echo "    missing:           $1"
            MISSING="${MISSING:+$MISSING }${2%% *}"
        fi
    }

    echo "==> Checking system packages (${PM})..."
    check_requirement "iw"            "$TOOLS"
    check_requirement "docker engine" "$ENGINE"
    check_requirement "docker-cli"    "$CLI"

    if [ -n "$MISSING" ]; then
        # Refresh the package index first where that is a separate step.
        if [ "$PM" = "apt" ]; then
            $SUDO apt-get update || { die "apt-get update failed"; return 1; }
        elif [ "$PM" = "pacman" ]; then
            $SUDO pacman -Sy --noconfirm || { die "pacman sync failed"; return 1; }
        fi
        echo "==> Installing system packages: ${MISSING}"
        # shellcheck disable=SC2086  # intentional word-splitting of the list
        pm_install "$PM" $MISSING || { die "package install failed"; return 1; }
    else
        echo "==> All required system packages are already installed."
    fi

    # docker-cli is a hard requirement.
    if ! any_pkg_installed "$PM" "$CLI" || ! command -v docker >/dev/null 2>&1; then
        die "docker-cli is required but is not installed (package: ${CLI%% *})"
        return 1
    fi

    # --- Step 2: make sure the Docker daemon is running ----------------------
    if ! $SUDO docker info >/dev/null 2>&1; then
        echo "==> Starting the Docker daemon..."
        if command -v systemctl >/dev/null 2>&1; then
            $SUDO systemctl enable --now docker >/dev/null 2>&1
        elif command -v service >/dev/null 2>&1; then
            $SUDO service docker start >/dev/null 2>&1
        fi
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            $SUDO docker info >/dev/null 2>&1 && break
            sleep 1
        done
        $SUDO docker info >/dev/null 2>&1 || { die "the Docker daemon is not running"; return 1; }
    fi

    # --- Step 3: build the container image -----------------------------------
    # The image is defined by scripts/Dockerfile (python:3 plus iw, a DHCP client
    # and the pip requirements, all installed inside the container).
    if $SUDO docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "==> Container image '${IMAGE}' already built (docker rmi ${IMAGE} to rebuild)."
    else
        echo "==> Building container image '${IMAGE}'..."
        $SUDO docker build -t "$IMAGE" "$__UNT_SCRIPTS" || { die "failed to build container image '${IMAGE}'"; return 1; }
    fi

    export UNTUYAOS3_IMAGE="$IMAGE"
}

__install_requirements_main
__UNT_RC=$?

# Restore caller's shell options and clean up helpers (sourcing-safe).
eval "$__UNT_OPTS"
unset __UNT_OPTS __UNT_SCRIPTS IMAGE SUDO
unset -f die pkg_installed any_pkg_installed pm_install check_requirement 2>/dev/null
if [ "$__UNT_SOURCED" = 1 ]; then
    unset __UNT_SOURCED
    return "$__UNT_RC"
fi
unset __UNT_SOURCED
exit "$__UNT_RC"
