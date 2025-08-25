#!/system/bin/sh
#
# Magisk late_start service: start/stop sing-box (tproxy mode) and rules
# - Uses persistent directory /data/adb/transparent-singbox for user config, tokens, logs
# - Seeds defaults from module on first run
# - Honors settings.conf to optionally start monitor.sh and refresh-ipset.sh
#
set -e

MODDIR=${MAGISK_MODULE_DIR:-/data/adb/modules/transparent-singbox}
PERSIST_DIR="/data/adb/transparent-singbox"

LOGFILE="$PERSIST_DIR/transparent-singbox.log"
PIDFILE="$PERSIST_DIR/singbox.pid"

MODULE_CONFIG="$MODDIR/config.json"
MODULE_RULES="$MODDIR/start.rules.sh"
MODULE_GHTOKEN="$MODDIR/github_token"
UPDATE_SCRIPT="$MODDIR/update-singbox.sh"
SINGBOX_BIN="$MODDIR/sing-box"

# defaults
CONFIG="$MODULE_CONFIG"
RULES_SCRIPT="$MODULE_RULES"

# whether to attempt auto-download of sing-box if missing
ENABLE_AUTO_UPDATE=1

log() {
  if [ ! -d "$PERSIST_DIR" ]; then
    mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    chmod 755 "$PERSIST_DIR" 2>/dev/null || true
  fi
  echo "[$(date +'%F %T')] $*" >> "$LOGFILE"
}

seed_persisted_defaults() {
  if [ ! -d "$PERSIST_DIR" ]; then
    mkdir -p "$PERSIST_DIR" 2>/dev/null || {
      log "ERROR: failed to create persist dir $PERSIST_DIR"
      return 1
    }
    chmod 755 "$PERSIST_DIR" 2>/dev/null || true
    log "Created persist dir $PERSIST_DIR"
  fi

  if [ ! -f "$PERSIST_DIR/config.json" ] && [ -f "$MODULE_CONFIG" ]; then
    cp -p "$MODULE_CONFIG" "$PERSIST_DIR/config.json" 2>/dev/null || {
      log "WARN: failed to copy default config.json to persist dir"
    }
    chmod 644 "$PERSIST_DIR/config.json" 2>/dev/null || true
    log "Seeded default config.json to persist dir"
  fi

  if [ ! -f "$PERSIST_DIR/start.rules.sh" ] && [ -f "$MODULE_RULES" ]; then
    cp -p "$MODULE_RULES" "$PERSIST_DIR/start.rules.sh" 2>/dev/null || {
      log "WARN: failed to copy default start.rules.sh to persist dir"
    }
    chmod 755 "$PERSIST_DIR/start.rules.sh" 2>/dev/null || true
    log "Seeded default start.rules.sh to persist dir"
  fi

  if [ -f "$MODULE_GHTOKEN" ] && [ ! -f "$PERSIST_DIR/github_token" ]; then
    cp -p "$MODULE_GHTOKEN" "$PERSIST_DIR/github_token" 2>/dev/null || {
      log "WARN: failed to copy github_token to persist dir"
    }
    chmod 600 "$PERSIST_DIR/github_token" 2>/dev/null || true
    log "Seeded github_token to persist dir"
  fi
}

# ensure sing-box binary exists (try update script if allowed)
ensure_singbox() {
  if [ ! -x "$SINGBOX_BIN" ]; then
    if [ "$ENABLE_AUTO_UPDATE" -eq 1 ] && [ -x "$UPDATE_SCRIPT" ]; then
      if [ -f "$PERSIST_DIR/github_token" ]; then
        GHTOKEN=$(cat "$PERSIST_DIR/github_token" 2>/dev/null | tr -d '\r\n' || true)
        if [ -n "$GHTOKEN" ]; then
          export GITHUB_TOKEN="$GHTOKEN"
          export GH_TOKEN="$GHTOKEN"
          log "Exported GITHUB_TOKEN from persist dir for update"
        fi
      fi
      log "sing-box missing: attempting download via update-singbox.sh"
      sh "$UPDATE_SCRIPT" >> "$LOGFILE" 2>&1 || log "update-singbox.sh failed"
    fi
  fi

  if [ ! -x "$SINGBOX_BIN" ]; then
    log "ERROR: sing-box binary not found at $SINGBOX_BIN"
    return 1
  fi
  return 0
}

cleanup() {
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      log "Stopping sing-box (pid $PID)"
      kill "$PID" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$PIDFILE" 2>/dev/null || true
  fi

  if [ -x "$PERSIST_DIR/start.rules.sh" ]; then
    log "Calling persisted start.rules.sh stop"
    sh "$PERSIST_DIR/start.rules.sh" stop >> "$LOGFILE" 2>&1 || true
  elif [ -x "$MODDIR/start.rules.sh" ]; then
    log "Calling module start.rules.sh stop"
    sh "$MODDIR/start.rules.sh" stop >> "$LOGFILE" 2>&1 || true
  else
    log "No start.rules.sh found; attempting generic cleanup"
    iptables -t mangle -D PREROUTING -j SINGBOX 2>/dev/null || true
    iptables -t mangle -F SINGBOX 2>/dev/null || true
    iptables -t mangle -X SINGBOX 2>/dev/null || true
    ip6tables -t mangle -D PREROUTING -j SINGBOX6 2>/dev/null || true
    ip6tables -t mangle -F SINGBOX6 2>/dev/null || true
    ip6tables -t mangle -X SINGBOX6 2>/dev/null || true
    ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null || true
    ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true
  fi

  # stop monitors if running
  if command -v pgrep >/dev/null 2>&1; then
    for p in monitor.sh refresh-ipset.sh; do
      for pid in $(pgrep -f "$p" 2>/dev/null || true); do
        kill "$pid" 2>/dev/null || true
      done
    done
  fi
}

start_singbox() {
  if [ ! -f "$CONFIG" ]; then
    log "ERROR: config.json not found at $CONFIG"
    return 1
  fi

  log "Starting sing-box with config $CONFIG"
  nohup "$SINGBOX_BIN" run -c "$CONFIG" >> "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 0.8
  if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "sing-box started (pid $(cat "$PIDFILE"))"
  else
    log "ERROR: sing-box failed to start; check $LOGFILE"
  fi
}

apply_rules() {
  if [ -x "$PERSIST_DIR/start.rules.sh" ]; then
    log "Using persisted rules script: $PERSIST_DIR/start.rules.sh"
    sh "$PERSIST_DIR/start.rules.sh" start >> "$LOGFILE" 2>&1 || {
      log "Persisted start.rules.sh failed; falling back to module start.rules.sh"
      if [ -x "$MODDIR/start.rules.sh" ]; then
        sh "$MODDIR/start.rules.sh" start >> "$LOGFILE" 2>&1 || {
          log "Module start.rules.sh failed"
          return 1
        }
      else
        log "No module start.rules.sh available"
        return 1
      fi
    }
  elif [ -x "$MODDIR/start.rules.sh" ]; then
    log "Using module rules script: $MODDIR/start.rules.sh"
    sh "$MODDIR/start.rules.sh" start >> "$LOGFILE" 2>&1 || {
      log "Module start.rules.sh failed"
      return 1
    }
  else
    log "No start.rules.sh found; aborting"
    return 1
  fi
  return 0
}

# Utility to read settings from persisted settings.conf
read_setting() {
  key="$1"
  f="$PERSIST_DIR/settings.conf"
  if [ ! -f "$f" ]; then
    return 1
  fi
  grep -oP "(?<=^${key}=).*" "$f" 2>/dev/null | tr -d '\r\n'
}

start_monitor_if_needed() {
  en=$(read_setting "ENABLE_MONITOR" || true)
  if [ "$en" = "1" ]; then
    if ! pgrep -f monitor.sh >/dev/null 2>&1; then
      if [ -x "$MODDIR/monitor.sh" ]; then
        log "Starting monitor.sh"
        nohup sh "$MODDIR/monitor.sh" >> "$LOGFILE" 2>&1 &
      else
        log "monitor.sh not found in module dir; skipping monitor start"
      fi
    else
      log "monitor.sh already running"
    fi
  else
    log "Monitor disabled by settings"
  fi
}

start_refresh_if_needed() {
  en=$(read_setting "ENABLE_REFRESH" || true)
  if [ "$en" = "1" ]; then
    if ! pgrep -f refresh-ipset.sh >/dev/null 2>&1; then
      if [ -x "$MODDIR/refresh-ipset.sh" ]; then
        log "Starting refresh-ipset.sh"
        nohup sh "$MODDIR/refresh-ipset.sh" >> "$LOGFILE" 2>&1 &
      else
        log "refresh-ipset.sh not found in module dir; skipping refresh start"
      fi
    else
      log "refresh-ipset.sh already running"
    fi
  else
    log "Refresh disabled by settings"
  fi
}

# Main
case "$1" in
  stop)
    log "Received stop"
    cleanup
    exit 0
    ;;
  *)
    log "Service start invoked"

    seed_persisted_defaults

    # prefer persisted config and rules if exist
    if [ -f "$PERSIST_DIR/config.json" ]; then
      CONFIG="$PERSIST_DIR/config.json"
    else
      CONFIG="$MODULE_CONFIG"
    fi

    if [ -x "$PERSIST_DIR/start.rules.sh" ]; then
      RULES_SCRIPT="$PERSIST_DIR/start.rules.sh"
    else
      RULES_SCRIPT="$MODULE_RULES"
    fi

    if ! ensure_singbox; then
      log "sing-box not available; aborting start"
      exit 0
    fi

    # apply iptables/ipset rules
    if ! apply_rules; then
      log "Failed to apply rules; aborting"
      exit 1
    fi

    # start sing-box
    start_singbox

    # start optional background helpers based on settings
    start_monitor_if_needed
    start_refresh_if_needed

    ;;
esac

exit 0