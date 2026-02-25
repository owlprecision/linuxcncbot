# LinuxCNC Configuration Guide

## Prerequisites

- You are in the repo root: `/Users/joel/dev/linuxcncbot`.
- You know which profile you are editing in `config/profiles/*.env`.
- For hardware profiles, machine power is in a safe state before testing.

## Risks and rollback

**Risks:** bad axis mapping, runaway motion, following-error trips, and EtherCAT faults.

**Immediate safe action:** hit E-stop and remove drive power.

**Rollback to known-good sim profile:**

```bash
cd /Users/joel/dev/linuxcncbot
printf '%s\n' '3axis-xyz-sim.env' > config/profiles/active
./ralph/configure.sh
```

---

## 1) Add or remove axes (edit profile + templates)

Axis count/letters are not fully profile-driven today; update both profile values and templates together.

### 1.1 Edit profile values

Start from the profile you use (for example `config/profiles/3axis-xyz-sim.env` or `config/profiles/3axis-xyz-ethercat.env`):

- `COORDINATES` (example: `XYZ`, `XYZA`)
- `NUM_JOINTS`
- `KINEMATICS` (example: `trivkins coordinates=XYZ`)
- Per-axis limits/tuning/home/scale variables, such as:
  - `AXIS_X_MAX_VEL`, `AXIS_X_MAX_ACCEL`, `AXIS_X_MIN_LIMIT`, `AXIS_X_MAX_LIMIT`, `AXIS_X_HOME`, `AXIS_X_SCALE`
  - matching variables for Y/Z/(new axes)
- Hardware profile only: `ETHERCAT_SLAVE_COUNT`

### 1.2 Edit templates for the new axis layout

Update all relevant templates so generated files stay consistent:

- `config/machine.ini`
  - `[KINS]`: update `KINEMATICS = ...` and `JOINTS = ...`
  - `[TRAJ]`: update `COORDINATES = ...`
  - Add/remove `[JOINT_n]` sections and map each section to the correct `${AXIS_*...}` variables.
- `config/machine.hal`
  - Update `loadrt sim_encoder names=...` and `loadrt scale count=...`
  - Add/remove `addf scale.N servo-thread` lines
  - Add/remove per-axis HAL hook blocks (`joint.N`, scale gain, pos cmd/fb, amp-enable nets).
- `config/sim.hal`
  - Add/remove `addf sim-enc-*` and `setp sim-enc-*` lines
  - Add/remove per-axis loopback nets for each `joint.N`.
- `config/ethercat-conf.xml` (hardware profiles)
  - Add/remove `<slave ...>` blocks to match axis count
  - Keep slave order aligned with joint/axis order.
- `ralph/configure.sh`
  - Update `required_sections` so it checks the same JOINT sections you now generate.

---

## 2) Change drive types (create a new profile)

Do this by creating a separate profile instead of mutating an existing one in-place.

1. Copy a close starting point:

```bash
cd /Users/joel/dev/linuxcncbot
cp config/profiles/3axis-xyz-ethercat.env config/profiles/3axis-xyz-<new-drive>.env
```

2. Edit the new profile:
   - `PROFILE_NAME`
   - `DRIVE_TYPE` (for example `leadshine-el8` or `generic-cia402`)
   - `ETHERCAT_VID`, `ETHERCAT_PID`
   - Axis scale/tuning values (`AXIS_*_SCALE`, velocity/accel limits) as required by the drive.
3. If the new drive needs different PDO mapping, update `config/ethercat-conf.xml` template accordingly.

> Note: `DRIVE_TYPE` is profile metadata; hardware behavior is defined by generated HAL/INI/XML content.

---

## 3) Adjust tuning (velocity, acceleration, ferror)

Edit tuning values in the target profile:

- Per-axis kinematics limits:
  - `AXIS_X_MAX_VEL`, `AXIS_X_MAX_ACCEL`
  - `AXIS_Y_MAX_VEL`, `AXIS_Y_MAX_ACCEL`
  - `AXIS_Z_MAX_VEL`, `AXIS_Z_MAX_ACCEL`
- Following error:
  - `FERROR`
  - `MIN_FERROR`

These values are substituted into `build/machine.ini` by `./ralph/configure.sh`:

- `[JOINT_n] MAX_VELOCITY`
- `[JOINT_n] MAX_ACCELERATION`
- `[JOINT_n] FERROR`
- `[JOINT_n] MIN_FERROR`

---

## 4) Create new profiles

Use copy-and-edit to keep profiles explicit and reversible.

```bash
cd /Users/joel/dev/linuxcncbot
cp config/profiles/3axis-xyz-sim.env config/profiles/<new-profile>.env
${EDITOR:-vi} config/profiles/<new-profile>.env
```

Minimum fields to set correctly:

- `PROFILE_NAME`, `PROFILE_MODE`
- geometry/kinematics: `COORDINATES`, `NUM_JOINTS`, `KINEMATICS`
- machine identity: `MACHINE_NAME`
- timing/tuning: `SERVO_PERIOD`, `FERROR`, `MIN_FERROR`, `AXIS_*` motion limits/scales
- hardware profiles: `DRIVE_TYPE`, `ETHERCAT_*`
- VM deploy fields: `VM_SSH_PORT`, `VM_SSH_USER`, `VM_SSH_HOST`, `VM_LINUXCNC_DIR`

Activate profile:

```bash
printf '%s\n' '<new-profile>.env' > config/profiles/active
```

---

## Validation workflow (configure + optional deploy/test)

1. Regenerate from active profile:

```bash
cd /Users/joel/dev/linuxcncbot
./ralph/configure.sh
```

2. Confirm generated artifacts and manifest:

```bash
cat build/manifest.json
```

3. Spot-check key substitutions:

```bash
grep -nE '^\[KINS\]|^\[TRAJ\]|^\[JOINT_' build/machine.ini
grep -nE 'loadrt sim_encoder|loadrt scale|joint\.[0-9]+' build/machine.hal
grep -nE '<slave idx=' build/ethercat-conf.xml
```

4. Optional VM deploy and hardware/sim test:

```bash
./ralph/deploy.sh
# Then run your normal LinuxCNC startup and jog checks.
```
