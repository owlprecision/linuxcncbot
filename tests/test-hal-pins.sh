#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_HAL_PATH="${ROOT_DIR}/build/machine.hal"
BUILD_INI_PATH="${ROOT_DIR}/build/machine.ini"
CONFIGURE_SCRIPT="${ROOT_DIR}/ralph/configure.sh"
PROFILES_DIR="${ROOT_DIR}/config/profiles"
ACTIVE_PROFILE_FILE="${PROFILES_DIR}/active"
DEFAULT_PROFILE="3axis-xyz-sim.env"

if [[ ! -f "${BUILD_HAL_PATH}" ]]; then
  if [[ ! -x "${CONFIGURE_SCRIPT}" && ! -f "${CONFIGURE_SCRIPT}" ]]; then
    echo "Missing prerequisite: ${BUILD_HAL_PATH} not found and configure script unavailable at ${CONFIGURE_SCRIPT}" >&2
    exit 1
  fi

  bash "${CONFIGURE_SCRIPT}" >/dev/null
fi

if [[ ! -f "${BUILD_HAL_PATH}" ]]; then
  echo "Missing prerequisite: generated HAL file not found at ${BUILD_HAL_PATH}" >&2
  exit 1
fi

if [[ ! -f "${BUILD_INI_PATH}" ]]; then
  echo "Missing prerequisite: generated INI file not found at ${BUILD_INI_PATH}" >&2
  exit 1
fi

if ! command -v halcmd >/dev/null 2>&1; then
  echo "Missing prerequisite: halcmd command not found" >&2
  exit 1
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
  echo "Missing prerequisite: profile env file not found at ${profile_path}" >&2
  exit 1
fi

set -a
source "${profile_path}"
set +a

default_expected_pins=$'joint.0.motor-pos-cmd\njoint.0.motor-pos-fb\njoint.0.amp-enable-out\njoint.0.amp-enable-in\njoint.1.motor-pos-cmd\njoint.1.motor-pos-fb\njoint.1.amp-enable-out\njoint.1.amp-enable-in\njoint.2.motor-pos-cmd\njoint.2.motor-pos-fb\njoint.2.amp-enable-out\njoint.2.amp-enable-in'
raw_expected_pins="${HAL_EXPECTED_PINS:-${default_expected_pins}}"

tmp_hal_cmds="$(mktemp)"
tmp_hal_output="$(mktemp)"
tmp_expected_pins="$(mktemp)"
tmp_actual_pins="$(mktemp)"
trap 'rm -f "${tmp_hal_cmds}" "${tmp_hal_output}" "${tmp_expected_pins}" "${tmp_actual_pins}"' EXIT

cat >"${tmp_hal_cmds}" <<EOF
source ${BUILD_HAL_PATH}
show pin
quit
EOF

if ! halcmd -i "${BUILD_INI_PATH}" -f "${tmp_hal_cmds}" >"${tmp_hal_output}" 2>&1; then
  echo "Failed to load HAL and inspect pins using halcmd" >&2
  cat "${tmp_hal_output}" >&2
  exit 1
fi

awk 'NF > 0 {print}' "${tmp_hal_output}" | awk '$1 ~ /^[0-9]+$/ {print $NF}' | sort -u >"${tmp_actual_pins}"
printf '%s\n' "${raw_expected_pins}" | tr ',' '\n' | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -u >"${tmp_expected_pins}"

missing_pins=()
while IFS= read -r expected_pin; do
  [[ -z "${expected_pin}" ]] && continue
  if ! grep -Fxq "${expected_pin}" "${tmp_actual_pins}"; then
    missing_pins+=("${expected_pin}")
  fi
done <"${tmp_expected_pins}"

if (( ${#missing_pins[@]} > 0 )); then
  echo "HAL pin verification failed: missing ${#missing_pins[@]} expected pin(s):" >&2
  for pin in "${missing_pins[@]}"; do
    echo "  - ${pin}" >&2
  done
  exit 1
fi
