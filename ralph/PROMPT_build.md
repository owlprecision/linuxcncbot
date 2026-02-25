You are in BUILD MODE for the LinuxCNC Bot project. One task per iteration.

## On Start

1. Read `PLAN.md` — your assigned task is provided below. That is your ONLY task.
2. Read the recent progress log below to understand what happened in prior iterations.
3. Run: `git log --oneline -5` to see recent changes.
4. Examine existing code in the repo to understand current state.

## Your Task

Implement the assigned task from PLAN.md (provided below). Follow the task's
*Instructions* section closely. The task description tells you exactly what file(s)
to create or modify and what they should do.

Key rules:
- Create scripts that are executable (`chmod +x`)
- Use `#!/usr/bin/env bash` and `set -euo pipefail` for shell scripts
- Scripts should be idempotent where possible (safe to re-run)
- Use the existing project structure (scripts/, config/, ralph/, tests/, docs/, vm/)
- Reference config from `config/profiles/*.env` when appropriate
- All VM interaction goes through SSH (port 2222 by default)
- Do NOT modify `ralph/loop.sh`, `ralph/PROMPT_build.md`, or `ralph/commit.sh`

After implementing:
- Test your changes where possible (run the script, check syntax, verify file creation)
- Fix any issues before completing

## On Success

1. Mark the task done in PLAN.md: change `⬜` to `✅` on the task line
2. Commit your changes: `git add -A && git commit -m "ralph[<task-id>]: <description>"`
   Include trailer: `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`

## Before Exiting (MANDATORY)

Output exactly this completion signal on its own line:
<promise>COMPLETE</promise>

If you CANNOT complete the task (blocked, unclear, error you can't fix):
- Do NOT output the completion signal
- Append a note to `ralph/progress.txt` explaining what went wrong
- Exit normally (the loop will retry or a human can intervene)

## Rules

- One task per iteration, no more
- Do not modify `ralph/loop.sh`, `ralph/PROMPT_build.md`, or `ralph/commit.sh`
- Do not modify files in `external/`
- If tests fail on something you didn't change, document it and move on
- Keep changes minimal and focused on the assigned task
