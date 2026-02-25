#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="${ROOT_DIR}/config/profiles"
ACTIVE_PROFILE_FILE="${PROFILES_DIR}/active"
DEFAULT_PROFILE_FILE="${PROFILES_DIR}/3axis-xyz-sim.env"

load_profile() {
  local profile_file="${DEFAULT_PROFILE_FILE}"

  if [[ -f "${ACTIVE_PROFILE_FILE}" ]]; then
    local active_profile
    active_profile="$(grep -v '^[[:space:]]*#' "${ACTIVE_PROFILE_FILE}" | sed '/^[[:space:]]*$/d' | head -n 1 || true)"
    if [[ -n "${active_profile}" ]]; then
      profile_file="${PROFILES_DIR}/${active_profile}"
    fi
  fi

  if [[ ! -f "${profile_file}" ]]; then
    profile_file="${DEFAULT_PROFILE_FILE}"
  fi

  if [[ ! -f "${profile_file}" ]]; then
    echo "Hardware gate failed: profile file not found: ${profile_file}" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  set -a
  source "${profile_file}"
  set +a
}

load_profile

if [[ "${PROFILE_MODE:-sim}" != "ethercat" ]]; then
  echo "GATE ethercat_bus_scan SKIP profile_mode=${PROFILE_MODE:-sim}"
  exit 0
fi

if ! command -v ethercat >/dev/null 2>&1; then
  echo "Hardware gate failed: ethercat command not found" >&2
  exit 1
fi

set +e
scan_output="$(ethercat slaves 2>&1)"
scan_status=$?
set -e

if [[ ${scan_status} -ne 0 ]]; then
  echo "Hardware gate failed: ethercat slaves exited ${scan_status}" >&2
  echo "${scan_output}" >&2
  exit 1
fi

ek_count="$(printf '%s\n' "${scan_output}" | grep -Eic 'EK1100' || true)"
el_count="$(printf '%s\n' "${scan_output}" | grep -Eic 'EL7031' || true)"

if [[ "${ek_count}" -ne 1 || "${el_count}" -ne 2 ]]; then
  echo "Hardware gate failed: expected EK1100=1 and EL7031=2, got EK1100=${ek_count}, EL7031=${el_count}" >&2
  echo "${scan_output}" >&2
  exit 1
fi

echo "GATE ethercat_bus_scan PASS"
echo "DETECTED_EK1100=${ek_count}"
echo "DETECTED_EL7031=${el_count}"
