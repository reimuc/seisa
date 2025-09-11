#!/system/bin/sh
# =====================================================================
# 👁️ monitor.sh - 核心进程守护脚本
# ---------------------------------------------------------------------
# 守护代理核心进程, 自动检测并重启异常退出, 防止服务中断
# - 定期检查核心进程存活状态
# - 自动重启并限制重启频率
# =====================================================================

set -e
trap '[ $? -ne 0 ] && abort_safe "⛔ 脚本执行失败: $?"' EXIT

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

MAX_RESTARTS=${MAX_RESTARTS:-6}       # 时间窗口内最大重启次数
WINDOW=${WINDOW:-300}                 # 时间窗口（秒）
CHECK_INTERVAL=${CHECK_INTERVAL:-5}   # 检查间隔（秒）
RESTARTS_FILE="$PERSIST_DIR/.restart_timestamps"

touch "$RESTARTS_FILE" 2>/dev/null || true

log_safe "❤️=== [monitor] ===❤️"
log_safe "👁️ 启动监控守护..."

[ -x "$SERVICE" ] || abort_safe "❌ 服务 $(basename "$SERVICE") 不可执行, 启动失败"

while true; do
  sleep "$CHECK_INTERVAL"

  # 检查 PID 文件
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
  fi

  log_safe "❗ 检测到核心已停止"

  # 如果 service.sh 正在运行, 等待
  if [ -f "$LOCK_FILE" ]; then
    log_safe "⏳ 服务启动中, 等待..."
    sleep 10
    continue
  fi

  # 重启频率限制
  now=$(date +%s)
  tmpfile=$(mktemp)
  awk -v now="$now" -v win="$WINDOW" '$1 >= now-win {print $1}' "$RESTARTS_FILE" 2>/dev/null > "$tmpfile" || true
  mv -f "$tmpfile" "$RESTARTS_FILE" 2>/dev/null || true
  count=$(wc -l < "$RESTARTS_FILE" 2>/dev/null || echo 0)

  if [ "$count" -ge "$MAX_RESTARTS" ]; then
    log_safe "❗ $WINDOW 秒内重启次数超限($count), 休眠 60 秒"
    sleep 60
    continue
  fi

  # 执行重启
  log_safe "🚀 核心未运行, 尝试重启"

  $SERVICE >/dev/null 2>&1 || abort_safe "❌ 服务 $(basename "$SERVICE") 重启失败"

  "$(date +%s)" >> "$RESTARTS_FILE"
  sleep 2
done