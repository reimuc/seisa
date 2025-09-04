#!/system/bin/sh
#
# ==============================================================================
# 🔥 start.rules.sh - 透明代理 iptables 规则管理脚本
# ==============================================================================
#
# 管理并应用透明代理所需的 iptables 规则, 支持 IPv4/IPv6、TPROXY、ipset 优化及动态提取配置
# - 自动创建/清理自定义链与路由
# - 动态提取 FakeIP 网段与出站服务器地址
# - 支持 ipset 白名单, 防止代理回环
# - 兼容多种内核与环境
#
# ==============================================================================
set -e

MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

CHAIN_NAME_PRE="${CHAIN_NAME}_PRE"
CHAIN_NAME_OUT="${CHAIN_NAME}_OUT"

log "❤️=== [start.rules] ===❤️"
log "📬 规则应用, 接受参数 $1"

# --- 动态端口检测 ---
# 从 sing-box 配置文件中提取 TProxy 监听端口, 覆盖 common.sh 中的默认值
TPROXY_PORT_FROM_CONFIG=$( (
  if [ -f "$CONFIG" ]; then
    awk '/"type": "tproxy"/,/"}/' "$CONFIG" | grep '"listen_port"' | grep -o '[0-9]*'
  fi
) )

if [ -n "$TPROXY_PORT_FROM_CONFIG" ]; then
  log "⚙️ 检测到 TProxy 端口: $TPROXY_PORT_FROM_CONFIG"
  TPROXY_PORT=$TPROXY_PORT_FROM_CONFIG
else
  log "⚠️ 未检测到 TProxy 端口, 使用默认值: $TPROXY_PORT"
fi

# 封装 common.sh 中的 resolve_ips 函数, 便于在此脚本中调用
resolve_ips_bin() {
  resolve_ips "$1"
}

# 从 sing-box 配置文件中提取 FakeIP 网段
# FakeIP 用于为无 IP 的域名分配一个虚构的 IP 地址, 便于 DNS 管理
extract_fakeip_ranges() {
  fair4=""
  fair6=""
  if [ -f "$CONFIG" ]; then
    # 使用 grep 和 cut 提取 inet4_range 的值
    fair4=$(grep '"inet4_range"' "$CONFIG" | cut -d'"' -f4 || true)
    fair6=$(grep '"inet6_range"' "$CONFIG" | cut -d'"' -f4 || true)
  fi
  echo "$fair4" "$fair6"
}

# 创建 ipset 集合
# ipset 可以高效地存储和匹配大量 IP 地址, 性能远高于逐条 iptables 规则
create_ipsets() {
  log "📦 正在创建 ipSet 集合..."
  if command -v ipset >/dev/null 2>&1; then
    # 创建 IPv4 ipset, 如果已存在则忽略
    ipset create "$IPSET_V4" hash:ip family inet -exist >/dev/null 2>&1 || true
    # 创建 IPv6 ipset
    ipset create "$IPSET_V6" hash:ip family inet6 -exist >/dev/null 2>&1 || true
  else
    log "⚠️ ipSet 命令不可用, 性能可能会受影响"
  fi
}

# 清空 ipset 集合中的所有条目
# 这在重新配置或更新规则时非常有用, 确保旧的 IP 地址不会干扰新的规则
flush_ipsets() {
  log "🗑️ 正在清空 ipSet 集合..."
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "$IPSET_V4" 2>/dev/null || true
    ipset flush "$IPSET_V6" 2>/dev/null || true
  fi
}

# 填充出站服务器 IP 到 ipset
# 这是为了防止代理服务器自身的流量被再次送入代理, 造成循环
populate_outbound_ipsets() {
  log "➕ 正在填充出站服务器 IP..."
  # 解析配置文件中的出站服务器地址并添加到 ipset
  if [ -f "$CONFIG" ]; then
    # 提取所有 "server" 字段的值, 去重
    # 这个 awk 脚本比之前的版本更健壮, 它处理 JSON 对象时不依赖于键的顺序
    awk 'BEGIN{in_obj=has_server=has_uuid=has_password=0;server_val=""} \
         /\{/ {in_obj++} \
         /\}/ {if(in_obj>0){if(has_server&&(has_uuid||has_password))print server_val;has_server=has_uuid=has_password=0;server_val="";in_obj--}} \
         /"server"[[:space:]]*:/ {if(match($0,/"server"[[:space:]]*:[[:space:]]*"([^"]+)"/,m)){has_server=1;server_val=m[1]}} \
         /"uuid"[[:space:]]*:/ {has_uuid=1} \
         /"password"[[:space:]]*:/ {has_password=1}' "$CONFIG" | sort -u | while read -r host; do
      log "🔍 正在处理出站服务器: $host"
      [ -z "$host" ] && continue
      # 使用 case 语句判断是 IP 还是域名, 这比 grep -E 更具可移植性
      case "$host" in
      # 匹配看起来像 IPv4 地址的字符串 (e.g., 1.2.3.4)
      [0-9]*.[0-9]*.[0-9]*.[0-9]*)
        log "➡️ 处理出站服务器: $host"
        if command -v ipset >/dev/null 2>&1; then
          ipset add "$IPSET_V4" "$host" -exist 2>/dev/null || true
        else
          iptables -w 100 -t mangle -I "$CHAIN_NAME" 1 -d "$host" -j RETURN 2>/dev/null || true
        fi
        ;;
        # 匹配包含冒号的字符串, 视为 IPv6 地址
      *:*)
        log "➡️ 处理出站服务器v6: $host"
        if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
          if command -v ipset >/dev/null 2>&1; then
            ipset add "$IPSET_V6" "$host" -exist 2>/dev/null || true
          else
            ip6tables -w 100 -t mangle -I "${CHAIN_NAME}6" 1 -d "$host" -j RETURN 2>/dev/null || true
          fi
        fi
        ;;
        # 其他情况视为域名
      *)
        for ip in $(resolve_ips_bin "$host"); do
          log "🌐 解析到的出站服务器: $ip"
          # 解析出的 IP 再次用 case 判断
          case "$ip" in
          *:*) # IPv6
            if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
              if command -v ipset >/dev/null 2>&1; then
                ipset add "$IPSET_V6" "$ip" -exist 2>/dev/null || true
              else
                ip6tables -w 100 -t mangle -I "${CHAIN_NAME}6" 1 -d "$ip" -j RETURN 2>/dev/null || true
              fi
            fi
            ;;
          *) # IPv4
            if command -v ipset >/dev/null 2>&1; then
              ipset add "$IPSET_V4" "$ip" -exist 2>/dev/null || true
            else
              iptables -w 100 -t mangle -I "$CHAIN_NAME" 1 -d "$ip" -j RETURN 2>/dev/null || true
            fi
            ;;
          esac
        done
        ;;
      esac
    done
  fi
}

# 设置策略路由
# 将带有特定 fwmark 的数据包路由到指定的路由表, 该表将所有流量导向本地（lo）, 由 TPROXY 处理
setup_routes() {
  log "🗺️ 正在设置策略路由..."
  # 为 IPv4 设置路由规则
  ip route add local default dev lo table "$ROUTE_TABLE" 2>/dev/null || true
  ip rule add fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true

  # 如果系统支持 IPv6, 则同样设置
  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip -6 route add local default dev lo table "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 rule add fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
  fi
}

# 创建自定义的 iptables 链
create_chains() {
  log "🔗 正在创建自定义 iptables 链..."
  # 为 IPv4 创建自定义链
  iptables -w 100 -t mangle -N "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -F "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -N "$CHAIN_NAME_OUT" 2>/dev/null || true
  iptables -w 100 -t mangle -F "$CHAIN_NAME_OUT" 2>/dev/null || true

  # 如果支持 IPv6, 则创建对应的 IPv6 链
  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -N "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -N "${CHAIN_NAME_OUT}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_OUT}6" 2>/dev/null || true
  fi
}

# 添加白名单和核心 TPROXY 规则
add_whitelists_and_rules() {
  # --- 白名单规则 (RETURN) ---
  log "🛡️ 正在添加白名单规则..."

  # 1. PREROUTING 链: 处理转发流量
  # --------------------------------------------------
  # 跳过发往保留/私有地址的流量
  log "🏠 添加内网白名单..."
  if [ -n "$INTRANET" ]; then
    for ip in $INTRANET; do
      iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -d "$ip" -j RETURN
    done
  fi
  if [ "$IPV6" = "true" ] && [ -n "$INTRANET6" ]; then
    for ip in $INTRANET6; do
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -d "$ip" -j RETURN 2>/dev/null || true
    done
  fi

  # 跳过发往 FakeIP 网段的流量
  log "👻 添加 FakeIP 白名单..."
  # shellcheck disable=SC2046
  set -- $(extract_fakeip_ranges)
  fake4="$1"
  fake6="$2"
  if [ -n "$fake4" ]; then
    iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -d "$fake4" -j RETURN
  fi
  if [ -n "$fake6" ] && [ "$IPV6" = "true" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -d "$fake6" -j RETURN 2>/dev/null || true
  fi

  # 使用 ipset 跳过出站服务器
  if command -v ipset >/dev/null 2>&1; then
    log "➡️ 添加 ipset 出站白名单..."
    iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -m set --match-set "$IPSET_V4" dst -j RETURN
    if [ "$IPV6" = "true" ]; then
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -m set --match-set "$IPSET_V6" dst -j RETURN 2>/dev/null || true
    fi
  fi

  # 2. OUTPUT 链: 处理本机产生的流量
  # --------------------------------------------------
  # 跳过所有源自本机套接字的流量
  log "🔌 添加 socket 白名单..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m socket -j RETURN
  if [ "$IPV6" = "true" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m socket -j RETURN 2>/dev/null || true
  fi

  # 跳过代理进程自身产生的流量
  if [ -n "$PROXY_UID" ]; then
    log "👤 添加代理 UID ($PROXY_UID) 白名单..."
    iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m owner --uid-owner "$PROXY_UID" -j RETURN
    if [ "$IPV6" = "true" ]; then
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m owner --uid-owner "$PROXY_UID" -j RETURN 2>/dev/null || true
    fi
  fi

  # --- DNS 重定向规则 (关键修复) ---
  log "🌐 正在添加 DNS 重定向规则..."
  # 将 PREROUTING 链的 DNS 流量重定向到 TPROXY 端口
  iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -p udp --dport 53 -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK"
  # 对于 OUTPUT 链, 我们只标记 DNS 数据包, 由策略路由处理, 因为 TPROXY 目标不适用于 OUTPUT 链
  iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p udp --dport 53 -j MARK --set-mark "$MARK"
  if [ "$IPV6" = "true" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -p udp --dport 53 -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK" 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p udp --dport 53 -j MARK --set-mark "$MARK" 2>/dev/null || true
  fi

  # --- 应用代理规则 (OUTPUT 链) ---
  # 假设 $PROXY_MODE, $WHITELIST_APPS, $BLACKLIST_APPS 在 common.sh 中定义
  if command -v dumpsys >/dev/null 2>&1; then
    # 白名单模式 (默认)
    if [ "$PROXY_MODE" = "whitelist" ]; then
      log "📱 应用白名单代理模式..."
      if [ -n "$WHITELIST_APPS" ]; then
        for app_pkg in $WHITELIST_APPS; do
          uid=$(dumpsys package "$app_pkg" 2>/dev/null | grep 'userId=' | cut -d'=' -f2)
          if [ -n "$uid" ]; then
            log "⚪️ 将应用 '$app_pkg' (UID: $uid) 加入白名单 (代理)"
            iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m owner --uid-owner "$uid" -j MARK --set-mark "$MARK"
            if [ "$IPV6" = "true" ]; then
              ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m owner --uid-owner "$uid" -j MARK --set-mark "$MARK" 2>/dev/null || true
            fi
          else
            log "⚠️ [警告] 无法找到应用 '$app_pkg' 的 UID"
          fi
        done
      else
        log "ℹ️ 应用白名单为空, 除 DNS 外, 本机流量将不通过代理"
      fi
    # 黑名单模式
    elif [ "$PROXY_MODE" = "blacklist" ]; then
      log "📱 应用黑名单代理模式..."
      if [ -n "$BLACKLIST_APPS" ]; then
        for app_pkg in $BLACKLIST_APPS; do
          uid=$(dumpsys package "$app_pkg" 2>/dev/null | grep 'userId=' | cut -d'=' -f2)
          if [ -n "$uid" ]; then
            log "⚫️ 将应用 '$app_pkg' (UID: $uid) 加入黑名单 (不代理)"
            iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m owner --uid-owner "$uid" -j RETURN
            if [ "$IPV6" = "true" ]; then
              ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
            fi
          else
            log "⚠️ [警告] 无法找到应用 '$app_pkg' 的 UID"
          fi
        done
      fi
      # 黑名单模式下, 其他所有流量都代理
      iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p tcp -j MARK --set-mark "$MARK"
      iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p udp -j MARK --set-mark "$MARK"
      if [ "$IPV6" = "true" ]; then
        ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p tcp -j MARK --set-mark "$MARK" 2>/dev/null || true
        ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p udp -j MARK --set-mark "$MARK" 2>/dev/null || true
      fi
    # 全局模式
    else
      log "🔥 应用全局代理模式..."
      iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p tcp -j MARK --set-mark "$MARK"
      iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p udp -j MARK --set-mark "$MARK"
      if [ "$IPV6" = "true" ]; then
        ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p tcp -j MARK --set-mark "$MARK" 2>/dev/null || true
        ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p udp -j MARK --set-mark "$MARK" 2>/dev/null || true
      fi
    fi
  else
    log "⚠️ [警告] dumpsys 命令不可用, 无法处理应用代理规则将对本机所有流量应用代理"
    iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p tcp -j MARK --set-mark "$MARK"
    iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p udp -j MARK --set-mark "$MARK"
    if [ "$IPV6" = "true" ]; then
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p tcp -j MARK --set-mark "$MARK" 2>/dev/null || true
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p udp -j MARK --set-mark "$MARK" 2>/dev/null || true
    fi
  fi

  # --- 核心 TPROXY 规则 (PREROUTING 链) ---
  log "🔥 正在添加核心 TPROXY 规则..."
  # PREROUTING 链: 转发 TCP/UDP 流量
  iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
  iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
  if [ "$IPV6" = "true" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK" 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK" 2>/dev/null || true
  fi

  # --- 应用规则链 ---
  log "✅ 正在应用规则链..."
  if ! iptables-save -t mangle | grep -q " -A PREROUTING -j $CHAIN_NAME_PRE"; then
    iptables -w 100 -t mangle -A PREROUTING -j "$CHAIN_NAME_PRE"
  fi
  if ! iptables-save -t mangle | grep -q " -A OUTPUT -j $CHAIN_NAME_OUT"; then
    iptables -w 100 -t mangle -A OUTPUT -j "$CHAIN_NAME_OUT"
  fi

  if [ "$IPV6" = "true" ]; then
    if ! ip6tables-save -t mangle | grep -q " -A PREROUTING -j ${CHAIN_NAME_PRE}6"; then
      ip6tables -w 100 -t mangle -A PREROUTING -j "${CHAIN_NAME_PRE}6"
    fi
    if ! ip6tables-save -t mangle | grep -q " -A OUTPUT -j ${CHAIN_NAME_OUT}6"; then
      ip6tables -w 100 -t mangle -A OUTPUT -j "${CHAIN_NAME_OUT}6"
    fi
  fi
}

get_proxy_uid() {
  # 获取代理二进制文件的 UID
  # 由于代理二进制文件不是标准的 Android 应用, 因此它没有由系统分配的固定 UID
  # 让代理二进制文件以特定的、非 root 的 UID 运行, 并在 'settings.conf' 中设置该 UID 是至关重要的
  # 例如, 通过以下方式以 'shell' 用户 (UID 2000) 身份运行: su 2000 -c "..."

  # 1. 主要且推荐的方法：使用 settings.conf 中的 PROXY_UID
  if [ -n "$PROXY_UID" ]; then
    log "ℹ️ 使用来自 settings.conf 的代理 UID '$PROXY_UID'"
    return 0
  fi

  # 2. 刷新时的备用方案：尝试从正在运行的进程中获取 UID
  # 如果在代理已激活时重新运行此脚本, 这可能会起作用
  # shellcheck disable=SC2009
  _pid=$(pidof "$BIN_NAME")
  if [ -n "$_pid" ]; then
    PROXY_UID=$(stat -c "%u" "/proc/$_pid")
    log "⚠️ 从运行中的进程检测到代理 UID '$PROXY_UID'请考虑在 settings.conf 中进行设置"
    return
  fi

  # 3. 严重失败
  log "❌ 致命错误：无法确定代理 UID"
  log "➡️ 请在设置中将 PROXY_UID 设置为代理二进制文件 ($BIN_NAME) 运行所使用的 UID"
  log "➡️ 例如：PROXY_UID=2000 (对于 shell 用户)"
  # 没有 UID 就无法继续, 因为它会造成代理循环
  PROXY_UID="" # 确保其为空
}

# "start" 命令的执行函数
do_start() {
  log "🚀 正在应用防火墙规则..."
  create_ipsets
  setup_routes
  create_chains
  populate_outbound_ipsets
  add_whitelists_and_rules
  log "✅ 防火墙规则已应用"
}

# "stop" 命令的执行函数
do_stop() {
  log "🛑 正在清除防火墙规则..."
  # 从 PREROUTING 和 OUTPUT 链中删除我们的规则
  iptables -w 100 -t mangle -D PREROUTING -j "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -D OUTPUT -j "$CHAIN_NAME_OUT" 2>/dev/null || true
  # 清空并删除自定义链
  iptables -w 100 -t mangle -F "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -X "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -F "$CHAIN_NAME_OUT" 2>/dev/null || true
  iptables -w 100 -t mangle -X "$CHAIN_NAME_OUT" 2>/dev/null || true

  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -D PREROUTING -j "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -D OUTPUT -j "${CHAIN_NAME_OUT}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -X "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_OUT}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -X "${CHAIN_NAME_OUT}6" 2>/dev/null || true
  fi

  # 删除策略路由规则和清空路由表
  ip rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
  ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip -6 rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 route flush table "$ROUTE_TABLE" 2>/dev/null || true
  fi

  # 清空 ipset
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "$IPSET_V4" 2>/dev/null || true
    ipset flush "$IPSET_V6" 2>/dev/null || true
  fi

  log "✅ 防火墙规则已清除"
}

# "refresh" 命令的执行函数
do_refresh() {
  log "🔄 正在刷新 ipSet ..."
  flush_ipsets
  populate_outbound_ipsets
  log "✅ ipSet 刷新完成"
}

# --- 主逻辑 ---
# 根据传入的第一个参数执行相应的函数
case "$1" in
  start) do_start ;;
  stop) do_stop ;;
  refresh) do_refresh ;;
  *) echo "用法: $0 {start|stop|refresh}" ;;
esac

exit 0