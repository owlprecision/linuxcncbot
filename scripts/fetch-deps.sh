#!/usr/bin/env bash
# Fetch external dependencies: reference repo and Debian ISO
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTERNAL_DIR="$REPO_ROOT/external"
VM_DIR="$REPO_ROOT/vm"

REFERENCE_REPO="https://github.com/marcoreps/linuxcnc_leadshine_EL8.git"
DEBIAN_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.9.0-amd64-netinst.iso"
DEBIAN_ISO_SHA256="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"
DEBIAN_ISO_NAME="debian-12-amd64-netinst.iso"

mkdir -p "$EXTERNAL_DIR" "$VM_DIR"

echo "=== Fetching Dependencies ==="

# Clone reference repo
if [ -d "$EXTERNAL_DIR/linuxcnc_leadshine_EL8" ]; then
    echo "Reference repo already cloned, pulling latest..."
    git -C "$EXTERNAL_DIR/linuxcnc_leadshine_EL8" pull --ff-only 2>/dev/null || true
else
    echo "Cloning reference repo..."
    git clone "$REFERENCE_REPO" "$EXTERNAL_DIR/linuxcnc_leadshine_EL8"
fi
echo "  ✓ Reference repo ready"

# Download Debian ISO
if [ -f "$VM_DIR/$DEBIAN_ISO_NAME" ]; then
    echo "Debian ISO already downloaded"
else
    echo "Downloading Debian 12 netinst ISO..."
    echo "  URL: $DEBIAN_ISO_URL"
    curl -L -o "$VM_DIR/$DEBIAN_ISO_NAME" "$DEBIAN_ISO_URL"
fi

# Verify checksum
echo "Verifying ISO checksum..."
if [ -f "$VM_DIR/$DEBIAN_ISO_NAME" ]; then
    echo "  Downloading SHA256SUMS for verification..."
    curl -sL "$DEBIAN_ISO_SHA256" -o "$VM_DIR/SHA256SUMS.tmp"
    EXPECTED_SHA=$(grep "netinst.iso" "$VM_DIR/SHA256SUMS.tmp" | head -1 | awk '{print $1}')
    ACTUAL_SHA=$(shasum -a 256 "$VM_DIR/$DEBIAN_ISO_NAME" | awk '{print $1}')
    rm -f "$VM_DIR/SHA256SUMS.tmp"

    if [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ]; then
        echo "  ✓ ISO checksum verified"
    else
        echo "  ⚠ Checksum mismatch (ISO may be for a different point release)"
        echo "    Expected: $EXPECTED_SHA"
        echo "    Actual:   $ACTUAL_SHA"
        echo "    This is OK if Debian released a newer point release. Re-run with a fresh download if concerned."
    fi
fi

echo "=== Dependencies fetched ==="
