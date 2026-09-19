#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for function_name in runtime_resource_names remove_lxd_persistent_rules remove_lxd_iptables_persistence remove_lxd_fstab_entries prepare_lxd_runtime_cleanup remove_lxd_managed_networks; do
    definition=$(awk -v name="$function_name" '$0==name "() {" { active=1 } active {print} active && /^}$/ {exit}' "$repo_root/scripts/lxduninstall.sh")
    [ -n "$definition" ] || fail "missing $function_name"
    eval "$definition"
done
printf '%s\n' \
    '# host firewall' \
    'include "/etc/nftables.d/*.nft"' \
    'include "/etc/nftables.d/oneclickvirt-lxd.nft"' \
    'table inet host_policy { chain input { type filter hook input priority 0; } }' \
    'table inet lxd_nat { chain postrouting { type nat hook postrouting priority 100; } }' \
    'table inet lxd { chain forward { type filter hook forward priority 0; } }' \
    >"$test_dir/nftables.conf"
remove_lxd_persistent_rules "$test_dir/nftables.conf"
grep -Fq 'table inet host_policy' "$test_dir/nftables.conf" || fail 'host table removed'
grep -Fxq 'include "/etc/nftables.d/*.nft"' "$test_dir/nftables.conf" || fail 'shared include removed'
if grep -q lxd "$test_dir/nftables.conf"; then fail 'LXD persistence survived'; fi
cp "$test_dir/nftables.conf" "$test_dir/expected"
remove_lxd_persistent_rules "$test_dir/nftables.conf"
cmp "$test_dir/expected" "$test_dir/nftables.conf" || fail 'firewall cleanup not idempotent'
printf '%s\n' \
    'UUID=root / ext4 defaults 0 1' \
    '/data/other.img /data/other btrfs loop 0 0' \
    '/data/lxd-storage/btrfs_pool.img /data/lxd-storage/btrfs_mount btrfs loop 0 0' \
    '/custom/lxd/btrfs_pool.img /custom/lxd/btrfs_mount btrfs loop 0 0' \
    '/custom/lxd/btrfs_pool.img /another-mount btrfs loop 0 0' \
    >"$test_dir/fstab"
remove_lxd_fstab_entries "$test_dir/fstab" /custom/lxd
[ "$(wc -l <"$test_dir/fstab" | tr -d ' ')" -eq 3 ] || fail 'unexpected fstab records removed'
grep -Fq '/data/other.img' "$test_dir/fstab" || fail 'unrelated btrfs entry removed'
grep -Fq '/another-mount' "$test_dir/fstab" || fail 'unrelated mount target removed'
cp "$test_dir/fstab" "$test_dir/expected"
remove_lxd_fstab_entries "$test_dir/fstab" /custom/lxd
cmp "$test_dir/expected" "$test_dir/fstab" || fail 'fstab cleanup not idempotent'
printf 'PASS: LXD uninstall preserves unrelated firewall and btrfs configuration\n'

printf '%s\n' '*nat' ':POSTROUTING ACCEPT [0:0]' \
    '-A POSTROUTING -s 10.78.1.0/24 ! -o lxdbr0 -m comment --comment "oneclickvirt-lxd-ipv4" -j MASQUERADE' \
    '-A POSTROUTING -j MASQUERADE' \
    '-A POSTROUTING -s 198.18.0.0/24 -m comment --comment "oneclickvirt-lxd-ipv4-custom" -j MASQUERADE' \
    'COMMIT' >"$test_dir/rules.v4"
chmod 600 "$test_dir/rules.v4"
remove_lxd_iptables_persistence "$test_dir/rules.v4"
[ "$(wc -l <"$test_dir/rules.v4" | tr -d ' ')" -eq 5 ] || fail 'persistent iptables cleanup changed unrelated lines'
grep -Fxq -- '-A POSTROUTING -j MASQUERADE' "$test_dir/rules.v4" || fail 'persistent host-wide NAT removed'
grep -Fq 'oneclickvirt-lxd-ipv4-custom' "$test_dir/rules.v4" || fail 'persistent administrator tag removed'
cp "$test_dir/rules.v4" "$test_dir/expected"
remove_lxd_iptables_persistence "$test_dir/rules.v4"
cmp "$test_dir/expected" "$test_dir/rules.v4" || fail 'persistent iptables cleanup not idempotent'
remove_lxd_iptables_persistence "$test_dir/no-persistent-policy"
[ ! -e "$test_dir/no-persistent-policy" ] || fail 'uninstall created a missing policy'
printf 'PASS: persistent iptables cleanup preserves unrelated rules and handles repeated/absent policies\n'

# Model the daemon's reference graph: deleting a managed bridge must fail until
# every profile using it is detached. A host bridge must never be deleted.
_red() { printf '%s\n' "$*" >&2; }
export LXC_CMD=mock_lxc
mock_lxc() {
    printf '%s\n' "$*" >>"$test_dir/commands"
    case "$*" in
        'project list --format json')
            if [ "${extra_project:-false}" = true ]; then printf '[{"name":"default"},{"name":"production"}]\n'; else printf '[{"name":"default"}]\n'; fi
            ;;
        'profile list --format csv -c n')
            [ "${inventory_error:-false}" != true ] || return 39
            printf '%s\n' default custom-profile
            ;;
        'profile device list default') printf '%s\n' root eth0 ;;
        'profile device list custom-profile') printf '%s\n' alternate-nic ;;
        'profile device remove default root') ;;
        'profile device remove default eth0')
            [ "${detach_error:-false}" != true ] || return 40
            : >"$test_dir/default-detached"
            ;;
        'profile device remove custom-profile alternate-nic') : >"$test_dir/custom-detached" ;;
        'network list --format json')
            [ "${network_inventory_error:-false}" != true ] || return 41
            if [ "${network_inventory_invalid:-false}" = true ]; then
                printf '[{"name":"lxdbr0","managed":true},{"name":"hostbr0"}]\n'
            else
                printf '[{"name":"lxdbr0","managed":true},{"name":"custom-managed","managed":true},{"name":"eth0","managed":false},{"name":"hostbr0","managed":false}]\n'
            fi
            ;;
        'network delete lxdbr0'|'network delete custom-managed')
            [ "${network_delete_error:-false}" != true ] || return 42
            [ -f "$test_dir/default-detached" ] && [ -f "$test_dir/custom-detached" ] || return 43
            ;;
        *) fail "unexpected runtime mutation: $*" ;;
    esac
}
prepare_lxd_runtime_cleanup
remove_lxd_managed_networks
grep -Fxq 'network delete lxdbr0' "$test_dir/commands" || fail 'managed bridge was not removed'
grep -Fxq 'network delete custom-managed' "$test_dir/commands" || fail 'managed network with custom name was not removed'
for failure in extra_project inventory_error detach_error; do
    if (export "$failure=true"; prepare_lxd_runtime_cleanup) >/dev/null 2>&1; then
        fail "runtime cleanup hid $failure"
    fi
done
for failure in network_inventory_error network_inventory_invalid network_delete_error; do
    : >"$test_dir/commands"
    if (export "$failure=true"; remove_lxd_managed_networks) >/dev/null 2>&1; then
        fail "network cleanup hid $failure"
    fi
    if [[ "$failure" != network_delete_error ]] && grep -q '^network delete ' "$test_dir/commands"; then
        fail 'invalid or failed network inventory triggered partial deletion'
    fi
done
printf 'PASS: LXD cleanup detaches profile references, checks project scope and surfaces daemon failures\n'
