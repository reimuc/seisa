#!/system/bin/sh
#
# monitor.sh - 简单守护 sing-box 进程
# - 由 service.sh 在后台启动（nohup monitor.sh &）
# - 功能：检测 sing-box 是否存活，若退出则尝试重新启动（有限次数），并记录日志
#
set -e

MODDIR=${MAGISK_MODULE_DIR:-/data/adb/modules/transparent-singbox}
PERSIST=${PERSIST_DIR:-/data/adb/transparent-singbox}
BIN="$MODDIR/sing-box"
SERVICE_SH="$MODDIR/service.sh"
PIDFILE="$PERSIST/singbox.pid"
LOG="$PERSIST/transparent-singbox.log"

# 参数：最大重启次数，重启窗口（秒）
MAX_RESTARTS=6
WINDOW=300    # 5 minutes

log() {
  echo "[$(date +'%F %T')] $*" >> "$LOG"
}

# track restart timestamps
RESTARTS_FILE="$PERSIST/.restart_timestamps"
touch "$RESTARTS_FILE" 2>/dev/null || true

monitor_loop() {
  while true; do
    sleep 5
    # is pid alive?
    if [ -f "$PIDFILE" ]; then
      PID=$(cat "$PIDFILE" 2>/dev/null || true)
      if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        # alive
        continue
      fi
    fi

    # not running -> attempt restart with rate limiting
    now=$(date +%s)
    # remove old timestamps
    awk -v now="$now" -v win="$WINDOW" '$1 >= now-win {print $1}' "$RESTARTS_FILE" 2>/dev/null > "${RESTARTS_FILE}.tmp" || true
    mv "${RESTARTS_FILE}.tmp" "$RESTARTS_FILE" 2>/dev/null || true
    count=$(wc -l < "$RESTARTS_FILE" 2>/dev/null || echo 0)

    if [ "$count" -ge "$MAX_RESTARTS" ]; then
      log "monitor: reached max restart count ($count) in $WINDOW s; not restarting to avoid loop"
      # sleep longer and continue
      sleep 60
      continue
    fi

    # attempt restart: call service.sh (which will reapply rules and start sing-box)
    if [ -x "$SERVICE_SH" ]; then
      log "monitor: sing-box not running; attempting restart via $SERVICE_SH"
      sh "$SERVICE_SH" >> "$LOG" 2>&1 || log "monitor: failed to start via service.sh"
    else
      log "monitor: service.sh not found/executable; cannot restart"
    fi

    # record restart timestamp
    echo "$(date +%s)" >> "$RESTARTS_FILE"
    sleep 2
  done
}

monitor_loop