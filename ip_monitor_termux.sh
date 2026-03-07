#!/data/data/com.termux/files/usr/bin/bash

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

# 创建data目录（如果不存在）
mkdir -p "$DATA_DIR"

LOG_FILE="$DATA_DIR/ip_changes.log"
TEMP_FILE="$DATA_DIR/ip_changes.tmp"
LOCK_FILE="$DATA_DIR/ip_monitor.lock"

# 清理字段中的特殊字符
clean_field() {
    local field="$1"
    # 移除换行符、回车符
    field=$(echo "$field" | tr -d '\n\r')
    # 替换竖线为横线（避免破坏日志格式）
    field=$(echo "$field" | sed 's/|/-/g')
    # 替换冒号为空格+冒号（提高可读性）
    field=$(echo "$field" | sed 's/:/ :/g')
    echo "$field"
}

# 检查并安装必要的工具
check_dependencies() {
    if ! command -v ifconfig &> /dev/null; then
        echo "ifconfig未安装，正在安装net-tools..."
        pkg install net-tools -y
    fi

    if ! command -v curl &> /dev/null; then
        echo "curl未安装，正在安装..."
        pkg install curl -y
    fi

    if ! command -v jq &> /dev/null; then
        echo "jq未安装，正在安装..."
        pkg install jq -y
    fi
}

# 获取当前网络类型和WiFi名称
get_network_info() {
    local wifi_info network_type wifi_name

    # 获取WiFi连接信息
    wifi_info=$(termux-wifi-connectioninfo 2>/dev/null)

    if echo "$wifi_info" | grep -q "ssid"; then
        network_type="WiFi"
        # 提取WiFi名称（SSID），处理可能的特殊字符
        wifi_name=$(echo "$wifi_info" | grep -o '"ssid":"[^"]*"' | cut -d'"' -f4)
        # 如果提取失败，尝试其他方法
        if [ -z "$wifi_name" ]; then
            wifi_name=$(echo "$wifi_info" | jq -r '.ssid' 2>/dev/null || echo "Unknown_WiFi")
        fi
        # 如果WiFi名称为空或null，使用Unknown_WiFi
        if [ -z "$wifi_name" ] || [ "$wifi_name" = "null" ] || [ "$wifi_name" = "<unknown ssid>" ]; then
            wifi_name="Unknown_WiFi"
        fi
    else
        network_type="Mobile"
        wifi_name="N/A"
    fi

    # 清理WiFi名称
    wifi_name=$(clean_field "$wifi_name")

    echo "$network_type|$wifi_name"
}

# 获取公网IP
get_public_ip() {
    local ip
    # 尝试多个API，增加成功率
    ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null)
    if [ -z "$ip" ] || [ "$ip" = "" ]; then
        ip=$(curl -s --max-time 3 https://ipinfo.io/ip 2>/dev/null)
    fi
    if [ -z "$ip" ] || [ "$ip" = "" ]; then
        ip=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null)
    fi
    echo "${ip:-Unknown}"
}

# 使用ifconfig获取局域网IP（修复版）
get_local_ip() {
    local network_type="$1"
    local ip=""

    # 获取所有网络接口信息
    local ifconfig_output
    ifconfig_output=$(ifconfig 2>/dev/null)

    if [ "$network_type" = "WiFi" ]; then
        # 方法1：优先使用termux-wifi-connectioninfo获取WiFi IP
        ip=$(termux-wifi-connectioninfo 2>/dev/null | grep -o '"ip_address":"[^"]*"' | cut -d'"' -f4)

        # 方法2：如果方法1失败，从ifconfig输出中查找WiFi接口IP
        if [ -z "$ip" ] || [ "$ip" = "null" ]; then
            # 查找所有wlan接口（wlan0, wlan1等）
            for iface in $(echo "$ifconfig_output" | grep -o '^wlan[0-9]*' | sort -u); do
                ip=$(echo "$ifconfig_output" | sed -n "/^$iface:/,/^[^ ]/p" | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
                if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
                    break
                fi
            done
        fi

        # 方法3：如果还没有找到，尝试查找其他可能的WiFi接口
        if [ -z "$ip" ]; then
            ip=$(echo "$ifconfig_output" | (
                while read -r line; do
                    if echo "$line" | grep -q '^[a-z]'; then
                        current_iface=$(echo "$line" | cut -d: -f1)
                    fi
                    if echo "$line" | grep -q 'inet ' && [ "$current_iface" != "lo" ]; then
                        temp_ip=$(echo "$line" | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
                        if [ -n "$temp_ip" ] && [ "$temp_ip" != "127.0.0.1" ]; then
                            # 检查是否为私有IP（WiFi通常是私有IP）
                            if echo "$temp_ip" | grep -q '^192\.168\.' || echo "$temp_ip" | grep -q '^10\.' || echo "$temp_ip" | grep -q '^172\.'; then
                                echo "$temp_ip"
                                exit 0
                            fi
                        fi
                    fi
                done
                echo "N/A"
            ))
        fi
    else
        # 移动数据：从ifconfig输出中查找移动数据接口IP
        # 查找rmnet接口（rmnet0, rmnet1等）
        for iface in $(echo "$ifconfig_output" | grep -o '^rmnet[0-9]*' | sort -u); do
            ip=$(echo "$ifconfig_output" | sed -n "/^$iface:/,/^[^ ]/p" | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
                break
            fi
        done

        # 如果还没有找到，尝试其他可能的移动数据接口
        if [ -z "$ip" ]; then
            ip=$(echo "$ifconfig_output" | (
                while read -r line; do
                    if echo "$line" | grep -q '^[a-z]'; then
                        current_iface=$(echo "$line" | cut -d: -f1)
                    fi
                    if echo "$line" | grep -q 'inet ' && [ "$current_iface" != "lo" ] && [[ "$current_iface" != wlan* ]]; then
                        temp_ip=$(echo "$line" | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
                        if [ -n "$temp_ip" ] && [ "$temp_ip" != "127.0.0.1" ]; then
                            # 移动数据IP通常是10.x.x.x或运营商分配的IP
                            echo "$temp_ip"
                            exit 0
                        fi
                    fi
                done
                echo "N/A"
            ))
        fi
    fi

    # 清理IP地址，移除可能的换行符
    ip=$(echo "$ip" | tr -d '\n\r')

    # 如果IP为空，返回N/A
    if [ -z "$ip" ]; then
        echo "N/A"
    else
        echo "$ip"
    fi
}

# 获取VPN接口信息
get_vpn_info() {
    local ifconfig_output vpn_ip vpn_interface

    # 获取所有网络接口信息
    ifconfig_output=$(ifconfig 2>/dev/null)

    # 查找常见的VPN接口（tun0, tun1, ppp0, etc）
    for vpn_iface in $(echo "$ifconfig_output" | grep -o '^tun[0-9]*\|^ppp[0-9]*\|^tap[0-9]*' | sort -u); do
        vpn_ip=$(echo "$ifconfig_output" | sed -n "/^$vpn_iface:/,/^[^ ]/p" | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
        if [ -n "$vpn_ip" ] && [ "$vpn_ip" != "127.0.0.1" ]; then
            vpn_interface="$vpn_iface"
            break
        fi
    done

    # 如果没有找到常见的VPN接口，尝试查找其他可能的VPN接口
    if [ -z "$vpn_ip" ]; then
        # 查找包含"POINTOPOINT"标志的接口（通常是VPN接口）
        echo "$ifconfig_output" | while read -r line; do
            if echo "$line" | grep -q '^[a-z]'; then
                current_iface=$(echo "$line" | cut -d: -f1)
            fi
            if echo "$line" | grep -q 'POINTOPOINT' && echo "$line" | grep -q 'RUNNING'; then
                # 这是一个点对点接口，可能是VPN
                vpn_ip=$(echo "$ifconfig_output" | sed -n "/^$current_iface:/,/^[^ ]/p" | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
                if [ -n "$vpn_ip" ] && [ "$vpn_ip" != "127.0.0.1" ]; then
                    vpn_interface="$current_iface"
                    echo "$vpn_interface|$vpn_ip"
                    return
                fi
            fi
        done | head -1
    else
        echo "$vpn_interface|$vpn_ip"
    fi

    # 如果没有找到VPN接口，返回N/A
    if [ -z "$vpn_ip" ]; then
        echo "N/A|N/A"
    fi
}

# 从日志行中提取信息
extract_log_info() {
    local line="$1"
    local timestamp network wifi_name public_ip local_ip vpn_interface vpn_ip

    # 解析日志行格式: 2026-03-07 10:30:15 | Network: Mobile | WiFi_Name: N/A | Public_IP: 123.45.67.89 | Local_IP: 192.168.1.100 | VPN_Interface: tun0 | VPN_IP: 10.8.0.2
    # 或者旧格式（兼容处理）

    # 统计字段数量
    local field_count
    field_count=$(echo "$line" | tr '|' '\n' | wc -l)

    timestamp=$(echo "$line" | cut -d'|' -f1 | xargs)
    network=$(echo "$line" | cut -d'|' -f2 | cut -d':' -f2 | xargs)

    if [ "$field_count" -eq 7 ]; then
        # 新格式（包含VPN信息）
        wifi_name=$(echo "$line" | cut -d'|' -f3 | cut -d':' -f2 | xargs)
        public_ip=$(echo "$line" | cut -d'|' -f4 | cut -d':' -f2 | xargs)
        local_ip=$(echo "$line" | cut -d'|' -f5 | cut -d':' -f2 | xargs)
        vpn_interface=$(echo "$line" | cut -d'|' -f6 | cut -d':' -f2 | xargs)
        vpn_ip=$(echo "$line" | cut -d'|' -f7 | cut -d':' -f2 | xargs)
    elif [ "$field_count" -eq 5 ]; then
        # 旧格式（包含WiFi_Name但不包含VPN信息）
        wifi_name=$(echo "$line" | cut -d'|' -f3 | cut -d':' -f2 | xargs)
        public_ip=$(echo "$line" | cut -d'|' -f4 | cut -d':' -f2 | xargs)
        local_ip=$(echo "$line" | cut -d'|' -f5 | cut -d':' -f2 | xargs)
        vpn_interface="N/A"
        vpn_ip="N/A"
    else
        # 更旧的格式（不包含WiFi_Name和VPN信息）
        wifi_name="N/A"
        public_ip=$(echo "$line" | cut -d'|' -f3 | cut -d':' -f2 | xargs)
        local_ip=$(echo "$line" | cut -d'|' -f4 | cut -d':' -f2 | xargs)
        vpn_interface="N/A"
        vpn_ip="N/A"
    fi

    echo "$timestamp|$network|$wifi_name|$public_ip|$local_ip|$vpn_interface|$vpn_ip"
}

# 检查是否有变化
has_changed() {
    local current_network="$1"
    local current_wifi_name="$2"
    local current_public_ip="$3"
    local current_local_ip="$4"
    local current_vpn_interface="$5"
    local current_vpn_ip="$6"

    # 如果日志文件不存在或为空，直接记录
    if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
        return 0  # 有变化（需要记录）
    fi

    # 读取最新的一条记录（文件第一行）
    local latest_line
    latest_line=$(head -n 1 "$LOG_FILE" 2>/dev/null)

    if [ -z "$latest_line" ]; then
        return 0
    fi

    # 提取最新记录的信息
    local latest_info
    latest_info=$(extract_log_info "$latest_line")

    local latest_network latest_wifi_name latest_public_ip latest_local_ip latest_vpn_interface latest_vpn_ip
    latest_network=$(echo "$latest_info" | cut -d'|' -f2)
    latest_wifi_name=$(echo "$latest_info" | cut -d'|' -f3)
    latest_public_ip=$(echo "$latest_info" | cut -d'|' -f4)
    latest_local_ip=$(echo "$latest_info" | cut -d'|' -f5)
    latest_vpn_interface=$(echo "$latest_info" | cut -d'|' -f6)
    latest_vpn_ip=$(echo "$latest_info" | cut -d'|' -f7)

    # 比较当前信息与最新记录
    if [ "$current_network" != "$latest_network" ] || \
       [ "$current_wifi_name" != "$latest_wifi_name" ] || \
       [ "$current_public_ip" != "$latest_public_ip" ] || \
       [ "$current_local_ip" != "$latest_local_ip" ] || \
       [ "$current_vpn_interface" != "$latest_vpn_interface" ] || \
       [ "$current_vpn_ip" != "$latest_vpn_ip" ]; then
        return 0  # 有变化
    else
        return 1  # 无变化
    fi
}

# 防止多实例运行
acquire_lock() {
    # 尝试获取锁，如果失败则退出
    if [ -e "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && ps -p "$lock_pid" > /dev/null 2>&1; then
            echo "脚本已在运行中 (PID: $lock_pid)，跳过本次执行"
            exit 0
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# 释放锁
release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null
}

# 设置超时处理
timeout_handler() {
    echo "脚本执行超时，强制退出"
    release_lock
    exit 1
}

# 主函数
main() {
    # 设置超时（30秒）
    trap timeout_handler ALRM
    (sleep 30; kill -ALRM $$) &
    timeout_pid=$!

    # 获取锁
    acquire_lock

    # 检查依赖
    check_dependencies

    # 获取当前网络信息
    local network_info
    network_info=$(get_network_info)
    NETWORK_TYPE=$(echo "$network_info" | cut -d'|' -f1)
    WIFI_NAME=$(echo "$network_info" | cut -d'|' -f2)

    # 获取IP信息
    PUBLIC_IP=$(get_public_ip)
    LOCAL_IP=$(get_local_ip "$NETWORK_TYPE")

    # 获取VPN信息
    local vpn_info
    vpn_info=$(get_vpn_info)
    VPN_INTERFACE=$(echo "$vpn_info" | cut -d'|' -f1)
    VPN_IP=$(echo "$vpn_info" | cut -d'|' -f2)

    # 清理所有字段
    WIFI_NAME=$(clean_field "$WIFI_NAME")
    PUBLIC_IP=$(clean_field "$PUBLIC_IP")
    LOCAL_IP=$(clean_field "$LOCAL_IP")
    VPN_INTERFACE=$(clean_field "$VPN_INTERFACE")
    VPN_IP=$(clean_field "$VPN_IP")

    # 检查是否有变化
    if has_changed "$NETWORK_TYPE" "$WIFI_NAME" "$PUBLIC_IP" "$LOCAL_IP" "$VPN_INTERFACE" "$VPN_IP"; then
        # 生成新记录 - 使用printf确保格式一致
        NEW_RECORD=$(printf "%s | Network: %s | WiFi_Name: %s | Public_IP: %s | Local_IP: %s | VPN_Interface: %s | VPN_IP: %s" \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$NETWORK_TYPE" \
            "$WIFI_NAME" \
            "$PUBLIC_IP" \
            "$LOCAL_IP" \
            "$VPN_INTERFACE" \
            "$VPN_IP")

        echo "检测到网络/IP变化，记录新信息:"
        echo "$NEW_RECORD"

        # 将新记录添加到文件开头（实现日期倒序）
        if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
            # 创建临时文件，先写入新记录，再追加旧内容
            echo "$NEW_RECORD" > "$TEMP_FILE"
            cat "$LOG_FILE" >> "$TEMP_FILE"
            mv "$TEMP_FILE" "$LOG_FILE"
        else
            # 文件不存在或为空，直接创建
            echo "$NEW_RECORD" > "$LOG_FILE"
        fi

        # 可选：限制日志文件大小（保留最近100000条记录）
        if [ -f "$LOG_FILE" ]; then
            head -n 100000 "$LOG_FILE" > "$TEMP_FILE" 2>/dev/null && mv "$TEMP_FILE" "$LOG_FILE"
        fi
    else
        echo "网络/IP未发生变化，跳过记录"
        echo "当前: Network: $NETWORK_TYPE, WiFi: $WIFI_NAME, Public_IP: $PUBLIC_IP, Local_IP: $LOCAL_IP, VPN: $VPN_INTERFACE ($VPN_IP)"
    fi

    # 清理超时进程
    kill -9 "$timeout_pid" 2>/dev/null || true

    # 释放锁
    release_lock
}

# 执行主函数
if [ "$1" = "--debug" ]; then
    main "--debug"                                 
else
    main                                          
fi
