#!/system/bin/sh
#
# ============================================================================== 
# ⬇️ update-bin.sh - 核心程序自动更新脚本
# ============================================================================== 
#
# 自动下载并更新代理核心程序, 支持多架构和自定义参数。
# - 支持 GitHub Releases 自动拉取最新版
# - 自动检测 CPU 架构与文件类型
# - 断点续传与重试机制, 保障下载可靠
#
# ==============================================================================
set -e

BIN_REPO="$1"
RELEASE_TAG="$2"

MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

# --- 重试机制定义 ---
MAX_RETRIES=3
RETRY_DELAY=5

# --- 路径定义 ---
TMPDIR="${MODDIR}/.tmp"
API_URL_BASE="https://api.github.com/repos/${BIN_REPO}/releases"

log "❤️=== [update-bin] ===❤️"
log "🚀 开始更新代理核心..."

# --- 架构检测 ---
case $(getprop ro.product.cpu.abi) in
  arm64-v8a)
    ARCHITECTURE="android-arm64"
    ;;
  armeabi-v7a)
    ARCHITECTURE="android-armv7"
    ;;
  x86_64)
    ARCHITECTURE="android-amd64"
    ;;
  x86)
    ARCHITECTURE="android-386"
    ;;
  *)
    log "🤔 未知CPU架构, 使用通用名称匹配"
    ARCHITECTURE=""
    ;;
esac
log "💻 检测到 CPU 架构: $ARCHITECTURE"

# --- 函数定义 ---

# 函数: retry_curl
# 作用: 带重试机制的 curl 下载
retry_curl() {
  url="$1"
  output_path="$2"
  count=0
  while [ "$count" -lt "$MAX_RETRIES" ]; do
    if curl -sSL -H "Accept: application/vnd.github.v3+json" -H "$AUTH_HDR" "$url" -o "$output_path" && [ -s "$output_path" ]; then
      return 0
    fi
    count=$((count + 1))
    if [ "$count" -ge "$MAX_RETRIES" ]; then
      log "❌ 错误: 下载失败 (重试 $MAX_RETRIES 次后): $url"
      return 1
    fi
    log "⏳ 下载失败, $RETRY_DELAY 秒后进行第 $count 次重试..."
    sleep "$RETRY_DELAY"
  done
}

# --- 主逻辑 ---

mkdir -p "$TMPDIR" 2>/dev/null || true

# --- GitHub Token 处理 ---
GHTOKEN=""
if [ -f "$PERSIST_DIR/github_token" ]; then
  GHTOKEN=$(tr -d '\r\n' < "$PERSIST_DIR/github_token" 2>/dev/null)
  [ -n "$GHTOKEN" ] && log "🎯 下载指定版本: $RELEASE_TAG"
fi
AUTH_HDR=""
if [ -n "$GHTOKEN" ]; then
  AUTH_HDR="Authorization: token $GHTOKEN"
fi

# --- API URL 构建 ---
if [ -n "$RELEASE_TAG" ] && [ "$RELEASE_TAG" != "latest" ]; then
  RELEASE_API="$API_URL_BASE/tags/$RELEASE_TAG"
  log "🎯 下载指定版本: $RELEASE_TAG"
else
  RELEASE_API="$API_URL_BASE/latest"
  log "☁️ 下载最新版本"
fi

# --- 获取 Release 元数据 ---
log "📡 查询 Release 元数据..."
if ! retry_curl "$RELEASE_API" "$TMPDIR/release.json"; then
  rm -rf "$TMPDIR"
  exit 1
fi

# --- 解析资源下载链接 ---
log "🔗 解析 $ARCHITECTURE 架构下载链接..."
ALL_URLS=$(awk -F'"' '/"browser_download_url"/ {print $4}' "$TMPDIR/release.json")
ASSET_URL=$(echo "$ALL_URLS" | awk -v arch="$ARCHITECTURE" 'tolower($0) ~ tolower(arch) { print; exit }')

if [ -z "$ASSET_URL" ]; then
  log "🤔 未找到 $ARCHITECTURE 版本, 尝试查找通用 Linux 版本..."
  ASSET_URL=$(echo "$ALL_URLS" | awk 'tolower($0) ~ /linux/ { print; exit }')
fi

if [ -z "$ASSET_URL" ]; then
  log "❌ 错误: 在 Release 元数据中找不到合适的资源文件。"
  rm -rf "$TMPDIR"
  exit 1
fi

# --- 下载并解压资源 ---
log "✅ 确定下载资源: $ASSET_URL"
FNAME="$TMPDIR/asset"
log "📥 下载资源文件..."
if ! retry_curl "$ASSET_URL" "$FNAME"; then
  rm -rf "$TMPDIR"
  exit 1
fi

log "📦 下载完成, 分析文件类型..."
BPATH=""
file "$FNAME" 2>/dev/null | grep -i 'gzip compressed data' >/dev/null 2>&1 && IS_TAR=1 || IS_TAR=0
file "$FNAME" 2>/dev/null | grep -i 'Zip archive data' >/dev/null 2>&1 && IS_ZIP=1 || IS_ZIP=0

if [ "$IS_TAR" -eq 1 ]; then
  log "🗜️ tar.gz 压缩包, 解压中..."
  tar -xzf "$FNAME" -C "$TMPDIR"
  BPATH=$(find "$TMPDIR" -type f -iname "$BIN_NAME" | head -n 1)
elif [ "$IS_ZIP" -eq 1 ]; then
  log "🗜️ zip 压缩包, 解压中..."
  unzip -o "$FNAME" -d "$TMPDIR" >/dev/null 2>&1
  BPATH=$(find "$TMPDIR" -type f -iname "$BIN_NAME" | head -n 1)
else
  log "🔨 裸二进制文件, 移动中..."
  mv "$FNAME" "$TMPDIR/$BIN_NAME"
  BPATH="$TMPDIR/$BIN_NAME"
fi

if [ -z "$BPATH" ]; then
  log "❌ 错误: 在下载的资源中找不到 '$BIN_NAME' 二进制文件。"
  rm -rf "$TMPDIR"
  exit 1
fi

log "🔍 临时目录找到 $BIN_NAME: $BPATH"

# --- 验证与安装 ---
chmod 755 "$BPATH"
VER=$("$BPATH" -v 2>/dev/null || "$BPATH" version 2>/dev/null || true)
if [ -n "$VER" ]; then
  log "ℹ️ 下载 $BIN_NAME 版本信息: $VER"
fi

if [ -f "$BIN_PATH" ]; then
  cp -p "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true
  log "📝 已将当前二进制文件备份到 ${BIN_PATH}.bak"
fi

mv "$BPATH" "$BIN_PATH"
chmod 755 "$BIN_PATH"
log "✅ 安装 $BIN_NAME 到 $BIN_PATH 成功"

# --- 清理 ---
rm -rf "$TMPDIR"

log "✨ 代理核心更新成功"
exit 0