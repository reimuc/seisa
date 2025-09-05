#!/system/bin/sh
# =====================================================================
# 🚀 service.sh - 延迟启动服务脚本
# ---------------------------------------------------------------------
# 负责代理核心主程序及防火墙规则的启动/停止, 管理持久化配置与日志。
# - 启动/停止核心进程与防火墙规则
# - 管理守护进程与规则刷新脚本
# - 保证服务运行状态与配置一致性
# =====================================================================

set -e
trap '[ $? -ne 0 ] && abort_safe "⛔ 脚本执行失败: $?"' EXIT

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

log_safe "❤️=== [service] ===❤️"
log_safe "📬 服务启动, 接收参数: $1"

# --- 函数定义 ---

# 函数: cleanup
# 作用: 停止核心进程, 并清理所有相关的防火墙规则这是模块停止或重启前的必要步骤
cleanup() {
  log_safe "🧹 开始清理残留..."
  # 1. 停止核心进程
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log_safe "🛑 正在停止核心进程 $pid..."
      kill "$pid" 2>/dev/null || true
      sleep 1 # 等待进程完全退出
    fi
    rm -f "$PIDFILE" 2>/dev/null || true
  fi

  # 2. 清理防火墙规则 (优先使用模块目录中的规则脚本, 最后是通用清理规则)
  if [ -x "$START_RULES" ]; then
    log_safe "🔥 正在清理防火墙规则..."
    # 调用规则脚本清理, 并将日志追加到主日志文件
    sh "$START_RULES" stop >> "$LOGFILE" 2>&1 || log_safe "❌ 规则脚本调用失败"
  else
    log_safe "⭕ 规则脚本在未找到, 尝试通用规则清理..."
    iptables -t mangle -D PREROUTING -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -t mangle -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN_NAME" 2>/dev/null || true

    if [ "$IPV6_SUPPORT" = "1" ]; then
      ip6tables -t mangle -D PREROUTING -j "${CHAIN_NAME}6" 2>/dev/null || true
      ip6tables -t mangle -F "${CHAIN_NAME}6" 2>/dev/null || true
      ip6tables -t mangle -X "${CHAIN_NAME}6" 2>/dev/null || true
    fi

    ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    if [ "$IPV6_SUPPORT" = "1" ]; then
      ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null || true
      ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true
    fi
  fi

  # 3. 停止所有相关的辅助脚本 (如 monitor.sh)
  if command -v pkill >/dev/null 2>&1; then
    log_safe "🛑 正在终止辅助脚本 (monitor.sh, refresh-ipset.sh)..."
    pkill -f "monitor.sh" 2>/dev/null || true
    pkill -f "refresh-ipset.sh" 2>/dev/null || true
  fi
  log_safe "✨ 残留服务清理完成"
}

# 函数: ensure_bin
# 作用: 确保核心程序存在且可执行如果文件不存在, 且 ENABLE_AUTO_UPDATE=1, 则尝试调用更新脚本来自动下载
ensure_bin() {
  en=$(read_setting "ENABLE_AUTO_UPDATE" "1")
  update="update-bin.sh"
  bin_repo=$(read_setting "BIN_REPO" "SagerNet/sing-box")
  release_tag=$(read_setting "BIN_RELEASE" "latest")

  # 检查更新脚本是否存在
  if [ ! -x "$MODDIR/$update" ]; then
    if [ ! -x "$BIN_PATH" ]; then
      log_safe "❌ 代理核心和更新脚本均未找到, 无法继续"
      return 1
    fi
    return 0 # 更新脚本不存在, 但核心存在, 继续
  fi

  # 如果核心不存在, 必须执行更新
  if [ ! -x "$BIN_PATH" ]; then
    log_safe "❗ 代理核心不存在, 尝试自动下载..."
    sh "$MODDIR/$update" "$bin_repo" "$release_tag" >> "$LOGFILE" 2>&1 || log_safe "❌ 自动更新执行失败"
    if [ ! -x "$BIN_PATH" ]; then
      log_safe "❌ 下载后代理核心依然不存在"
      return 1
    fi
    return 0
  fi

  # 如果启用了自动更新, 检查版本
  if [ "$en" -eq 1 ]; then
    log_safe "🔄 已启用自动更新, 正在检查版本..."

    # 1. 获取本地版本
    ver_str=$("$BIN_PATH" version 2>/dev/null | awk '/version/ {sub(/.*version /, ""); sub(/^v/, ""); print $1}')
    current_ver=${ver_str:-"0.0.0"}
    log_safe "💻 当前版本: $current_ver"

    # 2. 获取远程最新版本标签
    api_url="https://api.github.com/repos/${bin_repo}/releases/latest"
    latest_tag=$(curl -sSL "$api_url" | awk -F '"' '/"tag_name":/ {print $4}' | sed 's/v//' | head -n 1 || echo "0.0.0")
    log_safe "☁️ 最新版本: $latest_tag"

    # 3. 比较版本 (简单的字符串比较)
    if [ "$latest_tag" != "$current_ver" ] && [ "$latest_tag" != "0.0.0" ]; then
      log_safe "✨ 发现新版本, 开始更新..."
      sh "$MODDIR/$update" "$bin_repo" >> "$LOGFILE" 2>&1 || log_safe "❌ 自动更新执行失败"
    else
      log_safe "✅ 当前已是最新版本, 无需更新"
    fi
  fi

  if [ ! -x "$BIN_PATH" ]; then
    log_safe "❌ 代理核心未找到, 请确认程序是否存在"
    return 1
  fi
  return 0
}

# 函数: start_bin
# 作用: 在后台启动代理核心进程并等待初始化完成
start_bin() {
  if [ ! -f "$CONFIG" ]; then
    log_safe "❌ 配置文件未找到: $CONFIG"
    return 1
  fi
  log_safe "🚀 正在启动核心进程..."

  # 清空旧的日志文件
  : > "$BIN_LOG"

  # 使用 bg_run 启动进程
  pid_uid=$(bg_run "$BIN_PATH" run -D "$PERSIST_DIR")
  pid=$(echo "$pid_uid" | cut -d' ' -f1)
  echo "$pid" > "$PIDFILE"

  # 等待进程启动并检查初始化状态
  max_wait=15  # 最大等待时间（秒）
  wait_count=0
  log_safe "🔍 正在等待核心进程启动 (PID: $pid)..."
  while [ "$wait_count" -lt "$max_wait" ]; do
    # 首先检查进程是否还在运行
    if ! kill -0 "$pid" 2>/dev/null; then
      log_safe "🛑 核心进程已意外退出"
      return 1
    fi

    # 检查日志中是否有成功初始化的标志
    if grep -qi "started" "$BIN_LOG" 2>/dev/null && ! grep -qi "error\|failed\|fatal" "$BIN_LOG" 2>/dev/null; then
      log_safe "✅ 代理核心启动成功 ($pid)"
      return 0
    fi

    # 检查是否有明显的错误标志
    if grep -q -i "error\|failed\|fatal" "$BIN_LOG" 2>/dev/null; then
      log_safe "❌ 核心进程初始化失败, 发现错误信息"
      kill "$pid" 2>/dev/null || true
      return 1
    fi

    sleep 1
    wait_count=$((wait_count + 1))
  done

  # 如果超时仍未见到成功标志, 认为启动失败
  log_safe "❌ 核心进程初始化超时"
  kill "$pid" 2>/dev/null || true
  return 1
}

# 函数: apply_rules
# 作用: 应用防火墙规则, 以便将流量转发给核心进程
apply_rules() {
  if [ -x "$START_RULES" ]; then
    log_safe "🔥 正在应用防火墙规则..."
    sh "$START_RULES" start >> "$LOGFILE" 2>&1 || {
      log_safe "❌ 规则脚本调用失败"
      return 1
    }
  else
    log_safe "❌ 规则脚本未找到, 请重新安装模块"
    return 1
  fi
  log_safe "✅ 防火墙规则应用成功"
  return 0
}

# 函数: start_monitor_if_needed
# 作用: 根据模块配置, 决定是否启动守护进程
start_monitor_if_needed() {
  # 从 settings.conf 读取 ENABLE_MONITOR 的值, 默认为 "1" (启用)
  en=$(read_setting "ENABLE_MONITOR" "0")
  monitor="monitor.sh"

  if [ "$en" = "1" ]; then
    # 检查进程是否已在运行
    if ! pgrep -f "$monitor" >/dev/null; then
      if [ -x "$MODDIR/$monitor" ]; then
        log_safe "👁️ 正在启动守护进程..."
        bg_run sh "$MODDIR/$monitor"
      else
        log_safe "⭕ 守护进程脚本未找到, 跳过启动"
      fi
    else
      log_safe "❗ 守护进程 $monitor 已在运行"
    fi
  else
    log_safe "⛔ 根据配置, 守护进程已被禁用"
  fi
}

# 函数: start_refresh_if_needed
# 作用: 根据模块配置, 决定是否启动 IPSet 刷新脚本
start_refresh_if_needed() {
  en=$(read_setting "ENABLE_REFRESH" "0")
  refresh="refresh-ipset.sh"

  if [ "$en" = "1" ]; then
    if ! pgrep -f "$refresh" >/dev/null; then
      if [ -x "$MODDIR/$refresh" ]; then
        log_safe "🔄 正在启动 IPSet 刷新脚本..."
        bg_run sh "$MODDIR/$refresh"
      else
        log_safe "⭕ 刷新脚本未找到, 跳过启动"
      fi
    else
      log_safe "❗ IPSet 刷新脚本 $refresh 已在运行"
    fi
  else
    log_safe "⛔ 根据配置, IPSet 刷新已被禁用"
  fi
}

# --- 主逻辑 ---

# 使用 case 语句处理传入的参数 (如 "start" 或 "stop")
case "$1" in
  stop)
    log_safe "🛑 开始执行清理..."
    cleanup
    rm -f "$FLAG" 2>/dev/null || true
    update_desc "⛔"
    log_safe "✅ 服务已停止"
    exit 0
    ;;
  *)
    log_safe "🚀 服务启动..."

    # --- 锁机制: 防止多个实例同时运行 ---
    if [ -f "$LOCK_FILE" ]; then
      log_safe "❗ 检测到另一个服务实例正在运行, 本次启动中止"
      exit 1
    fi
    # 创建锁文件, 并设置 trap 以确保在脚本退出时自动删除
    touch "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"; log_safe "🔓 锁已释放"' EXIT HUP INT QUIT TERM

    # 1. 执行清理, 确保一个干净的启动环境
    cleanup

    # 2. 确保核心程序存在
    if ! ensure_bin; then
      log_safe "❌ 代理核心不可用, 启动中止"
      exit 1
    fi

    # 3. 应用防火墙规则
    if ! apply_rules; then
      log_safe "❌ 防火墙规则应用失败, 启动中止"
      cleanup # 尝试清理失败的规则
      exit 1
    fi

    # 4. 启动核心主进程
    if ! start_bin; then
      log_safe "❌ 代理核心启动失败, 启动中止"
      cleanup # 清理规则和可能的残留进程
      exit 1
    fi

    # 5. 启动可选的辅助脚本
    start_monitor_if_needed
    start_refresh_if_needed

    # 6. 创建服务运行标识
    touch "$FLAG" 2>/dev/null || true
    update_desc "✅"

    log_safe "✅ 服务启动完成"
    ;;
esac

exit 0