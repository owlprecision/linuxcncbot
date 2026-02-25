#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INI_PATH="${ROOT_DIR}/build/machine.ini"
HAL_PATH="${ROOT_DIR}/build/machine.hal"
CONFIGURE_SCRIPT="${ROOT_DIR}/ralph/configure.sh"
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
  echo "GATE linuxcnc_config_load SKIP profile_mode=${PROFILE_MODE:-sim}"
  exit 0
fi

if [[ ! -f "${INI_PATH}" ]]; then
  if [[ ! -x "${CONFIGURE_SCRIPT}" && ! -f "${CONFIGURE_SCRIPT}" ]]; then
    echo "Hardware gate failed: ${INI_PATH} missing and configure script unavailable at ${CONFIGURE_SCRIPT}" >&2
    exit 1
  fi
  bash "${CONFIGURE_SCRIPT}" >/dev/null
fi

if [[ ! -f "${INI_PATH}" || ! -f "${HAL_PATH}" ]]; then
  echo "Hardware gate failed: generated config missing (${INI_PATH}, ${HAL_PATH})" >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]*loadrt[[:space:]]+lcec([[:space:]]|$)' "${HAL_PATH}"; then
  echo "Hardware gate failed: HAL does not load lcec runtime" >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]*loadusr[[:space:]]+-W[[:space:]]+lcec_conf[[:space:]]+build/ethercat-conf.xml([[:space:]]|$)' "${HAL_PATH}"; then
  echo "Hardware gate failed: HAL does not load expected EtherCAT config (build/ethercat-conf.xml)" >&2
  exit 1
fi

if ! command -v linuxcnc >/dev/null 2>&1; then
  echo "Hardware gate failed: linuxcnc command not found" >&2
  exit 1
fi

linuxcnc --check "${INI_PATH}" >/dev/null

echo "GATE linuxcnc_config_load PASS"
echo "CONFIG_PATH=${INI_PATH}"
