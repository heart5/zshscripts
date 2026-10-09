#!/data/data/com.termux/files/usr/bin/bash
# 兼容垫片：旧 crontab 入口（Termux），转发到统一采集器（环境判断在 ip_monitor.sh 内部）
# 未迁移 wrapper 的主机（双手机等）pull 本仓库即获统一逻辑与修复，无需改 crontab
exec bash "$(cd "$(dirname "$0")" && pwd)/ip_monitor.sh" "$@"
