#!/system/bin/sh
#
# ==============================================================================
# 📜 common.sh - 模块通用核心脚本
# ==============================================================================
#
# 统一定义模块全局变量与通用函数，供各子脚本调用。
# - 管理路径、标识符、持久化目录等核心配置
# - 提供日志、安全输出、环境检测等辅助功能
# - 保证各脚本间逻辑一致性与可维护性
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
IPV6=${IPV6:-false}                                       # 是否启用ipv6
PROXY_MODE=${PROXY_MODE:-""}                              # whitelist | blacklist | ""
TPROXY_PORT=${TPROXY_PORT:-1536}                          # TProxy 监听端口
CHAIN_NAME=${CHAIN_NAME:-"FIREFLY"}                       # 链名, 用于 iptables 规则
MARK=${MARK:-0x1}                                         # fwmark 标记, 用于策略路由
ROUTE_TABLE=${ROUTE_TABLE:-100}                           # 策略路由使用的路由表ID
IPSET_V4=${IPSET_V4:-singbox_outbounds_v4}               # 用于匹配出站 IPv4 流量的 ipset 名称
IPSET_V6=${IPSET_V6:-singbox_outbounds_v6}               # 用于匹配出站 IPv6 流量的 ipset 名称
INTRANET=${INTRANET:-"0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32"}
INTRANET6=${INTRANET6:-"::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64 2001::/32 2001:10::/28 2001:20::/28 2001:db8::/32 2002::/16 fc00::/7 fe80::/10 ff00::/8"}

# --- 读写持久化函数 ---

# ⚙️ 从配置文件中读取一个键 (key) 对应的值 (value)
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
    value=$(awk -F= -v k="$key" '
      $1 == k {
        # Get the value part
        v = substr($0, length(k) + 2)
        # Trim leading/trailing whitespace
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        print v
        exit
      }
    ' "$f")
  fi

  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$default_val"
  fi
}

# ⚙️ 将配置项写入配置文件
#
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

# --- 模块核心文件和程序的默认路径 ---

BIN_NAME=$(read_setting "BIN_NAME" "sing-box")             # 代理核心文件名
BIN_PATH=${BIN_PATH:-"$MODDIR/$BIN_NAME"}                 # 代理核心完整路径
BIN_LOG=${BIN_LOG:-"$PERSIST_DIR/$BIN_NAME.log"}          # 核心日志文件路径

# --- 代理进程识别 ---

# 运行代理进程的用户 UID
# 1. 从由 BIN_NAME (在文件末尾定义) 指定的正在运行的进程中获取
# 2. 使用 PROXY_PACKAGE_NAME 从包管理器中获取
PROXY_UID=${PROXY_UID:-$(read_setting "PROXY_UID")}

# --- 应用黑白名单 ---

# 多个包名请用空格隔开
# 示例: WHITELIST_APPS="com.android.vending com.google.android.gms"
# 应用白名单, 列出的应用包名将绕过代理
WHITELIST_APPS=${WHITELIST_APPS:-$(read_setting "WHITELIST_APPS")}

# 应用黑名单, 列出的应用包名将被代理
BLACKLIST_APPS=${BLACKLIST_APPS:-$(read_setting "BLACKLIST_APPS")}

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
# 辅助函数 (Helper Functions)
# ==============================================================================

# --- 日志记录函数 ---
# 记录日志到文件
log() {
  mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
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
  tmp="$PROP.new"
  awk -v icon="$icon" '
    /^description=/ {
      desc = substr($0, 13)
      if (sub(/\[Proxy Status: [^]]*\]/, "[Proxy Status: " icon "]", desc)) {
        print "description=" desc
      } else {
        print "description=[Proxy Status: " icon "] " desc
      }
      next
    }
    { print }
  ' "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
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
    getent ahosts "$host" 2>/dev/null | cut -d' ' -f1 | uniq
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
    nslookup "$host" 2>/dev/null | grep '^Address: ' | cut -d' ' -f2 || true
    return 0
  fi
  # 4. ping: 作为最后的手段, 从 ping 的输出中提取 IP 地址
  if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
    ping -c1 -W1 "$host" 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p'
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

# END of common.sh