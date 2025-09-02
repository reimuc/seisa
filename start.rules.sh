#!/system/bin/sh
#
# ==============================================================================
# start.rules.sh - 透明代理 iptables 规则管理脚本
# ==============================================================================
#
# ## 功能:
# - 创建和管理 iptables TPROXY 规则, 用于实现透明代理。
# - 支持 IPv4 和 IPv6。
# - 使用 ipset 优化性能, 将出站服务器 IP 加入白名单, 避免代理回环。
# - 支持动态从代理核心配置文件中提取 FakeIP 网段和出站服务器地址。
#
# ==============================================================================

set -e

# --- 初始化与变量定义 ---
MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

log "[start.rules.sh]: 接收参数: $1"

# --- 动态端口检测 ---
# 从 sing-box 配置文件中提取 TProxy 监听端口, 覆盖 common.sh 中的默认值
TPROXY_PORT_FROM_CONFIG=$( (
  if [ -f "$CONFIG" ]; then
    # 查找 "inbounds" 中 "type": "tproxy" 的 "listen_port"
    awk '/"type": "tproxy"/,/"}/' "$CONFIG" | grep '"listen_port"' | awk '{print $2}' | tr -d ','
  fi
) )

if [ -n "$TPROXY_PORT_FROM_CONFIG" ]; then
  log "检测到 TProxy 端口: $TPROXY_PORT_FROM_CONFIG"
  TPROXY_PORT=$TPROXY_PORT_FROM_CONFIG
else
  log "- 未检测到 TProxy 端口, 使用默认值: $TPROXY_PORT"
fi

# 封装 common.sh 中的 resolve_ips 函数, 便于在此脚本中调用
resolve_ips_bin() { resolve_ips "$1"; }

# 从 sing-box 配置文件中提取 FakeIP 网段
# FakeIP 用于为无 IP 的域名分配一个虚构的 IP 地址, 便于 DNS 管理
extract_fakeip_ranges() {
  fair4=""
  fair6=""
  if [ -f "$CONFIG" ]; then
    # 使用 grep 和 -oP（Perl 兼容的正则表达式）提取 inet4_range 的值
    fair4=$(awk -F'"' '/"inet4_range"/ {print $4}' "$CONFIG" || true)
    fair6=$(awk -F'"' '/"inet6_range"/ {print $4}' "$CONFIG" || true)
  fi
  echo "$fair4" "$fair6"
}

# 创建 ipset 集合
# ipset 可以高效地存储和匹配大量 IP 地址, 性能远高于逐条 iptables 规则
create_ipsets() {
  log "正在创建 ipSet 集合..."
  if command -v ipset >/dev/null 2>&1; then
    # 创建 IPv4 ipset, 如果已存在则忽略
    ipset create "$IPSET_V4" hash:ip family inet -exist >/dev/null 2>&1 || true
    # 创建 IPv6 ipset
    ipset create "$IPSET_V6" hash:ip family inet6 -exist >/dev/null 2>&1 || true
  else
    log "- ipSet 命令不可用, 性能可能会受影响"
  fi
}

# 清空 ipset 集合中的所有条目
# 这在重新配置或更新规则时非常有用, 确保旧的 IP 地址不会干扰新的规则
flush_ipsets() {
  log "正在清空 ipSet 集合..."
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "$IPSET_V4" 2>/dev/null || true
    ipset flush "$IPSET_V6" 2>/dev/null || true
  fi
}

# 填充出站服务器 IP 到 ipset
# 这是为了防止代理服务器自身的流量被再次送入代理, 造成循环
populate_outbound_ipsets() {
  log "正在填充出站服务器 IP 到 ipSet 集合..."
  # 解析配置文件中的出站服务器地址并添加到 ipset
  if [ -f "$CONFIG" ]; then
    # 提取所有 "server" 字段的值, 去重
    awk 'BEGIN{in_outbounds=0;is_proxy_type=0;server=""} /"outbounds":\s*\[/{in_outbounds=1;next} in_outbounds&&/]/{in_outbounds=0} in_outbounds&&/^\s*{/{is_proxy_type=0;server=""} in_outbounds&&/"type":\s*"(vmess|vless|trojan|ss|ssr|shadowsocks)"/{is_proxy_type=1} in_outbounds&&/"server":/{split($0,p,"\"");server=p[4]} in_outbounds&&/^\s*}/{if(is_proxy_type&&server!=""){print server};is_proxy_type=0;server=""}' "$CONFIG" | sort -u | while read -r host; do
      log "正在处理出站服务器: $host"
      [ -z "$host" ] && continue
      # 使用 case 语句判断是 IP 还是域名, 这比 grep -E 更具可移植性
      case "$host" in
        # 匹配看起来像 IPv4 地址的字符串 (e.g., 1.2.3.4)
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
          log "> 出站服务器: $host"
          if command -v ipset >/dev/null 2>&1; then
            ipset add "$IPSET_V4" "$host" -exist 2>/dev/null || true
          else
            iptables -w 100 -t mangle -I "$CHAIN_NAME" 1 -d "$host" -j RETURN 2>/dev/null || true
          fi
          ;;
        # 匹配包含冒号的字符串, 视为 IPv6 地址
        *:*)
          log "> 出站服务器v6: $host"
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
            log "> 解析到的出站服务器: $ip"
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
  log "正在设置策略路由..."
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
  log "正在创建自定义 iptables 链..."
  # 为 IPv4 创建自定义链
  iptables -w 100 -t mangle -N "$CHAIN_NAME" 2>/dev/null || true
  iptables -w 100 -t mangle -F "$CHAIN_NAME" 2>/dev/null || true

  # 如果支持 IPv6, 则创建对应的 IPv6 链
  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -N "${CHAIN_NAME}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME}6" 2>/dev/null || true
  fi
}

# 添加白名单和核心 TPROXY 规则
add_whitelists_and_rules() {
  # --- 白名单规则 (RETURN) ---
  # 跳过所有源自本机套接字的流量，防止代理循环和代理本机流量
  log "正在添加白名单规则..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME" -m socket -j RETURN
  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -m socket -j RETURN 2>/dev/null || true
  fi

  # 如果定义了 PROXY_UID, 则跳过代理进程自身产生的流量
  if [ -n "$PROXY_UID" ]; then
    log "正在添加代理进程 UID 白名单规则..."
    iptables -w 100 -t mangle -A "$CHAIN_NAME" -m owner --uid-owner "$PROXY_UID" -j RETURN
    if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -m owner --uid-owner "$PROXY_UID" -j RETURN 2>/dev/null || true
    fi
  fi

  # --- 应用白名单处理 ---
  if [ -n "$WHITELIST_APPS" ]; then
    if command -v dumpsys >/dev/null 2>&1; then
      log "正在添加应用白名单规则..."
      for app_pkg in $WHITELIST_APPS; do
        uid=$(dumpsys package "$app_pkg" 2>/dev/null | awk -F'=' '/userId=/ {print $2; exit}')
        if [ -n "$uid" ]; then
          log "> 将应用 '$app_pkg' (UID: $uid) 加入白名单。"
          iptables -w 100 -t mangle -A "$CHAIN_NAME" -m owner --uid-owner "$uid" -j RETURN
          if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
            ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
          fi
        else
          log "[警告] 无法找到应用 '$app_pkg' 的 UID, 请检查包名是否正确。"
        fi
      done
    else
      log "[警告] dumpsys 命令不可用, 无法处理应用白名单。"
    fi
  fi

  # 允许访问保留地址和私有地址, 不通过代理
  log "正在添加保留地址和私有地址白名单规则..."
  if [ -n "$INTRANET" ]; then
    for ip in $INTRANET; do
      iptables -w 100 -t mangle -A "$CHAIN_NAME" -d "$ip" -j RETURN
    done
  fi

  if [ -n "$INTRANET6" ] && [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    for ip in $INTRANET6; do
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -d "$ip" -j RETURN 2>/dev/null || true
    done
  fi

  log "正在添加 FakeIP 网段白名单规则..."
  # shellcheck disable=SC2046
  set -- $(extract_fakeip_ranges)
  fake4="$1"
  fake6="$2"
  if [ -n "$fake4" ]; then
    iptables -w 100 -t mangle -A "$CHAIN_NAME" -d "$fake4" -j RETURN
  fi
  if [ -n "$fake6" ] && [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -d "$fake6" -j RETURN 2>/dev/null || true
  fi

  # 忽略发往代理端口自身的流量
  log "正在添加代理端口白名单规则..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME" -p tcp --dport "$TPROXY_PORT" -j RETURN
  iptables -w 100 -t mangle -A "$CHAIN_NAME" -p udp --dport "$TPROXY_PORT" -j RETURN
  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -p tcp --dport "$TPROXY_PORT" -j RETURN 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -p udp --dport "$TPROXY_PORT" -j RETURN 2>/dev/null || true
  fi

  # 使用 ipset 匹配出站服务器 IP, 并将其 RETURN
  if command -v ipset >/dev/null 2>&1; then
    iptables -w 100 -t mangle -A "$CHAIN_NAME" -m set --match-set "$IPSET_V4" dst -j RETURN 2>/dev/null || true
    if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -m set --match-set "$IPSET_V6" dst -j RETURN 2>/dev/null || true
    fi
  fi

  # --- 核心 TPROXY 规则 ---
  # 将剩余的 TCP/UDP 流量重定向到 TPROXY 端口, 并打上 fwmark
  log "正在添加核心 TPROXY 规则..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK"
  iptables -w 100 -t mangle -A "$CHAIN_NAME" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK"

  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK" 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME}6" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK" 2>/dev/null || true
  fi

  # --- 应用规则链 ---
  # 将 PREROUTING 和 OUTPUT 链的流量导向我们自定义的链
  # PREROUTING 用于转发流量, OUTPUT 用于本机产生的流量
  # 使用 iptables-save 检查规则是否存在, 避免重复添加
  log "正在添加应用规则链..."
  
  # 为 IPv4 添加规则
  if ! iptables-save -t mangle | grep -q " -A PREROUTING -j $CHAIN_NAME"; then
    log "> 添加 IPv4 PREROUTING 规则"
    iptables -w 100 -t mangle -A PREROUTING -j "$CHAIN_NAME"
  fi
  if ! iptables-save -t mangle | grep -q " -A OUTPUT -j $CHAIN_NAME"; then
    log "> 添加 IPv4 OUTPUT 规则"
    iptables -w 100 -t mangle -A OUTPUT -j "$CHAIN_NAME"
  fi

  # 为 IPv6 添加规则（如果启用）
  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    if ! ip6tables-save -t mangle | grep -q " -A PREROUTING -j ${CHAIN_NAME}6"; then
      log "> 添加 IPv6 PREROUTING 规则"
      ip6tables -w 100 -t mangle -A PREROUTING -j "${CHAIN_NAME}6"
    fi
    if ! ip6tables-save -t mangle | grep -q " -A OUTPUT -j ${CHAIN_NAME}6"; then
      log "> 添加 IPv6 OUTPUT 规则"
      ip6tables -w 100 -t mangle -A OUTPUT -j "${CHAIN_NAME}6"
    fi
  fi
}

get_proxy_uid() {
    # 获取代理二进制文件的 UID。
    # 由于代理二进制文件不是标准的 Android 应用，因此它没有由系统分配的固定 UID。
    # 让代理二进制文件以特定的、非 root 的 UID 运行，并在 'settings.conf' 中设置该 UID 是至关重要的。
    # 例如，通过以下方式以 'shell' 用户 (UID 2000) 身份运行: su 2000 -c "..."

    # 1. 主要且推荐的方法：使用 settings.conf 中的 PROXY_UID。
    if [ -n "$PROXY_UID" ]; then
        log "使用来自 settings.conf 的代理 UID '$PROXY_UID'。"
        return
    fi

    # 2. 刷新时的备用方案：尝试从正在运行的进程中获取 UID。
    # 如果在代理已激活时重新运行此脚本，这可能会起作用。
    # shellcheck disable=SC2009
    _pid=$(pidof "$BIN_NAME")
    if [ -n "$_pid" ]; then
        PROXY_UID=$(stat -c "%u" "/proc/$_pid")
        log "从运行中的进程检测到代理 UID '$PROXY_UID'。请考虑在 settings.conf 中进行设置。"
        return
    fi

    # 3. 严重失败。
    log "致命错误：无法确定代理 UID。"
    log "请在设置中将 PROXY_UID 设置为代理二进制文件 ($BIN_NAME) 运行所使用的 UID。"
    log "例如：PROXY_UID=2000 (对于 shell 用户)"
    # 没有 UID 就无法继续，因为它会造成代理循环。
    PROXY_UID="" # 确保其为空
}

# "start" 命令的执行函数
do_start() {
  log "正在应用防火墙规则..."
  # get_proxy_uid
  if ! kernel_supports_tproxy; then
    log "- 内核不支持 TPROXY, 跳过规则应用"
    return 1
  fi
  create_ipsets
  setup_routes
  create_chains
  populate_outbound_ipsets
  add_whitelists_and_rules
  log "[start.rules.sh]: 防火墙规则已应用"
}

# "stop" 命令的执行函数
do_stop() {
  log "正在清除防火墙规则..."
  # 从 PREROUTING 和 OUTPUT 链中删除我们的规则
  iptables -w 100 -t mangle -D PREROUTING -j "$CHAIN_NAME" 2>/dev/null || true
  iptables -w 100 -t mangle -D OUTPUT -j "$CHAIN_NAME" 2>/dev/null || true
  # 清空并删除自定义链
  iptables -w 100 -t mangle -F "$CHAIN_NAME" 2>/dev/null || true
  iptables -w 100 -t mangle -X "$CHAIN_NAME" 2>/dev/null || true

  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip6tables -w 100 -t mangle -D PREROUTING -j "${CHAIN_NAME}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -X "${CHAIN_NAME}6" 2>/dev/null || true
  fi

  # 删除策略路由规则和路由表项
  ip rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
  ip route del local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" 2>/dev/null || true

  if [ "$IPV6" = "true" ] && ip -6 route show >/dev/null 2>&1; then
    ip -6 rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 route del local ::/0 dev lo table "$ROUTE_TABLE" 2>/dev/null || true
  fi

  # 清空 ipset
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "$IPSET_V4" 2>/dev/null || true
    ipset flush "$IPSET_V6" 2>/dev/null || true
  fi

  log "[start.rules.sh]: 防火墙规则已清除"
}

# "refresh" 命令的执行函数
do_refresh() {
  log "正在刷新 ipSet ..."
  flush_ipsets
  populate_outbound_ipsets
  log "[start.rules.sh]: ipSet 已刷新"
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