# LinuxCNC Hardware Commissioning Test

## Prerequisites

- VM is running and reachable over SSH as `cnc@localhost` on port `2222`.
- Host repo is up to date and you are in `/Users/joel/dev/linuxcncbot`.
- Hardware profile file exists: `config/profiles/3axis-xyz-ethercat.env`.
- E-stop chain is wired and verified with power disabled.
- You can safely remove drive power immediately if motion is unexpected.

## Risks and rollback

**Risks:** unexpected motion, runaway axis, drive faults, and potential machine damage/injury.

**Immediate safe action:** hit E-stop and remove drive power.

**Rollback to sim profile:**

```bash
cd /Users/joel/dev/linuxcncbot
printf '%s\n' '3axis-xyz-sim.env' > config/profiles/active
./ralph/configure.sh
./ralph/deploy.sh
```

---

## 1) Pre-flight checklist

Before enabling LinuxCNC motion:

- Wiring: motor phases, encoder/feedback, STO/enable, and limit/home switches match schematics.
- Power: logic power first, then drive power; verify correct supply voltages and grounds.
- EtherCAT chain: NIC/link LEDs up, in/out cable order correct, last slave termination/state as expected.
- E-stop: physical E-stop drops drive enable; LinuxCNC E-stop input changes state correctly.
- Mechanical safety: clear travel path, axis can move freely, low speed limits configured, one person at controls.

---

## 2) Switch from sim to hardware profile and deploy

Set active profile to EtherCAT hardware, regenerate build artifacts, and deploy to VM:

```bash
cd /Users/joel/dev/linuxcncbot
printf '%s\n' '3axis-xyz-ethercat.env' > config/profiles/active
./ralph/configure.sh
./ralph/deploy.sh
```

If either script fails, fix that error before continuing.

---

## 3) EtherCAT bus scan (inside VM)

SSH to VM and scan detected slaves:

```bash
ssh -p 2222 cnc@localhost
ethercat slaves
```

Expected: each physical slave appears with a stable state (not missing/flapping).

If done, exit VM shell:

```bash
exit
```

---

## 4) Single-axis commissioning (one axis at a time)

Commission one axis only before enabling the full machine.

1. Keep other axes mechanically safe/disabled at the drive level.
2. Start LinuxCNC in hardware mode on the VM.
3. Enable **only one axis**.
4. Jog that axis at very low speed first (short jogs in both directions).
5. Verify:
   - Direction is correct.
   - Motion is smooth and controlled.
   - Following error remains stable.
   - E-stop immediately removes enable.

Do not continue until one axis passes all checks.

---

## 5) Full machine test (all axes)

After each axis passes single-axis commissioning:

1. Enable all axes.
2. Jog each axis slowly, then at moderate speed.
3. Run basic coordinated moves (e.g., XY, then XYZ) and watch for:
   - correct direction/sign,
   - no oscillation or runaway,
   - no unexpected following errors,
   - predictable stop behavior on disable/E-stop.
4. Confirm machine returns to a known safe position.

Record any fault codes before power cycling.

---

## 6) Troubleshooting

| Symptom | Likely causes | What to do |
|---|---|---|
| `ethercat slaves` shows no slaves | Cabling order/link down, wrong NIC, EtherCAT master not active in VM | Check link LEDs/cables, verify VM NIC mapping, rerun `ethercat slaves` after fixing network path. |
| Slaves stuck in `PREOP`/`SAFEOP` | PDO/config mismatch, drive not ready, missing enable sequence | Re-check deployed profile (`3axis-xyz-ethercat.env`), inspect drive status/fault, redeploy with `./ralph/configure.sh && ./ralph/deploy.sh`. |
| Axis runs away | Wrong sign/scale, feedback polarity mismatch, tuning invalid | Hit E-stop immediately, remove drive power, correct sign/scale/tuning before re-enable. Test only single-axis at low speed. |
| Following error trips | Aggressive accel/vel, tuning mismatch, mechanical drag/binding | Lower limits in profile, inspect mechanics, retest low-speed jog first. |
| Axis will not enable | E-stop chain open, STO active, drive fault, enable pin mapping wrong | Verify E-stop/STO state, clear drive fault, confirm HAL enable mapping from deployed config. |

For persistent faults, rollback to sim profile, confirm toolchain works, then re-apply hardware profile changes incrementally.
