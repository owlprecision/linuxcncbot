#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

ETHERCAT_NIC_MAC="${ETHERCAT_NIC_MAC:-}"
ETHERCAT_CONN_NAME="${ETHERCAT_CONN_NAME:-ethercat-static}"
ETHERCAT_IPV4_CIDR="${ETHERCAT_IPV4_CIDR:-192.168.200.1/24}"
ETHERCAT_IPV4_GATEWAY="${ETHERCAT_IPV4_GATEWAY:-}"

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME --mac <aa:bb:cc:dd:ee:ff> [options]

Deterministically configure an EtherCAT NIC with NetworkManager.

Required:
  --mac <mac>              NIC MAC address used to identify the interface.

Options:
  --connection-name <name> NetworkManager connection name (default: $ETHERCAT_CONN_NAME)
  --ipv4-cidr <cidr>       Static IPv4 CIDR (default: $ETHERCAT_IPV4_CIDR)
  --gateway <ip>           Optional IPv4 gateway (default: none)
  --help, -h               Show this help

Environment overrides:
  ETHERCAT_NIC_MAC
  ETHERCAT_CONN_NAME
  ETHERCAT_IPV4_CIDR
  ETHERCAT_IPV4_GATEWAY

Examples:
  $SCRIPT_NAME --mac 00:11:22:33:44:55
  $SCRIPT_NAME --mac 00:11:22:33:44:55 --ipv4-cidr 192.168.10.1/24 --connection-name ethercat0
USAGE
}

info() {
    echo "[INFO] $*"
}

pass() {
    echo "[PASS] $*"
}

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "This step requires root privileges and sudo is not available."
    fi
}

normalize_mac() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

find_interface_by_mac() {
    local target_mac="$1"
    local iface

    for addr_file in /sys/class/net/*/address; do
        [ -e "$addr_file" ] || continue
        iface="$(basename "$(dirname "$addr_file")")"
        if [ "$(normalize_mac "$(cat "$addr_file")")" = "$target_mac" ]; then
            echo "$iface"
            return 0
        fi
    done

    return 1
}

write_nm_unmanaged_config() {
    local mac="$1"
    local conf_dir="/etc/NetworkManager/conf.d"
    local conf_file="$conf_dir/90-ethercat-unmanaged.conf"
    local tmp

    tmp="$(mktemp)"
    cat > "$tmp" <<CONF
# Managed by $SCRIPT_NAME
[keyfile]
unmanaged-devices=mac:$mac
CONF

    run_as_root mkdir -p "$conf_dir"

    if run_as_root test -f "$conf_file" && run_as_root cmp -s "$tmp" "$conf_file"; then
        pass "NetworkManager unmanaged config already up to date: $conf_file"
    else
        run_as_root install -m 0644 "$tmp" "$conf_file"
        pass "Wrote NetworkManager unmanaged config: $conf_file"
    fi

    rm -f "$tmp"
}

ensure_nm_connection() {
    local conn="$1"
    local iface="$2"
    local mac="$3"
    local cidr="$4"
    local gw="$5"

    if nmcli -t -f NAME connection show | grep -Fxq "$conn"; then
        info "Updating existing connection: $conn"
    else
        info "Creating connection: $conn"
        run_as_root nmcli connection add type ethernet ifname "$iface" con-name "$conn" >/dev/null
    fi

    run_as_root nmcli connection modify "$conn" \
        connection.interface-name "$iface" \
        802-3-ethernet.mac-address "$mac" \
        connection.autoconnect yes \
        ipv4.method manual \
        ipv4.addresses "$cidr" \
        ipv6.method ignore

    if [ -n "$gw" ]; then
        run_as_root nmcli connection modify "$conn" ipv4.gateway "$gw"
    else
        run_as_root nmcli connection modify "$conn" -ipv4.gateway
    fi

    run_as_root nmcli connection up "$conn" >/dev/null
    pass "Static NetworkManager connection applied: $conn ($iface, $cidr)"
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mac)
                [ "$#" -ge 2 ] || die "--mac requires a value"
                ETHERCAT_NIC_MAC="$2"
                shift 2
                ;;
            --connection-name)
                [ "$#" -ge 2 ] || die "--connection-name requires a value"
                ETHERCAT_CONN_NAME="$2"
                shift 2
                ;;
            --ipv4-cidr)
                [ "$#" -ge 2 ] || die "--ipv4-cidr requires a value"
                ETHERCAT_IPV4_CIDR="$2"
                shift 2
                ;;
            --gateway)
                [ "$#" -ge 2 ] || die "--gateway requires a value"
                ETHERCAT_IPV4_GATEWAY="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    [ -n "$ETHERCAT_NIC_MAC" ] || die "Missing required --mac (or ETHERCAT_NIC_MAC)."

    require_cmd ip
    require_cmd nmcli
    require_cmd NetworkManager

    local mac iface
    mac="$(normalize_mac "$ETHERCAT_NIC_MAC")"

    iface="$(find_interface_by_mac "$mac" || true)"
    [ -n "$iface" ] || die "No network interface found for MAC: $mac"

    info "Resolved EtherCAT NIC MAC $mac to interface: $iface"

    ensure_nm_connection "$ETHERCAT_CONN_NAME" "$iface" "$mac" "$ETHERCAT_IPV4_CIDR" "$ETHERCAT_IPV4_GATEWAY"

    write_nm_unmanaged_config "$mac"

    info "Reloading NetworkManager configuration"
    run_as_root nmcli general reload

    info "Marking device unmanaged at runtime: $iface"
    run_as_root nmcli device set "$iface" managed no

    pass "EtherCAT NIC setup complete for $iface ($mac)."
}

main "$@"
