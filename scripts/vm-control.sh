#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_DIR="$REPO_ROOT/vm"

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

DISK_IMAGE="${VM_DISK_IMAGE:-$VM_DIR/linuxcnc-vm.qcow2}"
PID_FILE="${VM_QEMU_PID_FILE:-$VM_DIR/qemu.pid}"
MONITOR_SOCK="${VM_QEMU_MONITOR_SOCK:-$VM_DIR/qemu-monitor.sock}"
VM_RAM="${VM_RAM:-2G}"
VM_CPUS="${VM_CPUS:-2}"
VM_SSH_HOST="${VM_SSH_HOST:-localhost}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_SSH_USER="${VM_SSH_USER:-cnc}"
VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  start             Boot VM in background with SSH forwarding
  stop              Graceful shutdown, then force kill if needed
  ssh               Open SSH session to VM
  snapshot <name>   Create qcow2 snapshot
  restore <name>    Restore qcow2 snapshot
  status            Show VM running status
EOF
}

require_dep() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $1"
        exit 1
    fi
}

is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

running_pid() {
    cat "$PID_FILE"
}

accel_args() {
    if [[ "$(uname)" == "Darwin" ]]; then
        if sysctl -n kern.hv_support 2>/dev/null | grep -q 1; then
            echo "hvf"
        else
            echo "tcg"
        fi
    elif [ -e /dev/kvm ]; then
        echo "kvm"
    else
        echo "tcg"
    fi
}

start_vm() {
    require_dep qemu-system-x86_64
    mkdir -p "$VM_DIR"

    if [ ! -f "$DISK_IMAGE" ]; then
        echo "ERROR: VM disk image not found: $DISK_IMAGE"
        echo "Run scripts/create-vm.sh first."
        exit 1
    fi

    if is_running; then
        echo "VM already running (PID $(running_pid))"
        return 0
    fi

    rm -f "$PID_FILE" "$MONITOR_SOCK"
    local accel
    accel="$(accel_args)"

    qemu-system-x86_64 \
        -accel "$accel" \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        -drive file="$DISK_IMAGE",format=qcow2,if=virtio \
        -netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -monitor "unix:${MONITOR_SOCK},server,nowait" \
        -pidfile "$PID_FILE" \
        -nographic \
        -daemonize

    if ! is_running; then
        echo "ERROR: Failed to start VM"
        exit 1
    fi

    echo "VM started (PID $(running_pid))"
    echo "SSH: ssh -i \"$VM_SSH_KEY\" -p $VM_SSH_PORT ${VM_SSH_USER}@${VM_SSH_HOST}"
}

stop_vm() {
    if ! is_running; then
        rm -f "$PID_FILE"
        echo "VM is not running"
        return 0
    fi

    local pid
    pid="$(running_pid)"
    local graceful=false

    if command -v ssh >/dev/null 2>&1 && [ -f "$VM_SSH_KEY" ]; then
        ssh \
            -i "$VM_SSH_KEY" \
            -p "$VM_SSH_PORT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=5 \
            "${VM_SSH_USER}@${VM_SSH_HOST}" \
            "sudo shutdown -h now" >/dev/null 2>&1 || true

        for _ in {1..20}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                graceful=true
                break
            fi
            sleep 1
        done
    fi

    if ! $graceful && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in {1..10}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE" "$MONITOR_SOCK"
    echo "VM stopped"
}

ssh_vm() {
    require_dep ssh
    if [ ! -f "$VM_SSH_KEY" ]; then
        echo "ERROR: SSH key not found: $VM_SSH_KEY"
        exit 1
    fi

    exec ssh \
        -i "$VM_SSH_KEY" \
        -p "$VM_SSH_PORT" \
        -o StrictHostKeyChecking=accept-new \
        "${VM_SSH_USER}@${VM_SSH_HOST}"
}

snapshot_vm() {
    require_dep qemu-img
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "ERROR: snapshot name is required"
        usage
        exit 1
    fi

    if is_running; then
        echo "ERROR: Stop VM before creating a disk snapshot"
        exit 1
    fi

    qemu-img snapshot -c "$name" "$DISK_IMAGE"
    echo "Snapshot created: $name"
}

restore_vm() {
    require_dep qemu-img
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "ERROR: snapshot name is required"
        usage
        exit 1
    fi

    if is_running; then
        echo "ERROR: Stop VM before restoring a disk snapshot"
        exit 1
    fi

    qemu-img snapshot -a "$name" "$DISK_IMAGE"
    echo "Snapshot restored: $name"
}

status_vm() {
    if is_running; then
        echo "running (PID $(running_pid))"
        return 0
    fi

    if [ -f "$PID_FILE" ]; then
        rm -f "$PID_FILE"
    fi
    echo "stopped"
    return 1
}

COMMAND="${1:-}"
case "$COMMAND" in
    start)
        start_vm
        ;;
    stop)
        stop_vm
        ;;
    ssh)
        ssh_vm
        ;;
    snapshot)
        snapshot_vm "${2:-}"
        ;;
    restore)
        restore_vm "${2:-}"
        ;;
    status)
        status_vm
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        echo "ERROR: Unknown command: ${COMMAND:-<none>}"
        usage
        exit 1
        ;;
esac
