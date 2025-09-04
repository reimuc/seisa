#!/system/bin/sh
#
# ============================================================================== 
# 🔄 refresh-ipset.sh - IPSet 规则刷新守护脚本
# ============================================================================== 
#
# 定期调用规则脚本刷新 IPSet, 确保代理规则实时更新。
# - 后台运行, 定时执行刷新命令
# - 保证出站服务器 IP 列表及时同步
#
# ==============================================================================
set -e

MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

# 刷新间隔（秒）, 可以从外部通过环境变量 REFRESH_INTERVAL_SEC 设置, 默认为 900 秒（15 分钟）。
INTERVAL=${REFRESH_INTERVAL_SEC:-900}

log "❤️=== [refresh-ipset] ===❤️"
log "🔄 启动 ipset 刷新, 间隔 ${INTERVAL} 秒"

if [ ! -x "$START_RULES" ]; then
  log "❌ 规则脚本 $(basename "$START_RULES") 不可执行, 启动失败"
  exit 0
fi

# --- 主循环 ---
refresh_ipset_loop() {
  while true; do
    log "🔄 执行刷新..."
    # 执行刷新命令, 并将输出追加到主日志文件
    sh "$START_RULES" refresh >> "$LOGFILE" 2>&1 || log "❌ 刷新执行失败"
    # 等待指定的间隔时间
    sleep "$INTERVAL"
  done
}

refresh_ipset_loop