#!/usr/bin/env bash
# Ralph Loop — main entry point
# Reads PLAN.md to determine next task, runs verification, commits changes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_FILE="$REPO_ROOT/PLAN.md"

usage() {
    cat <<EOF
Ralph Loop — iterative LinuxCNC configuration and testing

Usage: $0 <command>

Commands:
  next      Show the next pending task and its instructions
  status    Show status summary of all tasks
  verify    Run verification on current state, update PLAN.md, commit
  complete  Mark a task as done and commit (usage: complete <task-id> [message])

Typical workflow with Copilot CLI:
  1. ./ralph/loop.sh next          # See what to do
  2. (Copilot CLI does the work)
  3. ./ralph/loop.sh complete <id> "description of what was done"

EOF
    exit 1
}

cmd_next() {
    "$SCRIPT_DIR/update-plan.sh" --next
}

cmd_status() {
    "$SCRIPT_DIR/update-plan.sh" --status
}

cmd_verify() {
    echo "=== Running Verification ==="

    # Check if verify.sh exists yet (it's created as part of the plan)
    if [ -x "$SCRIPT_DIR/verify.sh" ]; then
        "$SCRIPT_DIR/verify.sh"
        local result=$?
    else
        echo "verify.sh not yet created — skipping VM verification"
        echo "Running basic checks instead..."

        local checks_passed=0
        local checks_total=0

        # Check repo structure
        checks_total=$((checks_total + 1))
        if [ -f "$PLAN_FILE" ]; then
            echo "  ✓ PLAN.md exists"
            checks_passed=$((checks_passed + 1))
        else
            echo "  ✗ PLAN.md missing"
        fi

        checks_total=$((checks_total + 1))
        if [ -f "$REPO_ROOT/README.md" ]; then
            echo "  ✓ README.md exists"
            checks_passed=$((checks_passed + 1))
        else
            echo "  ✗ README.md missing"
        fi

        checks_total=$((checks_total + 1))
        if [ -f "$REPO_ROOT/.gitignore" ]; then
            echo "  ✓ .gitignore exists"
            checks_passed=$((checks_passed + 1))
        else
            echo "  ✗ .gitignore missing"
        fi

        checks_total=$((checks_total + 1))
        if [ -d "$REPO_ROOT/scripts" ]; then
            echo "  ✓ scripts/ directory exists"
            checks_passed=$((checks_passed + 1))
        else
            echo "  ✗ scripts/ directory missing"
        fi

        checks_total=$((checks_total + 1))
        if [ -d "$REPO_ROOT/config/profiles" ]; then
            echo "  ✓ config/profiles/ exists"
            checks_passed=$((checks_passed + 1))
        else
            echo "  ✗ config/profiles/ missing"
        fi

        # Check scripts are executable
        for script in scripts/install-qemu.sh scripts/fetch-deps.sh ralph/commit.sh ralph/update-plan.sh ralph/loop.sh; do
            checks_total=$((checks_total + 1))
            if [ -x "$REPO_ROOT/$script" ]; then
                echo "  ✓ $script is executable"
                checks_passed=$((checks_passed + 1))
            elif [ -f "$REPO_ROOT/$script" ]; then
                echo "  ⚠ $script exists but not executable"
            else
                echo "  ✗ $script missing"
            fi
        done

        echo ""
        echo "Basic checks: $checks_passed/$checks_total passed"
        local result=0
        if [ "$checks_passed" -lt "$checks_total" ]; then
            result=1
        fi
    fi

    return ${result:-0}
}

cmd_complete() {
    local task_id="${1:?ERROR: task-id required}"
    local message="${2:-completed}"

    # Update plan
    "$SCRIPT_DIR/update-plan.sh" "$task_id" "done" "$message"

    # Commit
    "$SCRIPT_DIR/commit.sh" "$task_id" "$message"
}

# Main
case "${1:-}" in
    next)     cmd_next ;;
    status)   cmd_status ;;
    verify)   cmd_verify ;;
    complete)
        shift
        cmd_complete "$@"
        ;;
    --help|-h) usage ;;
    "")        usage ;;
    *)
        echo "Unknown command: $1"
        usage
        ;;
esac
