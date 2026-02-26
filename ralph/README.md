# Ralph Runner Internals

This folder contains the autonomous AI runner and its state.

## Core files

- `loop.sh` — autonomous iteration loop
- `PLAN.md` — runner task queue
- `PROMPT_build.md` — prompt template for each iteration
- `progress.txt` — append-only execution memory
- `agents/` — reusable specialist subagent profiles
- `update-plan.sh`, `commit.sh` — plan state + git checkpointing

## Typical runner usage

```bash
./ralph/loop.sh              # run until done or Ctrl+C
./ralph/loop.sh 1            # run one full step
./ralph/loop.sh --status     # status only
./ralph/loop.sh --dry-run    # inspect prompt
./ralph/loop.sh --model gpt-5.3-codex
```

## Notes

- `loop.sh` reads `ralph/PLAN.md`.
- Agent delegation is AI-chosen from `ralph/agents/`.
- Progress and interruption recovery are tracked in `ralph/progress.txt`.
