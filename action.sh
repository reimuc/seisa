#!/system/bin/sh
#
# ==============================================================================
# action - 模块操作脚本
# ==============================================================================
#
# ## 特性:
# - 启动/停止代理核心主程序以及相关的防火墙规则
#
# ==============================================================================

set -e

# --- 初始化与变量定义 ---
MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

ui_print_safe "[action.sh]: 正在切换服务状态..."

if [ -x "$SERVICE" ]; then

  # 检查服务运行标识
  if [ -f "$FLAG" ]; then
      # 服务已运行，执行停止操作
      ui_print_safe "[action.sh]: 服务已运行，正在停止..."
      # 停止服务
      sh "$SERVICE" stop >/dev/null 2>&1 || true
  else
      # 服务未运行，执行启动操作
      ui_print_safe "[action.sh]: 服务未运行，正在启动..."
      # 启动服务
      sh "$SERVICE" >/dev/null 2>&1 || true
  fi
else
  ui_print_safe "[action.sh]: 服务脚本不存在或不可执行"
fi