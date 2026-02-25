# LinuxCNC Bot

An iterative development workspace for configuring and testing a LinuxCNC installation with EtherCAT servo drives. Uses QEMU on macOS to run a Debian 12 VM, enabling automated configure → deploy → test → verify cycles via the **ralph loop**.

## Quickstart

```bash
# 1. Bootstrap the environment (installs QEMU, downloads deps, creates VM)
./scripts/bootstrap.sh

# 2. Start a Copilot CLI session and run the ralph loop
#    In this repo directory, start GitHub Copilot CLI and say:
#
#    "Read PLAN.md and execute the next pending task. After completing it,
#     run ./ralph/loop.sh verify to validate, then update PLAN.md and commit."
```

## What is the Ralph Loop?

The ralph loop is an iterative development cycle driven by GitHub Copilot CLI:

```
┌─────────────────────────────────────────────────┐
│                  PLAN.md                         │
│  (living task queue with ⬜/🔄/✅/❌ statuses)  │
└──────────┬──────────────────────────▲────────────┘
           │ read next task           │ update status
           ▼                          │ + commit
┌──────────────────┐    ┌─────────────┴────────────┐
│  Copilot CLI      │───▶│  ralph/loop.sh verify    │
│  executes task    │    │  (test + verify + commit) │
└──────────────────┘    └──────────────────────────┘
```

1. **PLAN.md** is the project's living task queue. Each task has a status, dependencies, and detailed instructions.
2. **Each Copilot CLI session** reads PLAN.md, picks the next pending task, executes it, then runs verification.
3. **Every iteration commits to git** — each session's work is a discrete, revertable unit. If something breaks, `git log` shows what each iteration did and `git revert` can undo it.
4. **Sessions are stateless** — any session can pick up where the last left off by reading PLAN.md.

## How to Run an Iteration

### Option 1: Let Copilot CLI drive (recommended)

Start Copilot CLI in this directory and say:
> "Read PLAN.md and execute the next pending task."

After it completes the work:
> "Run `./ralph/loop.sh verify` to validate and commit."

### Option 2: Manual ralph loop commands

```bash
./ralph/loop.sh next      # Show the next pending task and instructions
./ralph/loop.sh status    # Show status of all tasks
./ralph/loop.sh verify    # Run verification on current state + commit
```

### Option 3: Run specific scripts directly

```bash
./ralph/configure.sh              # Generate configs from active profile
./ralph/deploy.sh                 # Push config to VM
./ralph/test.sh                   # Run test suite in VM
./ralph/verify.sh                 # Full verification report
./ralph/commit.sh "description"   # Commit current changes
```

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
