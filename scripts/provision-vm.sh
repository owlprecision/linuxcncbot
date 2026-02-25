#!/usr/bin/env bash
# Provision Debian VM with LinuxCNC packages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

VM_SSH_HOST="${VM_SSH_HOST:-localhost}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_SSH_USER="${VM_SSH_USER:-cnc}"
VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
LINUXCNC_APT_DIST="${LINUXCNC_APT_DIST:-bookworm}"
LINUXCNC_APT_COMPONENTS="${LINUXCNC_APT_COMPONENTS:-base 2.9-uspace}"

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: $(basename "$0")"
            echo "Optional env overrides:"
            echo "  VM_SSH_HOST VM_SSH_PORT VM_SSH_USER VM_SSH_KEY"
            echo "  LINUXCNC_APT_DIST LINUXCNC_APT_COMPONENTS"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

if [ ! -f "$VM_SSH_KEY" ]; then
    echo "ERROR: SSH key not found: $VM_SSH_KEY"
    exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
    echo "ERROR: ssh command not found"
    exit 1
fi

SSH_OPTS=(
    -i "$VM_SSH_KEY"
    -p "$VM_SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=5
)
SSH_TARGET="${VM_SSH_USER}@${VM_SSH_HOST}"

echo "=== Provisioning LinuxCNC VM ==="
echo "Profile: $PROFILE_FILE"
echo "Target:  $SSH_TARGET:$VM_SSH_PORT"

echo "Waiting for SSH to become reachable..."
for _ in {1..30}; do
    if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "echo ok" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Unable to reach VM via SSH at $SSH_TARGET:$VM_SSH_PORT"
    exit 1
fi

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo bash -s -- '$LINUXCNC_APT_DIST' '$LINUXCNC_APT_COMPONENTS' '$VM_SSH_USER'" <<'EOF'
set -euo pipefail

APT_DIST="$1"
APT_COMPONENTS="$2"
VM_USER="$3"
REPO_FILE="/etc/apt/sources.list.d/linuxcnc.list"
REPO_LINE="deb [trusted=yes] http://www.linuxcnc.org/ ${APT_DIST} ${APT_COMPONENTS}"

if [ ! -f "$REPO_FILE" ] || ! grep -Fq "$REPO_LINE" "$REPO_FILE"; then
    echo "$REPO_LINE" | tee "$REPO_FILE" >/dev/null
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y linux-image-rt-amd64

PACKAGES=(linuxcnc linuxcnc-dev linuxcnc-ethercat)
if apt-cache show halcmd >/dev/null 2>&1; then
    PACKAGES+=(halcmd)
else
    PACKAGES+=(linuxcnc-uspace)
fi
apt-get install -y "${PACKAGES[@]}"

if ! command -v halcmd >/dev/null 2>&1; then
    echo "ERROR: halcmd command is not available after package installation"
    exit 1
fi

install -d -o "$VM_USER" -g "$VM_USER" /home/cnc/linuxcnc
EOF

echo "=== VM provisioning complete ==="
