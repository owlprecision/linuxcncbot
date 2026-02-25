# EL7031 First Power-On Stepgen Calibration Checklist

Profile target: `config/profiles/beckhoff-ek1100-2x-el7031.env`

## Prerequisites and risk

- You are at repo root: `/Users/joel/dev/linuxcncbot`
- VM/target is reachable for deploy (`cnc@localhost:2222` per profile)
- E-stop works and removes drive power
- You can cut drive power immediately if motion is wrong

**Immediate safe-stop:** hit E-stop, disable drives, remove motor power.

---

## 1) Activate profile and deploy

```bash
cd /Users/joel/dev/linuxcncbot
printf '%s\n' 'beckhoff-ek1100-2x-el7031.env' > config/profiles/active
./ralph/configure.sh
./ralph/deploy.sh
```

If configure/deploy fails, stop and fix before power-on.

---

## 2) Pre-power safety checks (before enabling motion)

- Mechanics clear; axis travel path unobstructed
- Couplers/set screws tight; no binding by hand
- Limit/home devices wired and readable
- EtherCAT chain correct (EK1100 + 2x EL7031, link stable)
- Only one operator at controls
- Initial limits are conservative in profile:
  - `AXIS_X_MAX_VEL`, `AXIS_Y_MAX_VEL`
  - `AXIS_X_MAX_ACCEL`, `AXIS_Y_MAX_ACCEL`
  - `AXIS_X_MIN_LIMIT`, `AXIS_X_MAX_LIMIT`
  - `AXIS_Y_MIN_LIMIT`, `AXIS_Y_MAX_LIMIT`

---

## 3) Set conservative first-power values

Edit:

```bash
${EDITOR:-vi} config/profiles/beckhoff-ek1100-2x-el7031.env
```

For first motion, use intentionally low values (example starting point):

- `AXIS_X_MAX_VEL=0.5`
- `AXIS_Y_MAX_VEL=0.5`
- `AXIS_X_MAX_ACCEL=5.0`
- `AXIS_Y_MAX_ACCEL=5.0`

Keep travel limits tight to safe local range until direction/scale is verified.

Rebuild and redeploy after edits:

```bash
./ralph/configure.sh
./ralph/deploy.sh
```

---

## 4) Initial jog procedure (one axis at a time)

1. Power control electronics, then drive power.
2. Start LinuxCNC on target.
3. Enable machine with hand near E-stop.
4. Jog **single axis only** in very small increments (for example 0.1 mm then 1.0 mm).
5. Verify smooth motion and immediate stop on disable/E-stop.
6. Repeat for second axis.

If any runaway/stall/unexpected direction: safe-stop immediately.

---

## 5) Direction verification

For each axis:

1. Command a small positive jog (`+` direction on UI).
2. Confirm:
   - axis physically moves in expected positive machine direction
   - displayed position changes with correct sign
3. If direction is reversed, flip sign of scale in profile:
    - `AXIS_X_SCALE=...`
    - `AXIS_Y_SCALE=...`
   - and match feedback sign:
     - `AXIS_X_FB_SCALE=...`
     - `AXIS_Y_FB_SCALE=...`

Example sign flip: `2000` ↔ `-2000`.

Re-run configure/deploy after any sign change.

---

## 6) Pulse-per-unit (scale) calibration

Scale values live in profile:

- `AXIS_X_SCALE`
- `AXIS_Y_SCALE`
- `AXIS_X_FB_SCALE`
- `AXIS_Y_FB_SCALE`

These feed HAL stepgen scaling in `config/machine-2axis-el7031.hal` via `./ralph/configure.sh`.

Calibration method (per axis):

1. Mark/measure from a known reference (indicator or ruler).
2. Command a known move distance `D_cmd` (example: 10.000 mm).
3. Measure actual travel `D_act`.
4. Compute:
    - `new_scale = old_scale * (D_cmd / D_act)`
    - `new_fb_scale = 1 / new_scale`
    - keep the existing sign unless direction is wrong
5. Update `AXIS_*_SCALE` and matching `AXIS_*_FB_SCALE` in profile.
6. Re-run configure/deploy and repeat until error is acceptable.

---

## 7) Velocity/acceleration ramp-up

After direction and scaling are correct:

1. Increase `AXIS_*_MAX_VEL` by ~10-20%.
2. Rebuild/redeploy, jog, and run short back-and-forth moves.
3. Increase `AXIS_*_MAX_ACCEL` by ~10-20%.
4. Repeat until target performance or first instability (stall/ferror/rough motion).
5. Back off to last stable values and keep margin.

Do not increase both aggressively in one jump.

---

## 8) Rollback and recovery

### Immediate motion fault

1. Hit E-stop.
2. Disable drives / remove motor power.
3. Record what move was commanded and fault behavior.

### Config rollback

Before editing, keep a backup:

```bash
cd /Users/joel/dev/linuxcncbot
cp config/profiles/beckhoff-ek1100-2x-el7031.env config/profiles/beckhoff-ek1100-2x-el7031.env.bak
```

Restore backup if needed:

```bash
cd /Users/joel/dev/linuxcncbot
cp config/profiles/beckhoff-ek1100-2x-el7031.env.bak config/profiles/beckhoff-ek1100-2x-el7031.env
./ralph/configure.sh
./ralph/deploy.sh
```

If hardware must be taken out of service, switch active profile to a known sim profile and reconfigure.
