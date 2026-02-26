#!/usr/bin/env bash
# Update task statuses in PLAN.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_FILE="$SCRIPT_DIR/PLAN.md"

usage() {
    echo "Usage: $0 <task-id> <status> [message]"
    echo "  status: pending | in-progress | done | failed"
    echo "  message: optional log message"
    echo ""
    echo "  $0 --next    Show the next pending task"
    echo "  $0 --status  Show status summary"
    exit 1
}

# Status emoji mapping
status_emoji() {
    case "$1" in
        pending)     echo "⬜" ;;
        in-progress) echo "🔄" ;;
        done)        echo "✅" ;;
        failed)      echo "❌" ;;
        *)           echo "⬜" ;;
    esac
}

# Find next pending task
find_next() {
    # Extract first line with ⬜ marker, parse task ID
    local next_line
    next_line=$(grep -n "^- ⬜ \*\*" "$PLAN_FILE" | head -1)
    if [ -z "$next_line" ]; then
        echo '{"status": "complete", "message": "All tasks are done!"}'
        return
    fi

    local line_num task_id task_title
    line_num=$(echo "$next_line" | cut -d: -f1)
    task_id=$(echo "$next_line" | sed 's/.*\*\*\([^*]*\)\*\*.*/\1/')

    # Extract the task block (from this line until next task or section)
    local block
    block=$(sed -n "${line_num},/^- [⬜🔄✅❌]/{ /^- [⬜🔄✅❌]/!p; }" "$PLAN_FILE")
    # Include the task line itself
    task_line=$(sed -n "${line_num}p" "$PLAN_FILE")

    echo "=== NEXT TASK ==="
    echo "$task_line"
    echo "$block"
    echo ""
    echo "Task ID: $task_id"
}

# Show status summary
show_status() {
    local done in_progress pending failed
    done=$(grep -c "^- ✅" "$PLAN_FILE" || true)
    in_progress=$(grep -c "^- 🔄" "$PLAN_FILE" || true)
    pending=$(grep -c "^- ⬜" "$PLAN_FILE" || true)
    failed=$(grep -c "^- ❌" "$PLAN_FILE" || true)
    done=${done:-0}; in_progress=${in_progress:-0}; pending=${pending:-0}; failed=${failed:-0}
    local total=$((done + in_progress + pending + failed))

    echo "=== PLAN STATUS ==="
    echo "  ✅ Done:        $done"
    echo "  🔄 In Progress: $in_progress"
    echo "  ⬜ Pending:     $pending"
    echo "  ❌ Failed:      $failed"
    echo "  Total:          $total"
    echo ""
    echo "Progress: $done/$total tasks complete"
}

# Update a task status
update_task() {
    local task_id="$1"
    local new_status="$2"
    local message="${3:-}"
    local emoji
    emoji=$(status_emoji "$new_status")

    # Find the line with this task ID and any status emoji
    if ! grep -q "\*\*${task_id}\*\*" "$PLAN_FILE"; then
        echo "ERROR: Task '$task_id' not found in PLAN.md"
        exit 1
    fi

    # Replace the status emoji on the task line
    sed -i '' "s/^- [⬜🔄✅❌] \*\*${task_id}\*\*/- ${emoji} **${task_id}**/" "$PLAN_FILE"

    # Append to log section
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local log_entry="- \`${timestamp}\` **${task_id}** → ${emoji} ${new_status}"
    if [ -n "$message" ]; then
        log_entry="$log_entry — $message"
    fi
    echo "$log_entry" >> "$PLAN_FILE"

    echo "Updated $task_id → $new_status"

    # Show what's next
    find_next
}

# Main
case "${1:-}" in
    --next)   find_next ;;
    --status) show_status ;;
    --help)   usage ;;
    "")       usage ;;
    *)
        if [ $# -lt 2 ]; then
            usage
        fi
        update_task "$1" "$2" "${3:-}"
        ;;
esac
