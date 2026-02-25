#!/usr/bin/env bash
# Ralph Loop — autonomous AI coding agent orchestrator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_FILE="$REPO_ROOT/PLAN.md"
PROGRESS_FILE="$REPO_ROOT/ralph/progress.txt"
PROMPT_FILE="$SCRIPT_DIR/PROMPT_build.md"
AGENTS_DIR="$REPO_ROOT/.github/agents"
COMPLETE_SIGNAL='<promise>COMPLETE</promise>'

# Defaults
MAX_ITERATIONS=0   # 0 = unlimited
MODEL=""
DRY_RUN=false
MODE="run"
SHOW_COPILOT_OUTPUT=true

CAFFEINATE_PID=""
CURRENT_TASK_ID=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; WHITE='\033[1;37m'; NC='\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) MODE="status"; shift ;;
    --next) MODE="next"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    --quiet-copilot) SHOW_COPILOT_OUTPUT=false; shift ;;
    -h|--help) MODE="help"; shift ;;
    [0-9]*) MAX_ITERATIONS="$1"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

start_caffeinate() {
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -s &
    CAFFEINATE_PID=$!
    echo -e "  ${GRAY}caffeinate started (PID $CAFFEINATE_PID) — system won't sleep${NC}"
  fi
}

stop_caffeinate() {
  if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
    wait "$CAFFEINATE_PID" 2>/dev/null || true
    CAFFEINATE_PID=""
  fi
}

cleanup() {
  local exit_code=$?
  stop_caffeinate
  if [[ -n "${CURRENT_TASK_ID:-}" ]]; then
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat >> "$PROGRESS_FILE" <<EOT

--- interrupted ($ts) ---
Task: ${CURRENT_TASK_ID}
Status: INTERRUPTED
Summary: Loop stopped (signal/Ctrl+C). Task left as 🔄 in-progress. Re-run to resume.
EOT
    "$SCRIPT_DIR/commit.sh" "$CURRENT_TASK_ID" "WIP: $CURRENT_TASK_ID (interrupted)" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

trap cleanup EXIT INT TERM

show_status() { "$SCRIPT_DIR/update-plan.sh" --status; }
show_next() { "$SCRIPT_DIR/update-plan.sh" --next; }

show_help() {
  cat <<EOT
Usage:
  ./ralph/loop.sh                    Run until done or Ctrl+C
  ./ralph/loop.sh 1                  Run exactly one full step
  ./ralph/loop.sh 5                  Run up to 5 steps
  ./ralph/loop.sh --status           Show task status
  ./ralph/loop.sh --next             Show next task
  ./ralph/loop.sh --dry-run          Show prompt, do not invoke Copilot
  ./ralph/loop.sh --model <model>    Force model for this run
  ./ralph/loop.sh --quiet-copilot    Hide live Copilot output
EOT
  exit 0
}

ensure_progress_file() {
  if [[ ! -f "$PROGRESS_FILE" ]]; then
    cat > "$PROGRESS_FILE" <<'EOT'
# Ralph Loop Progress Log
# Append-only log; last 20 lines are fed to Copilot each iteration.
EOT
  fi
}

get_progress_tail() {
  if [[ -f "$PROGRESS_FILE" ]]; then tail -20 "$PROGRESS_FILE"; else echo "(no previous progress)"; fi
}

find_next_task() {
  local in_progress
  in_progress=$(grep -n "^- 🔄 \*\*" "$PLAN_FILE" | head -1) || true
  if [[ -n "$in_progress" ]]; then echo "$in_progress"; return; fi
  grep -n "^- ⬜ \*\*" "$PLAN_FILE" | head -1
}

extract_task_block() {
  local line_num="$1"
  local task_line
  task_line=$(sed -n "${line_num}p" "$PLAN_FILE")
  local block=""
  local next_line=$((line_num + 1))
  while true; do
    local l
    l=$(sed -n "${next_line}p" "$PLAN_FILE") || break
    if [[ "$l" =~ ^-\ [⬜🔄✅❌] ]] || [[ "$l" =~ ^## ]] || [[ -z "$l" ]]; then break; fi
    block+="$l"$'\n'
    next_line=$((next_line + 1))
  done
  echo "$task_line"
  echo "$block"
}

extract_task_id() { echo "$1" | sed 's/.*\*\*\([^*]*\)\*\*.*/\1/'; }

list_available_agents() {
  if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "- (none found in .github/agents/)"
    return
  fi
  local found=0
  while IFS= read -r f; do
    found=1
    echo "- $(basename "$f" .agent.md)"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -name "*.agent.md" -type f | sort)
  if [[ "$found" -eq 0 ]]; then echo "- (none found in .github/agents/)"; fi
}

build_prompt() {
  local task_block="$1"
  local progress_tail="$2"
  local is_resume="$3"
  local available_agents="$4"
  local template
  template=$(cat "$PROMPT_FILE")

  local resume_note=""
  if [[ "$is_resume" == "true" ]]; then
    resume_note="
## IMPORTANT: RESUMING INTERRUPTED TASK

This task was previously started but interrupted (marked 🔄 in PLAN.md).
Check progress log and git log; continue from current state.
"
  fi

  cat <<EOT
$template
$resume_note
## AVAILABLE CUSTOM AGENTS

Choose and delegate to the most appropriate custom agent(s) below for this task.

$available_agents

## YOUR ASSIGNED TASK FOR THIS ITERATION

$task_block

## RECENT PROGRESS (last 20 lines of ralph/progress.txt)

$progress_tail
EOT
}

invoke_copilot() {
  local prompt="$1"
  local cli_args=(-p "$prompt" --allow-all-tools --no-ask-user)
  [[ -n "$MODEL" ]] && cli_args+=(--model "$MODEL")

  local tmp_out rc
  tmp_out="$(mktemp)"
  rc=0
  if [[ "$SHOW_COPILOT_OUTPUT" == "true" ]]; then
    copilot "${cli_args[@]}" 2>&1 | tee "$tmp_out" >&2 || rc=$?
  else
    copilot "${cli_args[@]}" >"$tmp_out" 2>&1 || rc=$?
  fi
  cat "$tmp_out"
  rm -f "$tmp_out"
  return "$rc"
}

log_progress() {
  local iteration="$1" task_id="$2" status="$3" summary="$4"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat >> "$PROGRESS_FILE" <<EOT

--- iteration ${iteration} (${timestamp}) ---
Task: ${task_id}
Status: ${status}
Summary: ${summary}
EOT
}

case "$MODE" in
  status) show_status; exit 0 ;;
  next) show_next; exit 0 ;;
  help) show_help ;;
esac

command -v copilot >/dev/null 2>&1 || { echo "ERROR: copilot CLI not found"; exit 1; }
[[ -f "$PLAN_FILE" ]] || { echo "ERROR: PLAN.md not found"; exit 1; }
[[ -f "$PROMPT_FILE" ]] || { echo "ERROR: ralph/PROMPT_build.md not found"; exit 1; }

ensure_progress_file

ITERATION=0
COMPLETE=false
SESSION_START=$(date +%s)
LIMIT_DISPLAY="$MAX_ITERATIONS"
[[ "$MAX_ITERATIONS" -eq 0 ]] && LIMIT_DISPLAY="unlimited (Ctrl+C to stop)"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}  RALPH LOOP — LinuxCNC Bot${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  Max iterations: ${YELLOW}${LIMIT_DISPLAY}${NC}"
echo -e "  Model:          ${YELLOW}${MODEL:-default}${NC}"
echo -e "  Dry run:        ${YELLOW}${DRY_RUN}${NC}"
echo -e "  Stream output:  ${YELLOW}${SHOW_COPILOT_OUTPUT}${NC}"

[[ "$DRY_RUN" != "true" ]] && start_caffeinate

show_status

while true; do
  if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then break; fi
  ITERATION=$((ITERATION + 1))
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

  echo ""
  if [[ "$MAX_ITERATIONS" -gt 0 ]]; then
    echo -e "${CYAN}═══ [$TIMESTAMP] Iteration $ITERATION / $MAX_ITERATIONS ═══${NC}"
  else
    echo -e "${CYAN}═══ [$TIMESTAMP] Iteration $ITERATION ═══${NC}"
  fi

  next_task_match=$(find_next_task)
  if [[ -z "$next_task_match" ]]; then COMPLETE=true; break; fi

  line_num=$(echo "$next_task_match" | cut -d: -f1)
  task_block=$(extract_task_block "$line_num")
  task_first_line=$(echo "$task_block" | head -1)
  task_id=$(extract_task_id "$task_first_line")
  is_resume=false
  [[ "$task_first_line" == *"🔄"* ]] && is_resume=true

  echo -e "  Task: ${WHITE}${task_id}${NC}"
  echo -e "  ${GRAY}${task_first_line}${NC}"
  echo -e "  Agent strategy: ${WHITE}AI-selected delegation${NC}"

  CURRENT_TASK_ID="$task_id"
  progress_tail=$(get_progress_tail)
  available_agents=$(list_available_agents)
  prompt=$(build_prompt "$task_block" "$progress_tail" "$is_resume" "$available_agents")

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "$prompt"
    CURRENT_TASK_ID=""
    exit 0
  fi

  "$SCRIPT_DIR/update-plan.sh" "$task_id" "in-progress" "Starting iteration $ITERATION" >/dev/null 2>&1 || true

  START_TIME=$(date +%s)
  OUTPUT=$(invoke_copilot "$prompt")
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  if echo "$OUTPUT" | grep -q "$COMPLETE_SIGNAL"; then
    "$SCRIPT_DIR/update-plan.sh" "$task_id" "done" "Completed in iteration $ITERATION (${DURATION}s)" >/dev/null 2>&1 || true
    log_progress "$ITERATION" "$task_id" "PASSED" "Completed successfully in ${DURATION}s"
    "$SCRIPT_DIR/commit.sh" "$task_id" "Completed: $task_id" >/dev/null 2>&1 || true
  else
    summary=$(echo "$OUTPUT" | tail -5 | tr '\n' ' ')
    log_progress "$ITERATION" "$task_id" "INCOMPLETE" "$summary"
    "$SCRIPT_DIR/commit.sh" "$task_id" "WIP: $task_id (iteration $ITERATION)" >/dev/null 2>&1 || true
  fi

  CURRENT_TASK_ID=""
  sleep 2
done

CURRENT_TASK_ID=""
SESSION_END=$(date +%s)
TOTAL_DURATION=$((SESSION_END - SESSION_START))

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}  SESSION COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  Iterations: ${YELLOW}${ITERATION}${NC}"
echo -e "  Duration:   ${YELLOW}$((TOTAL_DURATION / 60))m $((TOTAL_DURATION % 60))s${NC}"
show_status

if [[ "$COMPLETE" == "true" ]]; then
  echo -e "  ${GREEN}✓ ALL TASKS COMPLETED${NC}"
  exit 0
else
  if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    echo -e "  ${GREEN}✓ Requested step limit completed successfully.${NC}"
    echo -e "  ${GRAY}  More tasks remain. Re-run to continue.${NC}"
    exit 0
  fi
  echo -e "  ${YELLOW}◐ Loop stopped before completion.${NC}"
  exit 1
fi
