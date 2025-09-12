#!/system/bin/sh
# =====================================================================
# 🔥 start.rules.sh - 透明代理 iptables 规则管理脚本
# ---------------------------------------------------------------------
# 管理并应用透明代理所需的 iptables 规则, 支持 IPv4/IPv6、TPROXY 优化及动态提取配置
# - 自动创建/清理自定义链与路由
# - 动态提取 FakeIP 网段与出站服务器地址
# - 兼容多种内核与环境
# =====================================================================

set -e

MODDIR=$(dirname "$0")
. "$MODDIR/common.sh"

# --- 全局变量定义 ---
MARK_ID=${MARK_ID:-"16777216/16777216"}
TABLE_ID=${TABLE_ID:-"2024"}
CHAIN_NAME=${CHAIN_NAME:-FIREFLY}
CHAIN_PRE=${CHAIN_PRE:-"${CHAIN_NAME}_PRE"}
CHAIN_OUT=${CHAIN_OUT:-"${CHAIN_NAME}_OUT"}
CHAIN_LAN=${CHAIN_LAN:-"${CHAIN_NAME}_LAN"}

log_safe "❤️ === [start.rules] === ❤️"

read -r USER_ID GROUP_ID <<EOF
  $(resolve_user_group "$TPROXY_USER")
EOF

# --- 相关参数检测 ---
detect_tproxy_params() {
  fair4="" fair6="" t_port=""
  if [ -f "$CONFIG" ]; then
    fair4=$(grep '"inet4_range"' "$CONFIG" | cut -d'"' -f4)
    fair6=$(grep '"inet6_range"' "$CONFIG" | cut -d'"' -f4)
    t_port=$(awk '/"type": "tproxy"/,/"}/' "$CONFIG" | grep '"listen_port"' | grep -o '[0-9]*')
  fi

  if [ -n "$fair4" ]; then
    log_safe "🕹️ 检测到 FakeIP 网段: $fair4"
    FAIR4="$fair4"
  fi

  if [ -n "$fair6" ]; then
    log_safe "🕹️ 检测到 FakeIP 网段: $fair6"
    FAIR6="$fair6"
  fi

  if [ -n "$t_port" ]; then
    log_safe "🕹️ 检测到 TProxy 端口: $t_port"
    TPROXY_PORT="$t_port"
  fi
}

# --- 路由设置 ---
setup_routes() {
  log_safe "🗺️ 正在设置策略路由..."

  ip route add local default dev lo table "$TABLE_ID" 2>/dev/null || true
  ip rule add fwmark "$MARK_ID" lookup "$TABLE_ID" pref "$TABLE_ID" 2>/dev/null || true

  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip -6 route add local default dev lo table "$TABLE_ID" 2>/dev/null || true
    ip -6 rule add fwmark "$MARK_ID" lookup "$TABLE_ID" pref "$TABLE_ID" 2>/dev/null || true
  fi
}

unset_routes() {
  log_safe "🗺️ 正在清除策略路由..."

  if [ "$IPV6_SUPPORT" = "1" ]; then
    ip -6 rule del fwmark "$MARK_ID" lookup "$TABLE_ID" pref "$TABLE_ID" 2>/dev/null || true
    ip -6 route flush table "$TABLE_ID" 2>/dev/null || true
  fi

  ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID" pref "$TABLE_ID" 2>/dev/null || true
  ip route flush table "$TABLE_ID" 2>/dev/null || true
}

# --- tproxy 规则函数 ---
add_tproxy_rules() {
  ip_cmd=${1:-iptables}

  log_safe "🚦 正在添加 $ip_cmd 规则..."

  log_safe "🔗 创建自定义 LAN 链..."
  $ip_cmd -w 100 -t mangle -N "$CHAIN_LAN" 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -F "$CHAIN_LAN" 2>/dev/null || true

  log_safe "🔗 创建自定义 PREROUTING 链..."
  $ip_cmd -w 100 -t mangle -N "$CHAIN_PRE" 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -F "$CHAIN_PRE" 2>/dev/null || true

  log_safe "🔌 标记透明代理接管流量..."
  $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p tcp -m socket --transparent -j MARK --set-xmark "$MARK_ID"
  $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p udp -m socket --transparent -j MARK --set-xmark "$MARK_ID"

  log_safe "🔌 放行本机原生 socket 流量..."
  $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -m socket -j RETURN

  log_safe "🪩 放行/重定向 DNS 流量..."
  if [ "$BIN_NAME" = "mihomo" ] || [ "$BIN_NAME" = "hysteria" ] || [ "$BIN_NAME" = "clash" ]; then
    $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p tcp --dport 53 -j RETURN
    $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p udp --dport 53 -j RETURN
  else
    $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p tcp --dport 53 -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK_ID"
    $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p udp --dport 53 -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK_ID"
  fi

  log_safe "🏠 放行内网 IP 流量..."
  if [ "$ip_cmd" = "iptables" ]; then
    for ip in $INTRANET; do
      $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -d "$ip" -j RETURN
    done
  else
    for ip in $INTRANET6; do
      $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -d "$ip" -j RETURN
    done
  fi

  log_safe "♻️ 重定向 lo 回环流量..."
  $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p tcp -i lo -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK_ID"
  $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p udp -i lo -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK_ID"

  if [ "$AP_LIST" != "" ]; then
    log_safe "📡 重定向 AP 接口流量"
    for ap in $AP_LIST; do
      $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p tcp -i "$ap" -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK_ID"
      $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -p udp -i "$ap" -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK_ID"
    done
  fi

  log_safe "🎟️ 应用至 PREROUTING 链..."
  $ip_cmd -w 100 -t mangle -A "$CHAIN_PRE" -j "$CHAIN_LAN"
  $ip_cmd -w 100 -t mangle -I PREROUTING -j "$CHAIN_PRE"

  log_safe "🔗 创建自定义 OUTPUT 链..."
  $ip_cmd -w 100 -t mangle -N "$CHAIN_OUT" 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -F "$CHAIN_OUT" 2>/dev/null || true

  if [ -n "$TPROXY_USER" ]; then
    log_safe "👤 放行 $TPROXY_USER 服务本身流量..."
    $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -m owner --uid-owner "$USER_ID" --gid-owner "$GROUP_ID" -j RETURN
  fi

  if [ "$IGNORE_LIST" != "" ]; then
    log_safe "🚫 放行忽略列表接口流量..."
    for ignore in $IGNORE_LIST; do
      $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -o "$ignore" -j RETURN
    done
  fi

  log_safe "🪩 放行/重定向 DNS 流量..."
  if [ "$BIN_NAME" = "mihomo" ] || [ "$BIN_NAME" = "hysteria" ] || [ "$BIN_NAME" = "clash" ]; then
    $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p tcp --dport 53 -j RETURN
    $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p udp --dport 53 -j RETURN
  else
    $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p tcp --dport 53 -j MARK --set-xmark "$MARK_ID"
    $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p udp --dport 53 -j MARK --set-xmark "$MARK_ID"
  fi

  log_safe "🏠 放行内网 IP 流量..."
  if [ "$ip_cmd" = "iptables" ]; then
    for ip in $INTRANET; do
      $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -d "$ip" -j RETURN
    done
  else
    for ip in $INTRANET6; do
      $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -d "$ip" -j RETURN
    done
  fi

  log_safe "💼 放行/重定向应用流量"
  add_app_rules "$ip_cmd"

  log_safe "🎟️ 应用至 OUTPUT 链..."
  $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -j "$CHAIN_LAN"
  $ip_cmd -w 100 -t mangle -I OUTPUT -j "$CHAIN_OUT"

  log_safe "🔗 创建及应用 DIVERT 链..."
  $ip_cmd -w 100 -t mangle -N DIVERT 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -F DIVERT 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -A DIVERT -j MARK --set-xmark "$MARK_ID"
  $ip_cmd -w 100 -t mangle -A DIVERT -j ACCEPT
  $ip_cmd -w 100 -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

  if [ -n "$TPROXY_USER" ]; then
    log_safe "👤 阻止本地服务访问 tproxy 端口..."
    if [ "$ip_cmd" = "iptables" ]; then
      $ip_cmd -w 100 -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "$USER_ID" --gid-owner "$GROUP_ID" -m tcp --dport "$TPROXY_PORT" -j REJECT
    else
      $ip_cmd -w 100 -A OUTPUT -d ::1 -p tcp -m owner --uid-owner "$USER_ID" --gid-owner "$GROUP_ID" -m tcp --dport "$TPROXY_PORT" -j REJECT
    fi
  fi

  if [ "$ip_cmd" = "ip6tables" ]; then
    log_safe "🗑️ 丢弃 IPV6 流量的 DND请求..."
    $ip_cmd -w 100 -A OUTPUT -p udp --dport 53 -j DROP
    $ip_cmd -w 100 -A OUTPUT -p tcp --dport 853 -j DROP
  fi

  if $ip_cmd -t nat -nL >/dev/null 2>&1; then
    if [ "$BIN_NAME" = "mihomo" ] || [ "$BIN_NAME" = "hysteria" ] || [ "$BIN_NAME" = "clash" ]; then
      log_safe "🚀 开启 clash 全局 DNS 模式..."

      $ip_cmd -w 100 -t nat -N CLASH_DNS_PRE 2>/dev/null || true
      $ip_cmd -w 100 -t nat -F CLASH_DNS_PRE 2>/dev/null || true
      $ip_cmd -w 100 -t nat -A CLASH_DNS_PRE -p udp --dport 53 -j REDIRECT --to-ports 1053
      $ip_cmd -w 100 -t nat -I PREROUTING -j CLASH_DNS_PRE

      $ip_cmd -w 100 -t nat -N CLASH_DNS_OUT 2>/dev/null || true
      $ip_cmd -w 100 -t nat -F CLASH_DNS_OUT 2>/dev/null || true
      $ip_cmd -w 100 -t nat -A CLASH_DNS_OUT -m owner --uid-owner "$USER_ID" --gid-owner "$GROUP_ID" -j RETURN
      $ip_cmd -w 100 -t nat -A CLASH_DNS_OUT -p udp --dport 53 -j REDIRECT --to-ports 1053
      $ip_cmd -w 100 -t nat -I OUTPUT -j CLASH_DNS_OUT
    fi

    log_safe "👻 修复 FakeIP ICMP..."

    if [ "$ip_cmd" = "iptables" ]; then
      $ip_cmd -w 100 -t nat -A OUTPUT -d "$FAIR4" -p icmp -j DNAT --to-destination 127.0.0.1
      $ip_cmd -w 100 -t nat -A PREROUTING -d "$FAIR4" -p icmp -j DNAT --to-destination 127.0.0.1
    else
      $ip_cmd -w 100 -t nat -A OUTPUT -d "$FAIR6" -p icmp -j DNAT --to-destination ::1
      $ip_cmd -w 100 -t nat -A PREROUTING -d "$FAIR6" -p icmp -j DNAT --to-destination ::1
    fi
  else
    log_safe "❗ $ip_cmd 不支持 NAT 表, 跳过"
  fi
}

add_app_rules() {
  ip_cmd=${1:-iptables}

  if ! command -v dumpsys >/dev/null 2>&1; then
    log_safe "❗ dumpsys 命令不可用, 将对本机所有流量应用代理"
    add_global_proxy_rules "$ip_cmd"
    return
  fi

  case "$PROXY_MODE" in
    whitelist)
      add_whitelist_rules "$ip_cmd"
      ;;
    blacklist)
      add_blacklist_rules "$ip_cmd"
      ;;
    *)
      add_global_proxy_rules "$ip_cmd"
      ;;
  esac
}

add_global_proxy_rules() {
  ip_cmd=${1:-iptables}

  log_safe "🔥 应用全局代理模式..."
  $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p tcp -j MARK --set-xmark "$MARK_ID"
  $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p udp -j MARK --set-xmark "$MARK_ID"
}

add_blacklist_rules() {
  ip_cmd=${1:-iptables}

  log_safe "📱 应用黑名单代理模式..."
  if [ -n "$APP_PACKAGES" ]; then
    for app_pkg in $APP_PACKAGES; do
      uid=$(dumpsys package "$app_pkg" 2>/dev/null | grep 'userId=' | cut -d'=' -f2)
      if [ -n "$uid" ]; then
        log_safe "⚫️ 将应用 '$app_pkg' (UID: $uid) 加入黑名单 (不代理)"
        $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -m owner --uid-owner "$uid" -j RETURN
      else
        log_safe "❗ [警告] 无法找到应用 '$app_pkg' 的 UID"
      fi
    done
  fi
  add_global_proxy_rules "$ip_cmd"
}

add_whitelist_rules() {
  ip_cmd=${1:-iptables}

  log_safe "📱 应用白名单代理模式..."
  if [ -z "$APP_PACKAGES" ]; then
    log_safe "❗ 应用白名单为空, 除 DNS 外, 本机流量将不通过代理"
    return
  fi

  for app_pkg in $APP_PACKAGES; do
    uid=$(dumpsys package "$app_pkg" 2>/dev/null | grep 'userId=' | cut -d'=' -f2)
    if [ -n "$uid" ]; then
      log_safe "⚪️ 将应用 '$app_pkg' (UID: $uid) 加入白名单 (代理)"
      $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p tcp -m owner --uid-owner "$uid" -j MARK --set-xmark "$MARK_ID"
      $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p udp -m owner --uid-owner "$uid" -j MARK --set-xmark "$MARK_ID"
    else
      log_safe "❌ [警告] 无法找到应用 '$app_pkg' 的 UID"
    fi
  done
  $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p tcp -m owner --uid-owner 0 -j MARK --set-xmark "$MARK_ID"
  $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p udp -m owner --uid-owner 0 -j MARK --set-xmark "$MARK_ID"
  $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p tcp -m owner --uid-owner 1052 -j MARK --set-xmark "$MARK_ID"
  $ip_cmd -w 100 -t mangle -A "$CHAIN_OUT" -p udp -m owner --uid-owner 1052 -j MARK --set-xmark "$MARK_ID"
}

# --- 系统关键服务 ---
add_system_rules() {
  log_safe "🔧 添加系统服务白名单..."

  # DHCP 服务
  iptables -w 100 -t mangle -A "$CHAIN_OUT" -p udp --sport 68 --dport 67 -j RETURN
  iptables -w 100 -t mangle -A "$CHAIN_OUT" -p udp --sport 67 --dport 68 -j RETURN
  # NTP 服务
  iptables -w 100 -t mangle -A "$CHAIN_OUT" -p udp --dport 123 -j RETURN
  # 多播地址
  iptables -w 100 -t mangle -A "$CHAIN_OUT" -d 224.0.0.0/4 -j RETURN

  if [ "$IPV6_SUPPORT" = "1" ]; then
    # IPv6 DHCP
    ip6tables -w 100 -t mangle -A "$CHAIN_OUT" -p udp --sport 546 --dport 547 -j RETURN
    ip6tables -w 100 -t mangle -A "$CHAIN_OUT" -p udp --sport 547 --dport 546 -j RETURN
    # IPv6 NTP
    ip6tables -w 100 -t mangle -A "$CHAIN_OUT" -p udp --dport 123 -j RETURN
    # IPv6 多播地址
    ip6tables -w 100 -t mangle -A "$CHAIN_OUT" -d ff00::/8 -j RETURN
  fi
}

remove_tproxy_rules() {
  ip_cmd=${1:-iptables}

  log_safe "正在删除 $ip_cmd 规则..."

  if [ "$ip_cmd" = "ip6tables" ]; then
    $ip_cmd -w 100 -D OUTPUT -p udp --dport 53 -j DROP
    $ip_cmd -w 100 -D OUTPUT -p tcp --dport 853 -j DROP
  fi

  $ip_cmd -w 100 -t mangle -D OUTPUT -j "$CHAIN_OUT" 2>/dev/null || true

  $ip_cmd -w 100 -t mangle -D PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -D PREROUTING -j "$CHAIN_PRE" 2>/dev/null || true

  $ip_cmd -w 100 -t mangle -F DIVERT 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -X DIVERT 2>/dev/null || true

  $ip_cmd -w 100 -t mangle -F "$CHAIN_OUT" 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -X "$CHAIN_OUT" 2>/dev/null || true

  $ip_cmd -w 100 -t mangle -F "$CHAIN_PRE" 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -X "$CHAIN_PRE" 2>/dev/null || true

  $ip_cmd -w 100 -t mangle -F "$CHAIN_LAN" 2>/dev/null || true
  $ip_cmd -w 100 -t mangle -X "$CHAIN_LAN" 2>/dev/null || true

  if [ -n "$TPROXY_USER" ]; then
    if [ "$ip_cmd" = "iptables" ]; then
      $ip_cmd -w 100 -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "$USER_ID" --gid-owner "$GROUP_ID" -m tcp --dport "$TPROXY_PORT" -j REJECT
      $ip_cmd -w 100 -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner 0 -m tcp --dport "$TPROXY_PORT" -j REJECT 2>/dev/null || true
    else
      $ip_cmd -w 100 -D OUTPUT -d ::1 -p tcp -m owner --uid-owner "$USER_ID" --gid-owner "$GROUP_ID" -m tcp --dport "$TPROXY_PORT" -j REJECT
      $ip_cmd -w 100 -D OUTPUT -d ::1 -p tcp -m owner --uid-owner 0 -m tcp --dport "$TPROXY_PORT" -j REJECT 2>/dev/null || true
    fi
  fi

  if $ip_cmd -t nat -nL >/dev/null 2>&1; then
    $ip_cmd -w 100 -t nat -D OUTPUT -j CLASH_DNS_OUT 2>/dev/null || true
    $ip_cmd -w 100 -t nat -D PREROUTING -j CLASH_DNS_PRE 2>/dev/null || true

    $ip_cmd -w 100 -t nat -F CLASH_DNS_OUT 2>/dev/null || true
    $ip_cmd -w 100 -t nat -X CLASH_DNS_OUT 2>/dev/null || true

    $ip_cmd -w 100 -t nat -F CLASH_DNS_PRE 2>/dev/null || true
    $ip_cmd -w 100 -t nat -X CLASH_DNS_PRE 2>/dev/null || true

    if [ "$ip_cmd" = "iptables" ]; then
      $ip_cmd -w 100 -t nat -D OUTPUT -d "$FAIR4" -p icmp -j DNAT --to-destination 127.0.0.1
      $ip_cmd -w 100 -t nat -D PREROUTING -d "$FAIR4" -p icmp -j DNAT --to-destination 127.0.0.1
    else
      $ip_cmd -w 100 -t nat -D OUTPUT -d "$FAIR6" -p icmp -j DNAT --to-destination ::1
      $ip_cmd -w 100 -t nat -D PREROUTING -d "$FAIR6" -p icmp -j DNAT --to-destination ::1
    fi
  fi
}

# --- 主要功能函数 ---
do_start() {
  log_safe "🚀 正在应用防火墙规则..."
  detect_tproxy_params
  setup_routes
  add_tproxy_rules
  if [ "$IPV6_SUPPORT" = "1" ]; then
    add_tproxy_rules ip6tables
  fi
  add_system_rules
  log_safe "✅ 防火墙规则已应用"
}

do_stop() {
  log_safe "🛑 正在清除防火墙规则..."
  remove_tproxy_rules
  if [ "$IPV6_SUPPORT" = "1" ]; then
    remove_tproxy_rules ip6tables
  fi
  unset_routes
  log_safe "✅ 防火墙规则已清除"
}

# --- 主逻辑 ---
case "$1" in
  stop) do_stop ;;
  *) do_start ;;
esac

exit 0