# Hardware Verification Gates (EK1100 + 2x EL7031)

These scripted gates are run through `./ralph/test.sh` when the active profile is EtherCAT (`PROFILE_MODE=ethercat`).

## Gates

1. **EtherCAT bus scan gate** — `tests/test-hardware-ethercat-scan.sh`
   - Runs: `ethercat slaves`
   - Pass criteria: exactly **1x EK1100** and **2x EL7031** are detected.
   - Pass output includes:
     - `GATE ethercat_bus_scan PASS`
     - `DETECTED_EK1100=1`
     - `DETECTED_EL7031=2`

2. **LinuxCNC config load gate** — `tests/test-hardware-config-loads.sh`
   - Verifies hardware HAL uses `lcec` and `lcec_conf build/ethercat-conf.xml`.
   - Runs: `linuxcnc --check build/machine.ini`
   - Pass output includes:
     - `GATE linuxcnc_config_load PASS`

3. **Axis enable/jog low-speed gate** — `tests/test-hardware-axis-jog.sh`
   - Verifies HAL has amp-enable wiring for joint 0/1.
   - Runs a low-speed XY motion batch program (`F60`) as a scripted jog proxy.
   - Pass output includes:
     - `GATE axis_enable_jog_low_speed PASS`
     - `JOG_FEED=60`
     - `JOG_AXES=XY`

## Notes

- If a non-hardware profile is active, each hardware gate exits success with an explicit `SKIP` line.
- In `./ralph/test.sh` JSON output, these gates appear as normal tests with `status: "pass"` when passing (or skipped-by-profile).
