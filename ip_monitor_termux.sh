#!/data/data/com.termux/files/usr/bin/bash

# 优化版IP监控脚本 - 轻量、兼容、低资源占用

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

LOG_FILE="$DATA_DIR/ip_changes.log"
TEMP_FILE="$DATA_DIR/ip_changes.tmp"

# 配置参数 - 可根据不同手机性能调整
MAX_RUNTIME_SECONDS=15     # 最大运行时间（秒）
MAX_LOG_LINES=5000         # 最大日志行数（减少内存占用）
CHECK_INTERVAL_MINUTES=7   # 检查间隔（分钟）

# 清理字段中的特殊字符（简化版）
clean_field() {
    echo "$1" | tr -d '\n\r\t' | sed 's/|/_/g' | head -c 100
}

# 检查是否已有实例在运行（替代锁机制）
check_running_instance() {
    local script_name=$(basename "$0")
    local current_pid=$$
    
    # 查找同名脚本进程（排除当前进程）
    local running_pids=$(ps -o pid,cmd | grep -E "bash.*$script_name" | grep -v "grep" | grep -v " $current_pid " | awk '{print $1}')
    
    if [ -n "$running_pids" ]; then
        # 检查这些进程是否真的在运行（不是僵尸进程）
        for pid in $running_pids; do
            if [ -d "/proc/$pid" ]; then
                local elapsed_time=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
                if [ -n "$elapsed_time" ] && [ "$elapsed_time" -lt 300 ]; then  # 5分钟内启动的进程
                    echo "检测到已有实例在运行(PID: $pid, 已运行: ${elapsed_time}s)，退出当前进程"
                    return 1
                fi
            fi
        done
    fi
    return 0
}

# 简化网络检测 - 使用最可靠的方法
get_network_info() {
    local network_type="Mobile"
    local wifi_name="N/A"
    
    # 尝试获取WiFi信息（使用termux-wifi-connectioninfo）
    if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
        local wifi_info=$(termux-wifi-connectioninfo 2>/dev/null)
        if echo "$wifi_info" | grep -q '"ssid"'; then
            network_type="WiFi"
            # 简化WiFi名称提取
            wifi_name=$(echo "$wifi_info" | grep -o '"ssid":"[^"]*"' | cut -d'"' -f4)
            [ -z "$wifi_name" ] && wifi_name="Unknown_WiFi"
            [ "$wifi_name" = "null" ] && wifi_name="Unknown_WiFi"
        fi
    fi
    
    # 清理WiFi名称
    wifi_name=$(clean_field "$wifi_name")
    echo "$network_type|$wifi_name"
}

# 获取公网IP - 只使用一个最可靠的API
get_public_ip() {
    local ip="Unknown"
    
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

# 获取本地IP - 简化版
get_local_ip() {
    local network_type="$1"
    local ip="N/A"
    
    # ifconfig
    if command -v ifconfig >/dev/null 2>&1; then
        local ifconfig_output=$(ifconfig 2>/dev/null)
        
        if [ "$network_type" = "WiFi" ]; then
            # 查找wlan接口
            ip=$(echo "$ifconfig_output" | grep -A1 'wlan' | grep 'inet ' | awk '{print $2}' | head -1)
        else
            # 查找移动网络接口
            ip=$(echo "$ifconfig_output" | grep -A1 'rmnet\|ccmni' | grep 'inet ' | awk '{print $2}' | head -1)
        fi
    fi
    
    # 验证IP
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        echo "$ip"
    else
        echo "N/A"
    fi
}

# 获取VPN信息 - 简化版
get_vpn_info() {
    local vpn_interface="N/A"
    local vpn_ip="N/A"
    
    # 使用ip命令检测tun接口
    if command -v ip >/dev/null 2>&1; then
        vpn_interface=$(ip link show 2>/dev/null | grep -o 'tun[0-9]*:' | cut -d':' -f1 | head -1)
        if [ -n "$vpn_interface" ]; then
            vpn_ip=$(ip -o -4 addr show dev "$vpn_interface" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1)
        fi
    # 回退到ifconfig
    elif command -v ifconfig >/dev/null 2>&1; then
        vpn_interface=$(ifconfig 2>/dev/null | grep -o '^tun[0-9]*' | head -1)
        if [ -n "$vpn_interface" ]; then
            vpn_ip=$(ifconfig "$vpn_interface" 2>/dev/null | grep 'inet ' | awk '{print $2}')
        fi
    fi
    
    echo "${vpn_interface:-N/A}|${vpn_ip:-N/A}"
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
        # 简化解析逻辑
        local latest_network=$(echo "$latest_line" | cut -d'|' -f2 | cut -d':' -f2 | xargs)
        local latest_wifi=$(echo "$latest_line" | cut -d'|' -f3 | cut -d':' -f2 | xargs)
        local latest_public_ip=$(echo "$latest_line" | cut -d'|' -f4 | cut -d':' -f2 | xargs)
        local latest_local_ip=$(echo "$latest_line" | cut -d'|' -f5 | cut -d':' -f2 | xargs)
        local latest_vpn_iface=$(echo "$latest_line" | cut -d'|' -f6 | cut -d':' -f2 | xargs)
        local latest_vpn_ip=$(echo "$latest_line" | cut -d'|' -f7 | cut -d':' -f2 | xargs)
        
        # 比较所有字段
        if [ "$current_network" != "$latest_network" ] || \
           [ "$current_wifi" != "$latest_wifi" ] || \
           [ "$current_public_ip" != "$latest_public_ip" ] || \
           [ "$current_local_ip" != "$latest_local_ip" ] || \
           [ "$current_vpn_iface" != "$latest_vpn_iface" ] || \
           [ "$current_vpn_ip" != "$latest_vpn_ip" ]; then
            return 0  # 有变化
        fi
    else
        # 文件为空或读取失败
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

# 超时处理函数
timeout_handler() {
    echo "脚本执行超时（超过${MAX_RUNTIME_SECONDS}秒），强制退出"
    exit 1
}

# 主函数
main() {
    # 设置超时
    trap timeout_handler ALRM
    (sleep "$MAX_RUNTIME_SECONDS"; kill -ALRM $$) &
    local timeout_pid=$!
    
    # 检查是否有其他实例在运行
    if ! check_running_instance; then
        kill -9 "$timeout_pid" 2>/dev/null
        exit 0
    fi
    
    # 获取当前信息
    local network_info=$(get_network_info)
    local network_type=$(echo "$network_info" | cut -d'|' -f1)
    local wifi_name=$(echo "$network_info" | cut -d'|' -f2)
    
    local public_ip=$(get_public_ip)
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
    
    # 检查变化
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if has_changed "$network_type" "$wifi_name" "$public_ip" "$local_ip" "$vpn_interface" "$vpn_ip"; then
        echo "检测到网络/IP变化，记录新信息:"
        echo "时间: $timestamp"
        echo "网络: $network_type, WiFi: $wifi_name"
        echo "公网IP: $public_ip, 本地IP: $local_ip"
        echo "VPN: $vpn_interface ($vpn_ip)"
        
        # 写入日志
        write_log "$timestamp" "$network_type" "$wifi_name" "$public_ip" "$local_ip" "$vpn_interface" "$vpn_ip"
    else
        echo "网络/IP未发生变化，跳过记录"
        echo "当前: Network: $network_type, WiFi: $wifi_name, Public_IP: $public_ip, Local_IP: $local_ip, VPN: $vpn_interface ($vpn_ip)"
    fi
    
    # 清理超时进程
    kill -9 "$timeout_pid" 2>/dev/null || true
}

# 启动脚本
if [ "$1" = "--debug" ]; then
    echo "调试模式启动..."
    main
else
    # 静默运行（适合定时任务）
    main >/dev/null 2>&1
fi