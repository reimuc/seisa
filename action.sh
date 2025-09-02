#!/system/bin/sh
#
# ==============================================================================
# 🎬 action.sh - 模块操作入口脚本
# ==============================================================================
#
# 提供一键启动/停止代理核心主程序及防火墙规则的操作接口。
# - 统一入口，便于外部调用和集成
# - 简化用户操作流程
#
# ==============================================================================
set -e

MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

ui_print_safe "❤️❤️❤️=== [action] ===❤️❤️❤️"
ui_print_safe "🎬 正在切换服务状态..."

if [ -x "$SERVICE" ]; then

  if [ -f "$FLAG" ]; then

    ui_print_safe "⛔ 服务已运行，正在停止..."

    sh "$SERVICE" stop >/dev/null 2>&1 || {
      ui_print_safe "❌ 服务停止失败"
      exit 1
    }
  else
    ui_print_safe "🚀 服务未运行，正在启动..."

    sh "$SERVICE" >/dev/null 2>&1 || {
      ui_print_safe "❌ 服务启动失败"
      exit 1
    }
  fi
fi