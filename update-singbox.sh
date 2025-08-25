#!/system/bin/sh
#
# update-singbox.sh - 改进版
# - 支持环境变量 SINGBOX_TAG（可设置为 release tag，如 v1.12.3）以固定版本
# - 优先从 persist 中读取 github_token（或环境变量）
# - 下载后做原子替换（先解压到临时目录，验证存在 sing-box，可选校验 --version）
# - 备份旧二进制（sing-box.bak）以便回滚
#
set -e

MODDIR=${MAGISK_MODULE_DIR:-/data/adb/modules/transparent-singbox}
PERSIST=${PERSIST_DIR:-/data/adb/transparent-singbox}
BIN="$MODDIR/sing-box"
TMPDIR="${MODDIR}/.tmp_singbox"
API_URL_BASE="https://api.github.com/repos/SagerNet/sing-box/releases"
LOGFILE="${PERSIST}/transparent-singbox.log"

log() {
  if [ -n "$LOGFILE" ]; then
    echo "[$(date +'%F %T')] $*" >> "$LOGFILE"
  else
    echo "[$(date +'%F %T')] $*"
  fi
}

mkdir -p "$TMPDIR" "$PERSIST" 2>/dev/null || true

# read token: persist dir > env vars
GHTOKEN=""
if [ -f "$PERSIST/github_token" ]; then
  GHTOKEN=$(cat "$PERSIST/github_token" | tr -d '\r\n' || true)
fi
if [ -z "$GHTOKEN" ] && [ -n "$GITHUB_TOKEN" ]; then
  GHTOKEN="$GITHUB_TOKEN"
fi
if [ -z "$GHTOKEN" ] && [ -n "$GH_TOKEN" ]; then
  GHTOKEN="$GH_TOKEN"
fi

AUTH_HDR=""
if [ -n "$GHTOKEN" ]; then
  AUTH_HDR="-H Authorization: token $GHTOKEN"
  log "Using GitHub token from persist or env"
else
  log "No GitHub token provided; API requests may be rate limited"
fi

# optional pinned tag (e.g. v1.12.3)
SINGBOX_TAG="${SINGBOX_TAG:-}"
if [ -n "$SINGBOX_TAG" ]; then
  RELEASE_API="$API_URL_BASE/tags/$SINGBOX_TAG"
else
  RELEASE_API="$API_URL_BASE/latest"
fi

log "Querying release metadata: $RELEASE_API"
RELEASE_JSON=$(curl -sSL -H "Accept: application/vnd.github.v3+json" $AUTH_HDR "$RELEASE_API") || {
  log "ERROR: failed to fetch release metadata"
  rm -rf "$TMPDIR"
  exit 1
}

# helper: pick asset URL preferring android & arm64
pick_asset() {
  printf '%s' "$RELEASE_JSON" \
    | grep -oP '"browser_download_url":\s*"\K[^"]+' \
    | grep -iE "android.*(arm64|aarch64)" \
    | head -n1
  if [ $? -ne 0 ] || [ -z "$(printf '%s' "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]+' | grep -iE "android.*(arm64|aarch64)" | head -n1)" ]; then
    printf '%s' "$RELEASE_JSON" \
      | grep -oP '"browser_download_url":\s*"\K[^"]+' \
      | grep -iE "linux.*(aarch64|arm64|armv8|arm64)" \
      | head -n1
  fi
}

ASSET_URL=$(pick_asset)
if [ -z "$ASSET_URL" ]; then
  # last-resort: any asset with sing-box
  ASSET_URL=$(printf '%s' "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]+' | grep -i "sing-box" | head -n1)
fi

if [ -z "$ASSET_URL" ]; then
  log "ERROR: no suitable asset found in release"
  rm -rf "$TMPDIR"
  exit 1
fi

log "Selected asset: $ASSET_URL"
FNAME="$TMPDIR/asset"
curl -L -o "$FNAME" "$ASSET_URL" || {
  log "ERROR: failed to download asset"
  rm -rf "$TMPDIR"
  exit 1
}

# extract binary
BPATH=""
file "$FNAME" 2>/dev/null | grep -i zip >/dev/null 2>&1 && IS_ZIP=1 || IS_ZIP=0
file "$FNAME" 2>/dev/null | grep -i gzip >/dev/null 2>&1 && IS_TAR=1 || IS_TAR=0

if [ "$IS_TAR" -eq 1 ]; then
  tar -xzf "$FNAME" -C "$TMPDIR" || true
  BPATH=$(find "$TMPDIR" -type f -iname 'sing-box' | head -n1 || true)
elif [ "$IS_ZIP" -eq 1 ]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$FNAME" -d "$TMPDIR" >/dev/null 2>&1 || true
  elif command -v busybox >/dev/null 2>&1 && busybox unzip >/dev/null 2>&1; then
    busybox unzip -o "$FNAME" -d "$TMPDIR" >/dev/null 2>&1 || true
  fi
  BPATH=$(find "$TMPDIR" -type f -iname 'sing-box' | head -n1 || true)
else
  # maybe raw binary
  mv "$FNAME" "$TMPDIR/sing-box" || true
  BPATH="$TMPDIR/sing-box"
fi

if [ -z "$BPATH" ]; then
  # relaxed search
  BPATH=$(find "$TMPDIR" -type f -iname '*sing-box*' | head -n1 || true)
fi

if [ -z "$BPATH" ]; then
  log "ERROR: could not find sing-box binary inside asset"
  rm -rf "$TMPDIR"
  exit 1
fi

# verify binary is executable and reports version
chmod 755 "$BPATH" || true
VER=$("$BPATH" -v 2>/dev/null || "$BPATH" --version 2>/dev/null || true)
if [ -z "$VER" ]; then
  log "WARN: downloaded binary did not report version; will still install but check manually"
else
  log "Downloaded sing-box version info: $VER"
fi

# atomic backup & replace
if [ -f "$BIN" ]; then
  cp -p "$BIN" "${BIN}.bak" 2>/dev/null || true
  log "Backed up existing binary to ${BIN}.bak"
fi

# move into place atomically
mv "$BPATH" "$BIN" 2>/dev/null || cp -p "$BPATH" "$BIN"
chmod 755 "$BIN" 2>/dev/null || true
log "Installed sing-box to $BIN (atomic)"

# cleanup
rm -rf "$TMPDIR"
log "update-singbox.sh: success"
exit 0