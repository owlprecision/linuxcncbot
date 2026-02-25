# LinuxCNC Bot

An iterative development workspace for configuring and testing a LinuxCNC installation with EtherCAT servo drives. Uses QEMU on macOS to run a Debian 12 VM, enabling automated configure → deploy → test → verify cycles via the **ralph loop**.

## Quickstart

```bash
# 1. Bootstrap the environment (installs QEMU, downloads deps, creates VM)
./scripts/bootstrap.sh

# 2. Run the ralph loop — it invokes Copilot CLI autonomously
./ralph/loop.sh            # Default: 20 iterations max
./ralph/loop.sh 50         # Or set a custom limit
./ralph/loop.sh --dry-run  # Preview what would happen (no API calls)
```

The loop runs unattended, invoking `copilot` CLI repeatedly until all tasks in PLAN.md are done or the iteration limit is reached. Re-run to continue where it left off.

## One-command handoff flow (existing LinuxCNC target host)

Use this on a Debian PREEMPT-RT LinuxCNC target host that already exists.

```bash
# 1) Clone repo
git clone git@github.com:owlprecision/linuxcncbot.git linuxcncbot
cd linuxcncbot

# 2) Bootstrap target host
./scripts/bootstrap-target-host.sh

# 3) Apply Beckhoff profile
printf '%s\n' 'beckhoff-ek1100-2x-el7031.env' > config/profiles/active

# 4) Deploy (render + push config)
./ralph/configure.sh
./ralph/deploy.sh

# 5) Verify (runs test suite + HAL pin dump)
./ralph/verify.sh
```

`./ralph/verify.sh` calls `./ralph/test.sh`, which includes hardware verification gates for EtherCAT profiles.

## What is the Ralph Loop?

The ralph loop is an outer shell that wraps GitHub Copilot CLI and re-invokes it repeatedly with fresh context until all tasks are done:

```
┌─────────────────────────────────────────────────────────────┐
│  ralph/loop.sh  (outer shell — bash while loop)             │
│                                                             │
│  while tasks remain and iterations < max:                   │
│    1. Read PLAN.md → find next ⬜ task                      │
│    2. Build prompt (task + progress.txt tail)                │
│    3. copilot -p <prompt> --allow-all-tools                 │
│    4. Check output for <promise>COMPLETE</promise>          │
│    5. Log to progress.txt, commit to git                    │
│    6. Repeat with fresh context                             │
└─────────────────────────────────────────────────────────────┘
```

Key design principles:
1. **PLAN.md** is the living task queue — each task has status (⬜/🔄/✅/❌) and detailed instructions.
2. **Fresh context each iteration** — copilot is invoked as a new process each time, avoiding context drift.
3. **Disk as memory** — `ralph/progress.txt` is an append-only log. The last 20 lines are fed to copilot as short-term memory across context resets.
4. **Git as checkpoint** — every iteration commits, so every session's work is a discrete, revertable unit.
5. **External completion check** — the loop (not the AI) decides when a task is done, by checking for the `<promise>COMPLETE</promise>` signal.

## How to Run

```bash
# Run the autonomous loop (invokes copilot CLI repeatedly)
./ralph/loop.sh              # Run until done or Ctrl+C
./ralph/loop.sh 1            # Run exactly one full step
./ralph/loop.sh 50           # Custom iteration limit
./ralph/loop.sh --model claude-opus-4.6  # Use a specific model
./ralph/loop.sh --dry-run    # Preview prompt, no API calls

# Status and inspection (no copilot invocation)
./ralph/loop.sh --status     # Show task summary
./ralph/loop.sh --next       # Show next pending task
```

Re-run `./ralph/loop.sh` to continue where the last run left off. All state is in PLAN.md and `ralph/progress.txt`.
If `--model` is omitted, Copilot CLI uses its currently configured default model.

## Architecture

```
linuxcncbot/
├── PLAN.md              # Living task queue (ralph loop reads/updates this)
├── scripts/             # Bootstrap & VM management
│   ├── bootstrap.sh     # Master bootstrap (run once)
│   ├── install-qemu.sh  # Install QEMU via brew
│   ├── fetch-deps.sh    # Clone reference repo + download Debian ISO
│   ├── create-vm.sh     # Create QEMU VM
│   ├── provision-vm.sh  # Install LinuxCNC in VM
│   └── vm-control.sh    # Start/stop/snapshot VM
├── config/              # LinuxCNC configuration (parameterized)
│   ├── profiles/        # Machine profiles (.env files)
│   ├── machine.ini      # INI template
│   ├── machine.hal      # HAL template
│   └── sim.hal          # Simulation overrides
├── ralph/               # Ralph loop orchestration
│   ├── loop.sh          # Main entry point
│   ├── configure.sh     # Generate configs from profile
│   ├── deploy.sh        # Push to VM
│   ├── test.sh          # Run tests
│   ├── verify.sh        # Verification (the lynchpin)
│   ├── update-plan.sh   # Update PLAN.md statuses
│   └── commit.sh        # Git commit iteration
├── .github/agents/      # Reusable custom specialist agents used by loop
├── tests/               # Test suite (run inside VM)
├── docs/                # Hardware test & configuration guides
├── vm/                  # (gitignored) VM disk images & runtime
└── external/            # (gitignored) Cloned reference repos
```

## Configuration Profiles

Machine configuration is driven by profile `.env` files in `config/profiles/`. Profiles define:
- Number of axes and axis names (e.g., XYZ, XYZA)
- Drive type (sim, leadshine-el8, generic-cia402)
- Position scales, velocity/acceleration limits
- Servo period, following error tolerances

To switch profiles: edit `config/profiles/active` to point to the desired `.env` file.

## Reference

This project uses [marcoreps/linuxcnc_leadshine_EL8](https://github.com/marcoreps/linuxcnc_leadshine_EL8) as a reference configuration for EtherCAT servo drive integration with LinuxCNC.
