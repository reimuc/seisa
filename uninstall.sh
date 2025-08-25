#!/system/bin/sh
#
# uninstall.sh
# 建议在模块被卸载时运行，用来优雅停止运行中的 sing-box 并清理 iptables/ip6tables/ip rule/ip route/ipset 等
# 注意：Magisk 在卸载模块时并不总是会自动停止用户态进程或清理自定义防火墙规则，因此提供 uninstall.sh 做显式清理更稳妥。
#
# 用法：由 Magisk 在卸载时调用，或手动运行以完全移除规则与进程。
set -e

MODID="transparent-singbox"
MODDIR="/data/adb/modules/${MODID}"
LOGFILE="${MODDIR}/transparent-singbox.log"
TMPLOG="/data/local/tmp/${MODID}-uninstall.log"

log() {
  if [ -w "$LOGFILE" ]; then
    echo "[$(date +'%F %T')] $*" >> "$LOGFILE"
  else
    echo "[$(date +'%F %T')] $*" >> "$TMPLOG"
  fi
}

log "uninstall.sh: invoked"

# 1) Try to stop service via service.sh
if [ -x "$MODDIR/service.sh" ]; then
  log "Calling service.sh stop"
  sh "$MODDIR/service.sh" stop >> "$LOGFILE" 2>&1 || {
    log "service.sh stop returned non-zero"
  }
else
  log "No service.sh found or not executable"
fi

# 2) Try start.rules.sh stop (extra cleanup)
if [ -x "$MODDIR/start.rules.sh" ]; then
  log "Calling start.rules.sh stop"
  sh "$MODDIR/start.rules.sh" stop >> "$LOGFILE" 2>&1 || {
    log "start.rules.sh stop returned non-zero"
  }
fi

# 3) Ensure sing-box process is killed (pid file or process scan)
if [ -f "$MODDIR/singbox.pid" ]; then
  PID=$(cat "$MODDIR/singbox.pid" 2>/dev/null || true)
  if [ -n "$PID" ]; then
    if kill -0 "$PID" 2>/dev/null; then
      log "Killing sing-box pid $PID"
      kill "$PID" 2>/dev/null || true
      sleep 1
    fi
  fi
  rm -f "$MODDIR/singbox.pid" 2>/dev/null || true
fi

# fallback: try pkill for sing-box binaries inside module dir (best-effort)
if command -v pgrep >/dev/null 2>&1; then
  for pid in $(pgrep -f sing-box 2>/dev/null || true); do
    exe=$(readlink -f /proc/"$pid"/exe 2>/dev/null || true)
    case "$exe" in
      "$MODDIR"/*|*"$MODID"*)
        log "Killing sing-box (pid $pid, exe $exe)"
        kill "$pid" 2>/dev/null || true
        ;;
      *)
        ;;
    esac
  done
fi

# 4) Explicit firewall cleanup (best-effort)
log "Attempting firewall cleanup (iptables/ip6tables/ip/ip6/ipset)"

# remove ip rule / ip route (ipv4)
ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

# remove ip rule / ip route (ipv6)
ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true

# remove chains (iptables)
if command -v iptables >/dev/null 2>&1; then
  iptables -t mangle -D PREROUTING -j SINGBOX 2>/dev/null || true
  iptables -t mangle -F SINGBOX 2>/dev/null || true
  iptables -t mangle -X SINGBOX 2>/dev/null || true
fi

# remove chains (ip6tables)
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t mangle -D PREROUTING -j SINGBOX6 2>/dev/null || true
  ip6tables -t mangle -F SINGBOX6 2>/dev/null || true
  ip6tables -t mangle -X SINGBOX6 2>/dev/null || true
fi

# ipset cleanup
if command -v ipset >/dev/null 2>&1; then
  ipset destroy singbox_outbounds_v4 2>/dev/null || true
  ipset destroy singbox_outbounds_v6 2>/dev/null || true
fi

log "uninstall.sh: cleanup finished"

# Optionally leave module directory to Magisk to remove; do not try to rm -rf here (Magisk uninstaller will)
exit 0