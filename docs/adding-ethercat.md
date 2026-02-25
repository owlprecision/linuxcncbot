# Adding EtherCAT (Phase 2)

## Prerequisites

- VM is running and reachable over SSH as `cnc@localhost` on port `2222`.
- You are in the repo root: `/Users/joel/dev/linuxcncbot`.
- Baseline sim profile works end-to-end (`3axis-xyz-sim.env` config + deploy).
- IgH EtherCAT master tools are installed in the VM (`ethercat` CLI available).
- You can run privileged networking/module commands in the VM (`sudo` access).

## Risks and rollback

**Risks:** broken LinuxCNC startup, missing EtherCAT master devices, profile/config mismatch, and network interface disruption in the VM.

**Rollback target:** return to pure sim profile and redeploy known-good sim artifacts.

```bash
cd /Users/joel/dev/linuxcncbot
printf '%s\n' '3axis-xyz-sim.env' > config/profiles/active
./ralph/configure.sh
./ralph/deploy.sh
```

If virtual EtherCAT setup causes instability, stop LinuxCNC, remove virtual EtherCAT networking/module changes in the VM, and re-run the rollback sequence above.

---

## 1) Confirm profile model and generated EtherCAT config

This repository uses profile-driven config generation. `config/ethercat-conf.xml` is a template and is parameterized by profile environment variables (for example `${ETHERCAT_VID}`, `${ETHERCAT_PID}`, `${ETHERCAT_SLAVE_COUNT}`), then rendered to `build/ethercat-conf.xml` by `./ralph/configure.sh`.

Check current active profile and available profiles:

```bash
cd /Users/joel/dev/linuxcncbot
cat config/profiles/active
ls -1 config/profiles/3axis-xyz-*.env
```

Expected profiles for this phase:

- `3axis-xyz-sim.env` (pure simulation workflow)
- `3axis-xyz-ethercat.env` (EtherCAT workflow, can be tested first with a virtual bus)

Switch to EtherCAT profile and regenerate build artifacts:

```bash
cd /Users/joel/dev/linuxcncbot
printf '%s\n' '3axis-xyz-ethercat.env' > config/profiles/active
./ralph/configure.sh
```

Spot-check substituted EtherCAT values:

```bash
grep -nE 'vid=|pid=|slave idx=' build/ethercat-conf.xml
cat build/manifest.json
```

---

## 2) Configure IgH EtherCAT master in simulation/virtual-NIC workflow

Use a virtual Ethernet path in the VM so EtherCAT master startup and bus operations can be tested before real hardware.

SSH into VM:

```bash
ssh -p 2222 cnc@localhost
```

Create a veth pair (example names: `ecat0` and `ecat-peer0`) and bring links up:

```bash
sudo ip link add ecat0 type veth peer name ecat-peer0
sudo ip link set ecat0 up
sudo ip link set ecat-peer0 up
ip -br link show ecat0 ecat-peer0
```

Point the EtherCAT master at the virtual interface and restart service (exact service/module wiring depends on your VM image):

```bash
# Example: set the master device in /etc/default/ethercat
sudo sed -i 's/^MASTER0_DEVICE=.*/MASTER0_DEVICE="ecat0"/' /etc/default/ethercat
sudo systemctl restart ethercat
sudo systemctl status ethercat --no-pager
```

Quick master checks:

```bash
sudo ethercat master
sudo ethercat slaves
```

Notes:

- In pure virtual mode with no virtual slaves/emulation attached, `ethercat master` should report an active master bound to `ecat0`, while `ethercat slaves` may show zero slaves.
- This is still useful because it validates master startup, interface binding, and toolchain readiness before physical bus bring-up.

---

## 3) Test with a virtual EtherCAT bus

Use your VM’s EtherCAT simulation/emulation method to attach virtual slave devices to the virtual interface. Then validate scanning and state transitions with the same `ethercat` tooling used for hardware.

Minimal validation loop (inside VM):

```bash
sudo ethercat master
sudo ethercat slaves
sudo ethercat states
```

Expected progression:

1. Master is present and bound to the configured virtual NIC.
2. Virtual slaves appear in `ethercat slaves` (count should match your virtual bus setup).
3. Slave states are stable across repeated polls (no constant flapping/disconnects).

Exit VM shell when done:

```bash
exit
```

---

## 4) Deploy generated config and validate repo workflow

After the profile + VM virtual-bus setup is ready, run the repository’s normal configure/deploy workflow.

```bash
cd /Users/joel/dev/linuxcncbot
./ralph/configure.sh
./ralph/deploy.sh
```

`./ralph/deploy.sh` uses profile VM connection values (default `cnc@localhost:2222`) and syncs `build/` to `${VM_LINUXCNC_DIR}/config` in the VM.

Quick post-deploy checks:

```bash
ssh -p 2222 cnc@localhost "ls -1 /home/cnc/linuxcnc/config"
ssh -p 2222 cnc@localhost "cat /home/cnc/linuxcnc/config/ethercat-conf.xml | head -n 40"
```

---

## 5) Transition workflow: pure sim → virtual EtherCAT

Use this sequence to move safely from pure simulation to EtherCAT-oriented validation.

1. **Known-good baseline (sim):**

   ```bash
   cd /Users/joel/dev/linuxcncbot
   printf '%s\n' '3axis-xyz-sim.env' > config/profiles/active
   ./ralph/configure.sh
   ./ralph/deploy.sh
   ```

2. **Switch profile to EtherCAT:**

   ```bash
   printf '%s\n' '3axis-xyz-ethercat.env' > config/profiles/active
   ./ralph/configure.sh
   ```

3. **Enable virtual EtherCAT path in VM** (veth + IgH master binding) and confirm `ethercat master` is healthy.

4. **Run deploy again using EtherCAT profile artifacts:**

   ```bash
   ./ralph/deploy.sh
   ```

5. **Validate virtual bus behavior** (`ethercat slaves`, stable states) before any physical EtherCAT hardware bring-up.

This keeps the same repository workflow while changing only profile + VM network/master setup.

---

## Validation checklist

- `config/profiles/active` is set to expected phase profile.
- `./ralph/configure.sh` succeeds and updates `build/manifest.json`.
- `build/ethercat-conf.xml` reflects profile values (VID/PID/slave entries).
- VM is reachable on `ssh -p 2222 cnc@localhost`.
- EtherCAT master binds to virtual interface and reports healthy status.
- `./ralph/deploy.sh` succeeds and updates `/home/cnc/linuxcnc/config` in VM.

---

## Troubleshooting

| Symptom | Likely causes | What to do |
|---|---|---|
| `./ralph/configure.sh` succeeds but EtherCAT values look wrong | Wrong active profile or stale profile file name in `config/profiles/active` | `cat config/profiles/active`, set expected profile (`3axis-xyz-ethercat.env`), rerun `./ralph/configure.sh`, re-check `build/ethercat-conf.xml`. |
| `./ralph/deploy.sh` fails to connect | VM not running, SSH key issue, or wrong host/port/user in profile | Verify VM is up, test `ssh -p 2222 cnc@localhost`, confirm `VM_SSH_*` values in active profile, rerun deploy. |
| `ethercat master` shows no master/device | EtherCAT service not running or not bound to virtual NIC | Confirm `ecat0` exists/up, update `/etc/default/ethercat` to `MASTER0_DEVICE="ecat0"`, restart `ethercat` service. |
| `ethercat slaves` always empty during “virtual bus” test | No slave emulation attached to virtual interface | Start/verify your virtual slave/emulation process and retest with repeated `ethercat slaves` polls. |
| LinuxCNC workflow unstable after Phase 2 changes | Profile/workflow drift or virtual NIC setup conflicts | Roll back immediately to sim profile (`3axis-xyz-sim.env`), redeploy, then re-apply EtherCAT changes one step at a time. |

