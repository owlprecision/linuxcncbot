#!/usr/bin/env bash
# Bootstrap an existing Debian PREEMPT-RT LinuxCNC host for this repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || id -gn)"
DEFAULT_LINUXCNC_DIR="/home/$TARGET_USER/linuxcnc"
if [ "$TARGET_USER" = "root" ]; then
    DEFAULT_LINUXCNC_DIR="/root/linuxcnc"
fi
LINUXCNC_DIR="${LINUXCNC_DIR:-$DEFAULT_LINUXCNC_DIR}"

FAILURES=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Bootstrap an existing Debian PREEMPT-RT LinuxCNC host for linuxcncbot.

Options:
  --help, -h   Show this help

Environment overrides:
  LINUXCNC_DIR  LinuxCNC working directory to ensure exists (default: /home/<user>/linuxcnc)
USAGE
}

info() {
    echo "[INFO] $*"
}

pass() {
    echo "[PASS] $*"
}

warn() {
    echo "[WARN] $*"
}

fail() {
    echo "[FAIL] $*"
    FAILURES=$((FAILURES + 1))
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        fail "This step requires root privileges and sudo is not available."
        return 1
    fi
}

have_internet() {
    curl -fsSI --max-time 5 https://deb.debian.org >/dev/null 2>&1
}

install_required_packages() {
    if ! command -v apt-get >/dev/null 2>&1; then
        fail "apt-get not found. This script supports Debian/apt hosts only."
        return
    fi

    local desired_packages=(
        ca-certificates
        curl
        git
        rsync
        jq
        openssh-client
        build-essential
        pkg-config
        python3
        python3-venv
        python3-pip
        linuxcnc-uspace
        linuxcnc-dev
        linuxcnc-ethercat
        linux-image-rt-amd64
    )

    if ! have_internet; then
        warn "Internet connectivity check failed; skipping apt update/install."
        warn "Will continue with local verification. Missing tools will fail verification."
        return
    fi

    info "Refreshing apt package index..."
    run_as_root apt-get update -y

    local installable=()
    local pkg
    for pkg in "${desired_packages[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            installable+=("$pkg")
        else
            warn "Package not found in configured apt repos, skipping: $pkg"
        fi
    done

    local missing=()
    for pkg in "${installable[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        pass "Required apt packages already installed."
        return
    fi

    info "Installing packages: ${missing[*]}"
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    pass "Package installation step completed."
}

ensure_repo_paths() {
    local required_dirs=(
        "$REPO_ROOT/build"
        "$REPO_ROOT/vm"
        "$REPO_ROOT/external"
        "$LINUXCNC_DIR"
    )

    local dir
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            if [ "$dir" = "$LINUXCNC_DIR" ] || [ "$(id -u)" -eq 0 ]; then
                run_as_root mkdir -p "$dir"
            else
                mkdir -p "$dir"
            fi
            info "Created directory: $dir"
        fi

        if [ ! -w "$dir" ]; then
            if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
                run_as_root chown "$TARGET_USER:$TARGET_GROUP" "$dir" || true
            fi
        fi

        if [ -w "$dir" ]; then
            pass "Writable directory OK: $dir"
        else
            fail "Directory is not writable: $dir"
        fi
    done
}

verify_prerequisites() {
    local required_commands=(
        bash
        apt-get
        git
        rsync
        curl
        jq
        python3
        linuxcnc
        halcmd
        halcompile
    )

    local cmd
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            pass "Command present: $cmd"
        else
            fail "Required command missing: $cmd"
        fi
    done

    local rt_running=false
    if [ -r /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
        rt_running=true
    elif uname -v | grep -Eiq 'PREEMPT(_RT)?|PREEMPT RT'; then
        rt_running=true
    fi

    if [ "$rt_running" = true ]; then
        pass "Realtime kernel is active (kernel: $(uname -r))."
    else
        fail "Realtime kernel not active. Boot a PREEMPT-RT kernel and re-run (current: $(uname -r))."
    fi
}

main() {
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "ERROR: Unknown option: $arg"
                usage
                exit 2
                ;;
        esac
    done

    info "Bootstrapping target host for repository: $REPO_ROOT"
    info "Target user: $TARGET_USER"
    info "LinuxCNC directory: $LINUXCNC_DIR"

    install_required_packages
    ensure_repo_paths
    verify_prerequisites

    if [ "$FAILURES" -ne 0 ]; then
        echo
        echo "Bootstrap checks completed with $FAILURES failure(s)."
        exit 1
    fi

    echo
    echo "Bootstrap checks completed successfully."
}

main "$@"
