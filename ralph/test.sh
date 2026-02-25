#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="${ROOT_DIR}/config/profiles"
ACTIVE_PROFILE_FILE="${PROFILES_DIR}/active"
DEFAULT_PROFILE_FILE="${PROFILES_DIR}/3axis-xyz-sim.env"
TESTS_DIR="${ROOT_DIR}/tests"

results=()
overall_status=0

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
    add_result "setup" "fail" "Profile file not found: ${profile_file}"
    overall_status=1
    return 1
  fi

  # shellcheck source=/dev/null
  set -a
  source "${profile_file}"
  set +a
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

add_result() {
  local name="$1"
  local status="$2"
  local output="$3"
  results+=("$(printf '{"name":%s,"status":%s,"output":%s}' \
    "$(json_escape "${name}")" \
    "$(json_escape "${status}")" \
    "$(json_escape "${output}")")")
}

emit_json() {
  local json=""
  local item

  for item in "${results[@]:-}"; do
    [[ -n "${item}" ]] || continue
    [[ -n "${json}" ]] && json+=","
    json+="${item}"
  done

  printf '[%s]\n' "${json}"
}

main() {
  load_profile || return 1

  VM_SSH_HOST="${VM_SSH_HOST:-localhost}"
  VM_SSH_PORT="${VM_SSH_PORT:-2222}"
  VM_SSH_USER="${VM_SSH_USER:-cnc}"
  VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
  VM_LINUXCNC_DIR="${VM_LINUXCNC_DIR:-/home/cnc/linuxcnc}"
  REMOTE_TESTS_DIR="${VM_LINUXCNC_DIR}/tests"

  if [[ ! -d "${TESTS_DIR}" ]]; then
    add_result "setup" "fail" "Local tests directory not found: ${TESTS_DIR}"
    overall_status=1
    return 1
  fi

  if [[ ! -f "${VM_SSH_KEY}" ]]; then
    add_result "setup" "fail" "SSH key not found: ${VM_SSH_KEY}"
    overall_status=1
    return 1
  fi

  local -a test_files=()
  mapfile -t test_files < <(find "${TESTS_DIR}" -maxdepth 1 -type f -name '*.sh' -print | sort)

  local ssh_opts=(
    -i "${VM_SSH_KEY}"
    -p "${VM_SSH_PORT}"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
  )

  if ! ssh "${ssh_opts[@]}" "${VM_SSH_USER}@${VM_SSH_HOST}" "mkdir -p '${REMOTE_TESTS_DIR}'" >/dev/null 2>&1; then
    add_result "setup" "fail" "Failed to create remote tests directory: ${REMOTE_TESTS_DIR}"
    overall_status=1
    return 1
  fi

  if ! rsync -az --delete -e "ssh -i ${VM_SSH_KEY} -p ${VM_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
      "${TESTS_DIR}/" "${VM_SSH_USER}@${VM_SSH_HOST}:${REMOTE_TESTS_DIR}/" >/dev/null 2>&1; then
    add_result "setup" "fail" "Failed to sync tests to ${VM_SSH_HOST}:${REMOTE_TESTS_DIR}"
    overall_status=1
    return 1
  fi

  local test_path
  for test_path in "${test_files[@]:-}"; do
    local test_name
    local output
    local status

    test_name="$(basename "${test_path}")"

    set +e
    output="$(ssh "${ssh_opts[@]}" "${VM_SSH_USER}@${VM_SSH_HOST}" \
      "cd '${REMOTE_TESTS_DIR}' && bash './${test_name}'" 2>&1)"
    status=$?
    set -e

    if [[ ${status} -eq 0 ]]; then
      add_result "${test_name}" "pass" "${output}"
    else
      add_result "${test_name}" "fail" "${output}"
      overall_status=1
    fi
  done

  return 0
}

if ! main; then
  emit_json
  exit 1
fi

emit_json

if [[ ${overall_status} -ne 0 ]]; then
  exit 1
fi
