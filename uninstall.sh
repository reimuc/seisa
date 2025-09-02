#!/system/bin/sh
#
# ============================================================================== 
# 🧹 uninstall.sh - 卸载清理脚本
# ============================================================================== 
#
# 优雅停止核心进程，清理所有网络规则，恢复系统环境。
# - 停止代理核心与相关进程
# - 清理 iptables/ip6tables/ip rule/ip route/ipset
# - 保证卸载后网络环境干净
#
# ============================================================================== 
set -e

# --- 初始化与变量定义 ---
MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

ui_print_safe "🗑️ [uninstall.sh]: 开始卸载清理..."

# --- 步骤 1: 尝试通过 service.sh 优雅地停止服务 ---
if [ -x "$SERVICE" ]; then
  ui_print_safe "🛑 停止服务..."
  # 在后台执行, 并将日志输出到主日志文件
  sh "$SERVICE" stop >> "$LOGFILE" 2>&1 || ui_print_safe "⚠️ - 脚本返回非零值, 服务可能未完全停止。"
fi

# --- 步骤 2: 通过进程名进行全面清理 ---
if command -v readlink >/dev/null 2>&1; then
  ui_print_safe "🔍 查找并终止残留进程..."
  for pid in $(ps -A | awk -v modid="$MODID" -v bin="$BIN_NAME" '$0 ~ bin && $0 ~ modid && !/awk/ {print $1}'); do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo "unknown")
    ui_print_safe "🚫 发现残留进程 $pid ($exe)，强制终止..."
    kill -9 "$pid" >/dev/null 2>&1
  done
fi

# --- 步骤 3: 显式地进行防火墙清理 (最大努力) ---
ui_print_safe "🔥 最终防火墙清理..."

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

ui_print_safe "✅ [uninstall.sh]: 清理完毕！"

# 模块目录将由 Magisk 自身负责移除, 脚本不应尝试删除它
exit 0