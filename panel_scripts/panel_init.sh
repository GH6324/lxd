#!/bin/bash
# by https://github.com/oneclickvirt/lxd
# 2025.08.14

# curl -L https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/lxdinstall.sh -o lxdinstall.sh && chmod +x lxdinstall.sh && bash lxdinstall.sh

cd /root >/dev/null 2>&1 || exit 1
# Snap installs expose lxc under /snap/bin.  panel_init.sh is usually run in
# a fresh non-login shell, so do not rely on /etc/profile or a .bashrc alias.
export PATH="${PATH}:/snap/bin:/var/lib/snapd/snap/bin"
REGEX=("debian|astra" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon[[:space:]]+linux" "fedora" "arch" "freebsd")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "FreeBSD")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(uname -s)")
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
if [ ! -d "/usr/local/bin" ]; then
    mkdir -p /usr/local/bin || exit 1
fi
_red() { printf '\033[31m\033[01m%s\033[0m\n' "$*"; }
_green() { printf '\033[32m\033[01m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[33m\033[01m%s\033[0m\n' "$*"; }
_blue() { printf '\033[36m\033[01m%s\033[0m\n' "$*"; }
reading() { read -rp "$(_green "$1")" "$2"; }

# 服务管理兼容性函数
service_manager() {
    local action=$1
    local service_name=$2
    local success=false
    
    case "$action" in
        enable)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable "$service_name" 2>/dev/null && success=true
            fi
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add "$service_name" default 2>/dev/null && success=true
            fi
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "$service_name" defaults 2>/dev/null && success=true
            fi
            ;;
        start)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl start "$service_name" 2>/dev/null && success=true
            fi
            if ! $success && command -v rc-service >/dev/null 2>&1; then
                rc-service "$service_name" start 2>/dev/null && success=true
            fi
            if ! $success && command -v service >/dev/null 2>&1; then
                service "$service_name" start 2>/dev/null && success=true
            fi
            if ! $success && [ -x "/etc/init.d/$service_name" ]; then
                /etc/init.d/"$service_name" start 2>/dev/null && success=true
            fi
            ;;
        restart)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart "$service_name" 2>/dev/null && success=true
            fi
            if ! $success && command -v rc-service >/dev/null 2>&1; then
                rc-service "$service_name" restart 2>/dev/null && success=true
            fi
            if ! $success && command -v service >/dev/null 2>&1; then
                service "$service_name" restart 2>/dev/null && success=true
            fi
            if ! $success && [ -x "/etc/init.d/$service_name" ]; then
                /etc/init.d/"$service_name" restart 2>/dev/null && success=true
            fi
            ;;
        daemon-reload)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload 2>/dev/null && success=true
            else
                success=true
            fi
            ;;
    esac
    
    $success && return 0 || return 1
}

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
export DEBIAN_FRONTEND=noninteractive
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    _green "Locale set to $utf8_locale"
fi

install_package() {
    local package_name="$1"
    if [ -z "$package_name" ]; then
        _red "Package name is empty"
        return 1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name" >/dev/null ||
            DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing "$package_name" >/dev/null || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$package_name" >/dev/null || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$package_name" >/dev/null || return 1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm --needed "$package_name" >/dev/null || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$package_name" >/dev/null || return 1
    else
        _red "No supported package manager found for $package_name"
        return 1
    fi
    if [ "$package_name" = "jq" ] && ! command -v jq >/dev/null 2>&1; then
        _red "jq was installed but is still unavailable"
        return 1
    fi
    if [ "$package_name" = "dos2unix" ] && ! command -v dos2unix >/dev/null 2>&1; then
        _red "dos2unix was installed but is still unavailable"
        return 1
    fi
    if [ "$package_name" = "uidmap" ] && ! command -v newuidmap >/dev/null 2>&1; then
        _red "uidmap was installed but newuidmap is unavailable"
        return 1
    fi
    _green "$package_name is ready"
    return 0
}

# Other vendor sysctl files can contain unsupported optional keys. Validate
# the forwarding file we own and the effective value before declaring ready.
apply_forwarding_config() {
    local config_file="$1"
    if sysctl --help 2>&1 | grep -q -- '--system'; then
        if ! sysctl --system >/dev/null 2>&1; then
            sysctl -p "$config_file" >/dev/null 2>&1 || return 1
        fi
    else
        sysctl -p "$config_file" >/dev/null 2>&1 || return 1
    fi
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] || {
        _red "Required IPv4 forwarding is not enabled"
        return 1
    }
}

install_uidmap() {
    if command -v newuidmap >/dev/null 2>&1 && command -v newgidmap >/dev/null 2>&1; then
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        install_package uidmap || return 1
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        install_package shadow-utils || return 1
    elif command -v apk >/dev/null 2>&1; then
        install_package shadow-uidmap || install_package shadow || return 1
    elif command -v pacman >/dev/null 2>&1; then
        install_package shadow || return 1
    else
        _red "No supported package manager found for uidmap"
        return 1
    fi
    if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
        _red "newuidmap/newgidmap are still unavailable after package installation"
        return 1
    fi
}

prepare_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf makecache -y >/dev/null || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum makecache -y >/dev/null || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null || return 1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm >/dev/null || return 1
    else
        _red "No supported package manager found"
        return 1
    fi
}

# A snap package can be installed and its daemon can be reachable before LXD
# has been initialized.  Treat an empty storage list as an uninitialized
# runtime and repair it before touching profiles or lxdbr0.  Existing pools
# and profile devices are preserved.
# JSON inventories work on LTS clients whose storage/network list has no -c.
# Capture the command first so a daemon failure cannot become an empty list.
runtime_resource_names() {
    local data
    data=$(lxc "$1" list --format json) || return 1
    jq -sr '
        if length != 1 or (.[0] | type) != "array" then error("invalid runtime inventory")
        else .[0] end |
        if all(.[]; type == "object" and (.name | type) == "string" and (.name | length) > 0)
        then .[].name else error("invalid resource name") end
    ' <<<"$data"
}

ensure_runtime_storage() {
    local pools init_output init_status
    command -v lxc >/dev/null 2>&1 || {
        _red "lxc command is unavailable"
        return 1
    }
    lxd waitready --timeout=120 >/dev/null 2>&1 || {
        _red "LXD daemon is not ready"
        return 1
    }
    pools=$(runtime_resource_names storage 2>/dev/null) || {
        init_output=$(lxd init --auto 2>&1)
        init_status=$?
        if [ "$init_status" -ne 0 ] && ! grep -Eiq 'already[[:space:]]+(been[[:space:]]+)?initialized|already[[:space:]]+exists|already[[:space:]]+configured' <<<"$init_output"; then
            printf '%s\n' "$init_output" >&2
            _red "LXD storage initialization failed"
            return 1
        fi
        pools=$(runtime_resource_names storage 2>/dev/null) || return 1
    }
    if [ -z "$pools" ]; then
        init_output=$(lxd init --auto 2>&1)
        init_status=$?
        if [ "$init_status" -ne 0 ] && ! grep -Eiq 'already[[:space:]]+(been[[:space:]]+)?initialized|already[[:space:]]+exists|already[[:space:]]+configured' <<<"$init_output"; then
            printf '%s\n' "$init_output" >&2
            _red "LXD storage initialization failed"
            return 1
        fi
        pools=$(runtime_resource_names storage 2>/dev/null) || return 1
    fi
    if [ -z "$pools" ]; then
        # Recover distro/snap combinations that have an initialized daemon but
        # no pool.  A dir pool is safe for existing data because no pool exists
        # yet; all non-empty configurations are left untouched above.
        lxc storage create default dir >/dev/null 2>&1 || return 1
        pools=$(runtime_resource_names storage 2>/dev/null) || return 1
    fi
    [ -n "$pools" ] || {
        _red "LXD has no usable storage pool after initialization"
        return 1
    }
    # Select a pool only when adding a missing root device. An existing
    # profile may already select a non-default pool among several pools.
    return 0
}

select_storage_pool_for_profile() {
    local pools selected
    pools=$(runtime_resource_names storage 2>/dev/null) || return 1
    if grep -Fxq default <<<"$pools"; then
        selected=default
    else
        selected=$(printf '%s\n' "$pools" | tr -d '\r' | awk 'NF { count++; first=$0 } END { if (count == 1) print first }')
    fi
    [ -n "${selected:-}" ] || {
        _red "无法唯一确定 LXD 存储池，拒绝自动接管"
        return 1
    }
    lxc storage show "$selected" >/dev/null 2>&1 || return 1
    printf '%s\n' "$selected"
}

ensure_default_bridge() {
    local bridge=lxdbr0 networks
    networks=$(runtime_resource_names network 2>/dev/null) || return 1
    if ! grep -Fxq "$bridge" <<<"$networks"; then
        if ip link show dev "$bridge" >/dev/null 2>&1; then
            _red "$bridge 已被宿主机外部设备占用，拒绝替换"
            return 1
        fi
        lxc network create "$bridge" ipv4.address=auto ipv4.nat=true ipv4.dhcp=true ipv6.address=none || return 1
        lxc network set "$bridge" ipv6.address auto || _yellow "IPv6 setup unavailable; retaining IPv4-only mode"
    fi
}

api_metadata() {
    # Slurp first: jq 1.6 can exit successfully on empty input even with -e.
    # Exactly one object is required before any default-setting mutation.
    jq -cs --arg resource "${1:-object}" '
        if length != 1 or (.[0] | type) != "object"
        then error("expected one API object") else .[0] end |
        if has("metadata") then
            if .type == "sync" and (.metadata | type) == "object"
               and ((has("status_code") | not) or .status_code == 200)
            then .metadata else error("invalid API envelope") end
        elif .type == "error" or .type == "async" or .type == "sync"
        then error("invalid API response") else . end |
        if $resource == "profile" then
            if (.devices | type) == "object"
               and all(.devices[]; type == "object" and all(.[]; type == "string"))
            then . else error("invalid profile devices") end
        elif $resource == "network" then
            if .type == "bridge" and .managed == true
               and (.config | type) == "object" and all(.config[]; type == "string")
            then . else error("invalid managed bridge configuration") end
        else . end
    '
}

ensure_default_profile_devices() {
    local profiles profile pool roots nics nic network
    profiles=$(lxc profile list --format csv -c n) || return 1
    if ! grep -Fxq default <<<"$profiles"; then
        lxc profile create default || return 1
    fi
    # Do not turn a failed/empty query into an empty, apparently valid
    # profile: jq alone can succeed when the command before the pipe fails.
    profile=$(lxc query /1.0/profiles/default) || return 1
    profile=$(api_metadata profile <<<"$profile") || return 1
    roots=$(jq -er '[.devices // {} | to_entries[] | select(.value.type == "disk" and .value.path == "/")] | length' <<<"$profile") || return 1
    if [ "$roots" -eq 0 ]; then
        jq -e '.devices.root != null' <<<"$profile" >/dev/null && {
            _red "default profile 的 root 设备已被占用，拒绝覆盖"
            return 1
        }
        pool=$(select_storage_pool_for_profile) || return 1
        lxc profile device add default root disk path=/ pool="$pool" || return 1
    elif [ "$roots" -eq 1 ]; then
        pool=$(jq -r '.devices[] | select(.type == "disk" and .path == "/") | .pool // empty' <<<"$profile")
        [ -n "$pool" ] && lxc storage show "$pool" >/dev/null 2>&1 || {
            _red "default profile 的 root 存储池不可用"
            return 1
        }
    else
        _red "default profile 存在多个 root 磁盘，拒绝自动修改"
        return 1
    fi

    nics=$(jq -er '[.devices // {} | to_entries[] | select(.value.type == "nic")] | length' <<<"$profile") || return 1
    if [ "$nics" -eq 0 ]; then
        if jq -e '.devices.eth0 != null' <<<"$profile" >/dev/null; then
            _red "default profile 的 eth0 设备已被占用，拒绝覆盖"
            return 1
        fi
        lxc profile device add default eth0 nic network=lxdbr0 name=eth0 || return 1
    else
        while IFS= read -r nic; do
            network=$(jq -r '.network // empty' <<<"$nic") || return 1
            if [ "$network" = lxdbr0 ] || [ "$network" = none ]; then
                continue
            elif [ -n "$network" ]; then
                lxc network show "$network" >/dev/null 2>&1 || return 1
            else
                network=$(jq -r '.parent // empty' <<<"$nic") || return 1
                [ -z "$network" ] || [ "$network" = lxdbr0 ] || ip link show dev "$network" >/dev/null 2>&1 || return 1
            fi
        done < <(jq -c '.devices[]? | select(.type == "nic")' <<<"$profile")
    fi
}

verify_runtime_network() {
    local profile network pool ipv4 dhcp
    command -v lxc >/dev/null 2>&1 || { _red "lxc command is unavailable"; return 1; }
    command -v jq >/dev/null 2>&1 || { _red "jq is required to verify LXD"; return 1; }
    lxc info >/dev/null 2>&1 || { _red "LXD daemon is unavailable"; return 1; }
    network=$(lxc query /1.0/networks/lxdbr0 2>/dev/null) || { _red "lxdbr0 is missing"; return 1; }
    network=$(api_metadata network <<<"$network") || return 1
    jq -e '.type == "bridge" and .managed == true' <<<"$network" >/dev/null || { _red "lxdbr0 is not a managed bridge"; return 1; }
    ipv4=$(jq -r '.config["ipv4.address"] // empty' <<<"$network") || return 1
    dhcp=$(jq -r '.config["ipv4.dhcp"] // empty' <<<"$network") || return 1
    [ -n "$ipv4" ] && [ "$ipv4" != "none" ] && [ "$dhcp" != "false" ] || {
        _red "lxdbr0 does not provide required IPv4 addressing/DHCP"
        return 1
    }
    profile=$(lxc query /1.0/profiles/default 2>/dev/null) || { _red "default profile is missing"; return 1; }
    profile=$(api_metadata profile <<<"$profile") || return 1
    pool=$(jq -r '[.devices[]? | select(.type == "disk" and .path == "/") | .pool // empty] | if length == 1 then .[0] else empty end' <<<"$profile") || return 1
    [ -n "$pool" ] && lxc storage show "$pool" >/dev/null 2>&1 || { _red "default profile has no usable root storage pool"; return 1; }
    local link_attempt=0
    while ! ip link show dev lxdbr0 >/dev/null 2>&1; do
        link_attempt=$((link_attempt + 1))
        if [ "$link_attempt" -ge 10 ]; then
            _red "lxdbr0 host interface is missing"
            return 1
        fi
        sleep 1
    done
}

configure_default_network_settings() {
    local config ipv4 ipv6 dns_mode raw_dnsmasq dhcp nat
    ensure_default_bridge || return 1
    config=$(lxc query /1.0/networks/lxdbr0) || return 1
    config=$(api_metadata network <<<"$config") || return 1
    ipv4=$(jq -r '.config["ipv4.address"] // empty' <<<"$config") || return 1
    if [ -z "$ipv4" ]; then
        lxc network set lxdbr0 ipv4.address auto || return 1
    elif [ "$ipv4" = "none" ]; then
        _red "lxdbr0 explicitly disables IPv4 addressing"
        return 1
    fi
    ipv6=$(jq -r '.config["ipv6.address"] // empty' <<<"$config") || return 1
    if [ -z "$ipv6" ]; then
        lxc network set lxdbr0 ipv6.address auto || _yellow "IPv6 setup unavailable; preserving IPv4-only mode"
    fi
    dhcp=$(jq -r '.config["ipv4.dhcp"] // empty' <<<"$config") || return 1
    if [ -z "$dhcp" ]; then
        lxc network set lxdbr0 ipv4.dhcp true || return 1
    elif [ "$dhcp" = "false" ]; then
        _red "lxdbr0 explicitly disables IPv4 DHCP"
        return 1
    fi
    nat=$(jq -r '.config["ipv4.nat"] // empty' <<<"$config") || return 1
    if [ -z "$nat" ]; then
        lxc network set lxdbr0 ipv4.nat true || return 1
    elif [ "$nat" = "false" ]; then
        # Routed subnets and installer-managed masquerading can intentionally
        # disable the daemon's NAT. Preserve that choice, as the main installer does.
        _yellow "lxdbr0 IPv4 NAT is disabled; external routing/NAT must provide connectivity"
    fi
    dns_mode=$(jq -r '.config["dns.mode"] // empty' <<<"$config") || return 1
    if [ -z "$dns_mode" ]; then
        lxc network set lxdbr0 dns.mode managed || return 1
    fi
    # dns.mode can already be managed on a partially initialized host; ensure
    # dnsmasq has reachable upstreams while preserving custom raw.dnsmasq.
    raw_dnsmasq=$(jq -r '.config["raw.dnsmasq"] // empty' <<<"$config") || return 1
    if [ -z "$raw_dnsmasq" ]; then
        lxc network set lxdbr0 raw.dnsmasq $'server=1.1.1.1\nserver=8.8.8.8' || return 1
    fi
}

# LXD host-address proxy mappings require Linux bridge netfilter. Make the
# prerequisite explicit and persist it so published SSH ports remain usable
# after a reboot.
ensure_bridge_netfilter() {
    local module_file=/etc/modules-load.d/oneclickvirt-bridge-netfilter.conf
    if [ ! -d /proc/sys/net/bridge ]; then
        command -v modprobe >/dev/null 2>&1 || return 1
        modprobe br_netfilter || return 1
    fi
    [ -d /proc/sys/net/bridge ] || return 1
    command -v sysctl >/dev/null 2>&1 || return 1
    sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null || return 1
    sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null || return 1
    mkdir -p /etc/modules-load.d /etc/sysctl.d || return 1
    if [ ! -f "$module_file" ] || ! grep -Fxq br_netfilter "$module_file"; then
        printf '%s\n' br_netfilter >"$module_file" || return 1
    fi
    local sysctl_file=/etc/sysctl.d/99-oneclickvirt-bridge.conf
    if [ ! -f "$sysctl_file" ] || ! grep -Eq '^net\.bridge\.bridge-nf-call-iptables=1$' "$sysctl_file"; then
        printf '%s\n' 'net.bridge.bridge-nf-call-iptables=1' >>"$sysctl_file" || return 1
    fi
    if ! grep -Eq '^net\.bridge\.bridge-nf-call-ip6tables=1$' "$sysctl_file"; then
        printf '%s\n' 'net.bridge.bridge-nf-call-ip6tables=1' >>"$sysctl_file" || return 1
    fi
}

prepare_package_manager || { _red "Package index preparation failed"; exit 1; }
for package_name in jq dos2unix curl; do
    install_package "$package_name" || exit 1
done
install_uidmap || exit 1
ensure_runtime_storage || exit 1
configure_default_network_settings || exit 1
ensure_default_profile_devices || exit 1
verify_runtime_network || exit 1
ensure_bridge_netfilter || { _red "br_netfilter is required for LXD proxy port mappings"; exit 1; }

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=()
    mapfile -t shuffled_cdn_urls < <(printf '%s\n' "${cdn_urls[@]}" | shuf)
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    local withoutcdn_upper
    withoutcdn_upper=$(printf '%s' "${WITHOUTCDN:-}" | tr '[:lower:]' '[:upper:]')
    if [ "$withoutcdn_upper" = "TRUE" ]; then
        export cdn_success_url=""
        echo "WITHOUTCDN=TRUE, skip CDN acceleration"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        echo "CDN available, using CDN"
    else
        echo "No CDN available, no use CDN"
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    if ! curl -fsSLk "${cdn_success_url}${url}" -o "$output"; then
        _red "Failed to download: ${url}"
        _red "下载失败：${url}"
        exit 1
    fi
}

statistics_of_run_times() {
    COUNT=$(curl -4 -ksm1 "https://hits.spiritlhl.net/lxd?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null ||
        curl -6 -ksm1 "https://hits.spiritlhl.net/lxd?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null)
    TODAY=$(echo "$COUNT" | grep -oE '"daily":[[:space:]]*[0-9]+' | sed 's/"daily":[[:space:]]*\([0-9]*\)/\1/')
    TOTAL=$(echo "$COUNT" | grep -oE '"total":[[:space:]]*[0-9]+' | sed 's/"total":[[:space:]]*\([0-9]*\)/\1/')
}

check_cdn_file
statistics_of_run_times
_green "脚本当天运行次数:${TODAY:-0}，累计运行次数:${TOTAL:-0}"

lxc config set core.https_address 0.0.0.0:8443 || exit 1
service_manager restart snap.lxd.daemon || exit 1

# 设置镜像不更新
lxc config unset images.auto_update_interval >/dev/null 2>&1 || true
lxc config set images.auto_update_interval 0 || exit 1
# 下载预制文件
files=(
    "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_bash.sh"
    "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_sh.sh"
    "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/config.sh"
    "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/buildct.sh"
)
for file in "${files[@]}"; do
    filename=$(basename "$file")
    rm -f -- "$filename"
    download_file "$file" "$filename"
    chmod 755 "$filename" || exit 1
    dos2unix "$filename" || exit 1
done
cp /root/ssh_sh.sh /usr/local/bin/ || exit 1
cp /root/ssh_bash.sh /usr/local/bin/ || exit 1
cp /root/config.sh /usr/local/bin/ || exit 1
command -v sysctl >/dev/null 2>&1 || exit 1
sysctl -w net.ipv4.ip_forward=1 >/dev/null || exit 1
if [ -f "/etc/sysctl.conf" ]; then
    if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        sed -i 's/^#\?net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf || exit 1
    fi
fi
SYSCTL_D_CONF="/etc/sysctl.d/99-custom.conf"
mkdir -p /etc/sysctl.d || exit 1
if ! grep -q "^net.ipv4.ip_forward=1" "$SYSCTL_D_CONF" 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >>"$SYSCTL_D_CONF" || exit 1
fi
apply_forwarding_config "$SYSCTL_D_CONF" || exit 1
# 解除进程数限制
if [ -f "/etc/security/limits.conf" ]; then
    if ! grep -Fq "*          hard    nproc       unlimited" /etc/security/limits.conf; then
        printf '%s\n' '*          hard    nproc       unlimited' >>/etc/security/limits.conf || exit 1
    fi
    if ! grep -Fq "*          soft    nproc       unlimited" /etc/security/limits.conf; then
        printf '%s\n' '*          soft    nproc       unlimited' >>/etc/security/limits.conf || exit 1
    fi
fi
if [ -f "/etc/systemd/logind.conf" ]; then
    if ! grep -q "UserTasksMax=infinity" /etc/systemd/logind.conf; then
        printf '%s\n' 'UserTasksMax=infinity' >>/etc/systemd/logind.conf || exit 1
    fi
fi
# 环境安装
# 按发行版选择 vnstat 的等价编译依赖，避免在 dnf/yum/apk 节点使用
# Debian 专用包名导致面板初始化失败。
install_vnstat_dependencies() {
    local packages=()
    if command -v apt-get >/dev/null 2>&1; then
        packages=(make gcc libc6-dev libsqlite3-0 libsqlite3-dev libgd3 libgd-dev)
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        packages=(make gcc glibc-devel sqlite sqlite-devel gd gd-devel)
    elif command -v apk >/dev/null 2>&1; then
        packages=(build-base sqlite-dev gd-dev)
    elif command -v pacman >/dev/null 2>&1; then
        packages=(base-devel sqlite gd)
    else
        _red "No supported package manager found for vnstat dependencies"
        return 1
    fi
    local package_name
    for package_name in "${packages[@]}"; do
        install_package "$package_name" || return 1
    done
}

install_vnstat_dependencies || exit 1
cd /usr/src || exit 1
if ! curl -fsSL https://humdi.net/vnstat/vnstat-2.11.tar.gz -o vnstat-2.11.tar.gz; then
    _red "Failed to download vnstat source."
    _red "下载 vnstat 源码失败。"
    exit 1
fi
chmod 755 vnstat-2.11.tar.gz || exit 1
tar zxvf vnstat-2.11.tar.gz || exit 1
cd vnstat-2.11 || exit 1
./configure --prefix=/usr --sysconfdir=/etc && make && make install || exit 1
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cp -v examples/systemd/vnstat.service /etc/systemd/system/ || exit 1
    service_manager daemon-reload || exit 1
    service_manager enable vnstat || exit 1
    service_manager start vnstat || exit 1
elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
    if [ ! -x /etc/init.d/vnstat ]; then
        cat > /etc/init.d/vnstat <<'VNSTAT_OPENRC'
#!/sbin/openrc-run
name="vnstatd"
command="/usr/sbin/vnstatd"
command_args="-n"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
VNSTAT_OPENRC
        chmod 755 /etc/init.d/vnstat || exit 1
    fi
    rc-update add vnstat default >/dev/null 2>&1 || exit 1
    rc-service vnstat start >/dev/null 2>&1 || exit 1
else
    _yellow "No service manager found; vnstat binaries installed but daemon start was skipped"
fi
command -v vnstat >/dev/null 2>&1 || exit 1
command -v vnstatd >/dev/null 2>&1 || exit 1
command -v vnstati >/dev/null 2>&1 || exit 1

# 加装证书
mkdir -p /root/snap/lxd/common/config
download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/panel_scripts/client.crt" /root/snap/lxd/common/config/client.crt
chmod 644 /root/snap/lxd/common/config/client.crt || exit 1
# 双确认，部分版本切换了命令
if ! lxc config trust add /root/snap/lxd/common/config/client.crt >/dev/null 2>&1; then
    lxc config trust add-certificate /root/snap/lxd/common/config/client.crt >/dev/null 2>&1 ||
        lxc config trust list >/dev/null 2>&1 || exit 1
fi
lxc config set core.https_address :8443 || exit 1
# 加载修改脚本
download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/panel_scripts/modify.sh" /root/modify.sh
chmod 755 /root/modify.sh || exit 1
ufw disable >/dev/null 2>&1 || true
if [ ! -f /usr/local/bin/check-dns.sh ]; then
    download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/check-dns.sh" /usr/local/bin/check-dns.sh
    chmod +x /usr/local/bin/check-dns.sh || exit 1
else
    echo "Script already exists. Skipping installation."
fi
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if [ ! -f /etc/systemd/system/check-dns.service ]; then
        download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/check-dns.service" /etc/systemd/system/check-dns.service
        chmod +x /etc/systemd/system/check-dns.service || exit 1
        service_manager daemon-reload || exit 1
        service_manager enable check-dns.service || exit 1
        service_manager start check-dns.service || exit 1
    else
        echo "Service already exists. Skipping installation."
    fi
else
    _yellow "systemd is unavailable; skipping optional check-dns.service"
fi
# 设置IPV4优先
if [ -f /etc/gai.conf ]; then
    sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "networking.service"; then
        service_manager restart networking || _yellow "Networking restart unavailable; preserving current connectivity"
    elif command -v rc-service >/dev/null 2>&1 && rc-service --list | grep -q "networking"; then
        service_manager restart networking || _yellow "Networking restart unavailable; preserving current connectivity"
    fi
fi
if lxc remote list 2>/dev/null | grep -q '^| spiritlhl[[:space:]]*|'; then
    lxc remote remove spiritlhl >/dev/null 2>&1 || _yellow "Could not replace optional spiritlhl remote"
fi
lxc remote add spiritlhl https://lxdimages.spiritlhl.net --protocol simplestreams --public >/dev/null 2>&1 ||
    _yellow "Optional spiritlhl image remote is already present or unavailable"
lxc image list spiritlhl:debian >/dev/null 2>&1 || _yellow "Optional spiritlhl image listing unavailable"
verify_runtime_network || exit 1
exit 0
