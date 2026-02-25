#!/usr/bin/env bash
# Ralph Loop — autonomous AI coding agent orchestrator
#
# Repeatedly invokes GitHub Copilot CLI with fresh context, reading PLAN.md
# to find the next task, executing it, and checking for a completion signal.
# Each iteration gets a fresh context window. State persists via files + git.
#
# Usage:
#   ./ralph/loop.sh              # Run until done or Ctrl+C (unlimited)
#   ./ralph/loop.sh 1            # Run exactly 1 step
#   ./ralph/loop.sh 5            # Run up to 5 steps
#   ./ralph/loop.sh --status     # Show plan status
#   ./ralph/loop.sh --next       # Show next task (no execution)
#   ./ralph/loop.sh --dry-run    # Preview prompt without invoking copilot
#   ./ralph/loop.sh --model X    # Use specific AI model
#   ./ralph/loop.sh --quiet-copilot # Hide live copilot output
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_FILE="$REPO_ROOT/PLAN.md"
PROGRESS_FILE="$REPO_ROOT/ralph/progress.txt"
PROMPT_FILE="$SCRIPT_DIR/PROMPT_build.md"
COMPLETE_SIGNAL='<promise>COMPLETE</promise>'

# Defaults — 0 means unlimited (run until done or Ctrl+C)
MAX_ITERATIONS=0
MODEL=""
DRY_RUN=false
MODE="run"
SHOW_COPILOT_OUTPUT=true

# Caffeinate PID (to clean up on exit)
CAFFEINATE_PID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════════
#                     ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
    case $1 in
        --status)    MODE="status"; shift ;;
        --next)      MODE="next"; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --model)     MODEL="$2"; shift 2 ;;
        --quiet-copilot) SHOW_COPILOT_OUTPUT=false; shift ;;
        -h|--help)   MODE="help"; shift ;;
        [0-9]*)      MAX_ITERATIONS="$1"; shift ;;
        *)           echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ═══════════════════════════════════════════════════════════════
#                     CAFFEINATE & CLEANUP
# ═══════════════════════════════════════════════════════════════

start_caffeinate() {
    # Prevent macOS sleep while loop runs (display can sleep, system stays awake)
    if command -v caffeinate &>/dev/null; then
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
    # Log interruption if we were mid-iteration
    if [[ -n "${CURRENT_TASK_ID:-}" ]]; then
        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        cat >> "$PROGRESS_FILE" <<EOF

--- interrupted ($ts) ---
Task: ${CURRENT_TASK_ID}
Status: INTERRUPTED
Summary: Loop stopped (signal/Ctrl+C). Task left as 🔄 in-progress. Re-run to resume.
EOF
        echo ""
        echo -e "${YELLOW}  Interrupted during task: ${CURRENT_TASK_ID}${NC}"
        echo -e "${GRAY}  Task left as 🔄 in-progress in PLAN.md${NC}"
        echo -e "${GRAY}  Re-run ./ralph/loop.sh to pick up where you left off${NC}"

        # Commit any partial work so nothing is lost
        "$SCRIPT_DIR/commit.sh" "$CURRENT_TASK_ID" "WIP: $CURRENT_TASK_ID (interrupted)" 2>/dev/null || true
    fi
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# Track the task currently being worked on (for cleanup handler)
CURRENT_TASK_ID=""

# ═══════════════════════════════════════════════════════════════
#                     HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════

show_status() {
    "$SCRIPT_DIR/update-plan.sh" --status
}

show_next() {
    "$SCRIPT_DIR/update-plan.sh" --next
}

show_help() {
    cat <<EOF
Ralph Loop — autonomous AI coding agent orchestrator for LinuxCNC Bot

Repeatedly invokes GitHub Copilot CLI to work through tasks in PLAN.md.
Each iteration gets a fresh context window. State persists via PLAN.md,
progress.txt, and git commits.

Usage:
  ./ralph/loop.sh              Run until all tasks done or Ctrl+C
  ./ralph/loop.sh 1            Run exactly 1 step (good for limited time)
  ./ralph/loop.sh 5            Run up to 5 steps
  ./ralph/loop.sh --status     Show plan status (no execution)
  ./ralph/loop.sh --next       Show next task (no execution)
  ./ralph/loop.sh --dry-run    Preview what would be sent to copilot
  ./ralph/loop.sh --model X    Use specific AI model (e.g., claude-sonnet-4)
  ./ralph/loop.sh --quiet-copilot  Hide live copilot output (still logged)

The loop:
  1. Reads PLAN.md for the next ⬜ (or 🔄 interrupted) task
  2. Invokes 'copilot -p <prompt>' with the task instructions
  3. Checks output for completion signal: ${COMPLETE_SIGNAL}
  4. Logs results to ralph/progress.txt
  5. Commits changes to git
  6. Repeats until all tasks pass or limit reached

Interruption & resume:
  - Ctrl+C at any time safely stops the loop
  - Partial work is committed, task stays as 🔄 in-progress
  - Re-run ./ralph/loop.sh to pick up where you left off
  - macOS sleep is prevented via caffeinate (display can sleep)

EOF
    exit 0
}

ensure_progress_file() {
    if [[ ! -f "$PROGRESS_FILE" ]]; then
        cat > "$PROGRESS_FILE" <<'EOF'
# Ralph Loop Progress Log
# Append-only log of what happened each iteration.
# The last ~20 lines are fed to copilot as short-term memory.
EOF
    fi
}

get_progress_tail() {
    if [[ -f "$PROGRESS_FILE" ]]; then
        tail -20 "$PROGRESS_FILE"
    else
        echo "(no previous progress)"
    fi
}

find_next_task() {
    # First check for any 🔄 in-progress tasks (resume interrupted work)
    local in_progress
    in_progress=$(grep -n "^- 🔄 \*\*" "$PLAN_FILE" | head -1) || true
    if [[ -n "$in_progress" ]]; then
        echo "$in_progress"
        return
    fi
    # Then find first ⬜ pending task
    grep -n "^- ⬜ \*\*" "$PLAN_FILE" | head -1
}

extract_task_block() {
    # Given a line number, extract the task and its instruction block
    local line_num="$1"
    local task_line
    task_line=$(sed -n "${line_num}p" "$PLAN_FILE")

    # Grab indented lines following the task (instructions, depends-on, etc.)
    local block=""
    local next_line=$((line_num + 1))
    while true; do
        local l
        l=$(sed -n "${next_line}p" "$PLAN_FILE") || break
        # Stop at next task, blank line, or section header
        if [[ "$l" =~ ^-\ [⬜🔄✅❌] ]] || [[ "$l" =~ ^## ]] || [[ -z "$l" ]]; then
            break
        fi
        block+="$l"$'\n'
        next_line=$((next_line + 1))
    done

    echo "$task_line"
    echo "$block"
}

extract_task_id() {
    # Pull task ID from a task line like: - ⬜ **create-vm-script** — ...
    echo "$1" | sed 's/.*\*\*\([^*]*\)\*\*.*/\1/'
}

build_prompt() {
    local task_block="$1"
    local progress_tail="$2"
    local is_resume="$3"

    # Read the build prompt template
    if [[ -f "$PROMPT_FILE" ]]; then
        local template
        template=$(cat "$PROMPT_FILE")
    else
        echo "ERROR: Build prompt not found at $PROMPT_FILE" >&2
        exit 1
    fi

    local resume_note=""
    if [[ "$is_resume" == "true" ]]; then
        resume_note="
## IMPORTANT: RESUMING INTERRUPTED TASK

This task was previously started but interrupted (marked 🔄 in PLAN.md).
Check the progress log and git log to see what was already done.
Continue from where the previous iteration left off — do NOT redo completed work.
If the task looks already complete, verify it works and mark it done.
"
    fi

    # Inject task and progress into the template
    local prompt="$template
${resume_note}
## YOUR ASSIGNED TASK FOR THIS ITERATION

${task_block}

## RECENT PROGRESS (last 20 lines of ralph/progress.txt)

${progress_tail}
"
    echo "$prompt"
}

invoke_copilot() {
    local prompt="$1"
    local cli_args=(-p "$prompt" --allow-all-tools --no-ask-user)
    if [[ -n "$MODEL" ]]; then
        cli_args+=(--model "$MODEL")
    fi
    local tmp_out
    tmp_out="$(mktemp)"
    local rc=0

    if [[ "$SHOW_COPILOT_OUTPUT" == "true" ]]; then
        # Stream copilot output live to stderr while capturing full output for checks/logging.
        copilot "${cli_args[@]}" 2>&1 | tee "$tmp_out" >&2 || rc=$?
    else
        copilot "${cli_args[@]}" >"$tmp_out" 2>&1 || rc=$?
    fi

    cat "$tmp_out"
    rm -f "$tmp_out"
    return "$rc"
}

log_progress() {
    local iteration="$1"
    local task_id="$2"
    local status="$3"
    local summary="$4"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat >> "$PROGRESS_FILE" <<EOF

--- iteration ${iteration} (${timestamp}) ---
Task: ${task_id}
Status: ${status}
Summary: ${summary}
EOF
}

# ═══════════════════════════════════════════════════════════════
#                     MODE DISPATCH
# ═══════════════════════════════════════════════════════════════

case "$MODE" in
    status) show_status; exit 0 ;;
    next)   show_next; exit 0 ;;
    help)   show_help ;;
esac

# ═══════════════════════════════════════════════════════════════
#                     PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════

if ! command -v copilot &>/dev/null; then
    echo -e "${RED}ERROR: 'copilot' CLI not found.${NC}"
    echo "Install: npm install -g @github/copilot"
    exit 1
fi

if [[ ! -f "$PLAN_FILE" ]]; then
    echo -e "${RED}ERROR: PLAN.md not found at $PLAN_FILE${NC}"
    exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo -e "${RED}ERROR: Build prompt not found at $PROMPT_FILE${NC}"
    echo "Create ralph/PROMPT_build.md first."
    exit 1
fi

ensure_progress_file

# ═══════════════════════════════════════════════════════════════
#                     MAIN LOOP
# ═══════════════════════════════════════════════════════════════

ITERATION=0
COMPLETE=false
SESSION_START=$(date +%s)

# Display iteration limit
if [[ "$MAX_ITERATIONS" -eq 0 ]]; then
    LIMIT_DISPLAY="unlimited (Ctrl+C to stop)"
else
    LIMIT_DISPLAY="$MAX_ITERATIONS"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}  RALPH LOOP — LinuxCNC Bot${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Max iterations: ${YELLOW}${LIMIT_DISPLAY}${NC}"
echo -e "  Model:          ${YELLOW}${MODEL:-default}${NC}"
echo -e "  Plan:           ${GRAY}${PLAN_FILE}${NC}"
echo -e "  Dry run:        ${YELLOW}${DRY_RUN}${NC}"
echo -e "  Stream output:  ${YELLOW}${SHOW_COPILOT_OUTPUT}${NC}"

# Start caffeinate for actual runs (not dry-run or status)
if [[ "$DRY_RUN" != "true" ]]; then
    start_caffeinate
fi

echo ""
show_status
echo ""

while true; do
    # Check iteration limit (0 = unlimited)
    if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
        break
    fi

    ITERATION=$((ITERATION + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    if [[ "$MAX_ITERATIONS" -gt 0 ]]; then
        echo -e "${CYAN}═══ [$TIMESTAMP] Iteration $ITERATION / $MAX_ITERATIONS ═══${NC}"
    else
        echo -e "${CYAN}═══ [$TIMESTAMP] Iteration $ITERATION ═══${NC}"
    fi

    # Find next task (prefers 🔄 in-progress over ⬜ pending)
    next_task_match=$(find_next_task)
    if [[ -z "$next_task_match" ]]; then
        echo -e "${GREEN}All tasks complete! Nothing left to do.${NC}"
        COMPLETE=true
        break
    fi

    line_num=$(echo "$next_task_match" | cut -d: -f1)
    task_block=$(extract_task_block "$line_num")
    task_first_line=$(echo "$task_block" | head -1)
    task_id=$(extract_task_id "$task_first_line")

    # Detect if this is a resume of an interrupted task
    is_resume=false
    if [[ "$task_first_line" == *"🔄"* ]]; then
        is_resume=true
        echo -e "  ${YELLOW}RESUMING:${NC} ${WHITE}${task_id}${NC}"
    else
        echo -e "  Task: ${WHITE}${task_id}${NC}"
    fi
    echo -e "  ${GRAY}${task_first_line}${NC}"

    # Set current task for cleanup handler
    CURRENT_TASK_ID="$task_id"

    # Build prompt
    progress_tail=$(get_progress_tail)
    prompt=$(build_prompt "$task_block" "$progress_tail" "$is_resume")

    # Dry-run mode: show prompt and exit
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}  DRY RUN — prompt that would be sent:${NC}"
        echo "────────────────────────────────────────────────────────"
        echo "$prompt"
        echo "────────────────────────────────────────────────────────"
        echo ""
        echo -e "${GRAY}  (No copilot invocation in dry-run mode)${NC}"
        CURRENT_TASK_ID=""
        exit 0
    fi

    # Mark task as in-progress in PLAN.md (idempotent if already 🔄)
    "$SCRIPT_DIR/update-plan.sh" "$task_id" "in-progress" "Starting iteration $ITERATION" 2>/dev/null || true

    # Invoke copilot with fresh context
    echo -e "  ${CYAN}Invoking copilot CLI...${NC}"
    START_TIME=$(date +%s)
    OUTPUT=$(invoke_copilot "$prompt")
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo -e "  ${GRAY}Copilot finished in ${DURATION}s${NC}"

    # Check for completion signal
    if echo "$OUTPUT" | grep -q "$COMPLETE_SIGNAL"; then
        echo -e "  ${GREEN}✓ Task completed (completion signal received)${NC}"

        # Update plan and log
        "$SCRIPT_DIR/update-plan.sh" "$task_id" "done" "Completed in iteration $ITERATION (${DURATION}s)" 2>/dev/null || true
        log_progress "$ITERATION" "$task_id" "PASSED" "Completed successfully in ${DURATION}s"

        # Commit changes
        "$SCRIPT_DIR/commit.sh" "$task_id" "Completed: $task_id" 2>/dev/null || true

    else
        echo -e "  ${YELLOW}⚠ No completion signal. Task may need more work.${NC}"

        # Log what happened (last 5 lines of output as summary)
        summary=$(echo "$OUTPUT" | tail -5 | tr '\n' ' ')
        log_progress "$ITERATION" "$task_id" "INCOMPLETE" "$summary"

        # Still commit any partial work
        "$SCRIPT_DIR/commit.sh" "$task_id" "WIP: $task_id (iteration $ITERATION)" 2>/dev/null || true
    fi

    # Clear current task (no longer mid-task for cleanup handler)
    CURRENT_TASK_ID=""

    # Brief pause between iterations
    sleep 2
done

# ═══════════════════════════════════════════════════════════════
#                     SESSION SUMMARY
# ═══════════════════════════════════════════════════════════════

# Clear task ID so cleanup handler doesn't log a false interruption
CURRENT_TASK_ID=""

SESSION_END=$(date +%s)
TOTAL_DURATION=$((SESSION_END - SESSION_START))

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}  SESSION COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Iterations: ${YELLOW}${ITERATION}${NC}"
echo -e "  Duration:   ${YELLOW}$((TOTAL_DURATION / 60))m $((TOTAL_DURATION % 60))s${NC}"
echo ""

show_status

if [[ "$COMPLETE" == "true" ]]; then
    echo ""
    echo -e "  ${GREEN}✓ ALL TASKS COMPLETED${NC}"
    exit 0
else
    echo ""
    echo -e "  ${YELLOW}◐ Iteration limit reached. Re-run to continue.${NC}"
    echo -e "  ${GRAY}  State preserved in PLAN.md and ralph/progress.txt${NC}"
    exit 1
fi
