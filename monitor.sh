#!/system/bin/sh
#
# ==============================================================================
# monitor.sh - 代理核心进程监控和自动重启脚本
# ==============================================================================
#
# ## 功能:
# - 定期检查代理核心进程是否仍在运行。
# - 如果进程意外退出, 则尝试自动重启它。
# - 实现了一个重启频率限制机制, 以避免在持续失败的情况下造成系统资源浪费。
#
# ==============================================================================

set -e

# --- 初始化与变量定义 ---
MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

# --- 可配置变量 ---

# 在指定时间窗口内允许的最大重启次数
MAX_RESTARTS=${MAX_RESTARTS:-6}
# 时间窗口大小（秒）
WINDOW=${WINDOW:-300} # 5 分钟

# 用于记录重启时间戳的文件
RESTARTS_FILE="$PERSIST_DIR/.restart_timestamps"
# 确保该文件存在
touch "$RESTARTS_FILE" 2>/dev/null || true

log "[monitor.sh]: 监控脚本启动中..."

if [ ! -x "$SERVICE" ]; then
  log "[monitor.sh]: 服务脚本 $(basename "$SERVICE") 未找到或不可执行, 启动失败"
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
    log "[monitor.sh]: 检测到代理核心已停止"

    # --- 重启频率限制逻辑 ---
    now=$(date +%s)
    # 使用 awk 清理时间戳文件, 只保留最近 $WINDOW 秒内的记录
    awk -v now="$now" -v win="$WINDOW" '$1 >= now-win {print $1}' "$RESTARTS_FILE" 2>/dev/null > "${RESTARTS_FILE}.tmp" || true
    mv "${RESTARTS_FILE}.tmp" "$RESTARTS_FILE" 2>/dev/null || true
    # 计算当前窗口内的重启次数
    count=$(wc -l < "$RESTARTS_FILE" 2>/dev/null || echo 0)

    # 如果重启次数超过上限
    if [ "$count" -ge "$MAX_RESTARTS" ]; then
      log "[monitor.sh]: 在 $WINDOW 秒内达到最大重启次数 ($count), 将休眠 60 秒"
      sleep 60
      continue # 休眠后重新开始检查, 而不是立即重启
    fi

    # --- 执行重启操作 ---
    log "[monitor.sh]: 代理核心未运行, 尝试通过 $(basename "$SERVICE") 重启"
    # 调用 service.sh 脚本来启动服务
    # 注意：这里不使用 'start' 参数, 因为 service.sh 的默认行为就是启动
    sh "$SERVICE" >> "$LOGFILE" 2>&1 || log "[monitor.sh]: 脚本 $(basename "$SERVICE") 调用失败"

    # 记录本次重启的时间戳
    echo "$(date +%s)" >> "$RESTARTS_FILE"
    # 短暂休眠, 等待 sing-box 启动
    sleep 2
  done
}

monitor_loop