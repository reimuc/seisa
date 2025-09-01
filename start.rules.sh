#!/system/bin/sh
#
# ==============================================================================
# start.rules.sh - 透明代理 iptables 规则管理脚本
# ==============================================================================
#
# ## 功能:
# - 创建和管理 iptables TPROXY 规则，用于实现透明代理。
# - 支持 IPv4 和 IPv6。
# - 使用 ipset 优化性能，将出站服务器 IP 加入白名单，避免代理回环。
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
  log "未检测到 TProxy 端口, 使用默认值: $TPROXY_PORT"
fi

# 封装 common.sh 中的 resolve_ips 函数，便于在此脚本中调用
resolve_ips_bin() { resolve_ips "$1"; }

# 从 sing-box 配置文件中提取 FakeIP 网段
# FakeIP 用于为无 IP 的域名分配一个虚构的 IP 地址，便于 DNS 管理
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
# ipset 可以高效地存储和匹配大量 IP 地址，性能远高于逐条 iptables 规则
create_ipsets() {
  if command -v ipset >/dev/null 2>&1; then
    # 创建 IPv4 ipset，如果已存在则忽略
    ipset create "$IPSET_V4" hash:ip family inet -exist >/dev/null 2>&1 || true
    # 创建 IPv6 ipset
    ipset create "$IPSET_V6" hash:ip family inet6 -exist >/dev/null 2>&1 || true
  else
    log "ipset 命令不可用，性能可能会受影响"
  fi
}

# 清空 ipset 集合中的所有条目
flush_ipsets() {
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "$IPSET_V4" 2>/dev/null || true
    ipset flush "$IPSET_V6" 2>/dev/null || true
  fi
}

# 填充出站服务器 IP 到 ipset
# 这是为了防止代理服务器自身的流量被再次送入代理，造成循环
populate_outbound_ipsets() {
  create_ipsets
  flush_ipsets

  # 解析配置文件中的出站服务器地址并添加到 ipset
  if [ -f "$CONFIG" ]; then
    # 提取所有 "server" 字段的值，去重
    awk -F'"' '/"server"/ {print $4}' "$CONFIG" | sort -u | while read -r host; do
      [ -z "$host" ] && continue
      # 如果是 IP 地址，直接添加
      if echo "$host" | grep -qE '^[0-9]+\.'; then
        if command -v ipset >/dev/null 2>&1; then
          ipset add "$IPSET_V4" "$host" -exist 2>/dev/null || true
        else
          # 如果 ipset 不可用，则回退到使用 iptables RETURN 规则
          iptables -t mangle -I "$CHAIN_NAME" 1 -d "$host" -j RETURN 2>/dev/null || true
        fi
        continue
      fi
      # 如果是域名，解析成 IP 再添加
      for ip in $(resolve_ips_bin "$host"); do
        if echo "$ip" | grep -q ":"; then # IPv6
          if command -v ipset >/dev/null 2>&1; then
            ipset add "$IPSET_V6" "$ip" -exist 2>/dev/null || true
          else
            ip6tables -t mangle -I "${CHAIN_NAME}6" 1 -d "$ip" -j RETURN 2>/dev/null || true
          fi
        else # IPv4
          if command -v ipset >/dev/null 2>&1; then
            ipset add "$IPSET_V4" "$ip" -exist 2>/dev/null || true
          else
            iptables -t mangle -I "$CHAIN_NAME" 1 -d "$ip" -j RETURN 2>/dev/null || true
          fi
        fi
      done
    done
  fi
}

# 设置策略路由
# 将带有特定 fwmark 的数据包路由到指定的路由表，该表将所有流量导向本地（lo），由 TPROXY 处理
setup_routes() {
  # 为 IPv4 设置路由规则
  ip route add local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" 2>/dev/null || true
  ip rule add fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true

  # 如果系统支持 IPv6，则同样设置
  if ip -6 route show >/dev/null 2>&1; then
    ip -6 route add local ::/0 dev lo table "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 rule add fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
  fi
}

# 创建自定义的 iptables 链
create_chains() {
  # 为 IPv4 创建自定义链
  iptables -t mangle -N "$CHAIN_NAME" 2>/dev/null || true
  iptables -t mangle -F "$CHAIN_NAME" 2>/dev/null || true

  # 如果支持 IPv6，则创建对应的 IPv6 链
  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -N "${CHAIN_NAME}6" 2>/dev/null || true
    ip6tables -t mangle -F "${CHAIN_NAME}6" 2>/dev/null || true
  fi
}

# 添加白名单和核心 TPROXY 规则
add_whitelists_and_rules() {
  # --- 白名单规则 (RETURN) ---
  # 允许访问保留地址和私有地址，不通过代理
  iptables -t mangle -A "$CHAIN_NAME" -d 127.0.0.0/8 -j RETURN
  iptables -t mangle -A "$CHAIN_NAME" -d 10.0.0.0/8 -j RETURN
  iptables -t mangle -A "$CHAIN_NAME" -d 192.168.0.0/16 -j RETURN
  iptables -t mangle -A "$CHAIN_NAME" -d 172.16.0.0/12 -j RETURN
  iptables -t mangle -A "$CHAIN_NAME" -d 169.254.0.0/16 -j RETURN
  iptables -t mangle -A "$CHAIN_NAME" -d 224.0.0.0/4 -j RETURN # 组播地址

  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -A "${CHAIN_NAME}6" -d ::1/128 -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "${CHAIN_NAME}6" -d fc00::/18 -j RETURN 2>/dev/null || true # ULA
  fi

  # 将 FakeIP 网段加入白名单，避免 DNS 查询结果被代理
  set -- $(extract_fakeip_ranges)
  fake4="$1"
  fake6="$2"
  if [ -n "$fake4" ]; then
    iptables -t mangle -A "$CHAIN_NAME" -d "$fake4" -j RETURN
  fi
  if [ -n "$fake6" ]; then
    ip6tables -t mangle -A "${CHAIN_NAME}6" -d "$fake6" -j RETURN 2>/dev/null || true
  fi

  # 忽略发往代理端口自身的流量
  iptables -t mangle -A "$CHAIN_NAME" -p tcp --dport "$TPROXY_PORT" -j RETURN
  iptables -t mangle -A "$CHAIN_NAME" -p udp --dport "$TPROXY_PORT" -j RETURN
  # 忽略 DNS 查询流量（通常由 sing-box 内部处理）
  iptables -t mangle -A "$CHAIN_NAME" -p udp --dport 53 -j RETURN
  iptables -t mangle -A "$CHAIN_NAME" -p tcp --dport 53 -j RETURN

  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -A "${CHAIN_NAME}6" -p tcp --dport "$TPROXY_PORT" -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "${CHAIN_NAME}6" -p udp --dport "$TPROXY_PORT" -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "${CHAIN_NAME}6" -p udp --dport 53 -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "${CHAIN_NAME}6" -p tcp --dport 53 -j RETURN 2>/dev/null || true
  fi

  # 使用 ipset 匹配出站服务器 IP，并将其 RETURN
  if command -v ipset >/dev/null 2>&1; then
    iptables -t mangle -A "$CHAIN_NAME" -m set --match-set "$IPSET_V4" dst -j RETURN 2>/dev/null || true
    if ip -6 route show >/dev/null 2>&1; then
      ip6tables -t mangle -A "${CHAIN_NAME}6" -m set --match-set "$IPSET_V6" dst -j RETURN 2>/dev/null || true
    fi
  fi

  # --- 核心 TPROXY 规则 ---
  # 将剩余的 TCP/UDP 流量重定向到 TPROXY 端口，并打上 fwmark
  # shellcheck disable=SC2086
  iptables -t mangle -A "$CHAIN_NAME" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/$MARK
  iptables -t mangle -A "$CHAIN_NAME" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK"

  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -A "${CHAIN_NAME}6" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK" 2>/dev/null || true
    ip6tables -t mangle -A "${CHAIN_NAME}6" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK" 2>/dev/null || true
  fi

  # --- 应用规则链 ---
  # 将 PREROUTING 链的流量导向我们自定义的链
  # 使用 -C 检查规则是否存在，避免重复添加
  iptables -t mangle -C PREROUTING -j "$CHAIN_NAME" 2>/dev/null || iptables -t mangle -A PREROUTING -j "$CHAIN_NAME"
  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -C PREROUTING -j "${CHAIN_NAME}6" 2>/dev/null || ip6tables -t mangle -A PREROUTING -j "${CHAIN_NAME}6"
  fi
}

# "start" 命令的执行函数
do_start() {
  log "[start.rules.sh]: 应用规则..."
  if ! kernel_supports_tproxy; then
    log "[start.rules.sh]: 内核不支持 TPROXY，跳过规则应用。"
    return 1
  fi
  create_ipsets
  setup_routes
  create_chains
  populate_outbound_ipsets
  add_whitelists_and_rules
  log "[start.rules.sh]: 规则已应用"
}

# "stop" 命令的执行函数
do_stop() {
  log "[start.rules.sh]: 清除规则..."
  # 从 PREROUTING 链中删除我们的规则
  iptables -t mangle -D PREROUTING -j "$CHAIN_NAME" 2>/dev/null || true
  # 清空并删除自定义链
  iptables -t mangle -F "$CHAIN_NAME" 2>/dev/null || true
  iptables -t mangle -X "$CHAIN_NAME" 2>/dev/null || true

  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -D PREROUTING -j "${CHAIN_NAME}6" 2>/dev/null || true
    ip6tables -t mangle -F "${CHAIN_NAME}6" 2>/dev/null || true
    ip6tables -t mangle -X "${CHAIN_NAME}6" 2>/dev/null || true
  fi

  # 删除策略路由规则和路由表项
  ip rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
  ip route del local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" 2>/dev/null || true

  if ip -6 route show >/dev/null 2>&1; then
    ip -6 rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 route del local ::/0 dev lo table "$ROUTE_TABLE" 2>/dev/null || true
  fi

  # 清空 ipset
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "$IPSET_V4" 2>/dev/null || true
    ipset flush "$IPSET_V6" 2>/dev/null || true
  fi

  log "[start.rules.sh]: 规则已清除"
}

# "refresh" 命令的执行函数
do_refresh() {
  log "[start.rules.sh]: 刷新 ipset ..."
  populate_outbound_ipsets
  log "[start.rules.sh]: ipset 已刷新"
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