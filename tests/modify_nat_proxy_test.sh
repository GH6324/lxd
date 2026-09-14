#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/panel_scripts/modify.sh"
source <(awk '$0 == "prepare_nat_ipv4_proxy() {" { emit=1 } emit { print } emit && /^}$/ { exit }' "$script")
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -f -- "$test_dir/calls"; rmdir -- "$test_dir"' EXIT
name=guest
mock_host='2: wan0    inet 198.51.100.10/24 scope global wan0'
mock_metadata='{"devices":{"root":{"type":"disk","pool":"local","path":"/"}},"expanded_config":{"volatile.uplink.hwaddr":"00:16:3e:11:22:33"},"expanded_devices":{"uplink":{"type":"nic","network":"custom","name":"eth0","mtu":"1400"}}}'
mock_state='{"network":{"enp5s0":{"hwaddr":"00:16:3e:11:22:33","addresses":[{"family":"inet","scope":"global","address":"192.0.2.10"}]}}}'
mock_query_fail=false mock_write_fail=false
ip() { [[ "$*" == '-o -4 addr show scope global' ]] || fail "unexpected IP query $*"; printf '%s\n' "$mock_host"; }
lxc() {
    printf '%s\n' "$*" >>"$test_dir/calls"
    case "$*" in
        'query /1.0/instances/guest') $mock_query_fail && return 1; printf '%s\n' "$mock_metadata" ;;
        'query /1.0/instances/guest/state') printf '%s\n' "$mock_state" ;;
        'config device override guest uplink ipv4.address=192.0.2.10'|'config device set guest uplink ipv4.address=192.0.2.10'|'config device set guest uplink ipv4.address 192.0.2.10') ! $mock_write_fail ;;
        *) fail "unexpected runtime command: $*" ;;
    esac
}
(
    : >"$test_dir/calls"
    prepare_nat_ipv4_proxy || fail 'profile NIC must be matched by VM MAC'
    [[ "$ipv4_address" == 198.51.100.10 ]] || fail 'listener must use concrete host IPv4'
    grep -Fxq 'config device override guest uplink ipv4.address=192.0.2.10' "$test_dir/calls" || fail 'wrong profile NIC'
)
(
    mock_metadata=$(jq '.devices.uplink=.expanded_devices.uplink' <<<"$mock_metadata")
    : >"$test_dir/calls"
    prepare_nat_ipv4_proxy || fail 'local NIC must be configured without override'
    grep -Fxq 'config device set guest uplink ipv4.address=192.0.2.10' "$test_dir/calls" || fail 'wrong local NIC operation'
)
(
    mock_metadata=$(jq '.expanded_devices.uplink["ipv4.address"]="192.0.2.10"' <<<"$mock_metadata")
    : >"$test_dir/calls"
    prepare_nat_ipv4_proxy || fail 'valid static NIC must remain usable'
    [[ "$(wc -l <"$test_dir/calls" | tr -d ' ')" == 1 ]] || fail 'static NIC must not be modified or require running guest state'
)
for scenario in disabled ambiguous query_failure no_host write_failure mac_mismatch; do
    (
        : >"$test_dir/calls"
        case "$scenario" in
            disabled) mock_metadata=$(jq '.expanded_devices.uplink["ipv4.address"]="none"' <<<"$mock_metadata") ;;
            ambiguous) mock_metadata=$(jq '.expanded_devices.other=.expanded_devices.uplink | .expanded_config["volatile.other.hwaddr"]="00:16:3e:11:22:33"' <<<"$mock_metadata") ;;
            query_failure) mock_query_fail=true ;;
            no_host) mock_host='' ;;
            write_failure) mock_write_fail=true ;;
            mac_mismatch) mock_metadata=$(jq '.expanded_devices.uplink.name="enp5s0" | .expanded_devices.uplink.hwaddr="00:16:3e:44:55:66"' <<<"$mock_metadata") ;;
        esac
        if prepare_nat_ipv4_proxy; then fail "$scenario was accepted"; fi
        if [[ "$scenario" != write_failure ]] && grep -q '^config device' "$test_dir/calls"; then
            fail "$scenario changed a NIC before validating the target"
        fi
    )
done
if grep -q 'listen=tcp:0\.0\.0\.0:' "$script" || grep -q 'listen=udp:0\.0\.0\.0:' "$script"; then
    fail 'modify path still installs a wildcard NAT listener'
fi
printf 'LXD modify NAT proxy checks passed (9 scenarios)\n'

