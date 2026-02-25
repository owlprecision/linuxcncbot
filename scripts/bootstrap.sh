#!/usr/bin/env bash
# Master bootstrap orchestrator for LinuxCNC bot VM environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_DIR="$REPO_ROOT/vm"
EXTERNAL_DIR="$REPO_ROOT/external"

INSTALL_QEMU_SCRIPT="$SCRIPT_DIR/install-qemu.sh"
FETCH_DEPS_SCRIPT="$SCRIPT_DIR/fetch-deps.sh"
CREATE_VM_SCRIPT="$SCRIPT_DIR/create-vm.sh"
PROVISION_VM_SCRIPT="$SCRIPT_DIR/provision-vm.sh"
VM_CONTROL_SCRIPT="$SCRIPT_DIR/vm-control.sh"

ACTIVE_PROFILE_FILE="$REPO_ROOT/config/profiles/active"
DEFAULT_PROFILE_FILE="$REPO_ROOT/config/profiles/3axis-xyz-sim.env"

if [ -f "$ACTIVE_PROFILE_FILE" ]; then
    PROFILE_NAME="$(tr -d '[:space:]' < "$ACTIVE_PROFILE_FILE")"
    PROFILE_FILE="$REPO_ROOT/config/profiles/$PROFILE_NAME"
else
    PROFILE_FILE="$DEFAULT_PROFILE_FILE"
fi

if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: Profile file not found: $PROFILE_FILE"
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_FILE"

VM_DISK_IMAGE="${VM_DISK_IMAGE:-$VM_DIR/linuxcnc-vm.qcow2}"
VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SNAPSHOT_NAME="clean"
PROVISION_MARKER="$VM_DIR/.provisioned"

DRY_RUN=false
FORCE_PROVISION=false
FORCE_SNAPSHOT=false

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --dry-run          Show what would run without making changes
  --force-provision  Run provisioning even if previous completion markers exist
  --force-snapshot   Recreate/refresh the '$SNAPSHOT_NAME' snapshot if possible
  -h, --help         Show this help
USAGE
}

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] $*"
        return 0
    fi
    "$@"
}

snapshot_exists() {
    [ -f "$VM_DISK_IMAGE" ] || return 1
    command -v qemu-img >/dev/null 2>&1 || return 1
    qemu-img snapshot -l "$VM_DISK_IMAGE" 2>/dev/null | awk 'NR>2 {print $2}' | grep -Fxq "$SNAPSHOT_NAME"
}

ensure_scripts_exist() {
    local required=(
        "$INSTALL_QEMU_SCRIPT"
        "$FETCH_DEPS_SCRIPT"
        "$CREATE_VM_SCRIPT"
        "$PROVISION_VM_SCRIPT"
        "$VM_CONTROL_SCRIPT"
    )

    for script_path in "${required[@]}"; do
        if [ ! -f "$script_path" ]; then
            echo "ERROR: Required bootstrap component script missing: $script_path"
            exit 1
        fi
    done
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --force-provision)
            FORCE_PROVISION=true
            ;;
        --force-snapshot)
            FORCE_SNAPSHOT=true
            ;;
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

ensure_scripts_exist
mkdir -p "$VM_DIR" "$EXTERNAL_DIR"

echo "=== LinuxCNC bootstrap ==="
echo "Profile: $PROFILE_FILE"
echo "Disk:    $VM_DISK_IMAGE"

# Step 1: install-qemu.sh
if command -v qemu-system-x86_64 >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    echo "[skip] install-qemu.sh (QEMU already installed)"
else
    echo "[run ] install-qemu.sh"
    run_cmd "$INSTALL_QEMU_SCRIPT"
fi

# Step 2: fetch-deps.sh
if [ -d "$EXTERNAL_DIR/linuxcnc_leadshine_EL8" ] && [ -f "$VM_DIR/debian-12-amd64-netinst.iso" ]; then
    echo "[skip] fetch-deps.sh (dependencies already present)"
else
    echo "[run ] fetch-deps.sh"
    run_cmd "$FETCH_DEPS_SCRIPT"
fi

# Step 3: create-vm.sh
if [ -f "$VM_DISK_IMAGE" ]; then
    echo "[skip] create-vm.sh (VM disk already exists)"
else
    echo "[run ] create-vm.sh"
    run_cmd "$CREATE_VM_SCRIPT"
fi

# Step 4: provision-vm.sh
PROVISION_DONE=false
if [ "$FORCE_PROVISION" = true ]; then
    echo "[run ] provision-vm.sh (--force-provision)"
elif [ -f "$PROVISION_MARKER" ]; then
    echo "[skip] provision-vm.sh (marker exists: $PROVISION_MARKER)"
    PROVISION_DONE=true
elif snapshot_exists; then
    echo "[skip] provision-vm.sh ('$SNAPSHOT_NAME' snapshot already exists)"
    PROVISION_DONE=true
else
    echo "[run ] provision-vm.sh"
fi

WAS_RUNNING=false
if "$VM_CONTROL_SCRIPT" status >/dev/null 2>&1; then
    WAS_RUNNING=true
fi

if [ "$PROVISION_DONE" = false ] || [ "$FORCE_PROVISION" = true ]; then
    if [ "$WAS_RUNNING" = false ]; then
        run_cmd "$VM_CONTROL_SCRIPT" start
    fi

    if [ "$DRY_RUN" = false ] && [ ! -f "$VM_SSH_KEY" ]; then
        echo "ERROR: SSH key not found: $VM_SSH_KEY"
        echo "Provisioning requires a valid key. Set VM_SSH_KEY in profile or environment."
        exit 1
    fi

    run_cmd "$PROVISION_VM_SCRIPT"
    if [ "$DRY_RUN" = false ]; then
        touch "$PROVISION_MARKER"
    fi
fi

# Step 5: snapshot via vm-control.sh
if "$VM_CONTROL_SCRIPT" status >/dev/null 2>&1; then
    run_cmd "$VM_CONTROL_SCRIPT" stop
fi

if snapshot_exists; then
    if [ "$FORCE_SNAPSHOT" = true ]; then
        echo "[run ] vm-control.sh restore $SNAPSHOT_NAME (--force-snapshot requested)"
        run_cmd "$VM_CONTROL_SCRIPT" restore "$SNAPSHOT_NAME"
        echo "[skip] vm-control.sh snapshot $SNAPSHOT_NAME (already exists)"
    else
        echo "[skip] vm-control.sh snapshot $SNAPSHOT_NAME (already exists)"
    fi
else
    echo "[run ] vm-control.sh snapshot $SNAPSHOT_NAME"
    run_cmd "$VM_CONTROL_SCRIPT" snapshot "$SNAPSHOT_NAME"
fi

echo "=== Bootstrap complete ==="
