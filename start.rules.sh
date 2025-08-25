#!/system/bin/sh
#
# start.rules.sh
# - 完整的 tproxy 启动脚本（支持 ipset 管理 outbound servers、IPv6、UDP TPROXY、fakeip 配置解析）
# - 用法： start.rules.sh start|stop|refresh
#
set -e

MODDIR=${MAGISK_MODULE_DIR:-/data/adb/modules/transparent-singbox}
CONFIG="$MODDIR/config.json"
LOGFILE="$MODDIR/transparent-singbox.log"

# tproxy port (应与 config.json 的 tproxy inbound.listen_port 保持一致)
TPROXY_PORT=1536
MARK=0x1
ROUTE_TABLE=100

# ipset 名称
IPSET_V4="singbox_outbounds_v4"
IPSET_V6="singbox_outbounds_v6"

log() {
  echo "[$(date +'%F %T')] $*" >> "$LOGFILE"
}

# 简单主机解析函数（best-effort）
resolve_ips() {
  host="$1"
  # returns lines: ipv4 or ipv6
  if [ -z "$host" ]; then
    return 1
  fi
  # try getent (both v4 and v6)
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | uniq
    return 0
  fi

  # try host/dig/nslookup
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$host" 2>/dev/null
    dig +short AAAA "$host" 2>/dev/null
    return 0
  fi

  if command -v host >/dev/null 2>&1; then
    host "$host" 2>/dev/null | awk '/has address/ {print $4} /has IPv6 address/ {print $5}'
    return 0
  fi

  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2}'
    return 0
  fi

  # fallback to ping (ipv4)
  if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
    ping -c 1 -W 1 "$host" 2>/dev/null | sed -n '1p' | grep -oE '\([0-9.]+\)' | tr -d '()'
  fi
  return 0
}

# Extract fakeip ranges from config.json (best-effort)
extract_fakeip_ranges() {
  FAIR4=""
  FAIR6=""
  if [ -f "$CONFIG" ]; then
    FAIR4=$(grep -oP '"inet4_range"\s*:\s*"\K[^"]+' "$CONFIG" || true)
    FAIR6=$(grep -oP '"inet6_range"\s*:\s*"\K[^"]+' "$CONFIG" || true)
  fi
  echo "$FAIR4" "$FAIR6"
}

# Extract all "server" hostnames from config.json
extract_servers() {
  if [ ! -f "$CONFIG" ]; then
    return 0
  fi
  # find "server": "..." occurrences
  grep -oP '"server"\s*:\s*"\K[^"]+' "$CONFIG" | sort -u || true
}

create_ipsets() {
  # Create or ensure ipsets exist
  if command -v ipset >/dev/null 2>&1; then
    # IPv4
    ipset create $IPSET_V4 hash:ip family inet -exist >/dev/null 2>&1 || true
    # IPv6
    ipset create $IPSET_V6 hash:ip family inet6 -exist >/dev/null 2>&1 || true
  else
    log "ipset not available; outbound IPs will be added directly to iptables (less efficient)"
  fi
}

flush_ipsets() {
  if command -v ipset >/dev/null 2>&1; then
    ipset flush $IPSET_V4 2>/dev/null || true
    ipset flush $IPSET_V6 2>/dev/null || true
  fi
}

populate_outbound_ipsets() {
  create_ipsets
  flush_ipsets

  # Add fixed local networks to ipset to be safe (optional)
  if command -v ipset >/dev/null 2>&1; then
    # (not necessary, kept for clarity)
    :
  fi

  # parse servers and add to ipset
  extract_servers | while read -r host; do
    if [ -z "$host" ]; then
      continue
    fi
    # skip plain IPs (will add directly to iptables/ipset)
    if echo "$host" | grep -qE '^[0-9]+\.'; then
      if command -v ipset >/dev/null 2>&1; then
        ipset add $IPSET_V4 "$host" -exist 2>/dev/null || true
      else
        iptables -t mangle -I SINGBOX 1 -d "$host" -j RETURN 2>/dev/null || true
      fi
      continue
    fi

    for ip in $(resolve_ips "$host"); do
      if echo "$ip" | grep -q ":"; then
        # IPv6
        if command -v ipset >/dev/null 2>&1; then
          ipset add $IPSET_V6 "$ip" -exist 2>/dev/null || true
        else
          ip6tables -t mangle -I SINGBOX6 1 -d "$ip" -j RETURN 2>/dev/null || true
        fi
      else
        # IPv4
        if command -v ipset >/dev/null 2>&1; then
          ipset add $IPSET_V4 "$ip" -exist 2>/dev/null || true
        else
          iptables -t mangle -I SINGBOX 1 -d "$ip" -j RETURN 2>/dev/null || true
        fi
      fi
    done
  done
}

setup_routes() {
  # IPv4
  ip route add local 0.0.0.0/0 dev lo table $ROUTE_TABLE 2>/dev/null || true
  ip rule add fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true

  # IPv6
  if ip -6 route show >/dev/null 2>&1; then
    ip -6 route add local ::/0 dev lo table $ROUTE_TABLE 2>/dev/null || true
    ip -6 rule add fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true
  fi
}

create_chains() {
  # IPv4 chain
  iptables -t mangle -N SINGBOX 2>/dev/null || true
  iptables -t mangle -F SINGBOX 2>/dev/null || true

  # IPv6 chain
  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -N SINGBOX6 2>/dev/null || true
    ip6tables -t mangle -F SINGBOX6 2>/dev/null || true
  fi
}

add_whitelists_and_rules() {
  # default whitelists for IPv4
  iptables -t mangle -A SINGBOX -d 127.0.0.0/8 -j RETURN
  iptables -t mangle -A SINGBOX -d 10.0.0.0/8 -j RETURN
  iptables -t mangle -A SINGBOX -d 192.168.0.0/16 -j RETURN
  iptables -t mangle -A SINGBOX -d 172.16.0.0/12 -j RETURN
  iptables -t mangle -A SINGBOX -d 169.254.0.0/16 -j RETURN
  iptables -t mangle -A SINGBOX -d 224.0.0.0/4 -j RETURN

  # IPv6 whitelists
  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -A SINGBOX6 -d ::1/128 -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A SINGBOX6 -d fc00::/18 -j RETURN 2>/dev/null || true
  fi

  # exclude fakeip ranges parsed from config
  set -- $(extract_fakeip_ranges)
  FAKE4="$1"
  FAKE6="$2"
  if [ -n "$FAKE4" ]; then
    iptables -t mangle -A SINGBOX -d "$FAKE4" -j RETURN
  fi
  if [ -n "$FAKE6" ]; then
    ip6tables -t mangle -A SINGBOX6 -d "$FAKE6" -j RETURN 2>/dev/null || true
  fi

  # exclude module/listening ports (avoid capturing sing-box's own inbound)
  iptables -t mangle -A SINGBOX -p tcp --dport $TPROXY_PORT -j RETURN
  iptables -t mangle -A SINGBOX -p udp --dport $TPROXY_PORT -j RETURN
  iptables -t mangle -A SINGBOX -p udp --dport 53 -j RETURN
  iptables -t mangle -A SINGBOX -p tcp --dport 53 -j RETURN

  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -A SINGBOX6 -p tcp --dport $TPROXY_PORT -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A SINGBOX6 -p udp --dport $TPROXY_PORT -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A SINGBOX6 -p udp --dport 53 -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A SINGBOX6 -p tcp --dport 53 -j RETURN 2>/dev/null || true
  fi

  # use ipset whitelist (if exists)
  if command -v ipset >/dev/null 2>&1; then
    iptables -t mangle -A SINGBOX -m set --match-set $IPSET_V4 dst -j RETURN 2>/dev/null || true
    if ip -6 route show >/dev/null 2>&1; then
      ip6tables -t mangle -A SINGBOX6 -m set --match-set $IPSET_V6 dst -j RETURN 2>/dev/null || true
    fi
  fi

  # finally, mark and tproxy (tcp + udp) IPv4
  iptables -t mangle -A SINGBOX -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK/$MARK
  iptables -t mangle -A SINGBOX -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK/$MARK

  # IPv6 tproxy if supported
  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -A SINGBOX6 -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK/$MARK 2>/dev/null || true
    ip6tables -t mangle -A SINGBOX6 -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK/$MARK 2>/dev/null || true
  fi

  # attach chains to PREROUTING (if not exist)
  iptables -t mangle -C PREROUTING -j SINGBOX 2>/dev/null || iptables -t mangle -A PREROUTING -j SINGBOX
  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -C PREROUTING -j SINGBOX6 2>/dev/null || ip6tables -t mangle -A PREROUTING -j SINGBOX6
  fi
}

do_start() {
  log "start.rules.sh: start"

  create_ipsets
  setup_routes
  create_chains

  # populate ipset with outbound servers (best-effort)
  populate_outbound_ipsets

  add_whitelists_and_rules

  log "start.rules.sh: rules applied"
}

do_stop() {
  log "start.rules.sh: stop"

  # detach chains
  iptables -t mangle -D PREROUTING -j SINGBOX 2>/dev/null || true
  iptables -t mangle -F SINGBOX 2>/dev/null || true
  iptables -t mangle -X SINGBOX 2>/dev/null || true

  if ip -6 route show >/dev/null 2>&1; then
    ip6tables -t mangle -D PREROUTING -j SINGBOX6 2>/dev/null || true
    ip6tables -t mangle -F SINGBOX6 2>/dev/null || true
    ip6tables -t mangle -X SINGBOX6 2>/dev/null || true
  fi

  # remove ip rules/routes
  ip rule del fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true
  ip route del local 0.0.0.0/0 dev lo table $ROUTE_TABLE 2>/dev/null || true

  if ip -6 route show >/dev/null 2>&1; then
    ip -6 rule del fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true
    ip -6 route del local ::/0 dev lo table $ROUTE_TABLE 2>/dev/null || true
  fi

  # flush ipsets (keep names)
  if command -v ipset >/dev/null 2>&1; then
    ipset flush $IPSET_V4 2>/dev/null || true
    ipset flush $IPSET_V6 2>/dev/null || true
  fi

  log "start.rules.sh: stopped"
}

do_refresh() {
  # 重解析 config.json 中的服务器并刷新 ipset（在 network 变化时可被调用）
  log "start.rules.sh: refresh ipset"
  populate_outbound_ipsets
  log "start.rules.sh: refresh done"
}

case "$1" in
  start)
    do_start
    ;;
  stop)
    do_stop
    ;;
  refresh)
    do_refresh
    ;;
  *)
    echo "Usage: $0 {start|stop|refresh}"
    ;;
esac

exit 0