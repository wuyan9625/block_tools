#!/bin/bash
# 修正 1: 移除 -e，避免因 DNS 解析失敗導致腳本中斷
set -u
set -o pipefail

ACTION="${1:-}"
SCRIPT_PATH="/usr/local/bin/cn-vm-egress-guard.sh"
# 你的 GitHub 下載連結
SELF_URL="https://raw.githubusercontent.com/wuyan9625/block_tools/main/setup.sh"

# ===== 資源連結 =====
CN_IPV4_URL="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
CN_IPV6_URL="https://ruleset.skk.moe/Clash/ip/china_ip_ipv6.txt"
P2P_TRACKER_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt"
BILI_URL="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/bilibili"

# ===== IPSET 設定 =====
CN4_SET="cn_block4"
CN6_SET="cn_block6"
P2P_SET="p2p_trackers"
BILI_SET="bili_allow"

# ===== 防火牆鏈名稱 =====
CHAIN="VM_EGRESS_FILTER"

# ---------- 基礎檢查 ----------
if [[ "$ACTION" != "apply" && "$ACTION" != "update" ]]; then
  echo "Usage: $0 {apply|update}"
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
tmpname() { echo "${1}_tmp_$$"; }

# ---------- 依賴安裝 ----------
if ! need_cmd ipset || ! need_cmd curl; then
  apt-get update && apt-get install -y ipset curl dnsutils
fi
if ! need_cmd iptables || ! need_cmd ip6tables; then
  apt-get update && apt-get install -y iptables
fi

# ---------- IPSET 初始化 ----------
ipset create -exist "$CN4_SET" hash:net family inet
ipset create -exist "$CN6_SET" hash:net family inet6
ipset create -exist "$P2P_SET" hash:ip  family inet
ipset create -exist "$BILI_SET" hash:ip  family inet

# ---------- 更新函數 ----------
update_set() {
  local url="$1" set="$2" type="$3" family="$4"
  local tmp="/tmp/${set}.txt"
  echo " -> 更新清單: $set ..."
  curl -fsSL "$url" -o "$tmp" || {
    echo "WARN: $set update failed, keep old data"
    return 0
  }

  local tset; tset=$(tmpname "$set")
  ipset create -exist "$tset" "hash:$type" family "$family"
  ipset flush "$tset"

  while read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    ipset add "$tset" "$line" -exist 2>/dev/null || true
  done < "$tmp"

  ipset swap "$tset" "$set"
  ipset destroy "$tset" 2>/dev/null || true
}

update_bili_whitelist() {
    echo " -> 解析 Bilibili 白名單 (來源: v2fly)..."
    local tmp_file="/tmp/bili_domains.txt"
    local tset; tset=$(tmpname "$BILI_SET")
    
    # 下載清單 (失敗不中斷)
    if ! curl -fsSL "$BILI_URL" | grep -vE "^#|include:|regexp:" | sed 's/full://g;s/domain://g' > "$tmp_file"; then
        echo "WARN: Bilibili list download failed."
        return
    fi

    ipset create -exist "$tset" hash:ip family inet
    ipset flush "$tset"

    # 修正 2: 增加容錯解析，防止腳本崩潰
    if [[ -s "$tmp_file" ]]; then
        while read -r domain; do
            [[ -z "$domain" ]] && continue
            for d in "$domain" "www.$domain" "api.$domain"; do
                # 使用 || true 強制忽略解析錯誤
                { getent ahostsv4 "$d" 2>/dev/null || true; } | awk '{print $1}' | sort -u | while read -r ip; do
                    ipset add "$tset" "$ip" -exist 2>/dev/null || true
                done
            done
        done < "$tmp_file"
    fi

    ipset swap "$tset" "$BILI_SET"
    ipset destroy "$tset" 2>/dev/null || true
    echo " -> Bilibili 白名單解析完成"
}

do_update() {
  update_set "$CN_IPV4_URL" "$CN4_SET" net inet
  update_set "$CN_IPV6_URL" "$CN6_SET" net inet6
  update_set "$P2P_TRACKER_URL" "$P2P_SET" ip inet
  update_bili_whitelist
  echo "OK: 所有 ipset 更新完成"
}

# ---------- 防火牆規則 ----------
apply_fw() {
  iptables  -N "$CHAIN" 2>/dev/null || true
  ip6tables -N "$CHAIN" 2>/dev/null || true
  iptables  -F "$CHAIN"
  ip6tables -F "$CHAIN"

  iptables -C FORWARD -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
    || iptables -I FORWARD 1 -m conntrack --ctstate NEW -j "$CHAIN"
  ip6tables -C FORWARD -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
    || ip6tables -I FORWARD 1 -m conntrack --ctstate NEW -j "$CHAIN"

  # 1. 放行 Bilibili
  iptables -A "$CHAIN" -m set --match-set "$BILI_SET" dst -j RETURN
  # 2. 阻斷 P2P
  iptables -A "$CHAIN" -m set --match-set "$P2P_SET" dst -j DROP
  # 3. 阻斷 CN
  iptables -A "$CHAIN" -m set --match-set "$CN4_SET" dst -j DROP
  ip6tables -A "$CHAIN" -m set --match-set "$CN6_SET" dst -j DROP
  # 4. 其他放行
  iptables  -A "$CHAIN" -j RETURN
  ip6tables -A "$CHAIN" -j RETURN

  echo "OK: 防火牆規則已應用 (B站優先放行)"
}

install_self() {
  echo "Installing script to $SCRIPT_PATH..."
  if curl -fsSL "$SELF_URL" -o "$SCRIPT_PATH"; then
      chmod +x "$SCRIPT_PATH"
      (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH update"; \
       echo "0 3 * * * $SCRIPT_PATH update > /dev/null 2>&1") | crontab -
      echo "OK: 腳本已安裝並設定自動更新"
  else
      echo "WARN: 腳本下載失敗，請檢查 URL"
  fi
}

if [[ "$ACTION" == "apply" ]]; then
  do_update
  apply_fw
  install_self
  echo "Done: 策略已啟用"
else
  do_update
fi
