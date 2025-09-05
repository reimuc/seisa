#!/system/bin/sh
# =====================================================================
# 🎬 action.sh - 模块操作入口脚本
# ---------------------------------------------------------------------
# 一键启动/停止代理核心主程序及防火墙规则
# =====================================================================

set -e
trap '[ $? -ne 0 ] && abort_safe "⛔ 脚本执行失败: $?"' EXIT

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

log_safe "❤️=== [action] ===❤️"
log_safe "🎬 正在切换服务状态..."

if [ ! -x "$SERVICE" ]; then
  log_safe "❌ 服务脚本 $(basename "$SERVICE") 不可执行，操作中止"
  exit 1
fi

if [ -f "$FLAG" ]; then
  log_safe "⛔ 服务已运行，正在停止..."
  if ! sh "$SERVICE" stop >/dev/null 2>&1; then
    log_safe "❌ 服务停止失败"
    exit 1
  fi
else
  log_safe "🚀 服务未运行，正在启动..."
  if ! sh "$SERVICE" >/dev/null 2>&1; then
    log_safe "❌ 服务启动失败"
    exit 1
  fi
fi