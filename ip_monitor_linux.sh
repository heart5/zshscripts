#!/usr/bin/env bash
# ============================================================
# Linux 版 IP/WiFi 采集器 —— 对应 ip_monitor_termux.sh（Termux）/ ip_monitor_wsl.sh（WSL）
# ------------------------------------------------------------------
# 环境：常规 Linux 服务器（恒创云 HCX 等；无 termux-api、无 Windows 互操作）
# 输出：<脚本目录>/data/ip_changes.log（可用 IP_LOG_FILE 覆盖；云端配置 [happyjpip] 的 <device_id>_ip_log 指向此文件）
# 格式：2026-10-09 12:00:00 | Network: Ethernet | WiFi_Name: Unknown_WiFi | Public_IP: … | Local_IP: … | VPN_Interface: N/A | VPN_IP: N/A
# 说明：与最新记录完全相同则跳过；新记录置于最前，上限 9000 行；
#       WiFi_Name 非 WiFi 或 SSID 取不到时记 Unknown_WiFi（报告端归一为未命名，不进热点列表）；
#       VPN 只探测 tun/tap/ppp 客户端接口——本机自身 WireGuard 服务端接口（wg0）不代表流量经 VPN 出口，不计入
#
# crontab: 2-57/5 * * * * ~/sbase/cronpy/ip_monitor.sh >> /data/sbase/ip_monitor.out 2>&1
# 调试：  ./ip_monitor_linux.sh -t    # 只打印当前状态，不写日志
# ============================================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${IP_LOG_FILE:-$SCRIPT_DIR/data/ip_changes.log}"
TEMP_FILE="${LOG_FILE}.tmp"
MAX_LOG_LINES=9000

# ---- 工具函数 ----

clean_field() {
    printf '%s' "$1" | tr -d '\n\r\t' | sed 's/|/_/g' | head -c 100
}

# 默认路由出口设备名（无默认路由为空）
default_iface() {
    ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1
}

# 默认路由源地址（本机参与外网通信的 IPv4，无则空）
default_src_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1
}

# 指定接口的 IPv4（无则空）
iface_ipv4() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

# WiFi SSID：iwgetid 优先，iw 兜底（未连接/无网卡为空）
get_ssid() {
    local dev="$1" ssid=""
    if command -v iwgetid >/dev/null 2>&1; then
        ssid=$(timeout 5 iwgetid -r "$dev" 2>/dev/null)
    fi
    if [ -z "$ssid" ] && command -v iw >/dev/null 2>&1; then
        ssid=$(timeout 5 iw dev "$dev" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p')
    fi
    printf '%s' "$ssid"
}

# VPN：tun/tap/ppp 客户端接口（wg 服务端接口不计入，见文件头说明）
get_vpn_info() {
    local iface vip
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|tap|ppp)' | head -1)
    if [ -n "$iface" ]; then
        vip=$(iface_ipv4 "$iface")
        printf '%s|%s' "$iface" "${vip:-N/A}"; return
    fi
    printf 'N/A|N/A'
}

# 公网 IP：多端点轮询（-4 强制 IPv4，避免双栈下取回 IPv6）
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

# 追加记录（新记录最前，原子替换）
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

    local dev network_type
    dev=$(default_iface)
    case "$dev" in
        wl*) network_type="WiFi" ;;
        "")  network_type="Unknown" ;;
        *)   network_type="Ethernet" ;;
    esac

    local ssid wifi_name
    ssid=""
    if [ "$network_type" = "WiFi" ]; then
        ssid=$(clean_field "$(get_ssid "$dev")")
    fi
    wifi_name="${ssid:-Unknown_WiFi}"

    local public_ip local_ip vpn_info vpn_iface vpn_ip
    public_ip=$(clean_field "$(get_public_ip)")
    local_ip=$(clean_field "$(default_src_ip)")
    [ -z "$local_ip" ] && local_ip="N/A"
    vpn_info=$(get_vpn_info)
    vpn_iface=$(clean_field "$(printf '%s' "$vpn_info" | cut -d'|' -f1)")
    vpn_ip=$(clean_field "$(printf '%s' "$vpn_info" | cut -d'|' -f2)")

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
