#!/usr/bin/env bash
# ============================================================
# WSL 版 IP/WiFi 采集器 —— 对应 zshscripts/ip_monitor_termux.sh
# ------------------------------------------------------------------
# 环境：WSL2 + Windows 互操作（netsh.exe 取 SSID、powershell.exe 取主机 IP/VPN）
# 输出：$HOME/codebase/zshscripts/data/ip_changes.log
#       （云端配置 [happyjpip] 的 <device_id>_ip_log 指向此文件）
# 格式：2026-10-09 12:00:00 | Network: WiFi | WiFi_Name: gzjjtj-5G | Public_IP: … | Local_IP: … | VPN_Interface: N/A | VPN_IP: N/A
# 说明：与最新记录完全相同则跳过；新记录置于最前，上限 9000 行
#
# crontab: */15 * * * * $HOME/codebase/zshscripts/ip_monitor_wsl.sh >> $HOME/codebase/zshscripts/data/ip_monitor_wsl.log 2>&1
# 调试：  ./ip_monitor_wsl.sh -t    # 只打印当前状态，不写日志
# ============================================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

LOG_FILE="${IP_LOG_FILE:-$HOME/codebase/zshscripts/data/ip_changes.log}"
TEMP_FILE="${LOG_FILE}.tmp"
MAX_LOG_LINES=9000

# cron 环境 PATH 极简，Windows 互操作命令写绝对路径 + 兜底
NETSH=/mnt/c/Windows/system32/netsh.exe
[ -x "$NETSH" ] || NETSH="$(command -v netsh.exe 2>/dev/null || true)"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[ -x "$PS" ] || PS="$(command -v powershell.exe 2>/dev/null || true)"

# ---- 工具函数 ----

clean_field() {
    printf '%s' "$1" | tr -d '\n\r\t' | sed 's/|/_/g' | head -c 100
}

# netsh 中文输出是 GBK 字节：若非合法 UTF-8，按 GBK 转回（转换失败则原样返回）
fix_encoding() {
    local s="$1"
    if printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
        printf '%s' "$s"
    else
        printf '%s' "$s" | iconv -f GBK -t UTF-8 2>/dev/null || printf '%s' "$s"
    fi
}

# Windows 默认路由适配器：名称|描述|主机IPv4|VPN适配器名|VPN地址
get_windows_info() {
    [ -n "$PS" ] || return 1
    timeout 30 "$PS" -NoProfile -Command "
\$r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1;
\$a = Get-NetAdapter -InterfaceIndex \$r.ifIndex;
\$ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex \$r.ifIndex | Select-Object -First 1).IPAddress;
\$v = Get-NetAdapter | Where-Object { \$_.Status -eq 'Up' -and \$_.InterfaceDescription -match 'VPN|WireGuard|OpenVPN|TAP|tun' } | Select-Object -First 1;
\$vip = '';
if (\$v) { \$vip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex \$v.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress };
\"\$(\$a.Name)|\$(\$a.InterfaceDescription)|\$ip|\$(\$v.Name)|\$vip\"" 2>/dev/null | tr -d '\r' | head -1
}

# 当前连接的 WiFi SSID（未连接/无网卡时输出为空；BSSID 行不会误匹配）
get_ssid() {
    [ -n "$NETSH" ] || return 0
    local ssid
    ssid=$(timeout 15 "$NETSH" wlan show interfaces 2>/dev/null | tr -d '\r' \
        | grep -E '^[[:space:]]*SSID[[:space:]]*:' | head -1 \
        | sed -E 's/^[[:space:]]*SSID[[:space:]]*:[[:space:]]*//')
    fix_encoding "$ssid"
}

# 本地 IP：优先 Windows 主机 IP（真实局域网地址；本机 WSL 为 NAT，172.x 无意义），
# 取不到再退回 WSL 出口 IP
get_local_ip() {
    local win_ip="${1:-}"
    if printf '%s' "$win_ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        printf '%s' "$win_ip"; return
    fi
    ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1
}

# VPN：WSL 内 tun/tap/ppp/wg 优先，其次 Windows 侧 VPN 适配器（读 WIN_VPN_* 全局）
get_vpn_info() {
    local iface vip
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|tap|ppp|wg)' | head -1)
    if [ -n "$iface" ]; then
        vip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        printf '%s|%s' "$iface" "${vip:-N/A}"; return
    fi
    if [ -n "${WIN_VPN_NAME:-}" ]; then
        printf '%s|%s' "$WIN_VPN_NAME" "${WIN_VPN_IP:-N/A}"; return
    fi
    printf 'N/A|N/A'
}

# 公网 IP：多端点轮询（实测部分网络屏蔽 ipify/ifconfig.me，返回空即换下一个）
get_public_ip() {
    local ip url
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
        ip=$(timeout 12 curl -4 -s --max-time 8 "$url" 2>/dev/null | tr -d '\r\n')
        if printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            printf '%s' "$ip"; return
        fi
    done
    printf 'Unknown'
}

# 与最新记录比对（忽略时间戳，六个字段逐个比）
has_changed() {
    local current="$1" latest_line latest_rest
    [ ! -f "$LOG_FILE" ] && return 0
    read -r latest_line < "$LOG_FILE" || return 0
    [ -z "$latest_line" ] && return 0
    latest_rest=$(printf '%s' "$latest_line" | sed -E 's/^[^|]+\| //')
    [ "$latest_rest" != "$current" ]
}

# 追加记录（新记录最前，原子替换；权限对齐 hc 的 600）
write_log() {
    local log_line="$1"
    mkdir -p "$(dirname "$LOG_FILE")"
    {
        printf '%s\n' "$log_line"
        [ -f "$LOG_FILE" ] && head -n $((MAX_LOG_LINES - 1)) "$LOG_FILE"
    } > "$TEMP_FILE" 2>/dev/null
    mv "$TEMP_FILE" "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

# ---- 主流程 ----

main() {
    local dry_run=0
    [ "${1:-}" = "-t" ] && dry_run=1

    local wininfo adapter_desc host_ip WIN_VPN_NAME WIN_VPN_IP
    wininfo=$(get_windows_info) || wininfo=""
    adapter_desc=$(printf '%s' "$wininfo" | cut -d'|' -f2)
    host_ip=$(printf '%s' "$wininfo" | cut -d'|' -f3)
    WIN_VPN_NAME=$(printf '%s' "$wininfo" | cut -d'|' -f4)
    WIN_VPN_IP=$(printf '%s' "$wininfo" | cut -d'|' -f5)

    # 网络类型：以 Windows 默认路由适配器为准（描述含 wireless/wlan 即 WiFi）
    local ssid network_type wifi_name
    ssid=$(clean_field "$(get_ssid)")
    if printf '%s' "$adapter_desc" | grep -qiE 'wireless|wi-fi|wlan|802\.11'; then
        network_type="WiFi"
        wifi_name="${ssid:-N/A}"
    elif [ -n "$adapter_desc" ]; then
        network_type="Ethernet"
        wifi_name="N/A"
    else
        # PowerShell 不可用时的兜底：以能否取到 SSID 判断
        if [ -n "$ssid" ]; then network_type="WiFi"; wifi_name="$ssid"
        else network_type="Ethernet"; wifi_name="N/A"; fi
    fi

    local public_ip local_ip vpn_info vpn_iface vpn_ip
    public_ip=$(clean_field "$(get_public_ip)")
    local_ip=$(clean_field "$(get_local_ip "$host_ip")")
    vpn_info=$(get_vpn_info)
    vpn_iface=$(clean_field "$(printf '%s' "$vpn_info" | cut -d'|' -f1)")
    vpn_ip=$(clean_field "$(printf '%s' "$vpn_info" | cut -d'|' -f2)")
    [ -z "$local_ip" ] && local_ip="N/A"
    [ -z "$public_ip" ] && public_ip="Unknown"

    local timestamp current
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    current="Network: $network_type | WiFi_Name: $wifi_name | Public_IP: $public_ip | Local_IP: $local_ip | VPN_Interface: $vpn_iface | VPN_IP: $vpn_ip"

    if [ "$dry_run" = 1 ]; then
        echo "$timestamp | $current"
        return 0
    fi

    if has_changed "$current"; then
        write_log "$timestamp | $current"
        echo "[$(date '+%F %T')] recorded: $current" >&2
    fi
}

main "$@"
