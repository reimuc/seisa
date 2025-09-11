#!/system/bin/sh
# =====================================================================
# 🧹 uninstall.sh - 卸载清理脚本
# ---------------------------------------------------------------------
# 优雅停止核心进程, 清理所有网络规则, 恢复系统环境
# =====================================================================

# 严格模式和错误处理
set -e
trap '[ $? -ne 0 ] && abort_safe "⛔ 脚本执行失败: $?"' EXIT

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

log_safe "❤️=== [uninstall] ===❤️"
log_safe "🗑️ 开始卸载清理..."

# 1. 尝试通过 service.sh 优雅地停止服务
if [ -x "$SERVICE" ]; then
  log_safe "⭕️ 正在通过 ($(basename "$SERVICE") 停止服务..."
  $SERVICE stop >/dev/null 2>&1 || log_safe "❗ 服务可能未完全停止"
fi

# 2. 使用 pkill 终止所有残留的核心进程, 确保无遗漏
if command -v pkill >/dev/null 2>&1; then
  log_safe "🔍 正在使用 pkill 终止残留的 '$BIN_NAME' 进程..."
  pkill -9 -f "$BIN_NAME.*$MODID" 2>/dev/null || true
fi

# 3. 再次尝试直接调用规则脚本清理网络规则, 作为最终保障
if [ -x "$START_RULES" ]; then
  log_safe "🧹 正在执行最终网络规则清理..."
  $START_RULES stop >/dev/null 2>&1 || log_safe "❗ 网络规则可能未完全清理"
fi

log_safe "✅ 卸载清理完毕"
exit 0