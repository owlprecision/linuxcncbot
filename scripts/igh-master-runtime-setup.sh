#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

ETHERCAT_NIC_MAC="${ETHERCAT_NIC_MAC:-}"
ETHERCAT_CONFIG_PATH="${ETHERCAT_CONFIG_PATH:-/etc/default/ethercat}"
ETHERCAT_MASTER_INDEX="${ETHERCAT_MASTER_INDEX:-0}"
ETHERCAT_DEVICE_MODULES="${ETHERCAT_DEVICE_MODULES:-}"
ETHERCAT_SERVICE_NAME="${ETHERCAT_SERVICE_NAME:-ethercat}"

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME --mac <aa:bb:cc:dd:ee:ff> [options]

Configure IgH EtherCAT master runtime so it starts on boot and binds the intended NIC.

Required:
  --mac <mac>                NIC MAC address used to resolve the runtime interface.

Options:
  --config-path <path>       IgH runtime config path (default: $ETHERCAT_CONFIG_PATH)
  --master-index <n>         Master index to configure (default: $ETHERCAT_MASTER_INDEX)
  --modules <module-list>    Optional DEVICE_MODULES value (example: "generic")
  --service <name>           Systemd service name (default: $ETHERCAT_SERVICE_NAME)
  --help, -h                 Show this help

Environment overrides:
  ETHERCAT_NIC_MAC
  ETHERCAT_CONFIG_PATH
  ETHERCAT_MASTER_INDEX
  ETHERCAT_DEVICE_MODULES
  ETHERCAT_SERVICE_NAME

Examples:
  $SCRIPT_NAME --mac 00:11:22:33:44:55
  $SCRIPT_NAME --mac 00:11:22:33:44:55 --modules generic
  $SCRIPT_NAME --mac 00:11:22:33:44:55 --master-index 0 --config-path /etc/default/ethercat
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

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

normalize_mac() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

validate_mac() {
    local mac="$1"
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || die "Invalid MAC format: $mac"
}

validate_master_index() {
    [[ "$ETHERCAT_MASTER_INDEX" =~ ^[0-9]+$ ]] || die "--master-index must be a non-negative integer"
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

ensure_config_file() {
    local path="$1"
    run_as_root mkdir -p "$(dirname "$path")"
    if run_as_root test -f "$path"; then
        pass "Config file exists: $path"
    else
        run_as_root install -m 0644 /dev/null "$path"
        pass "Created config file: $path"
    fi
}

upsert_config_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local current next

    current="$(mktemp)"
    next="$(mktemp)"

    run_as_root cat "$file" > "$current"

    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        $0 ~ "^[[:space:]]*" key "=" {
            if (!found) {
                print key "=\"" value "\""
                found = 1
            }
            next
        }
        { print }
        END {
            if (!found) {
                print key "=\"" value "\""
            }
        }
    ' "$current" > "$next"

    if cmp -s "$current" "$next"; then
        pass "Config key already set: $key"
    else
        run_as_root install -m 0644 "$next" "$file"
        pass "Updated config key: $key"
    fi

    rm -f "$current" "$next"
}

ensure_service_enabled() {
    local service="$1"

    if ! systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${service}.service"; then
        die "Systemd service not found: ${service}.service"
    fi

    info "Enabling service on boot: $service"
    run_as_root systemctl enable "$service" >/dev/null
    pass "Service enabled: $service"
}

restart_or_start_service() {
    local service="$1"

    if systemctl is-active --quiet "$service"; then
        info "Restarting active service: $service"
        run_as_root systemctl restart "$service"
    else
        info "Starting inactive service: $service"
        run_as_root systemctl start "$service"
    fi

    run_as_root systemctl --no-pager --full status "$service" || die "Service failed to start cleanly: $service"
    pass "Service running: $service"
}

verify_runtime() {
    info "Verification: ethercat master"
    run_as_root ethercat master || die "Verification failed: ethercat master"

    info "Verification: ethercat slaves"
    run_as_root ethercat slaves || die "Verification failed: ethercat slaves"

    pass "IgH runtime verification commands completed."
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mac)
                [ "$#" -ge 2 ] || die "--mac requires a value"
                ETHERCAT_NIC_MAC="$2"
                shift 2
                ;;
            --config-path)
                [ "$#" -ge 2 ] || die "--config-path requires a value"
                ETHERCAT_CONFIG_PATH="$2"
                shift 2
                ;;
            --master-index)
                [ "$#" -ge 2 ] || die "--master-index requires a value"
                ETHERCAT_MASTER_INDEX="$2"
                shift 2
                ;;
            --modules)
                [ "$#" -ge 2 ] || die "--modules requires a value"
                ETHERCAT_DEVICE_MODULES="$2"
                shift 2
                ;;
            --service)
                [ "$#" -ge 2 ] || die "--service requires a value"
                ETHERCAT_SERVICE_NAME="$2"
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
    validate_master_index

    require_cmd awk
    require_cmd grep
    require_cmd install
    require_cmd mktemp
    require_cmd systemctl
    require_cmd ethercat

    local mac iface master_key

    mac="$(normalize_mac "$ETHERCAT_NIC_MAC")"
    validate_mac "$mac"

    [ -d /sys/class/net ] || die "Expected Linux sysfs path missing: /sys/class/net"

    iface="$(find_interface_by_mac "$mac" || true)"
    [ -n "$iface" ] || die "No network interface found for MAC: $mac"

    master_key="MASTER${ETHERCAT_MASTER_INDEX}_DEVICE"

    info "Resolved MAC $mac to interface: $iface"
    info "Using config: $ETHERCAT_CONFIG_PATH"
    info "Using master key: $master_key"

    ensure_config_file "$ETHERCAT_CONFIG_PATH"
    upsert_config_key "$ETHERCAT_CONFIG_PATH" "$master_key" "$mac"

    if [ -n "$ETHERCAT_DEVICE_MODULES" ]; then
        upsert_config_key "$ETHERCAT_CONFIG_PATH" "DEVICE_MODULES" "$ETHERCAT_DEVICE_MODULES"
    else
        info "DEVICE_MODULES override not provided; leaving existing value unchanged."
    fi

    ensure_service_enabled "$ETHERCAT_SERVICE_NAME"
    restart_or_start_service "$ETHERCAT_SERVICE_NAME"

    verify_runtime

    pass "IgH EtherCAT master runtime setup complete for MAC $mac (interface $iface)."
}

main "$@"
