#!/usr/bin/env bash
# Create a QEMU VM with Debian 12 using preseed for unattended installation.
# Builds a qcow2 disk, boots the Debian netinst ISO with preseed, and waits
# for the install to complete. Idempotent: skips if disk image already exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_DIR="$REPO_ROOT/vm"

DISK_IMAGE="$VM_DIR/linuxcnc-vm.qcow2"
DEBIAN_ISO="$VM_DIR/debian-12-amd64-netinst.iso"
PRESEED_CFG="$VM_DIR/preseed.cfg"
EXTRACT_DIR="$VM_DIR/.installer-extract"

DISK_SIZE="20G"
SSH_HOST_PORT=2222
RAM="2G"
CPUS=2
PRESEED_HTTP_PORT=10680

# --- Parse arguments ---
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--force]"
            echo "  --force  Recreate disk image even if it already exists"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

echo "=== Creating LinuxCNC VM ==="

# --- Verify dependencies ---
for dep in qemu-system-x86_64 qemu-img python3; do
    if ! command -v "$dep" &>/dev/null; then
        echo "ERROR: $dep not found. Run scripts/install-qemu.sh first."
        exit 1
    fi
done

if [ ! -f "$DEBIAN_ISO" ]; then
    echo "ERROR: Debian ISO not found at $DEBIAN_ISO"
    echo "Run scripts/fetch-deps.sh first."
    exit 1
fi

if [ ! -f "$PRESEED_CFG" ]; then
    echo "ERROR: Preseed config not found at $PRESEED_CFG"
    exit 1
fi

# --- Idempotency: skip if disk image already exists ---
if [ -f "$DISK_IMAGE" ] && [ "$FORCE" = false ]; then
    echo "Disk image already exists: $DISK_IMAGE"
    echo "Use --force to recreate."
    exit 0
fi

# --- Create disk image ---
echo "Creating ${DISK_SIZE} qcow2 disk image..."
qemu-img create -f qcow2 "$DISK_IMAGE" "$DISK_SIZE"
echo "  ✓ Disk image created"

# --- Extract kernel and initrd from ISO for direct-boot preseed install ---
echo "Extracting installer kernel and initrd from ISO..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

MOUNT_POINT=$(mktemp -d)
if [[ "$(uname)" == "Darwin" ]]; then
    hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DEBIAN_ISO" >/dev/null
else
    sudo mount -o loop,ro "$DEBIAN_ISO" "$MOUNT_POINT"
fi

cp "$MOUNT_POINT/install.amd/vmlinuz" "$EXTRACT_DIR/vmlinuz"
cp "$MOUNT_POINT/install.amd/initrd.gz" "$EXTRACT_DIR/initrd.gz"

if [[ "$(uname)" == "Darwin" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null
else
    sudo umount "$MOUNT_POINT"
fi
rmdir "$MOUNT_POINT"
echo "  ✓ Kernel and initrd extracted"

# --- Detect hardware acceleration ---
ACCEL_ARGS=()
if [[ "$(uname)" == "Darwin" ]]; then
    if sysctl -n kern.hv_support 2>/dev/null | grep -q 1; then
        ACCEL_ARGS=(-accel hvf)
        echo "  ✓ Using HVF acceleration"
    else
        ACCEL_ARGS=(-accel tcg)
        echo "  ⚠ HVF not available, using TCG (slower)"
    fi
elif [ -e /dev/kvm ]; then
    ACCEL_ARGS=(-accel kvm)
    echo "  ✓ Using KVM acceleration"
else
    ACCEL_ARGS=(-accel tcg)
    echo "  ⚠ No hardware acceleration, using TCG"
fi

# --- Start HTTP server to serve preseed.cfg ---
# The Debian installer fetches the preseed from http://10.0.2.2 (QEMU host)
HTTP_PID=""
cleanup() {
    if [ -n "$HTTP_PID" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    rm -rf "$EXTRACT_DIR"
}
trap cleanup EXIT

echo "Starting preseed HTTP server on port $PRESEED_HTTP_PORT..."
python3 -m http.server "$PRESEED_HTTP_PORT" --bind 127.0.0.1 --directory "$VM_DIR" \
    >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1

if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "ERROR: Failed to start HTTP server on port $PRESEED_HTTP_PORT"
    echo "  Port may be in use. Try: lsof -i :$PRESEED_HTTP_PORT"
    exit 1
fi
echo "  ✓ Preseed HTTP server running (PID $HTTP_PID)"

# --- Build kernel command line for automated preseed install ---
# 10.0.2.2 is the default host gateway in QEMU user-mode networking (slirp)
KERNEL_CMDLINE="auto=true"
KERNEL_CMDLINE+=" priority=critical"
KERNEL_CMDLINE+=" preseed/url=http://10.0.2.2:${PRESEED_HTTP_PORT}/preseed.cfg"
KERNEL_CMDLINE+=" locale=en_US.UTF-8"
KERNEL_CMDLINE+=" keymap=us"
KERNEL_CMDLINE+=" hostname=linuxcnc-vm"
KERNEL_CMDLINE+=" domain=local"
KERNEL_CMDLINE+=" --- quiet"

# --- Launch QEMU ---
echo ""
echo "Launching QEMU for unattended Debian 12 install..."
echo "  Disk:     $DISK_IMAGE ($DISK_SIZE)"
echo "  ISO:      $DEBIAN_ISO"
echo "  RAM:      $RAM"
echo "  CPUs:     $CPUS"
echo "  SSH:      localhost:$SSH_HOST_PORT → guest:22"
echo "  Accel:    ${ACCEL_ARGS[*]#-accel }"
echo ""
echo "This will take 10-30 minutes. The VM shuts down when complete."
echo "---"

qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -m "$RAM" \
    -smp "$CPUS" \
    -drive file="$DISK_IMAGE",format=qcow2,if=virtio \
    -cdrom "$DEBIAN_ISO" \
    -kernel "$EXTRACT_DIR/vmlinuz" \
    -initrd "$EXTRACT_DIR/initrd.gz" \
    -append "$KERNEL_CMDLINE" \
    -netdev user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -no-reboot

QEMU_EXIT=$?
if [ $QEMU_EXIT -ne 0 ]; then
    echo ""
    echo "ERROR: QEMU exited with code $QEMU_EXIT"
    echo "The installation may have failed. Check output above."
    rm -f "$DISK_IMAGE"
    exit 1
fi

echo ""
echo "=== VM Installation Complete ==="
echo "Disk image: $DISK_IMAGE"
echo ""
echo "Next steps:"
echo "  Start VM:  scripts/vm-control.sh start"
echo "  SSH into:  ssh -p $SSH_HOST_PORT cnc@localhost"
echo "  Provision: scripts/provision-vm.sh"
