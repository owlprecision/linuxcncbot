# LinuxCNC Hardware Installer Guide

This repository is for installing/configuring a **physical LinuxCNC machine** with EtherCAT hardware (including Beckhoff EK1100 + EL7031 workflows).

## What this repo gives you

- LinuxCNC config templates and profiles under `config/`
- Host/bootstrap scripts under `scripts/`
- Deployment + verification scripts under `ralph/` (usable directly)
- Hardware test docs under `docs/`

## Prerequisites (target machine)

- Debian/Linux with LinuxCNC PREEMPT-RT already installed (or ready to install)
- Secondary NIC dedicated to EtherCAT chain
- Hardware connected (EK1100 + EL7031 terminals, power/wiring complete)
- `sudo` access

## Quick install on a physical machine

```bash
# 1) Clone
git clone https://github.com/owlprecision/linuxcncbot
cd linuxcncbot

# 2) Bootstrap target host prerequisites
./scripts/bootstrap-target-host.sh

# 3) Select profile (example Beckhoff 2-axis)
printf '%s\n' 'beckhoff-ek1100-2x-el7031.env' > config/profiles/active

# 4) Configure dedicated EtherCAT NIC (replace MAC)
ETHERCAT_NIC_MAC="aa:bb:cc:dd:ee:ff"
./scripts/ethercat-nic-setup.sh --mac "$ETHERCAT_NIC_MAC"
./scripts/igh-master-runtime-setup.sh --mac "$ETHERCAT_NIC_MAC"

# 5) Render + deploy LinuxCNC config
./ralph/configure.sh
VM_SSH_HOST=localhost VM_SSH_PORT=22 VM_SSH_USER="$USER" VM_SSH_KEY="$HOME/.ssh/id_ed25519" VM_LINUXCNC_DIR="$HOME/linuxcnc" ./ralph/deploy.sh

# 6) Verify
VM_SSH_HOST=localhost VM_SSH_PORT=22 VM_SSH_USER="$USER" VM_SSH_KEY="$HOME/.ssh/id_ed25519" ./ralph/verify.sh
```

## First hardware motion test

After verify passes, use:

- `docs/hardware-test.md`
- `docs/el7031-first-power-on-calibration-checklist.md`
- `docs/hardware-verification-gates.md`

Run initial motion at low speed/current only.

## If you need to restart cleanly

Use the backup/rollback procedure in this README history and in docs, then re-run the quick install sequence above.

## Where the AI runner materials live

All Ralph runner/support materials are under `ralph/`:

- `ralph/PLAN.md`
- `ralph/agents/`
- `ralph/loop.sh`
- `ralph/PROMPT_build.md`
- `ralph/progress.txt`

If you are only installing/configuring hardware, you usually only need `scripts/`, `config/`, `docs/`, and `ralph/{configure,deploy,verify}.sh`.
