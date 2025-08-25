#!/system/bin/sh
#
# install.sh
# Invoked by Magisk installer (best-effort).
# - Attempt to gracefully stop old instance
# - Migrate user-customizable files to persistent dir: /data/adb/transparent-singbox
# - Support "pre-install marker" method: create files on /sdcard/transparent-singbox/
#   (enable_monitor, enable_refresh, settings.conf) to have installer enable features
#
set -e

MODID="transparent-singbox"
OLDMODDIR="/data/adb/modules/${MODID}"
PERSIST_DIR="/data/adb/transparent-singbox"
LOGFILE="${PERSIST_DIR}/transparent-singbox.log"
TMPLOG="/data/local/tmp/${MODID}-install.log"
SDCARD_MARK_DIR="/sdcard/transparent-singbox"

log() {
  if [ -w "$LOGFILE" ]; then
    echo "[$(date +'%F %T')] $*" >> "$LOGFILE"
  else
    echo "[$(date +'%F %T')] $*" >> "$TMPLOG"
  fi
}

log "install.sh: invoked by Magisk installer"

# 1) Stop existing instance gracefully (best-effort)
if [ -d "$OLDMODDIR" ]; then
  log "Found existing module dir: $OLDMODDIR - attempting graceful stop"

  if [ -x "$OLDMODDIR/service.sh" ]; then
    sh "$OLDMODDIR/service.sh" stop >> "$TMPLOG" 2>&1 || log "Existing service.sh stop returned non-zero"
  fi

  if [ -x "$OLDMODDIR/start.rules.sh" ]; then
    sh "$OLDMODDIR/start.rules.sh" stop >> "$TMPLOG" 2>&1 || log "Existing start.rules.sh stop returned non-zero"
  fi

  if [ -f "$OLDMODDIR/singbox.pid" ]; then
    PID=$(cat "$OLDMODDIR/singbox.pid" 2>/dev/null || true)
    if [ -n "$PID" ]; then
      if kill -0 "$PID" 2>/dev/null; then
        log "Killing sing-box pid $PID"
        kill "$PID" 2>/dev/null || true
        sleep 1
      else
        log "PID $PID not running"
      fi
    fi
    rm -f "$OLDMODDIR/singbox.pid" 2>/dev/null || true
  fi

  # best-effort pkill for sing-box processes that appear to originate from old module
  if command -v pgrep >/dev/null 2>&1 && command -v readlink >/dev/null 2>&1; then
    for pid in $(pgrep -f sing-box 2>/dev/null || true); do
      exe=$(readlink -f /proc/"$pid"/exe 2>/dev/null || true)
      case "$exe" in
        "$OLDMODDIR"/*|*"$MODID"*)
          log "Killing sing-box (pid $pid, exe $exe)"
          kill "$pid" 2>/dev/null || true
          ;;
        *)
          ;;
      esac
    done
  fi

  sleep 1
else
  log "No existing module dir found at $OLDMODDIR"
fi

# 2) Ensure persist dir exists
if [ ! -d "$PERSIST_DIR" ]; then
  mkdir -p "$PERSIST_DIR" 2>/dev/null || {
    log "ERROR: failed to create persist dir $PERSIST_DIR"
  }
  chmod 755 "$PERSIST_DIR" 2>/dev/null || true
  log "Created persist dir $PERSIST_DIR"
fi

# 3) Migrate common user files from old module to persist (if present and not already present)
if [ -d "$OLDMODDIR" ]; then
  for f in config.json start.rules.sh github_token; do
    if [ -f "$OLDMODDIR/$f" ] && [ ! -f "$PERSIST_DIR/$f" ]; then
      cp -p "$OLDMODDIR/$f" "$PERSIST_DIR/" 2>/dev/null || log "WARN: failed to copy $OLDMODDIR/$f to $PERSIST_DIR/"
      chmod 600 "$PERSIST_DIR/$f" 2>/dev/null || true
      log "Migrated $f from old module to persist dir"
    fi
  done
fi

# 4) Copy packaged github_token if present in new package
THIS_MODULE_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd || true)"
if [ -f "${THIS_MODULE_DIR}/github_token" ] && [ ! -f "$PERSIST_DIR/github_token" ]; then
  cp -p "${THIS_MODULE_DIR}/github_token" "$PERSIST_DIR/" 2>/dev/null || log "WARN: failed to copy packaged github_token"
  chmod 600 "$PERSIST_DIR/github_token" 2>/dev/null || true
  log "Copied packaged github_token to persist dir"
fi

# 5) Pre-install markers on /sdcard: if user created /sdcard/transparent-singbox/enable_monitor or enable_refresh
SETTINGS_FILE="$PERSIST_DIR/settings.conf"
# ensure settings file exists
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "# Transparent-singbox settings (key=value)" > "$SETTINGS_FILE" 2>/dev/null || true
  chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
fi

mark() {
  KEY="$1"; VAL="$2"
  if grep -q "^${KEY}=" "$SETTINGS_FILE" 2>/dev/null; then
    sed -i "s/^${KEY}=.*/${KEY}=${VAL}/" "$SETTINGS_FILE" 2>/dev/null || true
  else
    echo "${KEY}=${VAL}" >> "$SETTINGS_FILE" 2>/dev/null || true
  fi
  log "Set ${KEY}=${VAL} in $SETTINGS_FILE"
}

if [ -d "$SDCARD_MARK_DIR" ]; then
  if [ -f "$SDCARD_MARK_DIR/enable_monitor" ]; then
    mark "ENABLE_MONITOR" "1"
  fi
  if [ -f "$SDCARD_MARK_DIR/enable_refresh" ]; then
    mark "ENABLE_REFRESH" "1"
  fi
  if [ -f "$SDCARD_MARK_DIR/settings.conf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '#'*) continue ;;
        *'='*)
          k=$(printf '%s' "$line" | cut -d= -f1)
          v=$(printf '%s' "$line" | cut -d= -f2-)
          if ! grep -q "^${k}=" "$SETTINGS_FILE" 2>/dev/null; then
            echo "${k}=${v}" >> "$SETTINGS_FILE" 2>/dev/null || true
            log "Copied preinstall key ${k} from sdcard settings"
          fi
          ;;
      esac
    done < "$SDCARD_MARK_DIR/settings.conf"
  fi
fi

log "install.sh: finished"
exit 0