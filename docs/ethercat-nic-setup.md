# EtherCAT NIC setup (NetworkManager)

Use `scripts/ethercat-nic-setup.sh` to deterministically bind EtherCAT networking to a specific NIC MAC address, apply static IPv4 settings, and keep that NIC unmanaged by NetworkManager.

## Prerequisites

- Debian/Linux host with NetworkManager.
- `nmcli` and `ip` available.
- Root/sudo access.

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

Pick the MAC address for the physical EtherCAT NIC.

## 2) Run setup

From repo root:

```bash
./scripts/ethercat-nic-setup.sh --mac 00:11:22:33:44:55
```

Optional overrides:

```bash
./scripts/ethercat-nic-setup.sh \
  --mac 00:11:22:33:44:55 \
  --connection-name ethercat0 \
  --ipv4-cidr 192.168.200.1/24 \
  --gateway 192.168.200.254
```

Environment variable equivalents are supported:

- `ETHERCAT_NIC_MAC`
- `ETHERCAT_CONN_NAME`
- `ETHERCAT_IPV4_CIDR`
- `ETHERCAT_IPV4_GATEWAY`

## 3) Verify state

Confirm the interface is detected and unmanaged:

```bash
nmcli device status
nmcli -f GENERAL.DEVICE,GENERAL.HWADDR,GENERAL.STATE,GENERAL.CONNECTION device show <iface>
```

Confirm unmanaged config file exists:

```bash
sudo cat /etc/NetworkManager/conf.d/90-ethercat-unmanaged.conf
```

Confirm static connection values:

```bash
nmcli connection show ethercat-static
ip -4 addr show dev <iface>
```

## Idempotency

The script is safe to re-run. It updates the same NetworkManager config/connection in place and re-applies state for the NIC resolved from the given MAC address.
