#!/system/bin/sh
# =====================================================================
# ⬇️ update-bin.sh - 核心程序自动更新脚本
# ---------------------------------------------------------------------
# 自动下载并更新代理核心程序，支持多架构和自定义参数
# =====================================================================

set -e
trap '[ $? -ne 0 ] && abort_safe "⛔ 脚本执行失败: $?"' EXIT

BIN_REPO="$1"       # GitHub 仓库名，如 user/project
RELEASE_TAG="$2"    # 版本标签，如 v1.0.0 或 latest

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-5}
TMPDIR=$(mktemp -d "${PERSIST_DIR}/.tmp")
API_URL_BASE="https://api.github.com/repos/${BIN_REPO}/releases"

log_safe "❤️=== [update-bin] ===❤️"
log_safe "🚀 开始更新代理核心..."

# 架构检测
case $(getprop ro.product.cpu.abi) in
  arm64-v8a) ARCHITECTURE="android-arm64" ;;
  armeabi-v7a) ARCHITECTURE="android-armv7" ;;
  x86_64) ARCHITECTURE="android-amd64" ;;
  x86) ARCHITECTURE="android-386" ;;
  *) ARCHITECTURE="" ; log_safe "🤔 未知CPU架构，使用通用匹配" ;;
esac
log_safe "💻 检测到 CPU 架构: ${ARCHITECTURE:-未知}"

# 带重试的 curl
retry_curl() {
  url="$1"; output_path="$2"; count=0
  while [ "$count" -lt "$MAX_RETRIES" ]; do
    if curl -sSL -H "Accept: application/vnd.github.v3+json" ${AUTH_HDR:+-H "$AUTH_HDR"} \
      "$url" -o "$output_path" && [ -s "$output_path" ]; then
      return 0
    fi
    count=$((count + 1))
    [ "$count" -ge "$MAX_RETRIES" ] && { log_safe "❌ 下载失败: $url"; return 1; }
    log_safe "⏳ 下载失败，$RETRY_DELAY 秒后重试 ($count/$MAX_RETRIES)..."
    sleep "$RETRY_DELAY"
  done
}

# GitHub Token
if [ -f "$PERSIST_DIR/github_token" ]; then
  GHTOKEN=$(tr -d '\r\n' < "$PERSIST_DIR/github_token" 2>/dev/null)
  [ -n "$GHTOKEN" ] && AUTH_HDR="Authorization: token $GHTOKEN"
fi

# API URL
if [ -n "$RELEASE_TAG" ] && [ "$RELEASE_TAG" != "latest" ]; then
  RELEASE_API="$API_URL_BASE/tags/$RELEASE_TAG"
  log_safe "🎯 下载指定版本: $RELEASE_TAG"
else
  RELEASE_API="$API_URL_BASE/latest"
  log_safe "☁️ 下载最新版本"
fi

# 获取 Release 元数据
log_safe "📡 查询 Release 元数据..."
retry_curl "$RELEASE_API" "$TMPDIR/release.json" || { rm -rf "$TMPDIR"; exit 1; }

# 解析下载链接
log_safe "🔗 解析 $ARCHITECTURE 架构下载链接..."
ALL_URLS=$(awk -F'"' '/"browser_download_url"/ {print $4}' "$TMPDIR/release.json")
ASSET_URL=$(echo "$ALL_URLS" | awk -v arch="$ARCHITECTURE" 'tolower($0) ~ tolower(arch) { print; exit }')
[ -z "$ASSET_URL" ] && ASSET_URL=$(echo "$ALL_URLS" | awk 'tolower($0) ~ /linux/ { print; exit }')
[ -z "$ASSET_URL" ] && { log_safe "❌ 未找到合适的资源文件"; rm -rf "$TMPDIR"; exit 1; }

# 下载资源
log_safe "✅ 确定下载资源: $ASSET_URL"
FNAME="$TMPDIR/asset"
log_safe "📥 下载资源文件..."
retry_curl "$ASSET_URL" "$FNAME" || { rm -rf "$TMPDIR"; exit 1; }

# 解压或移动
log_safe "📦 下载完成，分析文件类型..."
BPATH=""
if file "$FNAME" | grep -qi 'gzip compressed data'; then
  log_safe "🗜️ tar.gz 压缩包，解压中..."
  tar -xzf "$FNAME" -C "$TMPDIR"
  BPATH=$(find "$TMPDIR" -type f -iname "$BIN_NAME" | head -n 1)
elif file "$FNAME" | grep -qi 'Zip archive data'; then
  log_safe "🗜️ zip 压缩包，解压中..."
  unzip -o "$FNAME" -d "$TMPDIR" >/dev/null 2>&1
  BPATH=$(find "$TMPDIR" -type f -iname "$BIN_NAME" | head -n 1)
else
  log_safe "🔨 裸二进制文件，移动中..."
  mv "$FNAME" "$TMPDIR/$BIN_NAME"
  BPATH="$TMPDIR/$BIN_NAME"
fi

[ -z "$BPATH" ] && { log_safe "❌ 未找到 $BIN_NAME"; rm -rf "$TMPDIR"; exit 1; }

# 验证与安装
chmod 755 "$BPATH"
VER=$("$BPATH" -v 2>/dev/null || "$BPATH" version 2>/dev/null || true)
[ -n "$VER" ] && log_safe "ℹ️ 下载 $BIN_NAME 版本信息: $VER"

if [ -f "$BIN_PATH" ]; then
  cp -p "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true
  log_safe "📝 已备份当前二进制到 ${BIN_PATH}.bak"
fi

mv "$BPATH" "$BIN_PATH"
chmod 755 "$BIN_PATH"
log_safe "✅ 安装 $BIN_NAME 到 $BIN_PATH 成功"

# 清理
rm -rf "$TMPDIR"
log_safe "✨ 代理核心更新成功"
exit 0