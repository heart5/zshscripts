#!/usr/bin/zsh
#!/data/data/com.termux/files/usr/bin/zsh

# 可配置的磁盘空间监控脚本
# 用法: ./diskspacecount.zsh [挂载点:名称] [挂载点:名称] ...
# 示例: ./diskspacecount.zsh /:root /data:data /storage/emulated:termux_storage

# 检测是否在 Termux 环境中运行
if [[ -n "$TERMUX_VERSION" ]] || [[ -d "/data/data/com.termux/files/usr" ]]; then
    IS_TERMUX=true
else
    IS_TERMUX=false
fi

# 设置数据目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

# 获取当前时间戳
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# 默认监控配置（如果没有提供参数）
DEFAULT_MONITORS=("/:root")

# 解析命令行参数
parse_arguments() {
    local monitors=()

    if [[ $# -eq 0 ]]; then
        # 没有参数，使用默认配置
        echo "[$TIMESTAMP] 使用默认监控配置" >&2
        monitors=("${DEFAULT_MONITORS[@]}")
    else
        # 解析每个参数
        for arg in "$@"; do
            # 跳过空参数
            if [[ -z "$arg" ]]; then
                continue
            fi

            # 检查是否是有效的参数格式
            if [[ "$arg" =~ ^[^[:space:]]+:[^[:space:]]+$ ]]; then
                # 格式: 挂载点:名称
                monitors+=("$arg")
                echo "[$TIMESTAMP] 添加监控: $arg" >&2
            elif [[ "$arg" =~ ^/[^[:space:]]*$ ]]; then
                # 只有挂载点，自动生成名称
                mountpoint="$arg"
                if [[ "$mountpoint" == "/" ]]; then
                    name="root"
                else
                    # 从挂载点生成名称（去掉开头的/，替换/为_）
                    name=$(echo "$mountpoint" | sed 's|^/||' | tr '/' '_' | tr -cd '[:alnum:]_')
                    if [[ -z "$name" ]]; then
                        name="mount_$(date +%s)"
                    fi
                fi
                monitors+=("${mountpoint}:${name}")
                echo "[$TIMESTAMP] 自动命名: $mountpoint -> $name" >&2
            else
                echo "[$TIMESTAMP] 警告: 跳过无效参数 '$arg'" >&2
            fi
        done
    fi

    # 返回监控配置数组
    for monitor in "${monitors[@]}"; do
        echo "$monitor"
    done
}

# 验证挂载点
validate_mountpoint() {
    local mountpoint="$1"
    
    # 检查路径是否存在（基础检查）
    if [[ ! -e "$mountpoint" ]]; then
        echo "[$TIMESTAMP] 警告: 路径 $mountpoint 不存在" >&2
        return 1
    fi
    
    # Termux 环境：使用 df 命令验证路径可访问性
    if [[ "$IS_TERMUX" == true ]]; then
        if df "$mountpoint" >/dev/null 2>&1; then
            return 0
        else
            echo "[$TIMESTAMP] 警告: （termux环境）无法通过 df 访问 $mountpoint，可能无权限或路径无效" >&2
            return 1
        fi
    else
        # 标准 Linux 环境：使用 mountpoint 命令验证
        if ! mountpoint -q "$mountpoint" 2>/dev/null; then
            echo "[$TIMESTAMP] 警告: $mountpoint 未挂载或不是挂载点" >&2
            return 1
        fi
    fi
    
    return 0
}

# 监控单个挂载点
monitor_mountpoint() {
    local mountpoint="$1"
    local name="$2"
    
    # 验证挂载点
    if ! validate_mountpoint "$mountpoint"; then
        return 1
    fi
    
    # 数据文件路径
    DATA_FILE="$DATA_DIR/disk_${name}.log"
    
    # 获取磁盘信息
    if df -B 1G "$mountpoint" >/dev/null 2>&1; then
        # 使用GB单位
        DISK_INFO=$(df -B 1G -h "$mountpoint" 2>/dev/null | tail -1)
    else
        # 使用默认单位
        DISK_INFO=$(df -h "$mountpoint" 2>/dev/null | tail -1)
    fi
    
    if [[ -n "$DISK_INFO" ]]; then
        # 解析磁盘信息
        read -r filesystem size used available usage mount <<< "$(echo "$DISK_INFO")"
        
        # 清理使用率字符串（去掉%）
        usage_clean=$(echo "$usage" | sed 's/%//')
        
        # 记录格式: 时间戳 挂载点 使用率% 已用 总量 可用 文件系统
        echo "$TIMESTAMP $mountpoint $usage_clean $used $size $available $filesystem" >> "$DATA_FILE"
        
        # 输出到控制台
        echo "[$TIMESTAMP] ✓ $mountpoint ($name): $usage 已用, 可用: $available"
        
        # 限制日志文件大小（保留最近500行）
        if [[ $(wc -l < "$DATA_FILE") -gt 500 ]]; then
            tail -n 500 "$DATA_FILE" > "${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "$DATA_FILE"
        fi
        
        return 0
    else
        echo "[$TIMESTAMP] ✗ 无法获取 $mountpoint 的磁盘信息" >&2
        return 1
    fi
}

# 主函数
main() {
    echo "[$TIMESTAMP] 开始磁盘空间监控"
    
    # 解析参数
    local monitors=()
    while IFS= read -r line; do
        monitors+=("$line")
    done < <(parse_arguments "$@")
    
    if [[ ${#monitors[@]} -eq 0 ]]; then
        echo "[$TIMESTAMP] 错误: 没有有效的监控配置" >&2
        exit 1
    fi
    
    echo "[$TIMESTAMP] 配置监控 ${#monitors[@]} 个挂载点"
    
    local success_count=0
    local fail_count=0
    
    # 监控每个配置的挂载点
    for monitor in "${monitors[@]}"; do
        # 分割挂载点和名称
        IFS=':' read -r mountpoint name <<< "$monitor"
        
        if [[ -z "$mountpoint" ]] || [[ -z "$name" ]]; then
            echo "[$TIMESTAMP] 警告: 跳过无效监控配置 '$monitor'" >&2
            ((fail_count++))
            continue
        fi
        
        if monitor_mountpoint "$mountpoint" "$name"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    # 清理旧数据文件（保留最近30天）
    find "$DATA_DIR" -name "disk_*.log" -mtime +30 -delete 2>/dev/null
    
    echo "[$TIMESTAMP] 监控完成: ${success_count}成功, ${fail_count}失败"
    echo "[$TIMESTAMP] 数据保存在: $DATA_DIR"
    
    # 生成配置文件示例（如果不存在）
    if [[ ! -f "$DATA_DIR/monitor_config.example" ]]; then
        cat > "$DATA_DIR/monitor_config.example" << EOF
# 磁盘监控配置文件示例
# 格式: 挂载点:文件名
# 文件名将用于生成 disk_文件名.log

/:root
/data:data
/home:home
/storage/emulated:termux_storage
/Volumes/Data:mac_data

# 自动命名示例（只指定挂载点）
/var
/opt
EOF
        echo "[$TIMESTAMP] 配置文件示例已生成: $DATA_DIR/monitor_config.example"
    fi
    
    # 如果有失败，返回非零退出码
    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
}

# 执行主函数
main "$@"
