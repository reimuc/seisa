#!/system/bin/sh
#
# ============================================================================== 
# 👁️ monitor.sh - 核心进程守护脚本
# ============================================================================== 
#
# 守护代理核心进程, 自动检测并重启异常退出, 防止服务中断。
# - 定期检查核心进程存活状态
# - 自动重启并限制重启频率, 防止资源浪费
#
# ==============================================================================
set -e

MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

# 在指定时间窗口内允许的最大重启次数
MAX_RESTARTS=${MAX_RESTARTS:-6}
# 时间窗口大小（秒）
WINDOW=${WINDOW:-300} # 5 分钟

# 用于记录重启时间戳的文件
RESTARTS_FILE="$PERSIST_DIR/.restart_timestamps"
# 确保该文件存在
touch "$RESTARTS_FILE" 2>/dev/null || true

log "❤️=== [monitor] ===❤️"
log "👁️ 启动监控守护..."

if [ ! -x "$SERVICE" ]; then
  log "❌ 服务脚本 $(basename "$SERVICE") 不可执行, 启动失败"
  exit 0
fi

# 主监控循环
monitor_loop() {
  while true; do
    # 每 5 秒检查一次
    sleep 5
    # 检查 PID 文件是否存在
    if [ -f "$PIDFILE" ]; then
      # 读取 PID
      pid=$(cat "$PIDFILE" 2>/dev/null || true)
      # 如果 PID 存在且进程正在运行 (kill -0), 则跳过本次循环
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        continue
      fi
    fi

    # --- 如果代码执行到这里, 说明代理核心进程已停止运行 ---
    log "❗ 检测到核心已停止"

    # --- 检查 service.sh 是否正在运行 ---
    if [ -f "$LOCK_FILE" ]; then
      log "⏳ 服务启动中, 等待..."
      sleep 10 # 等待 10 秒后重新检查
      continue
    fi

    # --- 重启频率限制逻辑 ---
    now=$(date +%s)
    # 使用 awk 清理时间戳文件, 只保留最近 $WINDOW 秒内的记录
    awk -v now="$now" -v win="$WINDOW" '$1 >= now-win {print $1}' "$RESTARTS_FILE" 2>/dev/null > "${RESTARTS_FILE}.tmp" || true
    mv "${RESTARTS_FILE}.tmp" "$RESTARTS_FILE" 2>/dev/null || true
    # 计算当前窗口内的重启次数
    count=$(wc -l < "$RESTARTS_FILE" 2>/dev/null || echo 0)

    # 如果重启次数超过上限
    if [ "$count" -ge "$MAX_RESTARTS" ]; then
      log "⚠️ $WINDOW 秒内重启次数超限($count), 休眠 60 秒"
      sleep 60
      continue # 休眠后重新开始检查, 而不是立即重启
    fi

    # --- 执行重启操作 ---
    log "🚀 核心未运行, 尝试重启"

    sh "$SERVICE" >> "$LOGFILE" 2>&1 || log "❌ 服务重启失败"

    # 记录本次重启的时间戳
    echo "$(date +%s)" >> "$RESTARTS_FILE"

    sleep 2
  done
}

monitor_loop