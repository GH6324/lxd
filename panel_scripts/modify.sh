#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/lxd
# 2026.02.28

# 输入
# ./modify.sh 服务器名称 SSH端口 外网起端口 外网止端口 下载速度 上传速度 是否启用IPV6(Y or N)
# 如果 外网起端口 外网止端口 都设置为0则不做区间外网端口映射了，只映射基础的SSH端口，注意不能为空，不进行映射需要设置为0

validate_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_non_negative_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_port() {
    validate_non_negative_int "$1" && [ "$1" -le 65535 ]
}

validate_positive_port() {
    validate_positive_int "$1" && [ "$1" -le 65535 ]
}

validate_inputs() {
    if ! validate_positive_port "$sshn" || ! validate_port "$nat1" || ! validate_port "$nat2"; then
        echo "Error: ports must be integers in range 0-65535, and SSH port must be greater than 0."
        echo "错误：端口必须是 0-65535 的整数，SSH 端口必须大于 0。"
        exit 1
    fi
    if { [ "$nat1" = "0" ] && [ "$nat2" != "0" ]; } || { [ "$nat1" != "0" ] && [ "$nat2" = "0" ]; }; then
        echo "Error: NAT port range must either be both 0 or both non-zero."
        echo "错误：NAT 端口起止必须同时为 0，或同时为非 0。"
        exit 1
    fi
    if [ "$nat1" != "0" ] && [ "$nat2" != "0" ] && [ "$nat1" -gt "$nat2" ]; then
        echo "Error: NAT start port cannot be greater than NAT end port."
        echo "错误：NAT 起始端口不能大于结束端口。"
        exit 1
    fi
    if ! validate_positive_int "$in" || ! validate_positive_int "$out"; then
        echo "Error: speed values must be positive integers."
        echo "错误：网速参数必须是正整数。"
        exit 1
    fi
}

replace_proxy_device() {
    local device_name="$1"
    shift
    lxc config device remove "$name" "$device_name" 2>/dev/null || true
    lxc config device add "$name" "$device_name" proxy "$@"
}

remove_device_if_exists() {
    local device_name="$1"
    lxc config device remove "$name" "$device_name" 2>/dev/null || true
}

# NAT proxies on LXD/LTS require a concrete host listener and a static NIC
# address. Validate both before replacing any existing proxy devices.
prepare_nat_ipv4_proxy() {
    local host_addresses host_address metadata state binding device_name target_ip local_device
    host_addresses=$(ip -o -4 addr show scope global) || return 1
    ipv4_address=""
    while read -r host_address; do
        host_address=${host_address%/*}
        case "$host_address" in ''|0.*|127.*|169.254.*) continue ;; esac
        if [[ "$host_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ipv4_address="$host_address"
            break
        fi
    done < <(awk '{print $4}' <<<"$host_addresses")
    if [[ -z "$ipv4_address" ]]; then
        echo "NAT proxy requires a concrete host IPv4 address / 缺少宿主机IPv4监听地址" >&2
        return 1
    fi
    metadata=$(lxc query "/1.0/instances/$name") || return 1
    metadata=$(jq -e '(.metadata // .) | select(type == "object" and (.expanded_devices | type) == "object")' <<<"$metadata") || return 1
    # Keep a valid existing static NIC and wildcard connect auto-selection.
    if jq -e '[.expanded_devices[] | select(.type == "nic" and (.nictype == "bridged" or .nictype == "routed" or (.nictype == null and .network != null))) | .["ipv4.address"] | select(. != null and . != "" and . != "none")] | length > 0' <<<"$metadata" >/dev/null; then
        return 0
    fi
    state=$(lxc query "/1.0/instances/$name/state") || return 1
    state=$(jq -e '(.metadata // .) | select(type == "object" and (.network | type) == "object")' <<<"$state") || return 1
    binding=$(jq -er --argjson state "$state" '
        . as $instance |
        [.expanded_devices | to_entries[] |
         select(.value.type == "nic" and (.value.nictype == "bridged" or .value.nictype == "routed" or (.value.nictype == null and .value.network != null))) |
         select((.value["ipv4.address"] // "") == "") | . as $device |
         ($device.value.hwaddr // $instance.expanded_config["volatile." + $device.key + ".hwaddr"] // $instance.config["volatile." + $device.key + ".hwaddr"] // "") as $mac |
         $state.network | to_entries[] |
         select(if $mac != "" and (.value.hwaddr // "") != ""
                then (.value.hwaddr | ascii_downcase) == ($mac | ascii_downcase)
                else .key == ($device.value.name // $device.key) end) |
         [.value.addresses[]? | select(.family == "inet" and .scope == "global") | .address][0] as $ip |
         select($ip != null) |
         [$device.key, $ip, ($instance.devices | has($device.key))]] |
        if length == 1 then .[0] | @tsv else error("cannot uniquely match guest IPv4 to an instance NIC") end
    ' <<<"$metadata") || return 1
    IFS=$'\t' read -r device_name target_ip local_device <<<"$binding"
    if [[ "$local_device" == true ]]; then
        lxc config device set "$name" "$device_name" "ipv4.address=$target_ip" ||
            lxc config device set "$name" "$device_name" ipv4.address "$target_ip" || return 1
    else
        lxc config device override "$name" "$device_name" "ipv4.address=$target_ip" || return 1
    fi
}

ensure_container_ipv6_cron() {
    lxc exec "$name" -- sh -c 'set -eu; if [ -L /etc/cron.d ]; then exit 1; fi; [ -d /etc/cron.d ] || exit 0; mkdir -p /run/lock; test ! -L /run/lock; lock=/run/lock/oneclickvirt-ipv6.lock.d; acquired=0; i=0; while [ "$i" -lt 100 ]; do if mkdir "$lock" 2>/dev/null; then acquired=1; break; fi; i=$((i + 1)); sleep 0.1; done; [ "$acquired" -eq 1 ]; trap '\''rmdir "$lock" 2>/dev/null || true'\'' EXIT; target=/etc/cron.d/oneclickvirt-ipv6; line="*/1 * * * * root curl --noproxy '\''*'\'' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb >/dev/null 2>&1 && curl --noproxy '\''*'\'' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb >/dev/null 2>&1"; if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then exit 1; fi; if [ -f "$target" ] && grep -Fqx "$line" "$target"; then exit 0; fi; tmp=$(mktemp /etc/cron.d/.oneclickvirt-ipv6.XXXXXX); trap '\''rm -f -- "$tmp"; rmdir "$lock" 2>/dev/null || true'\'' EXIT; if [ -f "$target" ]; then cat "$target" >"$tmp"; last=$(tail -c 1 "$target" 2>/dev/null | od -An -t x1 | tr -d "[:space:]"); [ -z "$last" ] || [ "$last" = 0a ] || printf "\n" >>"$tmp"; fi; printf "%s\n" "$line" >>"$tmp"; chmod 0644 "$tmp"; mv -f "$tmp" "$target"'
}

download_file() {
    local url="$1"
    local output="$2"
    if ! curl -fsSLk "$url" -o "$output"; then
        echo "Failed to download: $url"
        echo "下载失败：$url"
        exit 1
    fi
}

# 创建容器
cd /root >/dev/null 2>&1 || exit 1
name="${1:-test}"
sshn="${2:-20001}"
nat1="${3:-20002}"
nat2="${4:-20025}"
in="${5:-300}"
out="${6:-300}"
enable_ipv6="${7:-N}"
enable_ipv6=$(echo "$enable_ipv6" | tr '[:lower:]' '[:upper:]')
validate_inputs
if ! lxc info "$name" >/dev/null 2>&1; then
    echo "Error: container '$name' does not exist."
    echo "错误：容器 '$name' 不存在。"
    exit 1
fi
# 支持docker虚拟化
lxc config set "$name" security.nesting true
ori=$(date | md5sum)
passwd=${ori:2:9}
lxc start "$name" 2>/dev/null || true
sleep 1
# 从容器内探测系统类型
system=$(lxc exec "$name" -- sh -c "grep -i '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' | tr '[:upper:]' '[:lower:]'" 2>/dev/null || echo "debian")
/usr/local/bin/check-dns.sh
if echo "$system" | grep -qiE "centos" || echo "$system" | grep -qiE "almalinux" || echo "$system" | grep -qiE "fedora" || echo "$system" | grep -qiE "rocky"; then
    lxc exec "$name" -- sudo yum update -y
    lxc exec "$name" -- sudo yum install -y curl
    lxc exec "$name" -- sudo yum install -y dos2unix
elif echo "$system" | grep -qiE "alpine"; then
    lxc exec "$name" -- apk update
    lxc exec "$name" -- apk add --no-cache curl
elif echo "$system" | grep -qiE "openwrt"; then
    lxc exec "$name" -- opkg update
else
    lxc exec "$name" -- sudo apt-get update -y
    lxc exec "$name" -- sudo apt-get install curl -y --fix-missing
    lxc exec "$name" -- sudo apt-get install dos2unix -y --fix-missing
fi
if echo "$system" | grep -qiE "alpine" || echo "$system" | grep -qiE "openwrt"; then
    if [ ! -f /usr/local/bin/ssh_sh.sh ]; then
        download_file https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_sh.sh /usr/local/bin/ssh_sh.sh
        chmod 777 /usr/local/bin/ssh_sh.sh
        dos2unix /usr/local/bin/ssh_sh.sh
    fi
    cp /usr/local/bin/ssh_sh.sh /root
    lxc file push /root/ssh_sh.sh "$name"/root/
    lxc exec "$name" -- chmod 777 ssh_sh.sh
    lxc exec "$name" -- ./ssh_sh.sh "$passwd"
else
    if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
        download_file https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_bash.sh /usr/local/bin/ssh_bash.sh
        chmod 777 /usr/local/bin/ssh_bash.sh
        dos2unix /usr/local/bin/ssh_bash.sh
    fi
    cp /usr/local/bin/ssh_bash.sh /root
    lxc file push /root/ssh_bash.sh "$name"/root/
    lxc exec "$name" -- chmod 777 ssh_bash.sh
    lxc exec "$name" -- dos2unix ssh_bash.sh
    lxc exec "$name" -- sudo ./ssh_bash.sh "$passwd"
    if [ ! -f /usr/local/bin/config.sh ]; then
        download_file https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/config.sh /usr/local/bin/config.sh
        chmod 777 /usr/local/bin/config.sh
        dos2unix /usr/local/bin/config.sh
    fi
    cp /usr/local/bin/config.sh /root
    lxc file push /root/config.sh "$name"/root/
    lxc exec "$name" -- chmod +x config.sh
    lxc exec "$name" -- dos2unix config.sh
    lxc exec "$name" -- bash config.sh
    # `history` is a Bash builtin; LXC exec needs a shell boundary.
    lxc exec "$name" -- bash -c 'history -c'
fi
prepare_nat_ipv4_proxy || exit 1
replace_proxy_device ssh-port "listen=tcp:$ipv4_address:$sshn" connect=tcp:0.0.0.0:22 nat=true || exit 1
# 是否要创建V6地址
if [ -n "$enable_ipv6" ]; then
    if [ "$enable_ipv6" == "Y" ]; then
        ensure_container_ipv6_cron || exit 1
        sleep 1
        if [ ! -f "./build_ipv6_network.sh" ]; then
            # 如果不存在，则从指定 URL 下载并添加可执行权限
            download_file https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/build_ipv6_network.sh build_ipv6_network.sh
            chmod +x build_ipv6_network.sh
        fi
        ./build_ipv6_network.sh "$name" || exit 1
    fi
fi
if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
    replace_proxy_device nattcp-ports "listen=tcp:$ipv4_address:$nat1-$nat2" "connect=tcp:0.0.0.0:$nat1-$nat2" nat=true || exit 1
    replace_proxy_device natudp-ports "listen=udp:$ipv4_address:$nat1-$nat2" "connect=udp:0.0.0.0:$nat1-$nat2" nat=true || exit 1
else
    remove_device_if_exists nattcp-ports
    remove_device_if_exists natudp-ports
fi
# 网速
lxc stop "$name"
if ((in == out)); then
    speed_limit="$in"
else
    speed_limit=$(($in > $out ? $in : $out))
fi
# 上传 下载 最大
if ! lxc config device override "$name" eth0 limits.egress="$out"Mbit limits.ingress="$in"Mbit limits.max="$speed_limit"Mbit 2>/dev/null; then
    lxc config device set "$name" eth0 limits.egress "$out"Mbit
    lxc config device set "$name" eth0 limits.ingress "$in"Mbit
    lxc config device set "$name" eth0 limits.max "$speed_limit"Mbit
fi
lxc start "$name"
rm -f -- ssh_bash.sh config.sh ssh_sh.sh
if echo "$system" | grep -qiE "alpine"; then
    sleep 3
    lxc stop "$name"
    lxc start "$name"
fi
if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
    echo "$name $sshn $passwd $nat1 $nat2" >"$name"
    echo "$name $sshn $passwd $nat1 $nat2"
    exit 0
fi
if [ "$nat1" == "0" ] && [ "$nat2" == "0" ]; then
    echo "$name $sshn $passwd" >"$name"
    echo "$name $sshn $passwd"
fi
