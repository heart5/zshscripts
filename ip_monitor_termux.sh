#!/data/data/com.termux/files/usr/bin/bash

# 优化版IP监控脚本 - 轻量、兼容、低资源占用

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

LOG_FILE="$DATA_DIR/ip_changes.log"
TEMP_FILE="$DATA_DIR/ip_changes.tmp"

# 配置参数 - 可根据不同手机性能调整
MAX_RUNTIME_SECONDS=8     # 最大运行时间（秒）
MAX_LOG_LINES=9000         # 最大日志行数（减少内存占用）
# CHECK_INTERVAL_MINUTES=7   # 检查间隔（分钟）

# 清理字段中的特殊字符（简化版）
clean_field() {
    echo "$1" | tr -d '\n\r\t' | sed 's/|/_/g' | head -c 100
}

# 简化进程检查 - 更可靠的方法
check_running_instance() {
    local script_name=$(basename "$0")
    local script_path=$(realpath "$0")
    local current_pid=$$

    # 方法1：使用pgrep（如果可用）
    if command -v pgrep >/dev/null 2>&1; then
        # 安装pgrep（如果不存在）
        if ! pkg list-installed | grep -q procps; then
            pkg install procps -y >/dev/null 2>&1
        fi

        # 查找同名脚本进程（排除当前进程）
        local running_count=$(pgrep -f "$script_name" | grep -v "^$current_pid$" | wc -l)
        if [ "$running_count" -gt 0 ]; then
            echo "检测到已有实例在运行，退出当前进程"
            return 1
        fi
        return 0
    fi

    # 方法2：使用ps的简化版本（避免复杂grep）
    # 获取所有bash进程，排除当前进程
    local other_instances=$(ps -o pid,comm,args 2>/dev/null | grep -E "bash.*$script_name" | grep -v "grep" | grep -v " $current_pid ")

    if [ -n "$other_instances" ]; then
        # 进一步过滤：只检查运行时间小于60秒的进程
        for pid in $(echo "$other_instances" | awk '{print $1}'); do
            if [ "$pid" != "$current_pid" ] && [ -n "$pid" ]; then
                # 检查进程是否存在
                if ps -p "$pid" >/dev/null 2>&1; then
                    local cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
                    # 确认确实是同一个脚本
                    if echo "$cmdline" | grep -q "$script_name"; then
                        echo "检测到已有实例在运行(PID: $pid)，退出当前进程"
                        return 1
                    fi
                fi
            fi
        done
    fi

    return 0
}

# 替代方案：使用简单的锁文件（更可靠）
check_running_instance_simple() {
    local lock_file="$DATA_DIR/ip_monitor.lock"
    local lock_timeout=60  # 锁超时时间（秒）

    # 如果锁文件存在且未超时
    if [ -f "$lock_file" ]; then
        local lock_pid=$(cat "$lock_file" 2>/dev/null)
        local lock_time=$(stat -c %Y "$lock_file" 2>/dev/null || echo 0)
        local current_time=$(date +%s)

        # 检查锁是否超时
        if [ $((current_time - lock_time)) -lt "$lock_timeout" ]; then
            # 检查锁中的PID是否仍在运行
            if [ -n "$lock_pid" ] && ps -p "$lock_pid" >/dev/null 2>&1; then
                echo "检测到已有实例在运行(PID: $lock_pid)，退出当前进程"
                return 1
            fi
        fi
    fi

    # 创建新锁
    echo $$ > "$lock_file"
    return 0
}

# 检测是否开启了热点
is_hotspot_active() {
    # 检查是否有热点相关的接口
    if command -v ifconfig >/dev/null 2>&1; then
        local ifconfig_output=$(ifconfig 2>/dev/null)
        
        # 检查p2p-p2p0-0接口（热点接口）
        if echo "$ifconfig_output" | grep -q '^p2p-p2p0-0:'; then
            return 0  # 热点活跃
        fi
        
        # 检查wlan0是否有热点IP（192.168.43.1）
        local wlan0_ip=$(echo "$ifconfig_output" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
        if echo "$wlan0_ip" | grep -q '^192\.168\.43\.1$'; then
            # 还需要确认wlan0没有连接到外部WiFi
            # 检查termux-wifi-connectioninfo是否返回有效的WiFi信息
            if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
                local wifi_info=$(termux-wifi-connectioninfo 2>/dev/null)
                local ssid=$(echo "$wifi_info" | grep -o '"ssid":"[^"]*"' | cut -d'"' -f4)
                
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

# 简化网络检测 - 增强版，支持热点检测
get_network_info() {
    local network_type="Mobile"
    local wifi_name="N/A"
    
    # 尝试获取WiFi信息（使用termux-wifi-connectioninfo）
    if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
        local wifi_info=$(termux-wifi-connectioninfo 2>/dev/null)
        
        # 检查是否有有效的ssid字段
        if echo "$wifi_info" | grep -q '"ssid"'; then
            # 提取ssid值
            wifi_name=$(echo "$wifi_info" | grep -o '"ssid":"[^"]*"' | cut -d'"' -f4)
            
            # 判断是否为有效的WiFi连接
            if [ "$wifi_name" != "<unknown ssid>" ] && [ "$wifi_name" != "null" ] && [ -n "$wifi_name" ]; then
                # 有效的WiFi连接
                network_type="WiFi"
                
                # 检查是否同时开启了热点
                if is_hotspot_active; then
                    # WiFi连接 + 热点开启
                    wifi_name="${wifi_name}_Hotspot"
                fi
            else
                # 非WiFi连接状态
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
            # 没有ssid字段
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
        # 命令不可用
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

# 获取本地IP - 增强版，支持热点检测
get_local_ip() {
    local network_type="$1"
    local ip="N/A"
    
    # ifconfig
    if command -v ifconfig >/dev/null 2>&1; then
        local ifconfig_output=$(ifconfig 2>/dev/null)
        
        # 根据网络类型获取对应的IP
        case "$network_type" in
            "WiFi")
                # WiFi连接：获取外部WiFi的IP
                # 查找wlan接口，排除热点IP（192.168.43.x）
                ip=$(echo "$ifconfig_output" | grep -A2 '^wlan' | grep 'inet ' | awk '{print $2}' | head -1)
                
                # 如果是热点IP，则不是真正的WiFi连接
                if echo "$ip" | grep -q '^192\.168\.43\.'; then
                    ip="N/A"
                fi
                ;;
                
            "Hotspot")
                # 热点模式：获取热点IP
                # 优先获取p2p-p2p0-0接口的IP
                ip=$(echo "$ifconfig_output" | grep -A2 '^p2p-p2p0-0:' | grep 'inet ' | awk '{print $2}' | head -1)
                
                # 如果没有p2p接口，获取wlan0的热点IP
                if [ -z "$ip" ] || [ "$ip" = "N/A" ]; then
                    ip=$(echo "$ifconfig_output" | grep -A2 '^wlan0:' | grep 'inet ' | awk '{print $2}' | head -1)
                    # 确认是热点IP（192.168.43.1）
                    if ! echo "$ip" | grep -q '^192\.168\.43\.1$'; then
                        ip="N/A"
                    fi
                fi
                ;;
                
            "Mobile")
                # 移动网络：获取移动网络IP
                ip=$(echo "$ifconfig_output" | grep -A2 '^rmnet\|^ccmni' | grep 'inet ' | awk '{print $2}' | head -1)
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

# 获取VPN信息 - 修复版
get_vpn_info() {
    local vpn_interface="N/A"
    local vpn_ip="N/A"

    # 获取完整的ifconfig输出
    local ifconfig_output=$(ifconfig 2>/dev/null)

    # 查找VPN接口（tun, tap, ppp等）
    # 先查找接口名
    vpn_interface=$(echo "$ifconfig_output" | grep -o '^tun[0-9]*:' | cut -d':' -f1 | head -1)

    # 如果没有找到tun接口，尝试其他VPN接口
    if [ -z "$vpn_interface" ]; then
        vpn_interface=$(echo "$ifconfig_output" | grep -o '^tap[0-9]*:' | cut -d':' -f1 | head -1)
    fi

    if [ -z "$vpn_interface" ]; then
        vpn_interface=$(echo "$ifconfig_output" | grep -o '^ppp[0-9]*:' | cut -d':' -f1 | head -1)
    fi

    # 如果找到了VPN接口，提取IP地址
    if [ -n "$vpn_interface" ]; then
        # 方法1：使用sed提取该接口的IP
        vpn_ip=$(echo "$ifconfig_output" | sed -n "/^$vpn_interface:/,/^[a-z]/p" | grep 'inet ' | awk '{print $2}' | head -1)

        # 方法2：如果方法1失败，尝试备用方法
        if [ -z "$vpn_ip" ] || [ "$vpn_ip" = "127.0.0.1" ]; then
            vpn_ip=$(echo "$ifconfig_output" | grep -A5 "^$vpn_interface:" | grep 'inet ' | awk '{print $2}' | head -1)
        fi

        # 方法3：最后尝试使用正则表达式直接匹配
        if [ -z "$vpn_ip" ] || [ "$vpn_ip" = "127.0.0.1" ]; then
            vpn_ip=$(echo "$ifconfig_output" | grep -A2 "^$vpn_interface:" | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1)
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

# 清理函数
cleanup() {
    # 清理锁文件（如果使用锁文件方案）
    local lock_file="$DATA_DIR/ip_monitor.lock"
    if [ -f "$lock_file" ]; then
        local lock_pid=$(cat "$lock_file" 2>/dev/null)
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$lock_file" 2>/dev/null
        fi
    fi

    # 清理超时进程
    [ -n "$timeout_pid" ] && kill -9 "$timeout_pid" 2>/dev/null || true
}

# 主函数
main() {
    # 设置清理陷阱
    trap cleanup EXIT

    # 设置超时
    trap timeout_handler ALRM
    (sleep "$MAX_RUNTIME_SECONDS"; kill -ALRM $$) &
    timeout_pid=$!

    # 检查是否有其他实例在运行（使用锁文件方案，更可靠）
    if ! check_running_instance_simple; then
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
}

# 启动脚本
if [ "$1" = "--debug" ]; then
    echo "调试模式启动..."
    echo "当前PID: $$"
    echo "脚本路径: $(realpath "$0")"
    main
else
    # 静默运行（适合定时任务）
    main >/dev/null 2>&1
fi