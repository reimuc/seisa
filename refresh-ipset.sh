#!/system/bin/sh
# =====================================================================
# 🔄 refresh-ipset.sh - IPSet 规则刷新守护脚本
# ---------------------------------------------------------------------
# 定期调用规则脚本刷新 IPSet，确保代理规则实时更新
# =====================================================================

# 严格模式和错误处理
set -e
trap '[ $? -ne 0 ] && abort_safe "⛔ 脚本执行失败: $?"' EXIT

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

# 刷新间隔（秒），可通过 REFRESH_INTERVAL_SEC 覆盖，默认 900 秒（15 分钟）
REFRESH_INTERVAL=${REFRESH_INTERVAL_SEC:-900}

log_safe "❤️=== [refresh-ipset] ===❤️"
log_safe "🔄 启动 ipset 刷新，间隔 ${REFRESH_INTERVAL} 秒"

if [ ! -x "$START_RULES" ]; then
  log_safe "❌ 规则脚本 $(basename "$START_RULES") 不可执行，启动失败"
  exit 1
fi

while true; do
  log_safe "🔄 执行刷新..."

  if ! sh "$START_RULES" refresh; then
    log_safe "❌ 刷新执行失败"
  fi

  sleep "$REFRESH_INTERVAL"
done