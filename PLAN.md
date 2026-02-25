# LinuxCNC Bot — PLAN.md

> This file is the living task queue for the ralph loop. Copilot CLI reads this to
> determine what to do next. Status markers: ⬜ pending | 🔄 in-progress | ✅ done | ❌ failed
>
> **To run the ralph loop:** Start a Copilot CLI session in this repo and say:
> "Read PLAN.md and execute the next pending task. After completing it, run `./ralph/loop.sh verify` to validate, then update this file and commit."

---

## Phase 1: Bootstrap Infrastructure

- ✅ **repo-init** — Initialize git repo, .gitignore
- ✅ **plan-md** — Create this PLAN.md task queue
- ✅ **readme** — Create README.md with ralph loop quickstart
- ✅ **install-qemu-script** — `scripts/install-qemu.sh` — install QEMU via brew, verify binaries
- ✅ **fetch-deps-script** — `scripts/fetch-deps.sh` — clone reference repo, download Debian 12 ISO
- ✅ **preseed-config** — `vm/preseed.cfg` — unattended Debian 12 install config
- ✅ **config-profiles** — `config/profiles/*.env` — parameterized machine profiles
- ✅ **commit-script** — `ralph/commit.sh` — auto-commit after each iteration
- ✅ **update-plan-script** — `ralph/update-plan.sh` — update task statuses in this file
- ✅ **create-vm-script** — `scripts/create-vm.sh` — create QEMU VM with Debian 12 + preseed
  - *Depends on:* install-qemu-script, fetch-deps-script, preseed-config
  - *Instructions:* Create a script that builds a qcow2 disk image (20GB), launches QEMU with the Debian netinst ISO and preseed for unattended install, configures SSH port forwarding (host 2222 → guest 22), and waits for install completion. Use HVF acceleration on macOS when available.
- ✅ **provision-vm-script** — `scripts/provision-vm.sh` — install LinuxCNC in the VM
  - *Depends on:* create-vm-script
  - *Instructions:* SSH into the VM and: add LinuxCNC apt repo (linuxcnc.org), install RT_PREEMPT kernel, install linuxcnc + linuxcnc-dev + halcmd, install linuxcnc-ethercat (lcec), create /home/cnc/linuxcnc/ working directory. Use the SSH key set up during preseed.
- ✅ **vm-control-script** — `scripts/vm-control.sh` — VM lifecycle management
  - *Depends on:* create-vm-script
  - *Instructions:* Create script with subcommands: `start` (boot VM background, SSH forwarding), `stop` (graceful shutdown then kill), `ssh` (open session), `snapshot <name>` (QEMU snapshot), `restore <name>`, `status` (check running). Store PID in vm/qemu.pid.
- ✅ **bootstrap-script** — `scripts/bootstrap.sh` — master orchestrator
  - *Depends on:* install-qemu-script, fetch-deps-script, create-vm-script, provision-vm-script, vm-control-script
  - *Instructions:* Run all bootstrap scripts in order, take a "clean" snapshot at the end. Should be idempotent (skip completed steps).

## Phase 2: LinuxCNC Configuration

- ✅ **machine-ini** — `config/machine.ini` — parameterized INI template
  - *Depends on:* config-profiles
  - *Instructions:* Create INI derived from reference repo's EL8_machine.ini but simplified to 3-axis XYZ. Use shell variable substitution markers (e.g., `${AXIS_X_MAX_VEL}`) that `ralph/configure.sh` will expand from the active profile. Include DISPLAY, KINS (trivkins coordinates=XYZ), TRAJ, EMCMOT, HAL, and JOINT_0/1/2 sections.
- ✅ **machine-hal** — `config/machine.hal` — HAL template for sim mode
  - *Depends on:* config-profiles
  - *Instructions:* Create HAL file that loads sim components (sim_encoder, sim_spindle, etc.) instead of lcec/cia402. Structure it modularly: motion setup section, then per-axis sections that can be swapped between sim and hardware HAL includes.
- ✅ **sim-hal** — `config/sim.hal` — simulation HAL overrides
  - *Depends on:* machine-hal
  - *Instructions:* Create sim-specific HAL that provides simulated position feedback loops for each axis. Uses `sim_encoder` and loopback connections so LinuxCNC thinks motors are responding.
- ✅ **ethercat-conf-template** — `config/ethercat-conf.xml` — EtherCAT config template
  - *Depends on:* config-profiles
  - *Instructions:* Create XML derived from reference repo's ethercat-conf.xml. Parameterize slave count and VID/PID per profile. Not loaded in sim mode but ready for hardware.

## Phase 3: Ralph Loop Orchestration

- ✅ **configure-script** — `ralph/configure.sh` — generate configs from profile
  - *Depends on:* machine-ini, machine-hal, sim-hal, config-profiles
  - *Instructions:* Read active profile .env, use envsubst to expand templates into build/ directory, validate INI syntax (check required sections exist), output JSON manifest of generated files.
- ⬜ **deploy-script** — `ralph/deploy.sh` — push config to VM
  - *Depends on:* vm-control-script, configure-script
  - *Instructions:* Rsync build/ contents to VM via SSH (port 2222), compile any .comp files with halcompile, output JSON status with file list and any errors.
- ⬜ **test-script** — `ralph/test.sh` — run tests in VM
  - *Depends on:* deploy-script, test-config-loads, test-hal-pins, test-gcode-basic, test-axis-limits
  - *Instructions:* SSH into VM, run each test from tests/ directory, capture exit codes and output, produce JSON results array with test name, status (pass/fail), and output.
- ⬜ **verify-script** — `ralph/verify.sh` — the verification lynchpin
  - *Depends on:* test-script
  - *Instructions:* Run test.sh, parse JSON, generate structured report: overall PASS/FAIL, per-test details, HAL pin dump, log excerpts, suggested fixes. Exit 0 if all pass, non-zero otherwise.
- ⬜ **loop-script** — `ralph/loop.sh` — main ralph loop entry point
  - *Depends on:* configure-script, deploy-script, test-script, verify-script, update-plan-script, commit-script
  - *Instructions:* Commands: `next` (parse PLAN.md, find first ⬜ task, output its instructions), `status` (summary of all tasks), `verify` (run verify.sh + update PLAN.md + commit), `run` (execute next + verify + commit). All output is structured for Copilot CLI consumption.

## Phase 4: Test Suite

- ⬜ **test-config-loads** — `tests/test-config-loads.sh` — verify config parses
  - *Depends on:* configure-script
  - *Instructions:* Run `linuxcnc --check <ini>` or equivalent to verify INI/HAL parse without errors. Exit 0 on success.
- ⬜ **test-hal-pins** — `tests/test-hal-pins.sh` — verify HAL pins
  - *Depends on:* configure-script
  - *Instructions:* Start halcmd, load HAL file, verify expected pins exist (joint.0/1/2.motor-pos-cmd, etc.). Compare against expected pin list from profile.
- ⬜ **test-gcode-basic** — `tests/test-gcode-basic.sh` — run basic G-code
  - *Depends on:* configure-script
  - *Instructions:* Run a simple G-code program (G0 X10 Y10 Z-5; G1 X20 F100; M2) through LinuxCNC in batch mode. Verify exit code 0 and no error in logs.
- ⬜ **test-axis-limits** — `tests/test-axis-limits.sh` — verify soft limits
  - *Depends on:* configure-script
  - *Instructions:* Attempt moves beyond configured soft limits, verify LinuxCNC rejects them. Test both positive and negative limits on all axes.

## Phase 5: Documentation

- ⬜ **hardware-test-doc** — `docs/hardware-test.md`
  - *Depends on:* loop-script
  - *Instructions:* Write step-by-step hardware test procedure: pre-flight checklist (wiring, power, EtherCAT chain), switch to hardware profile, EtherCAT bus scan (`ethercat slaves`), single-axis commissioning (enable one axis, jog slowly), full machine test, troubleshooting.
- ⬜ **configuration-guide-doc** — `docs/configuration-guide.md`
  - *Depends on:* config-profiles
  - *Instructions:* Document how to: add/remove axes (edit profile + templates), change drive types (new profile), adjust tuning (velocity, acceleration, ferror), create new profiles.
- ⬜ **adding-ethercat-doc** — `docs/adding-ethercat.md`
  - *Depends on:* ethercat-conf-template
  - *Instructions:* Document phase 2 setup: IgH EtherCAT master simulation mode, virtual network interfaces, testing with virtual EtherCAT bus, transitioning from sim to virtual EtherCAT.

---

## Log

<!-- Ralph loop appends timestamped entries here -->
- `2026-02-25T17:22:50Z` **create-vm-script** → 🔄 in-progress — Starting iteration 1
- `2026-02-25T17:24:17Z` **create-vm-script** → ✅ done — Completed in iteration 1 (87s)
- `2026-02-25T21:28:54Z` **provision-vm-script** → 🔄 in-progress — Starting iteration 1
- `2026-02-25T21:30:46Z` **provision-vm-script** → ✅ done — Completed in iteration 1 (112s)
- `2026-02-25T21:36:35Z` **vm-control-script** → 🔄 in-progress — Starting iteration 1
- `2026-02-25T21:38:17Z` **vm-control-script** → ✅ done — Completed in iteration 1 (101s)
- `2026-02-25T21:56:35Z` **bootstrap-script** → 🔄 in-progress — Starting iteration 1
- `2026-02-25T21:59:36Z` **bootstrap-script** → ✅ done — Completed in iteration 1 (181s)
- `2026-02-25T22:01:37Z` **machine-ini** → 🔄 in-progress — Starting iteration 1
- `2026-02-25T22:03:47Z` **machine-ini** → ✅ done — Completed in iteration 1 (130s)
- `2026-02-25T22:03:49Z` **machine-hal** → 🔄 in-progress — Starting iteration 2
- `2026-02-25T22:06:36Z` **machine-hal** → ✅ done — Completed in iteration 2 (167s)
- `2026-02-25T22:06:38Z` **sim-hal** → 🔄 in-progress — Starting iteration 3
- `2026-02-25T22:09:06Z` **sim-hal** → ✅ done — Completed in iteration 3 (148s)
- `2026-02-25T22:09:09Z` **ethercat-conf-template** → 🔄 in-progress — Starting iteration 4
- `2026-02-25T22:11:55Z` **ethercat-conf-template** → ✅ done — Completed in iteration 4 (166s)
- `2026-02-25T22:11:57Z` **configure-script** → 🔄 in-progress — Starting iteration 5
