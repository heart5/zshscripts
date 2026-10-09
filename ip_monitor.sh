#!/usr/bin/env bash
# ============================================================
# IP/WiFi 采集器（统一版）—— termux / WSL / 常规 Linux 自适应单脚本
# ------------------------------------------------------------------
# 环境探测（特征/能力判断，不判 OS 名；IP_MONITOR_FORCE=termux|wsl|linux 可强制，供测试）：
#   termux：/data/data/com.termux/files/usr 存在（或 termux-api 命令可用）
#   wsl   ：/mnt/c/Windows 存在（或 /proc/version 含 microsoft）
#   linux ：其余（恒创云等常规服务器）
# 输出：<脚本目录>/data/ip_changes.log（IP_LOG_FILE 可覆盖）
#       —— 各机云端配置 [happyjpip] 的 <device_id>_ip_log 与此路径对应，默认勿动
# 格式（报告端 ipupdate.py 按此解析，冻结勿改）：
#   2026-10-09 12:00:00 | Network: X | WiFi_Name: X | Public_IP: X | Local_IP: X | VPN_Interface: X | VPN_IP: X
# WiFi_Name 归一：无 WiFi / SSID 取不到一律 Unknown_WiFi（报告端归一为未命名、不进热点列表；
#   勿写 N/A——WSL 旧版曾如此，热点列表会混入「N/A」）
# 行为：与最新记录（首行）完全相同则跳过；新记录置最前；上限 9000 行；原子替换（tmp+mv）
# 运行：cron 非 tty 完全静默；tty 诊断走 stderr；-t 只打印当前状态（stdout）不写日志
#   Termux 无 /usr/bin/env —— Termux 上勿直接 ./ip_monitor.sh，用 `bash ip_monitor.sh`
#   （各机 wrapper 与兼容垫片均已显式 bash 调用）
# 超时预算：cron wrapper（cronpy/ip_monitor.sh）整体 timeout 40s；termux 分支最坏
#   ≈ 5s(ifconfig) + 5s+2s+7s(SSID 探测+重试) + 5s+3s(公网 IP) ≈ 27s，故 termux 公网 IP
#   用短预算版（勿共用 3 端点长预算版）
# VPN 探测差异（按分支保留，均为刻意设计）：termux/wsl 含 wg（客户端语义）；linux 仅
#   tun/tap/ppp——本机自身 WireGuard 服务端接口（如 HCX wg0）不代表流量经 VPN 出口，不计入
# 兼容：同目录 ip_monitor_termux.sh / ip_monitor_wsl.sh / ip_monitor_linux.sh 为转发垫片
#   （旧 crontab 入口零改动、pull 即生效）；各机 wrapper 迁移为 `bash ./ip_monitor.sh` 后垫片可删
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${IP_LOG_FILE:-$SCRIPT_DIR/data/ip_changes.log}"
TEMP_FILE="${LOG_FILE}.tmp"
MAX_LOG_LINES=9000

# run_* 填充这六个字段，main 统一清理/成行
NET_TYPE="Unknown"
WIFI_NAME="Unknown_WiFi"
PUBLIC_IP="Unknown"
LOCAL_IP="N/A"
VPN_IFACE="N/A"
VPN_IP="N/A"

# ---- 公共函数 ----

clean_field() {
    printf '%s' "$1" | tr -d '\n\r\t' | sed 's/|/_/g' | head -c 100
}

# 公网 IP·短预算版（termux；wrapper 40s 内）—— -4 强制 IPv4，避免双栈下取回 IPv6
get_public_ip_short() {
    local ip
    ip=$(curl -4 -s --max-time 5 --retry 1 https://api.ipify.org 2>/dev/null | tr -d '\r\n')
    if ! printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        ip=$(curl -4 -s --max-time 3 --retry 1 https://ifconfig.me 2>/dev/null | tr -d '\r\n')
    fi
    if printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        printf '%s' "$ip"; return
    fi
    printf 'Unknown'
}

# 公网 IP·3 端点轮询版（wsl/linux；实测部分网络屏蔽 ipify/ifconfig.me，返回空即换下一个）
get_public_ip_long() {
    local ip url
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
        ip=$(timeout 12 curl -4 -s --max-time 8 "$url" 2>/dev/null | tr -d '\r\n')
        if printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            printf '%s' "$ip"; return
        fi
    done
    printf 'Unknown'
}

# 与最新记录比对（忽略时间戳，六字段整串比较）
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

# ---- 环境探测 ----

detect_env() {
    if [ -n "${IP_MONITOR_FORCE:-}" ]; then printf '%s' "$IP_MONITOR_FORCE"; return; fi
    if [ -d /data/data/com.termux/files/usr ]; then printf 'termux'; return; fi
    if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then printf 'termux'; return; fi
    if [ -d /mnt/c/Windows ]; then printf 'wsl'; return; fi
    if grep -qi microsoft /proc/version 2>/dev/null; then printf 'wsl'; return; fi
    printf 'linux'
}

# ============================================================
# termux 分支（Android/Termux；逻辑基线 = 2026-10-09 生产加固版）
# ============================================================

T_IFCONFIG=""
T_WIFI_INFO=""
T_PUBLIC_IP=""
T_WIFI_PROBE_NOTE=""

t_init_cache() {
    if command -v ifconfig >/dev/null 2>&1; then
        T_IFCONFIG=$(timeout 5 ifconfig 2>/dev/null)
    fi

    # WiFi 信息（一次性；后台冻结下 termux-api 响应可能迟到超过 5s，疑似已连 WiFi 时重试一次）
    if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
        T_WIFI_INFO=$(timeout 5 termux-wifi-connectioninfo 2>/dev/null)
        T_WIFI_PROBE_NOTE="rc1=$?"
        if [ -z "$T_WIFI_INFO" ] && [ -n "$(t_wlan0_external_ip)" ]; then
            sleep 2
            T_WIFI_INFO=$(timeout 7 termux-wifi-connectioninfo 2>/dev/null)
            T_WIFI_PROBE_NOTE="$T_WIFI_PROBE_NOTE rc2=$?"
        fi
    else
        T_WIFI_PROBE_NOTE="命令不可用"
    fi

    T_PUBLIC_IP=$(get_public_ip_short)
}

# 提取 wlan0 持有的外部地址（排除热点段 192.168.43.x；无则输出空）
# 用途：SSID 未取到时判断「是否实际已连 WiFi」，以及决定是否值得重试探测
t_wlan0_external_ip() {
    local ip
    ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^wlan' | grep 'inet ' | awk '{print $2}' | head -1)
    if [ -n "$ip" ] && ! printf '%s' "$ip" | grep -q '^192\.168\.43\.'; then
        printf '%s' "$ip"
    fi
}

# 记录 WiFi 识别异常（wlan0 已持地址但 SSID 未取到；仅异常时写入，封顶 500 行）
t_log_wifi_anomaly() {
    local debug_file="$SCRIPT_DIR/data/wifi_debug.log"
    mkdir -p "$SCRIPT_DIR/data"
    printf '%s | wlan0=%s | %s | raw=%s\n' \
        "$(date '+%F %T')" "$1" "${T_WIFI_PROBE_NOTE:-无探测信息}" \
        "$(printf '%s' "$T_WIFI_INFO" | tr -d '\n\r' | head -c 300)" >> "$debug_file" 2>/dev/null
    if [ "$(wc -l < "$debug_file" 2>/dev/null || echo 0)" -gt 500 ]; then
        tail -n 300 "$debug_file" > "$debug_file.tmp" && mv "$debug_file.tmp" "$debug_file"
    fi
}

# 是否连接到其他手机的热点（wifi_ip 与 wlan0_ip 同为 192.168.43.x 双确认）
t_is_hotspot_connection() {
    if [ -n "$T_WIFI_INFO" ] && [ -n "$T_IFCONFIG" ]; then
        local wifi_ip wlan0_ip
        wifi_ip=$(printf '%s' "$T_WIFI_INFO" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        if printf '%s' "$wifi_ip" | grep -q '^192\.168\.43\.'; then
            wlan0_ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
            if [ "$wifi_ip" = "$wlan0_ip" ]; then
                return 0
            fi
        fi
    fi
    return 1
}

# 是否开启了热点（p2p-p2p0-0 存在，或 wlan0 持 192.168.43.1 且无有效 WiFi 连接）
t_is_hotspot_active() {
    if [ -n "$T_IFCONFIG" ]; then
        if printf '%s' "$T_IFCONFIG" | grep -q '^p2p-p2p0-0:'; then
            return 0
        fi
        local wlan0_ip
        wlan0_ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
        if printf '%s' "$wlan0_ip" | grep -q '^192\.168\.43\.1$'; then
            if [ -n "$T_WIFI_INFO" ]; then
                local ssid
                ssid=$(printf '%s' "$T_WIFI_INFO" | sed -n 's/.*"ssid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                if [ "$ssid" = "<unknown ssid>" ] || [ "$ssid" = "null" ] || [ -z "$ssid" ]; then
                    return 0
                fi
            else
                # 命令不可用，假设是热点
                return 0
            fi
        fi
    fi
    return 1
}

# 网络类型判定，输出 "类型|WiFi名"（类型 ∈ WiFi/Hotspot_Client/Hotspot/Mobile）
# 热点后缀名逐字保留（_HotspotClient 无下划线分隔 / _Hotspot / Hotspot_Mode）——报告端按名称展示
t_get_network_info() {
    local network_type="Mobile"
    local wifi_name="N/A"
    local ssid=""

    if [ -n "$T_WIFI_INFO" ]; then
        ssid=$(printf '%s' "$T_WIFI_INFO" | sed -n 's/.*"ssid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi

    if [ -n "$ssid" ] && [ "$ssid" != "<unknown ssid>" ] && [ "$ssid" != "null" ]; then
        # 有效的 WiFi 连接
        network_type="WiFi"
        wifi_name="$ssid"

        if t_is_hotspot_connection; then
            # 连接到其他手机的热点
            network_type="Hotspot_Client"
            wifi_name="${wifi_name}_HotspotClient"
        elif t_is_hotspot_active; then
            # WiFi 连接 + 热点开启
            wifi_name="${wifi_name}_Hotspot"
        fi
    else
        # SSID 未取到（API 超时/未知/Location 关闭）：若 wlan0 已持外部地址，
        # 说明 WiFi 实际已连接、仅识别失败，按 WiFi 记录（SSID 未知），避免误判为 Mobile
        wifi_name="Unknown_WiFi"
        local wlan_ip
        wlan_ip=$(t_wlan0_external_ip)
        if [ -n "$wlan_ip" ]; then
            network_type="WiFi"
            t_log_wifi_anomaly "$wlan_ip"
        elif t_is_hotspot_active; then
            # 移动网络 + 热点开启
            network_type="Hotspot"
            wifi_name="Hotspot_Mode"
        else
            # 纯移动网络
            network_type="Mobile"
        fi
    fi

    wifi_name=$(clean_field "$wifi_name")
    printf '%s|%s' "$network_type" "$wifi_name"
}

# 本地 IP：按网络类型取对应接口
t_get_local_ip() {
    local network_type="$1"
    local ip="N/A"

    if [ -n "$T_IFCONFIG" ]; then
        case "$network_type" in
            "WiFi")
                # 真正的 WiFi 连接：wlan 接口外部 IP（排除热点段）
                ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^wlan' | grep 'inet ' | awk '{print $2}' | head -1)
                if printf '%s' "$ip" | grep -q '^192\.168\.43\.'; then
                    ip="N/A"
                fi
                ;;
            "Hotspot_Client")
                # 连接到其他手机的热点：热点分配的 IP
                if [ -n "$T_WIFI_INFO" ]; then
                    ip=$(printf '%s' "$T_WIFI_INFO" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                fi
                if [ -z "$ip" ] || [ "$ip" = "N/A" ]; then
                    ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
                fi
                ;;
            "Hotspot")
                # 热点模式（本机开启热点）：优先 p2p 接口，其次 wlan0 的热点 IP
                ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^p2p-p2p0-0:' | grep 'inet ' | awk '{print $2}' | head -1)
                if [ -z "$ip" ] || [ "$ip" = "N/A" ]; then
                    ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
                    if ! printf '%s' "$ip" | grep -q '^192\.168\.43\.1$'; then
                        ip="N/A"
                    fi
                fi
                ;;
            "Mobile")
                # 移动网络
                ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 '^rmnet\|^ccmni' | grep 'inet ' | awk '{print $2}' | head -1)
                ;;
        esac
    fi

    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        printf '%s' "$ip"
    else
        printf 'N/A'
    fi
}

# VPN：仅 tun/tap/ppp（客户端接口；提取三级兜底）
t_get_vpn_info() {
    local vpn_interface="N/A"
    local vpn_ip="N/A"

    if [ -n "$T_IFCONFIG" ]; then
        vpn_interface=$(printf '%s' "$T_IFCONFIG" | grep -o '^tun[0-9]*:' | cut -d':' -f1 | head -1)
        if [ -z "$vpn_interface" ]; then
            vpn_interface=$(printf '%s' "$T_IFCONFIG" | grep -o '^tap[0-9]*:' | cut -d':' -f1 | head -1)
        fi
        if [ -z "$vpn_interface" ]; then
            vpn_interface=$(printf '%s' "$T_IFCONFIG" | grep -o '^ppp[0-9]*:' | cut -d':' -f1 | head -1)
        fi

        if [ -n "$vpn_interface" ]; then
            vpn_ip=$(printf '%s' "$T_IFCONFIG" | sed -n "/^$vpn_interface:/,/^[a-z]/p" | grep 'inet ' | awk '{print $2}' | head -1)
            if [ -z "$vpn_ip" ] || [ "$vpn_ip" = "127.0.0.1" ]; then
                vpn_ip=$(printf '%s' "$T_IFCONFIG" | grep -A5 "^$vpn_interface:" | grep 'inet ' | awk '{print $2}' | head -1)
            fi
            if [ -z "$vpn_ip" ] || [ "$vpn_ip" = "127.0.0.1" ]; then
                vpn_ip=$(printf '%s' "$T_IFCONFIG" | grep -A2 "^$vpn_interface:" | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1)
            fi
        fi
    fi

    [ -z "$vpn_ip" ] && vpn_ip="N/A"
    [ -z "$vpn_interface" ] && vpn_interface="N/A"
    printf '%s|%s' "$vpn_interface" "$vpn_ip"
}

run_termux() {
    t_init_cache
    local info vpn
    info=$(t_get_network_info)
    NET_TYPE=${info%%|*}
    WIFI_NAME=${info#*|}
    PUBLIC_IP=$T_PUBLIC_IP
    LOCAL_IP=$(t_get_local_ip "$NET_TYPE")
    vpn=$(t_get_vpn_info)
    VPN_IFACE=${vpn%%|*}
    VPN_IP=${vpn#*|}
}

# ============================================================
# wsl 分支（WSL2 + Windows 互操作；cron PATH 极简，互操作命令绝对路径+兜底）
# ============================================================

W_NETSH=""
W_PS=""
W_WIN_VPN_NAME=""
W_WIN_VPN_IP=""

# netsh 中文输出是 GBK 字节：若非合法 UTF-8，按 GBK 转回（转换失败则原样返回）
w_fix_encoding() {
    local s="$1"
    if printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
        printf '%s' "$s"
    else
        printf '%s' "$s" | iconv -f GBK -t UTF-8 2>/dev/null || printf '%s' "$s"
    fi
}

# Windows 默认路由适配器：名称|描述|主机IPv4|VPN适配器名|VPN地址
w_get_windows_info() {
    [ -n "$W_PS" ] || return 1
    timeout 30 "$W_PS" -NoProfile -Command "
\$r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1;
\$a = Get-NetAdapter -InterfaceIndex \$r.ifIndex;
\$ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex \$r.ifIndex | Select-Object -First 1).IPAddress;
\$v = Get-NetAdapter | Where-Object { \$_.Status -eq 'Up' -and \$_.InterfaceDescription -match 'VPN|WireGuard|OpenVPN|TAP|tun' } | Select-Object -First 1;
\$vip = '';
if (\$v) { \$vip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex \$v.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress };
\"\$(\$a.Name)|\$(\$a.InterfaceDescription)|\$ip|\$(\$v.Name)|\$vip\"" 2>/dev/null | tr -d '\r' | head -1
}

# 当前连接的 WiFi SSID（未连接/无网卡时输出为空；BSSID 行不会误匹配）
w_get_ssid() {
    [ -n "$W_NETSH" ] || return 0
    local ssid
    ssid=$(timeout 15 "$W_NETSH" wlan show interfaces 2>/dev/null | tr -d '\r' \
        | grep -E '^[[:space:]]*SSID[[:space:]]*:' | head -1 \
        | sed -E 's/^[[:space:]]*SSID[[:space:]]*:[[:space:]]*//')
    w_fix_encoding "$ssid"
}

# 本地 IP：优先 Windows 主机 IP（真实局域网地址；WSL 为 NAT，172.x 无意义），取不到再退回 WSL 出口
w_get_local_ip() {
    local win_ip="${1:-}"
    if printf '%s' "$win_ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        printf '%s' "$win_ip"; return
    fi
    ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1
}

# VPN：WSL 内 tun/tap/ppp/wg 优先（wg 为客户端语义），其次 Windows 侧 VPN 适配器
w_get_vpn_info() {
    local iface vip
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|tap|ppp|wg)' | head -1)
    if [ -n "$iface" ]; then
        vip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        printf '%s|%s' "$iface" "${vip:-N/A}"; return
    fi
    if [ -n "${W_WIN_VPN_NAME:-}" ]; then
        printf '%s|%s' "$W_WIN_VPN_NAME" "${W_WIN_VPN_IP:-N/A}"; return
    fi
    printf 'N/A|N/A'
}

run_wsl() {
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    W_NETSH=/mnt/c/Windows/system32/netsh.exe
    [ -x "$W_NETSH" ] || W_NETSH="$(command -v netsh.exe 2>/dev/null || true)"
    W_PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
    [ -x "$W_PS" ] || W_PS="$(command -v powershell.exe 2>/dev/null || true)"

    local wininfo adapter_desc host_ip ssid vpn
    wininfo=$(w_get_windows_info) || wininfo=""
    adapter_desc=$(printf '%s' "$wininfo" | cut -d'|' -f2)
    host_ip=$(printf '%s' "$wininfo" | cut -d'|' -f3)
    W_WIN_VPN_NAME=$(printf '%s' "$wininfo" | cut -d'|' -f4)
    W_WIN_VPN_IP=$(printf '%s' "$wininfo" | cut -d'|' -f5)

    # 网络类型：以 Windows 默认路由适配器为准（描述含 wireless/wlan 即 WiFi）
    # 无 WiFi 时 WiFi_Name 记 Unknown_WiFi（旧版写 N/A，会污染报告端热点列表）
    ssid=$(clean_field "$(w_get_ssid)")
    if printf '%s' "$adapter_desc" | grep -qiE 'wireless|wi-fi|wlan|802\.11'; then
        NET_TYPE="WiFi"
        WIFI_NAME="${ssid:-Unknown_WiFi}"
    elif [ -n "$adapter_desc" ]; then
        NET_TYPE="Ethernet"
        WIFI_NAME="Unknown_WiFi"
    else
        # PowerShell 不可用时的兜底：以能否取到 SSID 判断
        if [ -n "$ssid" ]; then NET_TYPE="WiFi"; WIFI_NAME="$ssid"
        else NET_TYPE="Ethernet"; WIFI_NAME="Unknown_WiFi"; fi
    fi

    PUBLIC_IP=$(get_public_ip_long)
    LOCAL_IP=$(w_get_local_ip "$host_ip")
    vpn=$(w_get_vpn_info)
    VPN_IFACE=${vpn%%|*}
    VPN_IP=${vpn#*|}
}

# ============================================================
# linux 分支（恒创云等常规服务器；无 termux-api、无 Windows 互操作）
# ============================================================

# 默认路由出口设备名（无默认路由为空）
l_default_iface() {
    ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1
}

# 默认路由源地址（本机参与外网通信的 IPv4，无则空）
l_default_src_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1
}

# WiFi SSID：iwgetid 优先，iw 兜底（未连接/无网卡为空）
l_get_ssid() {
    local dev="$1" ssid=""
    if command -v iwgetid >/dev/null 2>&1; then
        ssid=$(timeout 5 iwgetid -r "$dev" 2>/dev/null)
    fi
    if [ -z "$ssid" ] && command -v iw >/dev/null 2>&1; then
        ssid=$(timeout 5 iw dev "$dev" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p')
    fi
    printf '%s' "$ssid"
}

# VPN：仅 tun/tap/ppp——本机自身 WireGuard 服务端接口（wg0）不代表流量经 VPN 出口，不计入
l_get_vpn_info() {
    local iface vip
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|tap|ppp)' | head -1)
    if [ -n "$iface" ]; then
        vip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        printf '%s|%s' "$iface" "${vip:-N/A}"; return
    fi
    printf 'N/A|N/A'
}

run_linux() {
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    local dev ssid vpn
    dev=$(l_default_iface)
    case "$dev" in
        wl*) NET_TYPE="WiFi" ;;
        "")  NET_TYPE="Unknown" ;;
        *)   NET_TYPE="Ethernet" ;;
    esac

    ssid=""
    if [ "$NET_TYPE" = "WiFi" ]; then
        ssid=$(clean_field "$(l_get_ssid "$dev")")
    fi
    WIFI_NAME="${ssid:-Unknown_WiFi}"

    PUBLIC_IP=$(get_public_ip_long)
    LOCAL_IP=$(l_default_src_ip)
    vpn=$(l_get_vpn_info)
    VPN_IFACE=${vpn%%|*}
    VPN_IP=${vpn#*|}
}

# ---- 主流程 ----

main() {
    local dry_run=0
    [ "${1:-}" = "-t" ] && dry_run=1

    local env_name
    env_name=$(detect_env)
    [ -t 2 ] && echo "[ip_monitor] 环境分支: $env_name" >&2

    case "$env_name" in
        termux) run_termux ;;
        wsl)    run_wsl ;;
        linux)  run_linux ;;
        *)      echo "[ip_monitor] 未知分支: $env_name（IP_MONITOR_FORCE 只接受 termux|wsl|linux）" >&2; return 2 ;;
    esac

    # 字段清理与兜底归一（各分支产出后统一把关）
    NET_TYPE=$(clean_field "$NET_TYPE")
    WIFI_NAME=$(clean_field "$WIFI_NAME")
    PUBLIC_IP=$(clean_field "$PUBLIC_IP")
    LOCAL_IP=$(clean_field "$LOCAL_IP")
    VPN_IFACE=$(clean_field "$VPN_IFACE")
    VPN_IP=$(clean_field "$VPN_IP")
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="Unknown"
    [ -z "$LOCAL_IP" ] && LOCAL_IP="N/A"
    [ -z "$WIFI_NAME" ] && WIFI_NAME="Unknown_WiFi"
    [ -z "$VPN_IFACE" ] && VPN_IFACE="N/A"
    [ -z "$VPN_IP" ] && VPN_IP="N/A"

    local timestamp current full
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    current="Network: $NET_TYPE | WiFi_Name: $WIFI_NAME | Public_IP: $PUBLIC_IP | Local_IP: $LOCAL_IP | VPN_Interface: $VPN_IFACE | VPN_IP: $VPN_IP"
    full="$timestamp | $current"

    if [ "$dry_run" = 1 ]; then
        printf '%s\n' "$full"
        return 0
    fi

    if has_changed "$current"; then
        write_log "$full"
        [ -t 2 ] && echo "[ip_monitor] recorded: $current" >&2
    fi
    return 0
}

# 启动（-t 优先；cron 等非 tty 场景静默）
case "${1:-}" in
    -t) main "$@" ;;
    *)  if [ -t 2 ]; then main "$@"; else main "$@" >/dev/null 2>&1; fi ;;
esac
