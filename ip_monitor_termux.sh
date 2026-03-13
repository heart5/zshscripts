#!/data/data/com.termux/files/usr/bin/bash

# 修复版IP监控脚本 - 解决WiFi检测问题

SCRIPT_DIR="$(dirname "$0")"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

LOG_FILE="$DATA_DIR/ip_changes.log"
TEMP_FILE="$DATA_DIR/ip_changes.tmp"

# 配置参数
MAX_RUNTIME_SECONDS=10
MAX_LOG_LINES=9000

# 全局缓存变量
GLOBAL_IFCONFIG_OUTPUT=""
GLOBAL_WIFI_INFO=""
GLOBAL_PUBLIC_IP=""

# 初始化全局缓存
init_global_cache() {
    # 获取ifconfig输出（一次性）
    if command -v ifconfig >/dev/null 2>&1; then
        GLOBAL_IFCONFIG_OUTPUT=$(ifconfig 2>/dev/null)
        echo "ifconfig输出长度: ${#GLOBAL_IFCONFIG_OUTPUT}" >&2
    fi

    # 获取WiFi信息（一次性）
    if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
        GLOBAL_WIFI_INFO=$(termux-wifi-connectioninfo 2>/dev/null)
        echo "WiFi信息: $GLOBAL_WIFI_INFO" >&2
    else
        echo "termux-wifi-connectioninfo命令不可用" >&2
    fi

    # 获取公网IP（一次性）
    GLOBAL_PUBLIC_IP=$(get_public_ip_cached)
}

# 获取公网IP（缓存版本）
get_public_ip_cached() {
    local ip="Unknown"

    # 如果已经有缓存，直接返回
    if [ -n "$GLOBAL_PUBLIC_IP" ] && [ "$GLOBAL_PUBLIC_IP" != "Unknown" ]; then
        echo "$GLOBAL_PUBLIC_IP"
        return
    fi

    # 方法1: 使用ipify.org（最可靠）
    ip=$(curl -s --max-time 5 --retry 1 https://api.ipify.org 2>/dev/null)

    # 方法2: 如果失败，尝试备用API
    if [ -z "$ip" ] || [ "$ip" = "" ] || echo "$ip" | grep -q "[^0-9.]"; then
        ip=$(curl -s --max-time 3 --retry 1 https://ifconfig.me 2>/dev/null)
    fi

    # 验证IP格式
    if echo "$ip" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "$ip"
    else
        echo "Unknown"
    fi
}

# 清理字段中的特殊字符（简化版）
clean_field() {
    echo "$1" | tr -d '\n\r\t' | sed 's/|/_/g' | head -c 100
}

# 检测是否连接到其他手机的热点
is_hotspot_connection() {
    # 使用全局缓存
    if [ -n "$GLOBAL_WIFI_INFO" ] && [ -n "$GLOBAL_IFCONFIG_OUTPUT" ]; then
        # 从WiFi信息中提取IP
        local wifi_ip=$(echo "$GLOBAL_WIFI_INFO" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

        # 检查是否是热点IP段（192.168.43.x）
        if echo "$wifi_ip" | grep -q '^192\.168\.43\.'; then
            # 进一步确认：检查wlan0接口是否有相同的IP
            local wlan0_ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)

            if [ "$wifi_ip" = "$wlan0_ip" ]; then
                # 确认是连接到热点
                return 0  # 是热点连接
            fi
        fi
    fi

    return 1  # 不是热点连接
}

# 检测是否开启了热点（使用全局缓存）
is_hotspot_active() {
    # 使用全局缓存
    if [ -n "$GLOBAL_IFCONFIG_OUTPUT" ]; then
        # 检查p2p-p2p0-0接口（热点接口）
        if echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -q '^p2p-p2p0-0:'; then
            return 0  # 热点活跃
        fi

        # 检查wlan0是否有热点IP（192.168.43.1）
        local wlan0_ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
        if echo "$wlan0_ip" | grep -q '^192\.168\.43\.1$'; then
            # 还需要确认wlan0没有连接到外部WiFi
            # 检查termux-wifi-connectioninfo是否返回有效的WiFi信息
            if [ -n "$GLOBAL_WIFI_INFO" ]; then
                local ssid=$(echo "$GLOBAL_WIFI_INFO" | sed -n 's/.*"ssid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

                # 如果没有有效的WiFi连接，才认为是热点模式
                if [ "$ssid" = "<unknown ssid>" ] || [ "$ssid" = "null" ] || [ -z "$ssid" ]; then
                    return 0  # 热点活跃
                fi
            else
                # 命令不可用，假设是热点
                return 0
            fi
        fi
    fi

    return 1  # 热点不活跃
}

# 简化网络检测 - 使用全局缓存
get_network_info() {
    local network_type="Mobile"
    local wifi_name="N/A"

    # 使用全局缓存
    if [ -n "$GLOBAL_WIFI_INFO" ]; then
        # 提取ssid值
        local ssid=$(echo "$GLOBAL_WIFI_INFO" | sed -n 's/.*"ssid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

        echo "提取的WiFi SSID: '$ssid'" >&2

        # 判断是否为有效的WiFi连接
        if [ -n "$ssid" ] && [ "$ssid" != "<unknown ssid>" ] && [ "$ssid" != "null" ]; then
            # 有效的WiFi连接
            network_type="WiFi"
            wifi_name="$ssid"

            # 检查是否是热点连接（通过IP判断）
            if is_hotspot_connection; then
                # 连接到其他手机的热点
                network_type="Hotspot_Client"
                wifi_name="${wifi_name}_HotspotClient"
            else
                # 真正的WiFi连接
                # 检查是否同时开启了热点
                if is_hotspot_active; then
                    # WiFi连接 + 热点开启
                    wifi_name="${wifi_name}_Hotspot"
                fi
            fi
        else
            wifi_name="Unknown_WiFi"

            # 检查是否开启了热点
            if is_hotspot_active; then
                # 移动网络 + 热点开启
                network_type="Hotspot"
                wifi_name="Hotspot_Mode"
            else
                # 纯移动网络
                network_type="Mobile"
            fi
        fi
    else
        # 没有获取到WiFi信息
        wifi_name="Unknown_WiFi"

        # 检查是否开启了热点
        if is_hotspot_active; then
            # 移动网络 + 热点开启
            network_type="Hotspot"
            wifi_name="Hotspot_Mode"
        else
            # 纯移动网络
            network_type="Mobile"
        fi
    fi

    # 清理WiFi名称（确保统一格式）
    wifi_name=$(clean_field "$wifi_name")
    echo "$network_type|$wifi_name"
}

# 获取本地IP - 使用全局缓存
get_local_ip() {
    local network_type="$1"
    local ip="N/A"

    # 使用全局缓存
    if [ -n "$GLOBAL_IFCONFIG_OUTPUT" ]; then

        # 根据网络类型获取对应的IP
        case "$network_type" in
            "WiFi")
                # 真正的WiFi连接：获取外部WiFi的IP
                # 查找wlan接口，排除热点IP（192.168.43.x）
                ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 '^wlan' | grep 'inet ' | awk '{print $2}' | head -1)

                # 如果是热点IP，则不是真正的WiFi连接
                if echo "$ip" | grep -q '^192\.168\.43\.'; then
                    ip="N/A"
                fi
                ;;

            "Hotspot_Client")
                # 连接到其他手机的热点：获取热点分配的IP
                # 从WiFi信息中提取IP
                if [ -n "$GLOBAL_WIFI_INFO" ]; then
                    ip=$(echo "$GLOBAL_WIFI_INFO" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                fi

                # 如果提取失败，从wlan0获取
                if [ -z "$ip" ] || [ "$ip" = "N/A" ]; then
                    ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
                fi
                ;;

            "Hotspot")
                # 热点模式：获取热点IP（本机开启热点）
                # 优先获取p2p-p2p0-0接口的IP
                ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 '^p2p-p2p0-0:' | grep 'inet ' | awk '{print $2}' | head -1)

                # 如果没有p2p接口，获取wlan0的热点IP
                if [ -z "$ip" ] || [ "$ip" = "N/A" ]; then
                    ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
                    # 确认是热点IP（192.168.43.1）
                    if ! echo "$ip" | grep -q '^192\.168\.43\.1$'; then
                        ip="N/A"
                    fi
                fi
                ;;

            "Mobile")
                # 移动网络：获取移动网络IP
                ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 '^rmnet\|^ccmni' | grep 'inet ' | awk '{print $2}' | head -1)
                ;;
        esac
    fi

    # 验证IP
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        echo "$ip"
    else
        echo "N/A"
    fi
}

# 获取VPN信息 - 使用全局缓存
get_vpn_info() {
    local vpn_interface="N/A"
    local vpn_ip="N/A"

    # 使用全局缓存
    if [ -n "$GLOBAL_IFCONFIG_OUTPUT" ]; then
        # 查找VPN接口（tun, tap, ppp等）
        # 先查找接口名
        vpn_interface=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -o '^tun[0-9]*:' | cut -d':' -f1 | head -1)

        # 如果没有找到tun接口，尝试其他VPN接口
        if [ -z "$vpn_interface" ]; then
            vpn_interface=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -o '^tap[0-9]*:' | cut -d':' -f1 | head -1)
        fi

        if [ -z "$vpn_interface" ]; then
            vpn_interface=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -o '^ppp[0-9]*:' | cut -d':' -f1 | head -1)
        fi

        # 如果找到了VPN接口，提取IP地址
        if [ -n "$vpn_interface" ]; then
            # 方法1：使用sed提取该接口的IP
            vpn_ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | sed -n "/^$vpn_interface:/,/^[a-z]/p" | grep 'inet ' | awk '{print $2}' | head -1)

            # 方法2：如果方法1失败，尝试备用方法
            if [ -z "$vpn_ip" ] || [ "$vpn_ip" = "127.0.0.1" ]; then
                vpn_ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A5 "^$vpn_interface:" | grep 'inet ' | awk '{print $2}' | head -1)
            fi

            # 方法3：最后尝试使用正则表达式直接匹配
            if [ -z "$vpn_ip" ] || [ "$vpn_ip" = "127.0.0.1" ]; then
                vpn_ip=$(echo "$GLOBAL_IFCONFIG_OUTPUT" | grep -A2 "^$vpn_interface:" | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1)
            fi
        fi
    fi

    # 清理输出
    [ -z "$vpn_ip" ] && vpn_ip="N/A"
    [ -z "$vpn_interface" ] && vpn_interface="N/A"

    echo "$vpn_interface|$vpn_ip"
}

# 检查是否有变化 - 优化IO操作
has_changed() {
    local current_network="$1"
    local current_wifi="$2"
    local current_public_ip="$3"
    local current_local_ip="$4"
    local current_vpn_iface="$5"
    local current_vpn_ip="$6"

    # 如果日志文件不存在，直接返回有变化
    [ ! -f "$LOG_FILE" ] && return 0

    # 只读取第一行（最新记录），减少IO
    local latest_line
    if read -r latest_line < "$LOG_FILE"; then
        echo "=== 解析最新日志记录 ===" >&2
        echo "日志行: $latest_line" >&2

        # 使用更健壮的解析方法
        local latest_network=$(echo "$latest_line" | awk -F'[|]' '{print $2}' | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local latest_wifi=$(echo "$latest_line" | awk -F'[|]' '{print $3}' | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local latest_public_ip=$(echo "$latest_line" | awk -F'[|]' '{print $4}' | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local latest_local_ip=$(echo "$latest_line" | awk -F'[|]' '{print $5}' | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local latest_vpn_iface=$(echo "$latest_line" | awk -F'[|]' '{print $6}' | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local latest_vpn_ip=$(echo "$latest_line" | awk -F'[|]' '{print $7}' | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        echo "解析结果:" >&2
        echo "latest_network: '$latest_network'" >&2
        echo "latest_wifi: '$latest_wifi'" >&2
        echo "latest_public_ip: '$latest_public_ip'" >&2
        echo "latest_local_ip: '$latest_local_ip'" >&2
        echo "latest_vpn_iface: '$latest_vpn_iface'" >&2
        echo "latest_vpn_ip: '$latest_vpn_ip'" >&2

        # 比较所有字段
        if [ "$current_network" != "$latest_network" ] || \
           [ "$current_wifi" != "$latest_wifi" ] || \
           [ "$current_public_ip" != "$latest_public_ip" ] || \
           [ "$current_local_ip" != "$latest_local_ip" ] || \
           [ "$current_vpn_iface" != "$latest_vpn_iface" ] || \
           [ "$current_vpn_ip" != "$latest_vpn_ip" ]; then
            echo "检测到变化！" >&2
            return 0  # 有变化
        else
            echo "所有字段相同，无变化" >&2
        fi
    else
        # 文件为空或读取失败
        echo "日志文件为空或读取失败" >&2
        return 0
    fi

    return 1  # 无变化
}

# 写入日志 - 优化IO操作
write_log() {
    local timestamp="$1"
    local network="$2"
    local wifi="$3"
    local public_ip="$4"
    local local_ip="$5"
    local vpn_iface="$6"
    local vpn_ip="$7"

    # 构建日志行
    local log_line="$timestamp | Network: $network | WiFi_Name: $wifi | Public_IP: $public_ip | Local_IP: $local_ip | VPN_Interface: $vpn_iface | VPN_IP: $vpn_ip"

    # 写入临时文件
    echo "$log_line" > "$TEMP_FILE"

    # 如果原日志存在，追加内容（限制行数）
    if [ -f "$LOG_FILE" ]; then
        # 读取原文件，合并新旧内容，限制行数
        head -n $((MAX_LOG_LINES - 1)) "$LOG_FILE" >> "$TEMP_FILE" 2>/dev/null
    fi

    # 原子操作：替换原文件
    mv "$TEMP_FILE" "$LOG_FILE"

    # 清理过大的日志文件（额外保护）
    if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_LINES ]; then
        head -n "$MAX_LOG_LINES" "$LOG_FILE" > "$TEMP_FILE" 2>/dev/null && mv "$TEMP_FILE" "$LOG_FILE"
    fi
}

# 主函数
main() {
    echo "=== IP监控脚本开始运行 ===" >&2

    # 初始化全局缓存（一次性获取所有必要信息）
    init_global_cache

    # 获取当前信息（全部使用缓存）
    local network_info=$(get_network_info)
    local network_type=$(echo "$network_info" | cut -d'|' -f1)
    local wifi_name=$(echo "$network_info" | cut -d'|' -f2)

    local public_ip="$GLOBAL_PUBLIC_IP"
    local local_ip=$(get_local_ip "$network_type")

    local vpn_info=$(get_vpn_info)
    local vpn_interface=$(echo "$vpn_info" | cut -d'|' -f1)
    local vpn_ip=$(echo "$vpn_info" | cut -d'|' -f2)

    # 清理字段
    wifi_name=$(clean_field "$wifi_name")
    public_ip=$(clean_field "$public_ip")
    local_ip=$(clean_field "$local_ip")
    vpn_interface=$(clean_field "$vpn_interface")
    vpn_ip=$(clean_field "$vpn_ip")

    # 显示当前信息
    echo "=== 当前网络信息 ===" >&2
    echo "网络类型: $network_type" >&2
    echo "WiFi名称: $wifi_name" >&2
    echo "公网IP: $public_ip" >&2
    echo "本地IP: $local_ip" >&2
    echo "VPN接口: $vpn_interface" >&2
    echo "VPN IP: $vpn_ip" >&2

    # 检查变化
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if has_changed "$network_type" "$wifi_name" "$public_ip" "$local_ip" "$vpn_interface" "$vpn_ip"; then
        echo "检测到网络/IP变化，记录新信息:" >&2
        echo "时间: $timestamp" >&2
        echo "网络: $network_type, WiFi: $wifi_name" >&2
        echo "公网IP: $public_ip, 本地IP: $local_ip" >&2
        echo "VPN: $vpn_interface ($vpn_ip)" >&2

        # 写入日志
        write_log "$timestamp" "$network_type" "$wifi_name" "$public_ip" "$local_ip" "$vpn_interface" "$vpn_ip"

        echo "=== 记录已保存 ===" >&2
    else
        echo "网络/IP未发生变化，跳过记录" >&2
        echo "当前: Network: $network_type, WiFi: $wifi_name, Public_IP: $public_ip, Local_IP: $local_ip, VPN: $vpn_interface ($vpn_ip)" >&2
    fi

    echo "=== IP监控脚本运行结束 ===" >&2
}

# 启动脚本
if [ "$(basename "$0")" = "$(basename "$(realpath "$0")")" ]; then
    main
else
    # 静默运行（适合定时任务）
    main >/dev/null 2>&1
fi