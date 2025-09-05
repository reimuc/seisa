#!/system/bin/sh
# =====================================================================
# 🔥 start.rules.sh - 透明代理 iptables 规则管理脚本
# ---------------------------------------------------------------------
# 管理并应用透明代理所需的 iptables 规则, 支持 IPv4/IPv6、TPROXY、ipset 优化及动态提取配置
# - 自动创建/清理自定义链与路由
# - 动态提取 FakeIP 网段与出站服务器地址
# - 支持 ipset 白名单, 防止代理回环
# - 兼容多种内核与环境
# =====================================================================

# 严格模式和错误处理
set -e
trap '[ $? -ne 0 ] && abort_safe "⛔ 脚本执行失败: $?"' EXIT

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

# --- 全局变量定义 ---
CHAIN_NAME_PRE=${CHAIN_NAME_PRE:-"${CHAIN_NAME}_PRE"}
CHAIN_NAME_OUT=${CHAIN_NAME_OUT:-"${CHAIN_NAME}_OUT"}

log_safe "❤️=== [start.rules] ===❤️"
log_safe "📬 规则应用, 接受参数 $1"

# --- 动态端口检测 ---
detect_tproxy_port() {
  port_from_config=$( (
    if [ -f "$CONFIG" ]; then
      awk '/"type": "tproxy"/,/"}/' "$CONFIG" | grep '"listen_port"' | grep -o '[0-9]*'
    fi
  ) )

  if [ -n "$port_from_config" ]; then
    log_safe "🕹️ 检测到 TProxy 端口: $port_from_config"
    TPROXY_PORT=$port_from_config
  else
    log_safe "❗ 未检测到 TProxy 端口, 使用默认值: $TPROXY_PORT"
  fi
}

# --- FakeIP 网段提取 ---
extract_fakeip_ranges() {
  fair4="" fair6=""
  if [ -f "$CONFIG" ]; then
    fair4=$(grep '"inet4_range"' "$CONFIG" | cut -d'"' -f4 || true)
    fair6=$(grep '"inet6_range"' "$CONFIG" | cut -d'"' -f4 || true)
  fi
  echo "$fair4" "$fair6"
}

# --- ipset 管理函数 ---
create_ipsets() {
  log_safe "📦 正在创建 ipSets 集合..."
  if command -v ipset >/dev/null 2>&1; then
    ipset create "$IPSET_V4" hash:ip family inet -exist >/dev/null 2>&1 || true
    ipset create "$IPSET_V6" hash:ip family inet6 -exist >/dev/null 2>&1 || true
  else
    log_safe "❗ ipSets 命令不可用, 性能可能会受影响"
  fi
}

flush_ipsets() {
  log_safe "🗑️ 正在清空 ipSets 集合..."
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "$IPSET_V4" 2>/dev/null || true
    ipset flush "$IPSET_V6" 2>/dev/null || true
  fi
}

# --- 路由设置 ---
setup_routes() {
  log_safe "🗺️ 正在设置策略路由..."
  ip route add local default dev lo table "$ROUTE_TABLE" 2>/dev/null || true
  ip rule add fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true

  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip -6 route add local default dev lo table "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 rule add fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
  fi
}

# --- iptables 链管理 ---
create_chains() {
  log_safe "🔗 正在创建自定义 iptables 链..."
  iptables -w 100 -t mangle -N "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -F "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -N "$CHAIN_NAME_OUT" 2>/dev/null || true
  iptables -w 100 -t mangle -F "$CHAIN_NAME_OUT" 2>/dev/null || true

  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip6tables -w 100 -t mangle -N "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -N "${CHAIN_NAME_OUT}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_OUT}6" 2>/dev/null || true
  fi
}

# --- 出站服务器管理 ---
populate_outbound_ipsets() {
  log_safe "➕ 正在填充出站服务器 IP..."
  if [ ! -f "$CONFIG" ]; then
    log_safe "❗ 配置文件不存在: $CONFIG"
    return 0
  fi

  awk 'BEGIN{in_obj=has_server=has_uuid=has_password=0;server_val=""} \
       /\{/ {in_obj++} \
       /\}/ {if(in_obj>0){if(has_server&&(has_uuid||has_password))print server_val;has_server=has_uuid=has_password=0;server_val="";in_obj--}} \
       /"server"[[:space:]]*:/ {if(match($0,/"server"[[:space:]]*:[[:space:]]*"([^"]+)"/,m)){has_server=1;server_val=m[1]}} \
       /"uuid"[[:space:]]*:/ {has_uuid=1} \
       /"password"[[:space:]]*:/ {has_password=1}' "$CONFIG" | sort -u | while read -r host; do
    [ -z "$host" ] && continue
    log_safe "🔍 正在处理出站服务器: $host"

    case "$host" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*)
        add_to_ipset "v4" "$host"
        ;;
      *:*)
        [ "$IPV6_SUPPORT" = "1" ] && add_to_ipset "v6" "$host"
        ;;
      *)
        for ip in $(resolve_ips "$host"); do
          log_safe "🪩 解析到的出站服务器: $ip"
          case "$ip" in
            *:*)
              [ "$IPV6_SUPPORT" = "1" ] && add_to_ipset "v6" "$ip"
              ;;
            *)
              add_to_ipset "v4" "$ip"
              ;;
          esac
        done
        ;;
    esac
  done
}

# --- 辅助函数 ---
add_to_ipset() {
  version="$1" ip="$2"
  ipset_name="" chain_name=""

  if [ "$version" = "v4" ]; then
    ipset_name="$IPSET_V4"
    chain_name="$CHAIN_NAME_PRE"
  else
    ipset_name="$IPSET_V6"
    chain_name="${CHAIN_NAME_PRE}6"
  fi

  if command -v ipset >/dev/null 2>&1; then
    ipset add "$ipset_name" "$ip" -exist 2>/dev/null || true
  else
    if [ "$version" = "v4" ]; then
      iptables -w 100 -t mangle -I "$chain_name" 1 -d "$ip" -j RETURN 2>/dev/null || true
    else
      ip6tables -w 100 -t mangle -I "$chain_name" 1 -d "$ip" -j RETURN 2>/dev/null || true
    fi
  fi
}

# --- 规则应用函数 ---
add_whitelists_and_rules() {
  log_safe "🛡️ 正在添加白名单规则..."

  # 1. 内网白名单
  add_intranet_rules

  # 2. FakeIP 白名单
  add_fakeip_rules

  # 3. ipset 白名单
  add_ipset_rules

  # 4. 本机流量白名单
  add_local_rules

  # 5. DNS 规则
  add_dns_rules

  # 6. 应用代理规则
  add_app_rules

  # 7. 核心 TPROXY 规则
  add_core_tproxy_rules

  # 8. 应用规则链
  apply_rule_chains
}

# --- 子规则函数 ---
add_intranet_rules() {
  log_safe "🏠 添加内网白名单..."
  if [ -n "$INTRANET" ]; then
    for ip in $INTRANET; do
      iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -d "$ip" -j RETURN
    done
  fi
  if [ "$IPV6_SUPPORT" = "1" ] && [ -n "$INTRANET6" ]; then
    for ip in $INTRANET6; do
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -d "$ip" -j RETURN 2>/dev/null || true
    done
  fi
}

add_fakeip_rules() {
  log_safe "👻 添加 FakeIP 白名单..."
  # shellcheck disable=SC2046
  set -- $(extract_fakeip_ranges)
  fake4="$1" fake6="$2"

  if [ -n "$fake4" ]; then
    iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -d "$fake4" -j RETURN
  fi
  if [ "$IPV6_SUPPORT" = "1" ] && [ -n "$fake6" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -d "$fake6" -j RETURN 2>/dev/null || true
  fi
}

add_ipset_rules() {
  if command -v ipset >/dev/null 2>&1; then
    log_safe "📬 添加 ipset 出站白名单..."
    iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -m set --match-set "$IPSET_V4" dst -j RETURN
    if [ "$IPV6_SUPPORT" = "1" ]; then
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -m set --match-set "$IPSET_V6" dst -j RETURN 2>/dev/null || true
    fi
  fi
}

add_local_rules() {
  log_safe "🔌 添加 socket 白名单..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m socket -j RETURN
  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m socket -j RETURN 2>/dev/null || true
  fi

  if [ -n "$PROXY_UID" ]; then
    log_safe "👤 添加代理 UID ($PROXY_UID) 白名单..."
    iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m owner --uid-owner "$PROXY_UID" -j RETURN
    if [ "$IPV6_SUPPORT" = "1" ]; then
      ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m owner --uid-owner "$PROXY_UID" -j RETURN 2>/dev/null || true
    fi
  fi
}

add_dns_rules() {
  log_safe "🪩 正在添加 DNS 重定向规则..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -p udp --dport 53 -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK"
  iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p udp --dport 53 -j MARK --set-mark "$MARK"
  iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p tcp --dport 53 -j MARK --set-mark "$MARK"
  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -p udp --dport 53 -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"/"$MARK" 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p udp --dport 53 -j MARK --set-mark "$MARK" 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p tcp --dport 53 -j MARK --set-mark "$MARK" 2>/dev/null || true
  fi
}

add_app_rules() {
  if ! command -v dumpsys >/dev/null 2>&1; then
    log_safe "❗ [警告] dumpsys 命令不可用, 将对本机所有流量应用代理"
    add_global_proxy_rules
    return
  fi

  case "$PROXY_MODE" in
    whitelist)
      add_whitelist_rules
      ;;
    blacklist)
      add_blacklist_rules
      ;;
    *)
      add_global_proxy_rules
      ;;
  esac
}

add_whitelist_rules() {
  log_safe "📱 应用白名单代理模式..."
  if [ -z "$WHITELIST_APPS" ]; then
    log_safe "❗ 应用白名单为空, 除 DNS 外, 本机流量将不通过代理"
    return
  fi

  for app_pkg in $WHITELIST_APPS; do
    uid=$(dumpsys package "$app_pkg" 2>/dev/null | grep 'userId=' | cut -d'=' -f2)
    if [ -n "$uid" ]; then
      log_safe "⚪️ 将应用 '$app_pkg' (UID: $uid) 加入白名单 (代理)"
      iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m owner --uid-owner "$uid" -j MARK --set-mark "$MARK"
      if [ "$IPV6_SUPPORT" = "1" ]; then
        ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m owner --uid-owner "$uid" -j MARK --set-mark "$MARK" 2>/dev/null || true
      fi
    else
      log_safe "❌ [警告] 无法找到应用 '$app_pkg' 的 UID"
    fi
  done
}

add_blacklist_rules() {
  log_safe "📱 应用黑名单代理模式..."
  if [ -n "$BLACKLIST_APPS" ]; then
    for app_pkg in $BLACKLIST_APPS; do
      uid=$(dumpsys package "$app_pkg" 2>/dev/null | grep 'userId=' | cut -d'=' -f2)
      if [ -n "$uid" ]; then
        log_safe "⚫️ 将应用 '$app_pkg' (UID: $uid) 加入黑名单 (不代理)"
        iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -m owner --uid-owner "$uid" -j RETURN
        if [ "$IPV6_SUPPORT" = "1" ]; then
          ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
        fi
      else
        log_safe "❗ [警告] 无法找到应用 '$app_pkg' 的 UID"
      fi
    done
  fi
  add_global_proxy_rules
}

add_global_proxy_rules() {
  log_safe "🔥 应用全局代理模式..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p tcp -j MARK --set-mark "$MARK"
  iptables -w 100 -t mangle -A "$CHAIN_NAME_OUT" -p udp -j MARK --set-mark "$MARK"
  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p tcp -j MARK --set-mark "$MARK" 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_OUT}6" -p udp -j MARK --set-mark "$MARK" 2>/dev/null || true
  fi
}

add_core_tproxy_rules() {
  log_safe "🔥 正在添加核心 TPROXY 规则..."
  iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
  iptables -w 100 -t mangle -A "$CHAIN_NAME_PRE" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK" 2>/dev/null || true
    ip6tables -w 100 -t mangle -A "${CHAIN_NAME_PRE}6" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK" 2>/dev/null || true
  fi
}

apply_rule_chains() {
  log_safe "✅ 正在应用规则链..."

  if ! iptables -t mangle -C PREROUTING -j "$CHAIN_NAME_PRE" 2>/dev/null; then
    iptables -w 100 -t mangle -A PREROUTING -j "$CHAIN_NAME_PRE"
  fi

  if ! iptables -t mangle -C OUTPUT -j "$CHAIN_NAME_OUT" 2>/dev/null; then
    iptables -w 100 -t mangle -A OUTPUT -j "$CHAIN_NAME_OUT" 2>/dev/null \
    || iptables -w 100 -t mangle -I connmark_mangle_OUTPUT 1 -j "$CHAIN_NAME_OUT" 2>/dev/null \
    || iptables -w 100 -t mangle -I qcom_NWMGR 1 -j "$CHAIN_NAME_OUT" 2>/dev/null \
    || { log_safe "❌ 无法挂接 OUTPUT→$CHAIN_NAME_OUT"; return 1; }
  fi

  if [ "$IPV6_SUPPORT" = "1" ]; then
    if ! ip6tables -t mangle -C PREROUTING -j "${CHAIN_NAME_PRE}6" 2>/dev/null; then
      ip6tables -w 100 -t mangle -A PREROUTING -j "${CHAIN_NAME_PRE}6"
    fi
    if ! ip6tables -t mangle -C OUTPUT -j "${CHAIN_NAME_OUT}6" 2>/dev/null; then
      ip6tables -w 100 -t mangle -A OUTPUT -j "${CHAIN_NAME_OUT}6" 2>/dev/null \
      || ip6tables -w 100 -t mangle -I connmark_mangle_OUTPUT 1 -j "${CHAIN_NAME_OUT}6" 2>/dev/null \
      || ip6tables -w 100 -t mangle -I qcom_NWMGR 1 -j "${CHAIN_NAME_OUT}6" 2>/dev/null \
      || { log_safe "❌ 无法挂接 OUTPUT→${CHAIN_NAME_OUT}6"; return 1; }
    fi
  fi
}

# --- 主要功能函数 ---
do_start() {
  log_safe "🚀 正在应用防火墙规则..."
  detect_tproxy_port
  create_ipsets
  setup_routes
  create_chains
  populate_outbound_ipsets
  add_whitelists_and_rules
  log_safe "✅ 防火墙规则已应用"
}

do_stop() {
  log_safe "🛑 正在清除防火墙规则..."

  # 清理 iptables 规则
  while iptables -t mangle -C PREROUTING -j "$CHAIN_NAME_PRE" 2>/dev/null; do
    iptables -w 100 -t mangle -D PREROUTING -j "$CHAIN_NAME_PRE" 2>/dev/null || true
  done
  while iptables -t mangle -C OUTPUT -j "$CHAIN_NAME_OUT" 2>/dev/null; do
    iptables -w 100 -t mangle -D OUTPUT -j "$CHAIN_NAME_OUT" 2>/dev/null || true
  done

  iptables -w 100 -t mangle -F "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -X "$CHAIN_NAME_PRE" 2>/dev/null || true
  iptables -w 100 -t mangle -F "$CHAIN_NAME_OUT" 2>/dev/null || true
  iptables -w 100 -t mangle -X "$CHAIN_NAME_OUT" 2>/dev/null || true

  if [ "$IPV6_SUPPORT" = "1" ]; then
    while ip6tables -t mangle -C PREROUTING -j "${CHAIN_NAME_PRE}6" 2>/dev/null; do
      ip6tables -w 100 -t mangle -D PREROUTING -j "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    done
    while ip6tables -t mangle -C OUTPUT -j "${CHAIN_NAME_OUT}6" 2>/dev/null; do
      ip6tables -w 100 -t mangle -D OUTPUT -j "${CHAIN_NAME_OUT}6" 2>/dev/null || true
    done

    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -X "${CHAIN_NAME_PRE}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -F "${CHAIN_NAME_OUT}6" 2>/dev/null || true
    ip6tables -w 100 -t mangle -X "${CHAIN_NAME_OUT}6" 2>/dev/null || true
  fi

  # 清理路由规则
  ip rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
  ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip -6 rule del fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null || true
    ip -6 route flush table "$ROUTE_TABLE" 2>/dev/null || true
  fi

  # 清理 ipset
  flush_ipsets

  log_safe "✅ 防火墙规则已清除"
}

do_refresh() {
  log_safe "🔄 正在刷新 ipSets ..."
  flush_ipsets
  populate_outbound_ipsets
  log_safe "✅ ipSets 刷新完成"
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