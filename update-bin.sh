#!/system/bin/sh
#
# ==============================================================================
# update-bin.sh - 自动更新代理核心的脚本
# ==============================================================================
#
# ## 功能:
# - 支持通过环境变量 `SINGBOX_TAG` 指定版本, 否则拉取最新版
# - 支持从持久化目录或环境变量读取 GitHub Token, 避免 API 限流
# - 自动检测 CPU 架构 (arm64-v8a) 并下载对应的 release
# - 支持处理 zip/tar.gz 压缩包或裸二进制文件
# - 通过先下载到临时文件再移动的方式实现原子化替换, 保证更新过程的稳定性
# - 在替换前备份旧的核心文件
#
# ==============================================================================

# 当任何命令返回非零退出码时立即退出
set -e

# --- 初始化与变量定义 ---
MODDIR=${0%/*}
. "$MODDIR/common.sh"

# --- 重试机制定义 ---
# MAX_RETRIES: 最大重试次数
MAX_RETRIES=3
# RETRY_DELAY: 每次重试之间的等待时间 (秒)
RETRY_DELAY=5

# --- 路径定义 ---
# TMPDIR: 用于存放下载和解压的临时文件的目录
TMPDIR="${MODDIR}/.tmp"
API_URL_BASE="https://api.github.com/repos/SagerNet/sing-box/releases"

log "[update-bin.sh]: 开始更新..."

# 创建临时目录, `2>/dev/null || true` 忽略可能出现的“目录已存在”的错误
mkdir -p "$TMPDIR" 2>/dev/null || true

# --- GitHub Token 处理 ---

# 从持久化目录或环境变量中读取 GitHub Token
# 优先级: $PERSIST_DIR/github_token > $GITHUB_TOKEN > $GH_TOKEN
GHTOKEN=""
if [ -f "$PERSIST_DIR/github_token" ]; then
  # 从文件中读取 token, tr -d 删除可能存在的换行符
  GHTOKEN=$(tr -d '\r\n' < "$PERSIST_DIR/github_token" 2>/dev/null)
  [ -n "$GHTOKEN" ] && log "检测到 GitHub Token"
fi
if [ -z "$GHTOKEN" ] && [ -n "$GITHUB_TOKEN" ]; then
  GHTOKEN="$GITHUB_TOKEN"
  log "检测到环境变量 GITHUB_TOKEN"
fi
if [ -z "$GHTOKEN" ] && [ -n "$GH_TOKEN" ]; then
  GHTOKEN="$GH_TOKEN"
  log "检测到环境变量 GH_TOKEN"
fi

# 根据是否存在 Token 构建 cURL 的 Authorization header
AUTH_HDR=""
if [ -n "$GHTOKEN" ]; then
  AUTH_HDR="Authorization: token $GHTOKEN"
  log "将使用 GitHub Token 进行 API 请求"
else
  log "未提供 GitHub Token, API 请求可能会受到速率限制"
fi

# --- API URL 构建 ---

# 检查是否通过环境变量 SINGBOX_TAG 指定了特定版本
SINGBOX_TAG="${SINGBOX_TAG:-}"
if [ -n "$SINGBOX_TAG" ]; then
  # 如果指定了 tag, 构建指向特定 tag 的 API URL
  RELEASE_API="$API_URL_BASE/tags/$SINGBOX_TAG"
  log "准备下载指定版本: $SINGBOX_TAG"
else
  # 否则, 获取最新 release
  RELEASE_API="$API_URL_BASE/latest"
  log "准备下载最新版本"
fi

# --- 获取 Release 元数据 ---

log "正在查询 Release 元数据..."
# 使用 cURL 获取 release 的 JSON 数据
# -sSL: 静默模式, 显示错误, 并跟随重定向
# -H "Accept...": 指定 API 版本
# -H "$AUTH_HDR": 传入认证信息
count=0
while [ "$count" -lt "$MAX_RETRIES" ]; do
  # 使用 curl 获取 release 的 JSON 数据, 并检查命令是否成功以及输出是否非空
  if curl -sSL -H "Accept: application/vnd.github.v3+json" -H "$AUTH_HDR" "$RELEASE_API" > "$TMPDIR/release.json" && [ -s "$TMPDIR/release.json" ]; then
    RELEASE_JSON=$(cat "$TMPDIR/release.json")
    break
  fi

  count=$((count + 1))
  if [ "$count" -ge "$MAX_RETRIES" ]; then
    log "错误: 获取 Release 元数据失败 (重试 $MAX_RETRIES 次后)"
    rm -rf "$TMPDIR"
    exit 1
  fi
  log "获取元数据失败, $RETRY_DELAY 秒后进行第 $count 次重试..."
  sleep "$RETRY_DELAY"
done

# --- 解析资源下载链接 (Asset URL) ---

# 使用 grep 和正则表达式从 JSON 响应中提取下载链接
# 优先级: android-arm64 > linux-arm64 > 任何包含 $BIN_NAME 的文件
log "正在解析适用于 arm64 架构的下载链接..."
ASSET_URL=$(printf '%s' "$RELEASE_JSON" \
  | grep -oP '"browser_download_url":\s*"\K[^"]+' \
  | grep -iE "android.*(arm64|aarch64)" \
  | head -n1)

if [ -z "$ASSET_URL" ]; then
  log "未找到 Android arm64 版本, 尝试查找 Linux arm64 版本..."
  ASSET_URL=$(printf '%s' "$RELEASE_JSON" \
    | grep -oP '"browser_download_url":\s*"\K[^"]+' \
    | grep -iE "linux.*(aarch64|arm64|armv8)" \
    | head -n1)
fi

if [ -z "$ASSET_URL" ]; then
  log "未找到 arm64 架构的特定版本, 尝试查找通用文件名..."
  ASSET_URL=$(printf '%s' "$RELEASE_JSON" \
    | grep -oP '"browser_download_url":\s*"\K[^"]+' \
    | grep -i "$BIN_NAME" \
    | head -n1)
fi

if [ -z "$ASSET_URL" ]; then
  log "错误: 在 Release 元数据中找不到合适的资源文件"
  rm -rf "$TMPDIR"
  exit 1
fi

# --- 下载并解压资源 ---

log "已确定下载资源: $ASSET_URL"
FNAME="$TMPDIR/asset"
log "正在下载资源文件..."
count=0
while [ "$count" -lt "$MAX_RETRIES" ]; do
  # 下载文件, 并检查 curl 是否成功以及下载的文件不为空
  if curl -L -o "$FNAME" "$ASSET_URL" && [ -s "$FNAME" ]; then
    break
  fi

  count=$((count + 1))
  if [ "$count" -ge "$MAX_RETRIES" ]; then
    log "错误: 下载资源文件失败 (重试 $MAX_RETRIES 次后)"
    rm -rf "$TMPDIR"
    exit 1
  fi
  log "下载资源文件失败, $RETRY_DELAY 秒后进行第 $count 次重试..."
  sleep "$RETRY_DELAY"
done

log "下载完成, 正在分析文件类型..."

BPATH="" # 用于存储最终二进制文件的路径
# 使用 file 命令和 grep 判断文件类型
file "$FNAME" 2>/dev/null | grep -i zip >/dev/null 2>&1 && IS_ZIP=1 || IS_ZIP=0
file "$FNAME" 2>/dev/null | grep -i gzip >/dev/null 2>&1 && IS_TAR=1 || IS_TAR=0

if [ "$IS_TAR" -eq 1 ]; then
  log "文件为 tar.gz 压缩包, 正在解压..."
  tar -xzf "$FNAME" -C "$TMPDIR" || true
  BPATH=$(find "$TMPDIR" -type f -iname "$BIN_NAME" | head -n1 || true)
elif [ "$IS_ZIP" -eq 1 ]; then
  log "文件为 zip 压缩包, 正在解压..."
  # 优先使用 unzip, 其次尝试 busybox 内置的 unzip
  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$FNAME" -d "$TMPDIR" >/dev/null 2>&1 || true
  elif command -v busybox >/dev/null 2>&1 && busybox unzip --help >/dev/null 2>&1; then
    busybox unzip -o "$FNAME" -d "$TMPDIR" >/dev/null 2>&1 || true
  else
    log "错误: 找不到 unzip 命令来解压文件"
  fi
  BPATH=$(find "$TMPDIR" -type f -iname "$BIN_NAME" | head -n1 || true)
else
  log "文件为裸二进制文件, 正在移动..."
  # 如果不是压缩包, 假定它就是二进制文件本身
  mv "$FNAME" "$TMPDIR/$BIN_NAME" || true
  BPATH="$TMPDIR/$BIN_NAME"
fi

# 如果在标准路径下没找到, 做一次模糊查找
if [ -z "$BPATH" ]; then
  BPATH=$(find "$TMPDIR" -type f -iname "*$BIN_NAME*" | head -n1 || true)
fi

if [ -z "$BPATH" ]; then
  log "错误: 在下载的资源中找不到 $BIN_NAME 二进制文件"
  rm -rf "$TMPDIR"
  exit 1
fi

log "已在临时目录中找到 $BIN_NAME: $BPATH"

# --- 验证与安装 ---

# 赋予执行权限并获取版本号
chmod 755 "$BPATH" || true
VER=$("$BPATH" -v 2>/dev/null || "$BPATH" --version 2>/dev/null || true)
if [ -n "$VER" ]; then
  log "下载的 $BIN_NAME 版本信息: $VER"
fi

# 备份旧的二进制文件 (如果存在)
if [ -f "$BIN_PATH" ]; then
  # 使用 cp -p 保留权限和时间戳
  cp -p "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true
  log "已将当前二进制文件备份到 ${BIN_PATH}.bak"
fi

# 原子化替换: 使用 mv (移动) 来替换旧文件, 这是原子操作
# 如果 mv 失败 (例如跨文件系统), 则回退到 cp (复制)
mv "$BPATH" "$BIN_PATH" 2>/dev/null || cp -p "$BPATH" "$BIN_PATH"
chmod 755 "$BIN_PATH" 2>/dev/null || true
log "成功安装 $BIN_NAME 到 $BIN_PATH"

# --- 清理 ---

rm -rf "$TMPDIR"
log "清理临时文件完毕"
log "[update-bin.sh]: 更新成功"
exit 0