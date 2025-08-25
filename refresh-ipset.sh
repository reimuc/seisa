#!/system/bin/sh
#
# refresh-ipset.sh - 周期刷新 outbound ipset（用于应对 CDN IP 动态变化）
# - 调用 start.rules.sh refresh（你已有脚本支持 refresh）
# - 由 service.sh 在后台启动（可选）
#
set -e

PERSIST=${PERSIST_DIR:-/data/adb/transparent-singbox}
MODDIR=${MAGISK_MODULE_DIR:-/data/adb/modules/transparent-singbox}
REFRESH_SCRIPT="$PERSIST/start.rules.sh"
# fallback to module script if user didn't override
if [ ! -x "$REFRESH_SCRIPT" ]; then
  REFRESH_SCRIPT="$MODDIR/start.rules.sh"
fi

LOG="$PERSIST/transparent-singbox.log"
INTERVAL=${REFRESH_INTERVAL_SEC:-900} # 默认 15 分钟

log() { echo "[$(date +'%F %T')] $*" >> "$LOG"; }

if [ ! -x "$REFRESH_SCRIPT" ]; then
  log "refresh-ipset: no refresh-capable start.rules.sh found; exiting"
  exit 0
fi

while true; do
  log "refresh-ipset: invoking refresh on $REFRESH_SCRIPT"
  sh "$REFRESH_SCRIPT" refresh >> "$LOG" 2>&1 || log "refresh-ipset: refresh failed"
  sleep "$INTERVAL"
done