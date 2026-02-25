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

## Start over safely (messy existing machine setup)

Use this when the machine already has unknown/manual LinuxCNC + EtherCAT changes and you want a clean, repo-managed baseline **without losing rollback options**.

### 0) Prerequisites

```bash
cd /path/to/linuxcncbot
chmod +x scripts/bootstrap-target-host.sh scripts/ethercat-nic-setup.sh scripts/igh-master-runtime-setup.sh ralph/configure.sh ralph/deploy.sh ralph/verify.sh
```

### 1) Backup existing LinuxCNC + EtherCAT/runtime state (required)

```bash
# Create a timestamped backup root.
BACKUP_ROOT="$HOME/linuxcnc-migration-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_ROOT"

# Backup common LinuxCNC config locations (only if they exist).
[ -d "$HOME/linuxcnc/configs" ] && cp -a "$HOME/linuxcnc/configs" "$BACKUP_ROOT/linuxcnc-configs-home"
[ -d /etc/linuxcnc ] && sudo cp -a /etc/linuxcnc "$BACKUP_ROOT/linuxcnc-configs-etc"
[ -d /usr/share/linuxcnc/configs ] && sudo cp -a /usr/share/linuxcnc/configs "$BACKUP_ROOT/linuxcnc-configs-usrshare"

# Backup EtherCAT/runtime config files touched by this repo's setup scripts.
[ -f /etc/default/ethercat ] && sudo cp -a /etc/default/ethercat "$BACKUP_ROOT/etc-default-ethercat"
[ -f /etc/NetworkManager/conf.d/90-ethercat-unmanaged.conf ] && sudo cp -a /etc/NetworkManager/conf.d/90-ethercat-unmanaged.conf "$BACKUP_ROOT/90-ethercat-unmanaged.conf"

# Save quick machine state snapshots for audit/rollback.
ip -br link > "$BACKUP_ROOT/ip-link.txt"
ip -br addr > "$BACKUP_ROOT/ip-addr.txt"
sudo systemctl status ethercat --no-pager > "$BACKUP_ROOT/ethercat-service-status.txt" || true
echo "Backups written to: $BACKUP_ROOT"
```

### 2) Move to repo-managed baseline

```bash
# 2a) Verify host prerequisites and install missing packages.
./scripts/bootstrap-target-host.sh

# 2b) Choose machine profile managed by this repo.
printf '%s\n' 'beckhoff-ek1100-2x-el7031.env' > config/profiles/active

# 2c) Configure deterministic EtherCAT NIC + runtime (replace MAC with your NIC).
ETHERCAT_NIC_MAC="aa:bb:cc:dd:ee:ff"
./scripts/ethercat-nic-setup.sh --mac "$ETHERCAT_NIC_MAC"
./scripts/igh-master-runtime-setup.sh --mac "$ETHERCAT_NIC_MAC"

# 2d) Render and deploy repo config to this host (update user/key if needed).
./ralph/configure.sh
VM_SSH_HOST=localhost VM_SSH_PORT=22 VM_SSH_USER="$USER" VM_SSH_KEY="$HOME/.ssh/id_ed25519" VM_LINUXCNC_DIR="$HOME/linuxcnc" ./ralph/deploy.sh

# 2e) Run verification gates.
VM_SSH_HOST=localhost VM_SSH_PORT=22 VM_SSH_USER="$USER" VM_SSH_KEY="$HOME/.ssh/id_ed25519" ./ralph/verify.sh
```

### 3) Roll back safely to pre-migration state

Use the same `BACKUP_ROOT` path you created above.

```bash
# Stop EtherCAT service before restoring runtime config files.
sudo systemctl stop ethercat || true

# Restore EtherCAT/runtime files if backups exist.
[ -f "$BACKUP_ROOT/etc-default-ethercat" ] && sudo cp -a "$BACKUP_ROOT/etc-default-ethercat" /etc/default/ethercat
[ -f "$BACKUP_ROOT/90-ethercat-unmanaged.conf" ] && sudo cp -a "$BACKUP_ROOT/90-ethercat-unmanaged.conf" /etc/NetworkManager/conf.d/90-ethercat-unmanaged.conf

# Restore LinuxCNC config trees (choose the locations that existed on your machine).
[ -d "$BACKUP_ROOT/linuxcnc-configs-home" ] && cp -a "$BACKUP_ROOT/linuxcnc-configs-home/." "$HOME/linuxcnc/configs/"
[ -d "$BACKUP_ROOT/linuxcnc-configs-etc" ] && sudo cp -a "$BACKUP_ROOT/linuxcnc-configs-etc/." /etc/linuxcnc/
[ -d "$BACKUP_ROOT/linuxcnc-configs-usrshare" ] && sudo cp -a "$BACKUP_ROOT/linuxcnc-configs-usrshare/." /usr/share/linuxcnc/configs/

# Reload services/networking and re-check status.
sudo systemctl restart NetworkManager
sudo systemctl restart ethercat || true
sudo systemctl status ethercat --no-pager
```

If rollback is required because deployment failed, keep the repo checkout and backup directory; they help you diff old vs. new configs before retrying.

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
