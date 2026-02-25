# IgH master runtime setup

Use `scripts/igh-master-runtime-setup.sh` to configure the IgH EtherCAT runtime on Debian/Linux so the master service starts on boot and binds the intended NIC by MAC.

## Prerequisites

- Debian/Linux host with IgH EtherCAT runtime installed.
- `systemctl` and `ethercat` commands available.
- Root/sudo access.
- MAC address of the target EtherCAT NIC.

## 1) Find the NIC MAC address

Use one of the following:

```bash
ip -br link
```

or:

```bash
for f in /sys/class/net/*/address; do
  printf '%s %s\n' "$(basename "$(dirname "$f")")" "$(cat "$f")"
done
```

## 2) Run runtime setup

From repo root:

```bash
./scripts/igh-master-runtime-setup.sh --mac 00:11:22:33:44:55
```

Optional overrides:

```bash
./scripts/igh-master-runtime-setup.sh \
  --mac 00:11:22:33:44:55 \
  --master-index 0 \
  --config-path /etc/default/ethercat \
  --modules generic \
  --service ethercat
```

Environment variable equivalents are supported:

- `ETHERCAT_NIC_MAC`
- `ETHERCAT_CONFIG_PATH`
- `ETHERCAT_MASTER_INDEX`
- `ETHERCAT_DEVICE_MODULES`
- `ETHERCAT_SERVICE_NAME`

## 3) Verify runtime state

The script runs both verification commands automatically, but you can run them directly:

```bash
sudo ethercat master
sudo ethercat slaves
```

Expected result:

- `ethercat master` shows the configured master/device.
- `ethercat slaves` succeeds and reports discovered slaves (or zero slaves if no bus devices are attached yet).

## Idempotency

The script is deterministic and safe to re-run. It updates the same config keys in place, ensures the service is enabled, and restarts/starts the EtherCAT service consistently.
