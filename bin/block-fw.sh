#!/bin/bash
set -euo pipefail

CONF="/etc/block-fw/conf/options.conf"
DATA="/etc/block-fw/data"

source "$CONF"

ACTION="${1:-apply}"

CHAIN="VM_EGRESS_FILTER"

CN4_SET="cn_block4"
CN6_SET="cn_block6"
P2P_SET="p2p_trackers"

CN_IPV4_URL="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
CN_IPV6_URL="https://ruleset.skk.moe/Clash/ip/china_ip_ipv6.txt"
P2P_TRACKER_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

for c in iptables ip6tables ipset curl; do
  need_cmd "$c" || { echo "缺少指令: $c"; exit 1; }
done

ipset create -exist "$CN4_SET" hash:net family inet
ipset create -exist "$CN6_SET" hash:net family inet6
ipset create -exist "$P2P_SET" hash:net family inet

update_set() {
  local url="$1" set="$2" family="$3"
  local tmp="/tmp/${set}.txt"
  curl -fsSL "$url" -o "$tmp" || return 0

  local tset="${set}_tmp"
  ipset create -exist "$tset" hash:net family "$family"
  ipset flush "$tset"

  while read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    ipset add "$tset" "$line" -exist 2>/dev/null || true
  done < "$tmp"

  ipset swap "$tset" "$set"
  ipset destroy "$tset" 2>/dev/null || true
}

do_update() {
  [[ "$ENABLE_CN_BLOCK" == "1" ]] && {
    update_set "$CN_IPV4_URL" "$CN4_SET" inet
    update_set "$CN_IPV6_URL" "$CN6_SET" inet6
  }
  [[ "$ENABLE_P2P_BLOCK" == "1" ]] && {
    update_set "$P2P_TRACKER_URL" "$P2P_SET" inet
  }
}

apply_fw() {
  iptables -N "$CHAIN" 2>/dev/null || true
  ip6tables -N "$CHAIN" 2>/dev/null || true
  iptables -F "$CHAIN"
  ip6tables -F "$CHAIN"

  if [[ "$BRIDGE_MODE" == "all" ]]; then
    iptables -C FORWARD -i vmbr+ -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
      || iptables -I FORWARD 1 -i vmbr+ -m conntrack --ctstate NEW -j "$CHAIN"
  else
    for br in "${VM_BRIDGES[@]}"; do
      iptables -C FORWARD -i "$br" -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
        || iptables -I FORWARD 1 -i "$br" -m conntrack --ctstate NEW -j "$CHAIN"
    done
  fi

  [[ "$ENABLE_TW_BANK_SNI" == "1" ]] && {
    while read -r sni; do
      [[ -z "$sni" || "$sni" =~ ^# ]] && continue
      iptables -A "$CHAIN" -p tcp --dport 443 -m tls --tls-host "$sni" -j DROP
    done < "$DATA/tw_bank_sni.txt"
  }

  [[ "$ENABLE_P2P_BLOCK" == "1" ]] && {
    iptables -A "$CHAIN" -m set --match-set "$P2P_SET" dst -j DROP
  }

  [[ "$ENABLE_BT_PORT_BLOCK" == "1" ]] && {
    while read -r p; do
      iptables -A "$CHAIN" -p tcp --dport "$p" -j DROP
      iptables -A "$CHAIN" -p udp --dport "$p" -j DROP
    done < "$DATA/bt_ports.txt"
  }

  [[ "$ENABLE_CN_BLOCK" == "1" ]] && {
    iptables  -A "$CHAIN" -m set --match-set "$CN4_SET" dst -j DROP
    ip6tables -A "$CHAIN" -m set --match-set "$CN6_SET" dst -j DROP
  }

  iptables  -A "$CHAIN" -j RETURN
  ip6tables -A "$CHAIN" -j RETURN
}

case "$ACTION" in
  apply)
    do_update
    apply_fw
    ;;
  update)
    do_update
    ;;
  *)
    echo "Usage: block-fw {apply|update}"
    exit 1
    ;;
esac
