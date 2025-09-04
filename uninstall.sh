#!/system/bin/sh
#
# ============================================================================== 
# 🧹 uninstall.sh - 卸载清理脚本
# ============================================================================== 
#
# 优雅停止核心进程，清理所有网络规则，恢复系统环境。
# - 停止代理核心与相关进程
# - 清理 iptables/ip6tables/ip rule/ip route/ipset
#
# ============================================================================== 
set -e

MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

ui_print_safe "❤️=== [uninstall] ===❤️"
ui_print_safe "🗑️ 开始卸载清理..."

# --- 步骤 1: 尝试通过 service.sh 优雅地停止服务 ---
if [ -x "$SERVICE" ]; then
  ui_print_safe "🛑 卸载中: 停止服务..."
  # 在后台执行, 并将日志输出到主日志文件
  sh "$SERVICE" stop >> "$LOGFILE" 2>&1 || ui_print_safe "⚠️ 服务可能未完全停止"
fi

# --- 步骤 2: 通过进程名进行全面清理 ---
if command -v readlink >/dev/null 2>&1; then
  ui_print_safe "🔍 查找并终止残留进程..."
  for pid in $(ps -A | awk -v modid="$MODID" -v bin="$BIN_NAME" '$0 ~ bin && $0 ~ modid && !/awk/ {print $1}'); do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo "unknown")
    ui_print_safe "🚫 发现残留进程 $pid $exe, 正在终止"
    kill -9 "$pid" >/dev/null 2>&1
  done
fi

ui_print_safe "✅ 卸载清理完毕"

exit 0