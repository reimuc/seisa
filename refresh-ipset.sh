#!/system/bin/sh
#
# ==============================================================================
# refresh-ipset.sh - 定期刷新 ipset 规则的守护脚本
# ==============================================================================
#
# ## 功能:
# - 作为一个后台服务运行, 按固定的时间间隔调用 start.rules.sh 的 'refresh' 命令。
# - 'refresh' 命令会重新解析配置文件, 更新出站服务器的 IP 列表到 ipset 中。
# - 这对于使用域名作为出站服务器地址的场景非常重要, 因为域名解析到的 IP 可能会变化。
#
# ==============================================================================

set -e

# --- 初始化与变量定义 ---
MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

# --- 可配置变量 ---

# 刷新间隔（秒）, 可以从外部通过环境变量 REFRESH_INTERVAL_SEC 设置, 默认为 900 秒（15 分钟）。
INTERVAL=${REFRESH_INTERVAL_SEC:-900}

log "[refresh-ipset.sh]: 正在启动 ipset 刷新, 刷新间隔为 ${INTERVAL} 秒"

if [ ! -x "$START_RULES" ]; then
  log "[refresh-ipset.sh]: 规则脚本 $(basename "$START_RULES") 未找到或不可执行, 启动失败"
  exit 0
fi

# --- 主循环 ---
refresh_ipset_loop() {
  while true; do
    log "[refresh-ipset.sh]: 正在执行刷新..."
    # 执行刷新命令, 并将输出追加到主日志文件
    sh "$START_RULES" refresh >> "$LOGFILE" 2>&1 || log "[refresh-ipset.sh]: 脚本 $(basename "$START_RULES") 调用失败"
    # 等待指定的间隔时间
    sleep "$INTERVAL"
  done
}

refresh_ipset_loop