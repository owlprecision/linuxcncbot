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

tmp_gcode="$(mktemp)"
tmp_log="$(mktemp)"
trap 'rm -f "${tmp_gcode}" "${tmp_log}"' EXIT

cat >"${tmp_gcode}" <<'EOF'
G0 X10 Y10 Z-5
G1 X20 F100
M2
EOF

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

  if (( cmd_status == 0 )); then
    batch_ran=true
    break
  fi
done

if [[ "${batch_ran}" != "true" ]]; then
  echo "LinuxCNC batch run failed for all supported invocation forms" >&2
  cat "${tmp_log}" >&2
  exit 1
fi

if grep -Eqi '(^|[^[:alpha:]])(error|failed|failure|fatal)([^[:alpha:]]|$)' "${tmp_log}"; then
  echo "LinuxCNC batch run reported errors in logs" >&2
  cat "${tmp_log}" >&2
  exit 1
fi
