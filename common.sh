#!/system/bin/sh
#
# ==============================================================================
# common.sh - 模块通用核心脚本
# ==============================================================================
#
# ## 特性:
# - 定义了整个模块共享的变量和辅助函数 (helper functions)
#
# ==============================================================================

# --- 核心路径与模块标识符 ---

# --- 工作目录 ---
MODDIR=${MODDIR:-${0%/*}}
MODID=${MODID:-$(basename "$MODDIR")}

# --- 数据持久化目录 ---
PERSIST_DIR=${PERSIST_DIR:-"/data/adb/$MODID"}

# --- 文件与程序默认路径 ---
PROP=${PROP:-"$MODDIR/module.prop"}                        # 模块信息
SERVICE=${SERVICE:-"$MODDIR/service.sh"}                   # 主服务脚本路径
START_RULES=${START_RULES:-"$MODDIR/start.rules.sh"}       # iptables 规则脚本路径
FLAG=${FLAG:-"$MODDIR/service_enabled"}                    # 服务运行标识
SETTING=${SETTING:-"$PERSIST_DIR/settings.conf"}           # 模块配置文件路径
CONFIG=${CONFIG:-"$PERSIST_DIR/config.json"}               # 核心配置文件路径
LOGFILE=${LOGFILE:-"$PERSIST_DIR/$MODID.log"}              # 日志文件路径
PIDFILE=${PIDFILE:-"$PERSIST_DIR/$MODID.pid"}              # 进程ID文件路径
LOCK_FILE=${LOCK_FILE:-"$PERSIST_DIR/.service_lock"}       # 服务锁文件路径

# --- 网络与 TProxy 默认参数 ---

# 定义透明代理 (TProxy) 所需的网络参数
TPROXY_PORT=${TPROXY_PORT:-1536}                           # TProxy 监听端口
MARK=${MARK:-0x1}                                          # fwmark 标记, 用于策略路由
ROUTE_TABLE=${ROUTE_TABLE:-100}                            # 策略路由使用的路由表ID
IPSET_V4=${IPSET_V4:-singbox_outbounds_v4}                 # 用于匹配出站 IPv4 流量的 ipset 名称
IPSET_V6=${IPSET_V6:-singbox_outbounds_v6}                 # 用于匹配出站 IPv6 流量的 ipset 名称

# --- 系统 PATH 扩展 ---

# 扩展 PATH 环境变量, 将 Magisk/KernelSU 等工具的常用路径包含进来
# `${PATH:+$PATH:}` 是一个安全的写法: 
# - 如果 `PATH` 已设置且非空, 它会扩展为 `original_path:`
# - 如果 `PATH` 未设置或为空, 它会扩展为空字符串
export PATH="${PATH:+$PATH:}/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin"

# --- 运行环境检测 ---

# 检测当前脚本是否运行在 Magisk/KernelSU 的安装环境中
IS_INSTALLER_ENV=0
if type ui_print >/dev/null 2>&1; then
  IS_INSTALLER_ENV=1
fi

# ==============================================================================
# Helper 函数
# ==============================================================================

# --- 日志记录函数 ---
#
# @param "$@" 要记录的日志消息
log() {
  # 确保日志文件所在的目录存在
  mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
  # `"$@"` 会将所有传入参数作为独立的、被正确引用的字符串处理
  printf '[%s] %s\n' "$(date +'%F %T')" "$@" >> "$LOGFILE"
}

# --- 安全的打印函数 (兼容安装环境) ---
#
# @param "$1" 要打印的消息
ui_print_safe() {
  msg="$1"
  if [ "$IS_INSTALLER_ENV" -eq 1 ]; then
    ui_print "[$(date +'%T')] $msg"
  else
    echo "[$(date +'%T')] $msg"
  fi
  # 无论如何, 都将消息记录到日志文件
  log "$msg"
}

# --- 安全的终止函数 (兼容安装环境) ---
#
# @param "$1" 终止前显示的错误消息
abort_safe() {
  msg="$1"
  if [ "$IS_INSTALLER_ENV" -eq 1 ]; then
    abort "[$(date +'%T')] $msg"
  else
    echo "[$(date +'%T')] [ABORT]: $msg" >&2
    log "[ABORT]: $msg"
    exit 1
  fi
}

# --- 更新模块描述 ---
#
# @param "$1" 传入 "✅" 或 "⛔"
update_desc() {
  icon="$1"
  cur="$(sed -n 's/^description=//p' "$PROP")"
  if printf '%s' "$cur" | grep -q '\[Proxy Status: [^]]*\]'; then
    status="$(printf '%s' "$cur" | sed "s#\\[Proxy Status: [^]]*\\]#[Proxy Status: $icon]#")"
  else
    # 没找到状态片段时，将其前置到整个描述前面
    status="[Proxy Status: $icon] $cur"
  fi
  esc_status="$(printf '%s' "$status" | sed 's/[\/&]/\\&/g')"
  tmp="$PROP.new"
  sed "s/^description=.*/description=${esc_status}/" "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
}

# --- 安全的文件权限设置函数 (兼容非安装环境) ---
#
# 这是 Magisk 安装脚本提供的 `set_perm` 函数的一个后备实现 (fallback)
#
# @param "$1" file     目标文件或目录的路径
# @param "$2" owner    所有者 (UID)
# @param "$3" group    所属组 (GID)
# @param "$4" perm     权限 (例如 0755)
# @param "$5" context  (可选) SELinux 上下文
set_perm_safe() {
  f="$1"; owner="$2"; group="$3"; perm="$4"; ctx="$5"
  if [ "$IS_INSTALLER_ENV" -eq 1 ]; then
    # 在安装环境下, 直接调用 Magisk 提供的 `set_perm`
    set_perm "$f" "$owner" "$group" "$perm" "$ctx" 2>/dev/null || true
    return 0
  fi
  # 在普通环境下, 使用标准 shell 命令尽力完成权限设置
  if [ -n "$owner" ] && [ -n "$group" ]; then
    # 尝试两种 chown 的语法以提高兼容性
    chown "$owner.$group" "$f" 2>/dev/null || chown "$owner:$group" "$f" 2>/dev/null || true
  fi
  chmod "$perm" "$f" 2>/dev/null || true
  # 如果提供了 SELinux 上下文且 `chcon` 命令存在, 则设置它
  if [ -n "$ctx" ] && command -v chcon >/dev/null 2>&1; then
    chcon "$ctx" "$f" 2>/dev/null || true
  fi
}

# --- 安全的递归权限设置函数 (兼容非安装环境) ---
#
# 这是 Magisk 安装脚本提供的 `set_perm_recursive` 函数的一个后备实现
#
# @param "$1" dir       目标目录
# @param "$2" owner     所有者
# @param "$3" group     所属组
# @param "$4" dirperm   目录权限
# @param "$5" fileperm  文件权限
# @param "$6" context   (可选) SELinux 上下文
set_perm_recursive_safe() {
  dir="$1"; owner="$2"; group="$3"; dirperm="$4"; fileperm="$5"; ctx="$6"
  if [ "$IS_INSTALLER_ENV" -eq 1 ]; then
    # 在安装环境下, 直接调用 Magisk 提供的 `set_perm_recursive`
    set_perm_recursive "$dir" "$owner" "$group" "$dirperm" "$fileperm" "$ctx" 2>/dev/null || true
    return 0
  fi
  # 在普通环境下, 使用 `find` 和标准命令模拟实现
  find "$dir" -type d -exec chmod "$dirperm" {} \; 2>/dev/null || true
  find "$dir" -type f -exec chmod "$fileperm" {} \; 2>/dev/null || true
  chown -R "$owner.$group" "$dir" 2>/dev/null || chown -R "$owner:$group" "$dir" 2>/dev/null || true
  if [ -n "$ctx" ] && command -v chcon >/dev/null 2>&1; then
    chcon -R "$ctx" "$dir" 2>/dev/null || true
  fi
}

# --- 读取持久化配置 ---
#
# 从配置文件中读取一个键 (key) 对应的值 (value)
#
# @param "$1" key 要读取的键
# @param "$2" default_val (可选) 键不存在时返回的默认值
# @return 成功时返回读取到的值, 文件不存在或键不存在时返回默认值
read_setting() {
  key="$1"
  default_val="$2"
  f="$SETTING"
  value=""

  if [ -f "$f" ]; then
    # 使用 awk 安全地提取和清理值, 移除前导/尾随的空白字符和回车
    value=$(awk -v key="$key" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2); gsub(/^[ \t\r]+|[ \t\r]+$/, "", value); print value; exit; }' "$f")
  fi

  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$default_val"
  fi
}

# 将配置项写入配置文件
# @param "$1" 配置键 (key)
# @param "$2" 配置值 (value)
write_setting() {
  key="$1"; v="$2"
  f="$SETTING"
  tmp_f="$f.tmp.$$"

  mkdir -p "$(dirname "$f")"
  if [ ! -f "$f" ]; then echo "# 模块配置文件" > "$f" || true; fi

  awk -v k="$key" -v v="$v" '
    BEGIN { updated = 0 }
    {
      eq_pos = index($0, "=")
      if (eq_pos > 0 && substr($0, 1, eq_pos - 1) == k) {
        print k "=" v
        updated = 1
      } else {
        print $0
      }
    }
    END {
      if (updated == 0) {
        print k "=" v
      }
    }
  ' "$f" > "$tmp_f" && mv "$tmp_f" "$f"

  chmod 600 "$f" 2>/dev/null || true
}

# --- 域名解析工具 ---
#
# 使用系统上可用的工具, 尽力将主机名解析为 IP 地址, 按顺序尝试 `getent`, `dig`, `nslookup`, `ping`
#
# @param "$1" host 要解析的主机名
# @return 返回解析到的 IP 地址列表 (每行一个)
resolve_ips() {
  host="$1"
  if [ -z "$host" ]; then return 1; fi
  # 1. getent: 最可靠的方式, 能同时查询 hosts 文件和 DNS
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | uniq
    return 0
  fi
  # 2. dig: 专业的 DNS 查询工具
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$host" 2>/dev/null
    dig +short AAAA "$host" 2>/dev/null
    return 0
  fi
  # 3. nslookup: 另一个常见的 DNS 查询工具
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2}' || true
    return 0
  fi
  # 4. ping: 作为最后的手段, 从 ping 的输出中提取 IP 地址
  if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
    ping -c1 -W1 "$host" 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p'
    return 0
  fi
  return 1
}

# --- TProxy 支持检测 ---
#
# 检查内核的 iptables 是否支持 TPROXY 目标
#
# @return 0 表示支持, 1 表示不支持
kernel_supports_tproxy() {
  # 通过检查 `iptables` 的帮助文档中是否包含 "TPROXY" 关键字来判断
  if iptables -t mangle -h 2>&1 | awk '{if(tolower($0) ~ /tproxy/) exit 0} ENDFILE{exit 1}'; then
    return 0
  fi
  return 1
}

# --- 安全的后台命令执行函数 ---
#
# 以健壮、安全的方式在后台启动一个命令
#
# @param "$@" 要执行的命令及其所有参数
bg_run() {
  [ "$#" -ge 1 ] || { echo "Usage: bg_run CMD [ARGS...]" >&2; return 1; }

  # 可选：允许用户通过 BG_RUN_LOG 指定日志文件；默认丢弃
  : "${BG_RUN_LOG:=/dev/null}"

  if command -v nohup >/dev/null 2>&1; then
    nohup "$@" </dev/null >"$BG_RUN_LOG" 2>&1 &
  elif command -v setsid >/dev/null 2>&1; then
    # 有些系统可能没有 nohup，但有 setsid，也能避免挂起影响
    setsid "$@" </dev/null >"$BG_RUN_LOG" 2>&1 &
  else
    # 最后兜底：显式忽略 HUP，并后台化
    ( trap '' HUP; exec "$@" ) </dev/null >"$BG_RUN_LOG" 2>&1 &
  fi

  echo $!
}

# 定义模块使用的核心文件和程序的默认路径
BIN_NAME=$(read_setting "BIN_NAME" "sing-box")             # 代理核心文件名
BIN_PATH=${BIN_PATH:-"$MODDIR/$BIN_NAME"}                  # 代理核心完整路径
BIN_LOG=${BIN_LOG:-"$PERSIST_DIR/$BIN_NAME.log"}           # 核心日志文件路径
# END of common.sh