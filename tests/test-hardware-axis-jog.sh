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
  echo "GATE axis_enable_jog_low_speed SKIP profile_mode=${PROFILE_MODE:-sim}"
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

if ! grep -Fq 'joint.0.amp-enable-out' "${HAL_PATH}" || ! grep -Fq 'joint.1.amp-enable-out' "${HAL_PATH}"; then
  echo "Hardware gate failed: HAL missing joint amp-enable wiring for hardware axes" >&2
  exit 1
fi

if ! command -v linuxcnc >/dev/null 2>&1; then
  echo "Hardware gate failed: linuxcnc command not found" >&2
  exit 1
fi

tmp_gcode="$(mktemp)"
tmp_log="$(mktemp)"
trap 'rm -f "${tmp_gcode}" "${tmp_log}"' EXIT

cat >"${tmp_gcode}" <<'EOF_GCODE'
G90
G1 F60
G1 X0.50
G1 X0.00
G1 Y0.50
G1 Y0.00
M2
EOF_GCODE

batch_commands=(
  "linuxcnc --batch \"${INI_PATH}\" \"${tmp_gcode}\""
  "linuxcnc -b \"${INI_PATH}\" \"${tmp_gcode}\""
)

batch_ran=false
for batch_command in "${batch_commands[@]}"; do
  set +e
  eval "${batch_command}" >"${tmp_log}" 2>&1
  cmd_status=$?
  set -e

  if grep -Eqi '(unrecognized|unknown|invalid)[[:space:]]+(option|argument)|usage:.*linuxcnc' "${tmp_log}"; then
    continue
  fi

  batch_ran=true
  if (( cmd_status != 0 )); then
    echo "Hardware gate failed: low-speed jog batch run exited ${cmd_status}" >&2
    cat "${tmp_log}" >&2
    exit 1
  fi
  break
done

if [[ "${batch_ran}" != "true" ]]; then
  echo "Hardware gate failed: LinuxCNC batch run unsupported for low-speed jog gate" >&2
  cat "${tmp_log}" >&2
  exit 1
fi

if grep -Eqi '(^|[^[:alpha:]])(error|failed|failure|fatal|fault|ferror)([^[:alpha:]]|$)' "${tmp_log}"; then
  echo "Hardware gate failed: low-speed jog log contains error indicators" >&2
  cat "${tmp_log}" >&2
  exit 1
fi

echo "GATE axis_enable_jog_low_speed PASS"
echo "JOG_FEED=60"
echo "JOG_AXES=XY"
