#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="${ROOT_DIR}/config/profiles"
ACTIVE_PROFILE_FILE="${PROFILES_DIR}/active"
DEFAULT_PROFILE_FILE="${PROFILES_DIR}/3axis-xyz-sim.env"
BUILD_DIR="${ROOT_DIR}/build"

errors=()
deployed_files=()
compiled_comp_files=()
overall_status="success"

add_error() {
  errors+=("$1")
  overall_status="failure"
}

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
    add_error "Profile file not found: ${profile_file}"
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

emit_json() {
  local deployed_json=""
  local compiled_json=""
  local errors_json=""
  local item

  for item in "${deployed_files[@]:-}"; do
    [[ -n "${item}" ]] || continue
    [[ -n "${deployed_json}" ]] && deployed_json+=","
    deployed_json+="$(json_escape "${item}")"
  done

  for item in "${compiled_comp_files[@]:-}"; do
    [[ -n "${item}" ]] || continue
    [[ -n "${compiled_json}" ]] && compiled_json+=","
    compiled_json+="$(json_escape "${item}")"
  done

  for item in "${errors[@]:-}"; do
    [[ -n "${item}" ]] || continue
    [[ -n "${errors_json}" ]] && errors_json+=","
    errors_json+="$(json_escape "${item}")"
  done

  printf '{"status":%s,"deployed_files":[%s],"compiled_comp_files":[%s],"errors":[%s]}\n' \
    "$(json_escape "${overall_status}")" \
    "${deployed_json}" \
    "${compiled_json}" \
    "${errors_json}"
}

deploy_local() {
  local linuxcnc_dir="${LINUXCNC_DIR:-${VM_LINUXCNC_DIR:-$HOME/linuxcnc}}"
  local config_dir="${linuxcnc_dir}/configs/config"

  mkdir -p "${config_dir}"

  while IFS= read -r rel_file; do
    deployed_files+=("${rel_file}")
  done < <(cd "${BUILD_DIR}" && find . -type f | sed 's#^\./##' | sort)

  if ! rsync -a --delete "${BUILD_DIR}/" "${config_dir}/"; then
    add_error "Failed to copy build files to ${config_dir}"
    return 1
  fi

  local comp_file
  while IFS= read -r comp_file; do
    [[ -n "${comp_file}" ]] || continue
    if (cd "${config_dir}" && halcompile --install "${comp_file}") >/dev/null 2>&1; then
      compiled_comp_files+=("${comp_file}")
    else
      add_error "Failed to compile component: ${comp_file}"
      return 1
    fi
  done < <(cd "${BUILD_DIR}" && find . -type f -name '*.comp' | sed 's#^\./##' | sort)

  return 0
}

deploy_ssh() {
  VM_SSH_HOST="${VM_SSH_HOST:-localhost}"
  VM_SSH_PORT="${VM_SSH_PORT:-2222}"
  VM_SSH_USER="${VM_SSH_USER:-cnc}"
  VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
  VM_LINUXCNC_DIR="${VM_LINUXCNC_DIR:-/home/cnc/linuxcnc}"

  if [[ ! -f "${VM_SSH_KEY}" ]]; then
    add_error "SSH key not found: ${VM_SSH_KEY}"
    return 1
  fi

  while IFS= read -r rel_file; do
    deployed_files+=("${rel_file}")
  done < <(cd "${BUILD_DIR}" && find . -type f | sed 's#^\./##' | sort)

  local ssh_opts=(
    -i "${VM_SSH_KEY}"
    -p "${VM_SSH_PORT}"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
  )

  if ! ssh "${ssh_opts[@]}" "${VM_SSH_USER}@${VM_SSH_HOST}" "mkdir -p '${VM_LINUXCNC_DIR}/configs/config'" >/dev/null 2>&1; then
    add_error "Failed to create remote directory: ${VM_LINUXCNC_DIR}/configs/config"
    return 1
  fi

  if ! rsync -az --delete -e "ssh -i ${VM_SSH_KEY} -p ${VM_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
      "${BUILD_DIR}/" "${VM_SSH_USER}@${VM_SSH_HOST}:${VM_LINUXCNC_DIR}/configs/config/" >/dev/null 2>&1; then
    add_error "Failed to rsync build directory to ${VM_SSH_HOST}:${VM_LINUXCNC_DIR}/configs/config"
    return 1
  fi

  local comp_file
  while IFS= read -r comp_file; do
    [[ -n "${comp_file}" ]] || continue
    if ssh "${ssh_opts[@]}" "${VM_SSH_USER}@${VM_SSH_HOST}" \
      "cd '${VM_LINUXCNC_DIR}/configs/config' && halcompile --install '${comp_file}'" >/dev/null 2>&1; then
      compiled_comp_files+=("${comp_file}")
    else
      add_error "Failed to compile component: ${comp_file}"
      return 1
    fi
  done < <(cd "${BUILD_DIR}" && find . -type f -name '*.comp' | sed 's#^\./##' | sort)

  return 0
}

main() {
  local deploy_mode="local"
  for arg in "$@"; do
    case "${arg}" in
      --ssh) deploy_mode="ssh" ;;
    esac
  done

  load_profile || return 1

  if [[ ! -d "${BUILD_DIR}" ]]; then
    add_error "Build directory not found: ${BUILD_DIR}"
    return 1
  fi

  if [[ "${deploy_mode}" == "ssh" ]]; then
    deploy_ssh
  else
    deploy_local
  fi
}

if ! main "$@"; then
  emit_json
  exit 1
fi

emit_json
