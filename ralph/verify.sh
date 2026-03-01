#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="${ROOT_DIR}/config/profiles"
ACTIVE_PROFILE_FILE="${PROFILES_DIR}/active"
DEFAULT_PROFILE_FILE="${PROFILES_DIR}/3axis-xyz-sim.env"
TEST_SCRIPT="${ROOT_DIR}/ralph/test.sh"

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
    return 1
  fi

  # shellcheck source=/dev/null
  set -a
  source "${profile_file}"
  set +a
}

run_tests() {
  local output
  local status

  set +e
  output="$(bash "${TEST_SCRIPT}" 2>&1)"
  status=$?
  set -e

  TEST_JSON_RAW="${output}"
  TEST_EXIT_CODE="${status}"
}

collect_hal_pins() {
  if [[ "${DEPLOY_MODE:-local}" == "ssh" ]]; then
    collect_hal_pins_ssh
  else
    collect_hal_pins_local
  fi
}

collect_hal_pins_local() {
  HAL_PIN_STATUS="error"
  HAL_PIN_OUTPUT=""

  local hal_output
  local hal_status

  set +e
  hal_output="$(halcmd show pin 2>&1)"
  hal_status=$?
  set -e

  if [[ ${hal_status} -eq 0 ]]; then
    HAL_PIN_STATUS="ok"
    HAL_PIN_OUTPUT="${hal_output}"
  else
    HAL_PIN_OUTPUT="HAL pin dump unavailable: 'halcmd show pin' failed. Output: ${hal_output}"
  fi
}

collect_hal_pins_ssh() {
  VM_SSH_HOST="${VM_SSH_HOST:-localhost}"
  VM_SSH_PORT="${VM_SSH_PORT:-2222}"
  VM_SSH_USER="${VM_SSH_USER:-cnc}"
  VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"

  HAL_PIN_STATUS="error"
  HAL_PIN_OUTPUT=""

  if [[ ! -f "${VM_SSH_KEY}" ]]; then
    HAL_PIN_OUTPUT="HAL pin dump unavailable: SSH key not found: ${VM_SSH_KEY}"
    return 0
  fi

  local -a ssh_opts=(
    -i "${VM_SSH_KEY}"
    -p "${VM_SSH_PORT}"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
  )

  local hal_output
  local hal_status

  set +e
  hal_output="$(ssh "${ssh_opts[@]}" "${VM_SSH_USER}@${VM_SSH_HOST}" "halcmd show pin" 2>&1)"
  hal_status=$?
  set -e

  if [[ ${hal_status} -eq 0 ]]; then
    HAL_PIN_STATUS="ok"
    HAL_PIN_OUTPUT="${hal_output}"
  else
    HAL_PIN_OUTPUT="HAL pin dump unavailable: failed to run 'halcmd show pin' on ${VM_SSH_USER}@${VM_SSH_HOST}:${VM_SSH_PORT}. SSH/command output: ${hal_output}"
  fi
}

emit_report() {
  REPORT_JSON="$(TEST_JSON_RAW="${TEST_JSON_RAW}" TEST_EXIT_CODE="${TEST_EXIT_CODE}" HAL_PIN_STATUS="${HAL_PIN_STATUS}" HAL_PIN_OUTPUT="${HAL_PIN_OUTPUT}" python3 - <<'PY'
import json
import os

raw = os.environ.get("TEST_JSON_RAW", "")
try:
    test_exit_code = int(os.environ.get("TEST_EXIT_CODE", "1"))
except ValueError:
    test_exit_code = 1

hal_status = os.environ.get("HAL_PIN_STATUS", "error")
hal_output = os.environ.get("HAL_PIN_OUTPUT", "")

parse_error = None
try:
    parsed = json.loads(raw)
    if not isinstance(parsed, list):
        raise ValueError("test output JSON is not an array")
except Exception as exc:
    parsed = [{
        "name": "test.sh",
        "status": "fail",
        "output": f"Failed to parse ralph/test.sh JSON output. Raw output: {raw}",
    }]
    parse_error = str(exc)

results = []
for item in parsed:
    if not isinstance(item, dict):
        item = {}
    name = str(item.get("name", "unnamed-test"))
    status = str(item.get("status", "fail")).lower()
    if status not in ("pass", "fail"):
        status = "fail"
    output = str(item.get("output", ""))
    results.append({"name": name, "status": status, "output": output})

all_tests_pass = (parse_error is None and test_exit_code == 0 and all(r["status"] == "pass" for r in results))
overall = "PASS" if all_tests_pass else "FAIL"

def excerpt(text: str, lines: int = 5, limit: int = 500) -> str:
    chunk = "\n".join(text.splitlines()[:lines])
    if len(chunk) > limit:
        return chunk[:limit] + "..."
    return chunk

log_excerpts = []
for r in results:
    log_excerpts.append({
        "name": r["name"],
        "status": r["status"],
        "excerpt": excerpt(r["output"]),
    })

suggested_fixes = []
for r in results:
    if r["status"] == "pass":
        continue
    blob = f"{r['name']}\n{r['output']}".lower()
    suggestions = []
    if "ssh" in blob or "connection refused" in blob or "timed out" in blob:
        suggestions.append("Verify VM is running and SSH connectivity matches VM_SSH_HOST/PORT/USER/KEY profile values.")
    if "key" in blob and "not found" in blob:
        suggestions.append("Generate or point VM_SSH_KEY to a valid private key and ensure file permissions allow SSH usage.")
    if "rsync" in blob:
        suggestions.append("Check rsync availability on host/VM and confirm remote target directories exist and are writable.")
    if "linuxcnc" in blob or "hal" in blob or "halcmd" in blob:
        suggestions.append("Re-run configure/deploy and inspect generated machine.ini/machine.hal/sim.hal for profile placeholder or syntax issues.")
    if "profile" in blob:
        suggestions.append("Confirm config/profiles/active points to a valid .env file and required variables are defined.")
    if not suggestions:
        suggestions.append("Inspect full test output and rerun failing test manually for targeted diagnosis.")

    suggested_fixes.append({
        "name": r["name"],
        "suggestions": suggestions,
    })

report = {
    "overall": overall,
    "all_tests_pass": all_tests_pass,
    "test_exit_code": test_exit_code,
    "tests": results,
    "hal_pin_dump": {
        "status": hal_status,
        "output": hal_output,
    },
    "log_excerpts": log_excerpts,
    "suggested_fixes": suggested_fixes,
}

if parse_error is not None:
    report["parse_error"] = parse_error

print(json.dumps(report, separators=(",", ":")))
PY
)"

  printf '%s\n' "${REPORT_JSON}"
}

main() {
  DEPLOY_MODE="local"
  for arg in "$@"; do
    case "${arg}" in
      --ssh) DEPLOY_MODE="ssh" ;;
    esac
  done

  if ! load_profile; then
    TEST_JSON_RAW='[{"name":"setup","status":"fail","output":"Profile file not found while loading active/default profile."}]'
    TEST_EXIT_CODE=1
  else
    run_tests
  fi

  collect_hal_pins
  emit_report

  if python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("all_tests_pass") else 1)' <<<"${REPORT_JSON}"; then
    exit 0
  fi

  exit 1
}

main "$@"
