#!/system/bin/sh
#
# ==============================================================================
# uninstall.sh - 在模块被卸载时执行的脚本
# ==============================================================================
#
# ## 功能:
# - 优雅地停止正在运行的核心进程
# - 清理所有相关的 iptables, ip6tables, ip rule, ip route, 和 ipset 规则
# - 确保系统网络环境恢复到模块安装前的状态
#
# ==============================================================================

set -e

# --- 初始化与变量定义 ---
MODDIR=${0%/*}
. "$MODDIR/common.sh"

ui_print_safe "[uninstall.sh]: 开始执行..."

# --- 步骤 1: 尝试通过 service.sh 优雅地停止服务 ---
if [ -x "$SERVICE" ]; then
  ui_print_safe "正在停止服务..."
  # 在后台执行, 并将日志输出到主日志文件
  sh "$SERVICE" stop >> "$LOGFILE" 2>&1 || ui_print_safe "- 脚本返回非零值, 可能存在服务未停止"
fi

# 通过进程名进行全面清理
if command -v pgrep >/dev/null 2>&1 && command -v readlink >/dev/null 2>&1; then
  ui_print_safe "正在查找并终止残留进程..."
  first_char=${BIN_NAME%%"${BIN_NAME#?}"}
  rest_chars=${BIN_NAME#?}
  for pid in $(pgrep -f "[$first_char]$rest_chars.*$MODID" 2>/dev/null); do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo "unknown")
    ui_print_safe "- 发现残留进程PID: $pid"
    kill "$pid" >/dev/null 2>&1
    ui_print_safe "- 已终止 $exe"
  done
fi

# --- 步骤 2: 显式地进行防火墙清理 (最大努力) ---
ui_print_safe "正在尝试最终防火墙清理..."

# 移除 ip rule 和 ip route (IPv4)
ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

# 移除 ip rule 和 ip route (IPv6)
ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true

# 移除 iptables 链
if command -v iptables >/dev/null 2>&1; then
  iptables -t mangle -D PREROUTING -j SINGBOX 2>/dev/null || true
  iptables -t mangle -F SINGBOX 2>/dev/null || true
  iptables -t mangle -X SINGBOX 2>/dev/null || true
fi

# 移除 ip6tables 链
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t mangle -D PREROUTING -j SINGBOX6 2>/dev/null || true
  ip6tables -t mangle -F SINGBOX6 2>/dev/null || true
  ip6tables -t mangle -X SINGBOX6 2>/dev/null || true
fi

# 清理 ipset
if command -v ipset >/dev/null 2>&1; then
  ipset destroy singbox_outbounds_v4 2>/dev/null || true
  ipset destroy singbox_outbounds_v6 2>/dev/null || true
fi

ui_print_safe "[uninstall.sh]: 执行完毕"

# 模块目录将由 Magisk 自身负责移除, 脚本不应尝试删除它
exit 0