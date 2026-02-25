#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INI_PATH="${ROOT_DIR}/build/machine.ini"
CONFIGURE_SCRIPT="${ROOT_DIR}/ralph/configure.sh"

if [[ ! -f "${INI_PATH}" ]]; then
  if [[ ! -x "${CONFIGURE_SCRIPT}" && ! -f "${CONFIGURE_SCRIPT}" ]]; then
    echo "Missing prerequisite: ${INI_PATH} not found and configure script unavailable at ${CONFIGURE_SCRIPT}" >&2
    exit 1
  fi

  bash "${CONFIGURE_SCRIPT}" >/dev/null
fi

if [[ ! -f "${INI_PATH}" ]]; then
  echo "Missing prerequisite: generated config not found at ${INI_PATH}" >&2
  exit 1
fi

if ! command -v linuxcnc >/dev/null 2>&1; then
  echo "Missing prerequisite: linuxcnc command not found" >&2
  exit 1
fi

linuxcnc --check "${INI_PATH}" >/dev/null
