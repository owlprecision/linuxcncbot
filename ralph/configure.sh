#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
PROFILES_DIR="${CONFIG_DIR}/profiles"
BUILD_DIR="${ROOT_DIR}/build"

DEFAULT_PROFILE="3axis-xyz-sim.env"
ACTIVE_PROFILE_FILE="${PROFILES_DIR}/active"

if ! command -v envsubst >/dev/null 2>&1; then
  envsubst() {
    python3 -c 'import os, sys; sys.stdout.write(os.path.expandvars(sys.stdin.read()))'
  }
fi

profile_env_file="${DEFAULT_PROFILE}"
if [[ -f "${ACTIVE_PROFILE_FILE}" ]]; then
  active_profile="$(grep -v '^[[:space:]]*#' "${ACTIVE_PROFILE_FILE}" | sed '/^[[:space:]]*$/d' | head -n 1 || true)"
  if [[ -n "${active_profile}" ]]; then
    profile_env_file="${active_profile}"
  fi
fi

profile_path="${PROFILES_DIR}/${profile_env_file}"
if [[ ! -f "${profile_path}" ]]; then
  profile_path="${PROFILES_DIR}/${DEFAULT_PROFILE}"
fi

if [[ ! -f "${profile_path}" ]]; then
  echo "Profile file not found: ${profile_path}" >&2
  exit 1
fi

set -a
source "${profile_path}"
set +a

mkdir -p "${BUILD_DIR}"

envsubst < "${CONFIG_DIR}/machine.ini" > "${BUILD_DIR}/machine.ini"
envsubst < "${CONFIG_DIR}/machine.hal" > "${BUILD_DIR}/machine.hal"
envsubst < "${CONFIG_DIR}/sim.hal" > "${BUILD_DIR}/sim.hal"
envsubst < "${CONFIG_DIR}/ethercat-conf.xml" > "${BUILD_DIR}/ethercat-conf.xml"

required_sections=(
  DISPLAY
  KINS
  TRAJ
  EMCMOT
  HAL
  JOINT_0
  JOINT_1
  JOINT_2
)

missing_sections=()
for section in "${required_sections[@]}"; do
  if ! grep -Eq "^\[${section}\][[:space:]]*$" "${BUILD_DIR}/machine.ini"; then
    missing_sections+=("${section}")
  fi
done

if (( ${#missing_sections[@]} > 0 )); then
  echo "Missing required INI sections: ${missing_sections[*]}" >&2
  exit 1
fi

python3 - "${BUILD_DIR}" <<'PY' > "${BUILD_DIR}/manifest.json"
import json
import os
import sys

build_dir = sys.argv[1]
files = [
    "machine.ini",
    "machine.hal",
    "sim.hal",
    "ethercat-conf.xml",
]

manifest = []
for name in files:
    path = os.path.join(build_dir, name)
    manifest.append({
        "path": f"build/{name}",
        "size": os.path.getsize(path),
    })

print(json.dumps(manifest, indent=2))
PY

cat "${BUILD_DIR}/manifest.json"
