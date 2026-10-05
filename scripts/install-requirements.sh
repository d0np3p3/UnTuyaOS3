#!/usr/bin/env bash
#
# install-requirements.sh - Install python3 and pip via the system package
#                            manager, then create a Python environment named
#                            "venv-UnTuyaOS3" and install the Python packages
#                            listed in requirements.txt into it with pip, and
#                            finally activate it.
#
# Sourcing-safe: when sourced it returns instead of exiting (so it never closes
# your shell) and restores shell options / helper functions on the way out.
#
#     ./install-requirements.sh        # run normally (lands you in a sub-shell
#                                      #   with the env activated)
#     source ./install-requirements.sh # activate the env in the current shell

# Detect sourced vs executed (must run at top level, not inside a function).
if (return 0 2>/dev/null); then __UNT_SOURCED=1; else __UNT_SOURCED=0; fi

# Snapshot caller's shell options so we can restore them afterwards.
__UNT_OPTS="$(set +o)"
set -u

# Resolve the project root (the parent of this script's scripts/ directory) so
# the venv is always created there, regardless of the current working directory.
__UNT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

ENV_NAME="venv-UnTuyaOS3"
ENV_PATH="${__UNT_ROOT}/${ENV_NAME}"
REQUIREMENTS="${__UNT_ROOT}/requirements.txt"

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
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            die "not root and 'sudo' not available; re-run as root"
            return 1
        fi
    fi

    # --- Step 1: install python3, pip and build dependencies -----------------
    # Some packages (e.g. sslpsk3) are C extensions compiled at install time,
    # so a C toolchain plus the Python and OpenSSL development headers must be
    # present or the build fails with: fatal error: openssl/ssl.h: No such file.
    #
    # Detect the package manager and pick its package names, then install only
    # the ones that aren't already present.
    local PM="" SYS_PACKAGES=""
    if command -v apt-get >/dev/null 2>&1; then
        PM="apt";    SYS_PACKAGES="python3 python3-pip python3-venv python3-dev build-essential libssl-dev iw"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf";    SYS_PACKAGES="python3 python3-pip python3-virtualenv python3-devel gcc openssl-devel iw"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum";    SYS_PACKAGES="python3 python3-pip python3-virtualenv python3-devel gcc openssl-devel iw"
    elif command -v pacman >/dev/null 2>&1; then
        PM="pacman"; SYS_PACKAGES="python python-pip base-devel openssl iw"
    elif command -v zypper >/dev/null 2>&1; then
        PM="zypper"; SYS_PACKAGES="python3 python3-pip python3-virtualenv python3-devel gcc libopenssl-devel iw"
    elif command -v apk >/dev/null 2>&1; then
        PM="apk";    SYS_PACKAGES="python3 py3-pip py3-virtualenv python3-dev build-base openssl-dev iw"
    else
        die "no supported package manager found (apt, dnf, yum, pacman, zypper, apk)"
        return 1
    fi

    # connect.sh also needs `ip`. Most systems already have it (from iproute2,
    # or e.g. busybox), so only add the package when the command is missing.
    if ! command -v ip >/dev/null 2>&1; then
        case "$PM" in
            dnf|yum) SYS_PACKAGES="${SYS_PACKAGES} iproute" ;;
            *)       SYS_PACKAGES="${SYS_PACKAGES} iproute2" ;;
        esac
    fi

    local syspkg __UNT_SYS_MISSING=""
    echo "==> Checking system packages (${PM})..."
    for syspkg in $SYS_PACKAGES; do
        if pkg_installed "$PM" "$syspkg"; then
            echo "    already installed: $syspkg"
        else
            echo "    missing:           $syspkg"
            __UNT_SYS_MISSING="${__UNT_SYS_MISSING:+$__UNT_SYS_MISSING }$syspkg"
        fi
    done

    if [ -n "$__UNT_SYS_MISSING" ]; then
        # Refresh the package index first where that is a separate step.
        if [ "$PM" = "apt" ]; then
            $SUDO apt-get update || { die "apt-get update failed"; return 1; }
        elif [ "$PM" = "pacman" ]; then
            $SUDO pacman -Sy --noconfirm || { die "pacman sync failed"; return 1; }
        fi
        echo "==> Installing system packages: ${__UNT_SYS_MISSING}"
        # shellcheck disable=SC2086  # intentional word-splitting of the list
        pm_install "$PM" $__UNT_SYS_MISSING || { die "package install failed"; return 1; }
    else
        echo "==> All required system packages are already installed."
    fi

    # Pick a python interpreter.
    local PYTHON
    PYTHON="$(command -v python3 || command -v python)" || { die "python not found after install"; return 1; }

    # --- Step 2: create the "venv-UnTuyaOS3" environment and install packages -
    echo "==> Creating virtual environment at '${ENV_PATH}'..."
    "$PYTHON" -m venv "$ENV_PATH" || { die "failed to create venv '${ENV_PATH}'"; return 1; }

    local ENV_PIP="${ENV_PATH}/bin/pip"
    [ -x "$ENV_PIP" ] || ENV_PIP="${ENV_PATH}/Scripts/pip"   # Git-Bash/WSL safety

    # Only bootstrap/upgrade pip if the venv doesn't already provide it (a venv
    # normally includes pip, so this is typically skipped).
    if "$ENV_PIP" --version >/dev/null 2>&1; then
        echo "==> pip already present in '${ENV_NAME}'; skipping upgrade."
    else
        echo "==> pip not found in '${ENV_NAME}'; bootstrapping with ensurepip..."
        local ENV_PY="${ENV_PATH}/bin/python"
        [ -x "$ENV_PY" ] || ENV_PY="${ENV_PATH}/Scripts/python.exe"  # Git-Bash/WSL
        [ -x "$ENV_PY" ] || { die "could not locate python inside '${ENV_PATH}'"; return 1; }
        "$ENV_PY" -m ensurepip --upgrade || { die "failed to bootstrap pip"; return 1; }
        # Re-resolve pip after ensurepip created it.
        ENV_PIP="${ENV_PATH}/bin/pip"
        [ -x "$ENV_PIP" ] || ENV_PIP="${ENV_PATH}/Scripts/pip"
        [ -x "$ENV_PIP" ] || { die "could not locate pip inside '${ENV_PATH}'"; return 1; }
    fi

    [ -f "$REQUIREMENTS" ] || { die "missing requirements file: ${REQUIREMENTS}"; return 1; }

    # Only install packages that aren't already present in the venv. `pip show`
    # exits 0 when a distribution is installed (it normalizes case and the
    # hyphen/underscore in names like py-datastruct). Package names are taken
    # from requirements.txt with comments and version specifiers stripped.
    local pkg __UNT_MISSING=""
    echo "==> Checking installed packages in '${ENV_NAME}'..."
    for pkg in $(sed -e 's/#.*//' -e 's/[[:space:]<>=!~;\[].*//' "$REQUIREMENTS"); do
        if "$ENV_PIP" show "$pkg" >/dev/null 2>&1; then
            echo "    already installed: $pkg"
        else
            echo "    missing:           $pkg"
            __UNT_MISSING="${__UNT_MISSING:+$__UNT_MISSING }$pkg"
        fi
    done

    if [ -n "$__UNT_MISSING" ]; then
        # At least one package is missing: upgrade pip once before installing.
        echo "==> Upgrading pip in '${ENV_NAME}' before installing packages..."
        "$ENV_PIP" install --upgrade pip || { die "failed to upgrade pip"; return 1; }

        echo "==> Installing packages from requirements.txt: ${__UNT_MISSING}"
        "$ENV_PIP" install -r "$REQUIREMENTS" || { die "failed to install packages"; return 1; }
    else
        echo "==> All required packages are already installed."
    fi

    # --- Step 3: activate the environment ------------------------------------
    local ACTIVATE="${ENV_PATH}/bin/activate"
    [ -f "$ACTIVATE" ] || ACTIVATE="${ENV_PATH}/Scripts/activate"   # Git-Bash/WSL
    [ -f "$ACTIVATE" ] || { die "could not locate activate script in '${ENV_PATH}'"; return 1; }

    echo
    if [ "$__UNT_SOURCED" = 1 ]; then
        # Sourced: activate directly in the caller's current shell.
        # shellcheck disable=SC1090
        . "$ACTIVATE"
        echo "Environment '${ENV_NAME}' is now active in your current shell."
    else
        # Executed: a venv activated here would vanish on exit, so start an
        # interactive shell that already has the environment activated.
        echo "Activating '${ENV_NAME}' in a new shell (type 'exit' to leave it)..."
        exec bash --rcfile <(
            [ -f "$HOME/.bashrc" ] && cat "$HOME/.bashrc"
            printf '. %q\n' "$ACTIVATE"
        )
    fi
}

__install_requirements_main
__UNT_RC=$?

# Restore caller's shell options and clean up helpers (sourcing-safe).
eval "$__UNT_OPTS"
unset __UNT_OPTS __UNT_ROOT ENV_NAME ENV_PATH REQUIREMENTS
unset -f die pkg_installed pm_install 2>/dev/null
if [ "$__UNT_SOURCED" = 1 ]; then
    unset __UNT_SOURCED
    return "$__UNT_RC"
fi
unset __UNT_SOURCED
exit "$__UNT_RC"
