#!/bin/bash
# from
# https://github.com/oneclickvirt/lxd
# 2023.06.29

# 检查 screen 是否已安装
if ! command -v screen &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y screen
    else
        echo "screen is not installed and apt-get is unavailable."
        exit 1
    fi
fi

if ! curl -fsSL https://github.com/oneclickvirt/lxd/raw/main/scripts/monitor.sh -o monitor.sh; then
    echo "Failed to download monitor.sh"
    exit 1
fi
chmod +x monitor.sh

# 启动一个新的 screen 窗口并在其中运行命令
screen -dmS lxc_monitor bash monitor.sh
