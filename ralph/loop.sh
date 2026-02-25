#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_FILE="$REPO_ROOT/PLAN.md"
VERIFY_SCRIPT="$SCRIPT_DIR/verify.sh"
UPDATE_PLAN_SCRIPT="$SCRIPT_DIR/update-plan.sh"
COMMIT_SCRIPT="$SCRIPT_DIR/commit.sh"

json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_array_from_lines() {
  local input="${1:-}"
  local out=""
  local first=true

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$first" == true ]]; then
      first=false
    else
      out+=","
    fi
    out+="\"$(json_escape "$line")\""
  done <<< "$input"

  printf '[%s]' "$out"
}

task_line_to_id() {
  local task_line="$1"
  sed -E 's/.*\*\*([^*]+)\*\*.*/\1/' <<< "$task_line"
}

extract_task_block_by_line() {
  local line_num="$1"
  local task_line
  task_line="$(sed -n "${line_num}p" "$PLAN_FILE")"

  local block_lines=""
  local next_line=$((line_num + 1))

  while true; do
    local line
    line="$(sed -n "${next_line}p" "$PLAN_FILE")"

    if [[ -z "$line" ]]; then
      break
    fi

    if [[ "$line" =~ ^-\ [⬜🔄✅❌]\ \*\* ]] || [[ "$line" =~ ^##\  ]]; then
      break
    fi

    block_lines+="$line"$'\n'
    next_line=$((next_line + 1))
  done

  printf '%s\n' "$task_line"
  printf '%s' "$block_lines"
}

find_first_pending() {
  grep -n "^- ⬜ \*\*" "$PLAN_FILE" | head -1 || true
}

find_first_in_progress() {
  grep -n "^- 🔄 \*\*" "$PLAN_FILE" | head -1 || true
}

build_task_json_by_line() {
  local line_num="$1"
  local task_block
  task_block="$(extract_task_block_by_line "$line_num")"

  local task_line
  task_line="$(head -n 1 <<< "$task_block")"
  local task_id
  task_id="$(task_line_to_id "$task_line")"

  local instructions
  instructions="$(tail -n +2 <<< "$task_block")"

  local instruction_lines_json
  instruction_lines_json="$(json_array_from_lines "$instructions")"

  printf '{"id":"%s","line":%s,"task_line":"%s","instructions":%s}' \
    "$(json_escape "$task_id")" \
    "$line_num" \
    "$(json_escape "$task_line")" \
    "$instruction_lines_json"
}

cmd_next() {
  local next_match
  next_match="$(find_first_pending)"

  if [[ -z "$next_match" ]]; then
    printf '{"command":"next","status":"complete","message":"No pending tasks found","task":null}\n'
    return 0
  fi

  local line_num
  line_num="${next_match%%:*}"
  local task_json
  task_json="$(build_task_json_by_line "$line_num")"
  printf '{"command":"next","status":"ok","task":%s}\n' "$task_json"
}

cmd_status() {
  local done in_progress pending failed total completed_percent
  done=$(grep -c "^- ✅" "$PLAN_FILE" || true)
  in_progress=$(grep -c "^- 🔄" "$PLAN_FILE" || true)
  pending=$(grep -c "^- ⬜" "$PLAN_FILE" || true)
  failed=$(grep -c "^- ❌" "$PLAN_FILE" || true)

  done=${done:-0}
  in_progress=${in_progress:-0}
  pending=${pending:-0}
  failed=${failed:-0}
  total=$((done + in_progress + pending + failed))

  if [[ "$total" -eq 0 ]]; then
    completed_percent=0
  else
    completed_percent=$((done * 100 / total))
  fi

  printf '{"command":"status","status":"ok","counts":{"done":%s,"in_progress":%s,"pending":%s,"failed":%s,"total":%s},"progress":{"completed":%s,"percent":%s}}\n' \
    "$done" "$in_progress" "$pending" "$failed" "$total" "$done" "$completed_percent"
}

get_current_in_progress_task() {
  local current
  current="$(find_first_in_progress)"
  if [[ -z "$current" ]]; then
    return 1
  fi

  local line_num task_line task_id
  line_num="${current%%:*}"
  task_line="$(sed -n "${line_num}p" "$PLAN_FILE")"
  task_id="$(task_line_to_id "$task_line")"

  printf '%s\t%s\t%s\n' "$line_num" "$task_id" "$task_line"
}

mark_first_pending_in_progress() {
  local next_match
  next_match="$(find_first_pending)"
  if [[ -z "$next_match" ]]; then
    return 1
  fi

  local line_num task_line task_id
  line_num="${next_match%%:*}"
  task_line="$(sed -n "${line_num}p" "$PLAN_FILE")"
  task_id="$(task_line_to_id "$task_line")"

  "$UPDATE_PLAN_SCRIPT" "$task_id" "in-progress" "Started by ralph/loop.sh run" >/dev/null
  printf '%s\n' "$task_id"
}

cmd_verify() {
  if [[ ! -x "$VERIFY_SCRIPT" ]]; then
    printf '{"command":"verify","status":"error","message":"ralph/verify.sh not found or not executable"}\n'
    return 1
  fi

  local current_info
  if ! current_info="$(get_current_in_progress_task)"; then
    printf '{"command":"verify","status":"error","message":"No in-progress task found in PLAN.md"}\n'
    return 1
  fi

  local _line_num task_id _task_line
  _line_num="$(cut -f1 <<< "$current_info")"
  task_id="$(cut -f2 <<< "$current_info")"
  _task_line="$(cut -f3- <<< "$current_info")"

  local verify_output verify_rc
  set +e
  verify_output="$(bash "$VERIFY_SCRIPT" 2>&1)"
  verify_rc=$?
  set -e

  local verify_json_escaped
  verify_json_escaped="$(json_escape "$verify_output")"

  if [[ "$verify_rc" -eq 0 ]]; then
    "$UPDATE_PLAN_SCRIPT" "$task_id" "done" "verify passed via ralph/loop.sh" >/dev/null
    local commit_output
    commit_output="$(bash "$COMMIT_SCRIPT" "$task_id" "Completed: $task_id (verify passed)" 2>&1 || true)"

    printf '{"command":"verify","status":"pass","task_id":"%s","verify_exit_code":%s,"verify_output":"%s","plan_update":{"status":"done"},"commit":{"output":"%s"}}\n' \
      "$(json_escape "$task_id")" \
      "$verify_rc" \
      "$verify_json_escaped" \
      "$(json_escape "$commit_output")"
    return 0
  fi

  "$UPDATE_PLAN_SCRIPT" "$task_id" "failed" "verify failed via ralph/loop.sh" >/dev/null || true
  local fail_commit_output
  fail_commit_output="$(bash "$COMMIT_SCRIPT" "$task_id" "Failed: $task_id (verify failed)" 2>&1 || true)"

  printf '{"command":"verify","status":"fail","task_id":"%s","verify_exit_code":%s,"verify_output":"%s","plan_update":{"status":"failed"},"commit":{"output":"%s"}}\n' \
    "$(json_escape "$task_id")" \
    "$verify_rc" \
    "$verify_json_escaped" \
    "$(json_escape "$fail_commit_output")"
  return "$verify_rc"
}

cmd_run() {
  local current_info next_json verify_json verify_rc target_line target_task_json target_task_id

  if current_info="$(get_current_in_progress_task)"; then
    target_line="$(cut -f1 <<< "$current_info")"
    target_task_id="$(cut -f2 <<< "$current_info")"
    target_task_json="$(build_task_json_by_line "$target_line")"
    next_json="{\"command\":\"next\",\"status\":\"ok\",\"task\":${target_task_json}}"
  else
    local next_match
    next_match="$(find_first_pending)"
    if [[ -z "$next_match" ]]; then
      printf '{"command":"run","status":"complete","message":"No pending or in-progress tasks found"}\n'
      return 0
    fi

    target_line="${next_match%%:*}"
    target_task_json="$(build_task_json_by_line "$target_line")"
    target_task_id="$(sed -n "${target_line}p" "$PLAN_FILE" | sed -E 's/.*\*\*([^*]+)\*\*.*/\1/')"
    next_json="{\"command\":\"next\",\"status\":\"ok\",\"task\":${target_task_json}}"
    "$UPDATE_PLAN_SCRIPT" "$target_task_id" "in-progress" "Started by ralph/loop.sh run" >/dev/null
  fi

  set +e
  verify_json="$(cmd_verify)"
  verify_rc=$?
  set -e

  printf '{"command":"run","status":"%s","next":%s,"verify":%s}\n' \
    "$( [[ "$verify_rc" -eq 0 ]] && echo "pass" || echo "fail" )" \
    "$next_json" \
    "$verify_json"

  return "$verify_rc"
}

usage() {
  cat <<'__USAGE__'
Usage: ./ralph/loop.sh <subcommand>

Subcommands:
  next    Parse PLAN.md and return first pending (⬜) task with instruction block
  status  Return task counts and progress summary
  verify  Run ralph/verify.sh, update current in-progress task, and commit
  run     Execute next + verify + commit flow
__USAGE__
}

main() {
  if [[ ! -f "$PLAN_FILE" ]]; then
    printf '{"command":"unknown","status":"error","message":"PLAN.md not found"}\n'
    exit 1
  fi

  local cmd="${1:-}"
  case "$cmd" in
    next)
      cmd_next
      ;;
    status)
      cmd_status
      ;;
    verify)
      cmd_verify
      ;;
    run)
      cmd_run
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      printf '{"command":"unknown","status":"error","message":"Expected subcommand: next|status|verify|run"}\n'
      exit 1
      ;;
  esac
}

main "$@"
