#!/system/bin/sh
#
# ==============================================================================
# late_start service - 开机后延迟启动的服务
# ==============================================================================
#
# ## 特性:
# - 启动/停止代理核心主程序以及相关的防火墙规则
# - 持久化目录存放用户配置、日志等, 避免模块更新导致配置丢失
# - 根据模块设置启停 monitor.sh (守护进程) 和 refresh-ipset.sh (规则集刷新)
#
# ==============================================================================

# 当任何命令返回非零退出码时立即退出
set -e

# --- 初始化与变量定义 ---
MODDIR=${0%/*}
. "$MODDIR/common.sh"

log "[service.sh]: 接收参数: $1"

# --- 函数定义 ---

# 函数: cleanup
# 作用: 停止核心进程, 并清理所有相关的防火墙规则这是模块停止或重启前的必要步骤
cleanup() {
  log "开始清理..."
  # 1. 停止核心进程
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      log "正在停止核心进程 $PID..."
      kill "$PID" 2>/dev/null || true
      sleep 1 # 等待进程完全退出
    fi
    rm -f "$PIDFILE" 2>/dev/null || true
  fi

  # 2. 清理防火墙规则 (优先使用模块目录中的规则脚本, 最后是通用清理规则)
  if [ -x "$START_RULES" ]; then
    log "正在清理防火墙规则..."
    # 调用规则脚本清理, 并将日志追加到主日志文件
    sh "$START_RULES" stop >> "$LOGFILE" 2>&1 || log "- 规则脚本调用失败"
  else
    log "规则脚本在未找到, 尝试通用规则清理..."
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

  # 3. 停止所有相关的辅助脚本 (如 monitor.sh)
  if command -v pgrep >/dev/null 2>&1; then
    log "正在终止辅助脚本..."
    for p in monitor.sh refresh-ipset.sh; do
      pgrep -f "$p" | while read -r pid; do
        log "- 残留进程 $pid"
        kill "$pid" 2>/dev/null || true
        log "- 已终止 $p"
      done
    done
  fi
  log "清理完成"
}

# 函数: ensure_bin
# 作用: 确保核心程序存在且可执行如果文件不存在, 且 ENABLE_AUTO_UPDATE=1, 则尝试调用更新脚本来自动下载
ensure_bin() {
  en=$(read_setting "ENABLE_AUTO_UPDATE")

  if [ -x "$UPDATE_BIN" ]; then

    if [ ! -x "$BIN_PATH" ]; then
      log "代理核心不存在, 尝试自动下载..."
      # 执行更新脚本, 并将日志追加到主日志文件
      sh "$UPDATE_BIN" >> "$LOGFILE" 2>&1 || log "自动更新执行失败"
    fi

    if [ -x "$BIN_PATH" ] && [ "$en" -eq 1 ]; then
      log "已启用自动更新, 尝试自动更新..."
      ver=$("$BIN_PATH" -v 2>/dev/null || "$BIN_PATH" --version 2>/dev/null || true)
      log "当前版本: $ver"
      # 执行更新脚本, 并将日志追加到主日志文件
      sh "$UPDATE_BIN" >> "$LOGFILE" 2>&1 || log "自动更新执行失败"
    fi
  fi

  if [ ! -x "$BIN_PATH" ]; then
    log "错误: 代理核心未找到, 请确认程序是否存在"
    return 1
  fi
  return 0
}

# 函数: start_bin
# 作用: 在后台启动代理核心进程
start_bin() {
  if [ ! -f "$CONFIG" ]; then
    log "错误: 配置文件未找到: $CONFIG"
    return 1
  fi
  log "正在启动核心进程..."
  nohup "$BIN_PATH" run -D "$PERSIST_DIR" >> "$BINLOG" 2>&1 &
  # 将进程号写入 PID 文件, 以便后续管理
  echo $! > "$PIDFILE"
  sleep 0.8 # 短暂等待, 以便检查进程是否成功启动
  if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "代理核心启动成功 (PID $(cat "$PIDFILE"))"
  else
    log "错误: 核心进程启动失败, 请检查日志 $BINLOG"
    return 1
  fi
  return 0
}

# 函数: apply_rules
# 作用: 应用防火墙规则, 以便将流量转发给核心进程
apply_rules() {
  if [ -x "$START_RULES" ]; then
    log "正在应用防火墙规则..."
    sh "$START_RULES" start >> "$LOGFILE" 2>&1 || log "规则脚本调用失败"
  else
    log "错误: 规则脚本未找到, 请重新安装模块"
    return 1
  fi
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    log "错误: 防火墙规则应用失败"
    return 1
  fi
  log "防火墙规则应用成功"
  return 0
}

# 函数: start_monitor_if_needed
# 作用: 根据模块配置, 决定是否启动守护进程
start_monitor_if_needed() {
  # 从 settings.conf 读取 ENABLE_MONITOR 的值, 默认为 "1" (启用)
  en=$(read_setting "ENABLE_MONITOR" "0")
  if [ "$en" = "1" ]; then
    # 检查进程是否已在运行
    if ! pgrep -f monitor.sh >/dev/null 2>&1; then
      if [ -x "$MONITOR" ]; then
        log "正在启动守护进程..."
        bg_run sh "$MONITOR"
      else
        log "警告: 守护进程脚本未找到, 跳过启动"
      fi
    else
      log "守护进程 $(basename "$MONITOR") 已在运行"
    fi
  else
    log "根据配置, 守护进程已被禁用"
  fi
}

# 函数: start_refresh_if_needed
# 作用: 根据模块配置, 决定是否启动 IPSet 刷新脚本
start_refresh_if_needed() {
  en=$(read_setting "ENABLE_REFRESH" "0")
  if [ "$en" = "1" ]; then
    if ! pgrep -f refresh-ipset.sh >/dev/null 2>&1; then
      if [ -x "$REFRESH" ]; then
        log "正在启动 IPSet 刷新脚本..."
        bg_run sh "$REFRESH"
      else
        log "警告: 刷新脚本未找到, 跳过启动"
      fi
    else
      log "IPSet 刷新脚本 $(basename "$REFRESH") 已在运行"
    fi
  else
    log "根据配置, IPSet 刷新已被禁用"
  fi
}

# --- 主逻辑 ---

# 使用 case 语句处理传入的参数 (如 "start" 或 "stop")
case "$1" in
  stop)
    log "开始执行清理..."
    cleanup
    rm -f "$FLAG" 2>/dev/null || true
    update_desc "⛔"
    log "服务已停止"
    exit 0
    ;;
  *)
    log "[service.sh]: 服务启动..."

    # 1. 执行清理, 确保一个干净的启动环境
    cleanup

    # 2. 确保核心程序存在
    if ! ensure_bin; then
      log "代理核心不可用, 启动中止"
      exit 1
    fi

    # 3. 应用防火墙规则
    if ! apply_rules; then
      log "防火墙规则应用失败, 启动中止"
      cleanup # 尝试清理失败的规则
      exit 1
    fi

    # 4. 启动核心主进程
    if ! start_bin; then
      log "代理核心启动失败, 启动中止"
      cleanup # 清理规则和可能的残留进程
      exit 1
    fi

    # 5. 启动可选的辅助脚本
    start_monitor_if_needed
    start_refresh_if_needed

    # 6. 创建服务运行标识
    touch "$FLAG" 2>/dev/null || true
    update_desc "✅"

    log "[service.sh]: 服务启动完成"
    ;;
esac

exit 0