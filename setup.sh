#!/system/bin/sh
#
# setup.sh - interactive post-install wizard
# - Run via adb shell or terminal emulator after installation:
#     su
#     sh /data/adb/modules/transparent-singbox/setup.sh
#
PERSIST_DIR="/data/adb/transparent-singbox"
SERVICE_SH="/data/adb/modules/transparent-singbox/service.sh"

read_choice() {
  prompt="$1"
  default="$2"
  echo
  echo "$prompt"
  echo "  1) Yes"
  echo "  2) No"
  printf "Select [1/2] (default %s): " "$default"
  read opt
  if [ -z "$opt" ]; then
    opt="$default"
  fi
  case "$opt" in
    1) return 0 ;;
    2) return 1 ;;
    *) return 1 ;;
  esac
}

ensure_persist() {
  if [ ! -d "$PERSIST_DIR" ]; then
    mkdir -p "$PERSIST_DIR" 2>/dev/null || {
      echo "ERROR: cannot create $PERSIST_DIR"
      exit 1
    }
  fi
}

write_setting() {
  k="$1"; v="$2"
  f="$PERSIST_DIR/settings.conf"
  if [ ! -f "$f" ]; then
    echo "# settings" > "$f" || true
  fi
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    sed -i "s/^${k}=.*/${k}=${v}/" "$f" 2>/dev/null || true
  else
    echo "${k}=${v}" >> "$f" || true
  fi
  chmod 600 "$f" 2>/dev/null || true
}

ensure_persist

echo "Transparent-singbox setup wizard"
echo "Settings will be written to: $PERSIST_DIR/settings.conf"

if read_choice "Enable monitor (auto-restart sing-box on crash)?" 1; then
  write_setting "ENABLE_MONITOR" "1"
  echo "Monitor enabled"
else
  write_setting "ENABLE_MONITOR" "0"
  echo "Monitor disabled"
fi

if read_choice "Enable periodic ipset refresh (refresh-ipset.sh)?" 2; then
  write_setting "ENABLE_REFRESH" "1"
  echo "Refresh enabled"
else
  write_setting "ENABLE_REFRESH" "0"
  echo "Refresh disabled"
fi

echo
printf "Do you want to restart the module now to apply choices? [y/N]: "
read go
if echo "$go" | grep -qiE '^(y|yes)$'; then
  if [ -x "$SERVICE_SH" ]; then
    sh "$SERVICE_SH" stop >/dev/null 2>&1 || true
    sh "$SERVICE_SH" >/dev/null 2>&1 || true
    echo "Service restarted"
  else
    echo "Service script not found at $SERVICE_SH"
  fi
fi

echo "Setup complete. You can edit $PERSIST_DIR/settings.conf manually if needed."
exit 0