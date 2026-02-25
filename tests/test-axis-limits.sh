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

read_ini_value() {
  local section="$1"
  local key="$2"

  awk -v section="${section}" -v key="${key}" '
    BEGIN { in_section=0; found=0 }
    {
      line=$0
      sub(/[;#].*$/, "", line)
      if (line ~ /^[[:space:]]*\[/) {
        in_section = (line ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
        next
      }
      if (in_section && line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        split(line, parts, "=")
        value=parts[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        found=1
        exit
      }
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "${INI_PATH}"
}

require_numeric() {
  local value="$1"
  local name="$2"
  if ! [[ "${value}" =~ ^[-+]?[0-9]+([.][0-9]+)?$ ]]; then
    echo "Invalid numeric value for ${name}: ${value}" >&2
    exit 1
  fi
}

calc_offset() {
  local value="$1"
  local delta="$2"
  awk -v value="${value}" -v delta="${delta}" 'BEGIN { printf "%.6f", value + delta }'
}

x_min="$(read_ini_value "JOINT_0" "MIN_LIMIT")"
x_max="$(read_ini_value "JOINT_0" "MAX_LIMIT")"
y_min="$(read_ini_value "JOINT_1" "MIN_LIMIT")"
y_max="$(read_ini_value "JOINT_1" "MAX_LIMIT")"
z_min="$(read_ini_value "JOINT_2" "MIN_LIMIT")"
z_max="$(read_ini_value "JOINT_2" "MAX_LIMIT")"

require_numeric "${x_min}" "JOINT_0 MIN_LIMIT"
require_numeric "${x_max}" "JOINT_0 MAX_LIMIT"
require_numeric "${y_min}" "JOINT_1 MIN_LIMIT"
require_numeric "${y_max}" "JOINT_1 MAX_LIMIT"
require_numeric "${z_min}" "JOINT_2 MIN_LIMIT"
require_numeric "${z_max}" "JOINT_2 MAX_LIMIT"

x_over_max="$(calc_offset "${x_max}" "1")"
x_below_min="$(calc_offset "${x_min}" "-1")"
y_over_max="$(calc_offset "${y_max}" "1")"
y_below_min="$(calc_offset "${y_min}" "-1")"
z_over_max="$(calc_offset "${z_max}" "1")"
z_below_min="$(calc_offset "${z_min}" "-1")"

tmp_gcode="$(mktemp)"
tmp_log="$(mktemp)"
trap 'rm -f "${tmp_gcode}" "${tmp_log}"' EXIT

cat >"${tmp_gcode}" <<EOF_GCODE
G90
G1 X${x_over_max} F100
G1 X${x_below_min} F100
G1 Y${y_over_max} F100
G1 Y${y_below_min} F100
G1 Z${z_over_max} F100
G1 Z${z_below_min} F100
M2
EOF_GCODE

batch_commands=(
  "linuxcnc --batch \"${INI_PATH}\" \"${tmp_gcode}\""
  "linuxcnc -b \"${INI_PATH}\" \"${tmp_gcode}\""
)

batch_ran=false
run_status=0
for batch_command in "${batch_commands[@]}"; do
  set +e
  eval "${batch_command}" >"${tmp_log}" 2>&1
  cmd_status=$?
  set -e

  if grep -Eqi '(unrecognized|unknown|invalid)[[:space:]]+(option|argument)|usage:.*linuxcnc' "${tmp_log}"; then
    continue
  fi

  batch_ran=true
  run_status=${cmd_status}
  break
done

if [[ "${batch_ran}" != "true" ]]; then
  echo "LinuxCNC batch run failed for all supported invocation forms" >&2
  cat "${tmp_log}" >&2
  exit 1
fi

limit_rejection_regex='(soft[[:space:]_-]*limit|limit[[:space:]_-]*(violat|exceed|trip|error)|outside[[:space:]]+.*limit|out[[:space:]_-]*of[[:space:]_-]*range|joint[[:space:]_-]*[0-9]+.*limit|axis[[:space:]_-]*[xyz].*limit|cannot[[:space:]]+.*move)'

if (( run_status == 0 )) && ! grep -Eqi "${limit_rejection_regex}" "${tmp_log}"; then
  echo "Expected axis limit rejection, but LinuxCNC batch run succeeded without limit violation evidence" >&2
  cat "${tmp_log}" >&2
  exit 1
fi
