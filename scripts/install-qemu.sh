#!/usr/bin/env bash
# Install QEMU via Homebrew on macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Installing QEMU ==="

# Check if brew is available
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is not installed. Install it from https://brew.sh"
    exit 1
fi

# Install QEMU if not present
if command -v qemu-system-x86_64 &>/dev/null; then
    echo "QEMU is already installed: $(qemu-system-x86_64 --version | head -1)"
else
    echo "Installing QEMU via Homebrew..."
    brew install qemu
fi

# Verify required binaries
REQUIRED_BINS=(qemu-system-x86_64 qemu-img)
for bin in "${REQUIRED_BINS[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
        echo "ERROR: Required binary '$bin' not found after install"
        exit 1
    fi
    echo "  ✓ $bin found"
done

echo "=== QEMU installation verified ==="
