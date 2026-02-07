#!/bin/bash
set -u

# ================= 配置與變數 =================
BASE_DIR="/usr/local/block-tools"
CONF_FILE="$BASE_DIR/conf/options.conf"
DATA_DIR="$BASE_DIR/data"

# 確保設定檔存在
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    echo "錯誤: 找不到設定檔 $CONF_FILE"
    exit 1
fi

CHAIN="VM_EGRESS_FILTER"
CN4_SET="cn_block4"
CN6_SET="cn_block6"
P2P_SET="p2p_trackers"

CN_IPV4_URL="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
CN_IPV6_URL="https://ruleset.skk.moe/Clash/ip/china_ip_ipv6.txt"
P2P_TRACKER_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt"

# ================= 核心功能函數 =================

check_root() {
    [[ $EUID -ne 0 ]] && { echo "請用 root 執行"; exit 1; }
}

update_set() {
    local url="$1" set="$2" family="$3"
    local tmp="/tmp/${set}.txt"
    echo "正在更新 ipset: $set ..."
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
    echo "規則庫更新完成。"
}

apply_fw() {
    echo "正在套用防火牆規則..."
    # 初始化 Chain
    iptables -N "$CHAIN" 2>/dev/null || true
    ip6tables -N "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN"
    ip6tables -F "$CHAIN"

    # 綁定網橋 (Bridge Hook)
    if [[ "$BRIDGE_MODE" == "all" ]]; then
        iptables -C FORWARD -i vmbr+ -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
          || iptables -I FORWARD 1 -i vmbr+ -m conntrack --ctstate NEW -j "$CHAIN"
    else
        # 讀取陣列，處理特定網橋
        for br in "${VM_BRIDGES[@]}"; do
            iptables -C FORWARD -i "$br" -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
              || iptables -I FORWARD 1 -i "$br" -m conntrack --ctstate NEW -j "$CHAIN"
        done
    fi

    # SNI 阻擋 (銀行/支付)
    if [[ "$ENABLE_TW_BANK_SNI" == "1" ]]; then
        if [ -f "$DATA_DIR/tw_bank_sni.txt" ]; then
            while read -r sni; do
                [[ -z "$sni" || "$sni" =~ ^# ]] && continue
                # 嘗試使用 xt_tls，如果失敗則警告
                iptables -A "$CHAIN" -p tcp --dport 443 -m tls --tls-host "$sni" -j DROP 2>/dev/null \
                || echo "警告: 無法套用 SNI 阻擋 ($sni)，請檢查 xt_tls 模組是否載入"
            done < "$DATA_DIR/tw_bank_sni.txt"
        fi
    fi

    # P2P 阻擋
    [[ "$ENABLE_P2P_BLOCK" == "1" ]] && {
        ipset create -exist "$P2P_SET" hash:net family inet
        iptables -A "$CHAIN" -m set --match-set "$P2P_SET" dst -j DROP
    }

    # BT Port 阻擋
    if [[ "$ENABLE_BT_PORT_BLOCK" == "1" ]] && [ -f "$DATA_DIR/bt_ports.txt" ]; then
        while read -r p; do
            [[ -z "$p" ]] && continue
            iptables -A "$CHAIN" -p tcp --dport "$p" -j DROP
            iptables -A "$CHAIN" -p udp --dport "$p" -j DROP
        done < "$DATA_DIR/bt_ports.txt"
    fi

    # CN IP 阻擋
    [[ "$ENABLE_CN_BLOCK" == "1" ]] && {
        ipset create -exist "$CN4_SET" hash:net family inet
        ipset create -exist "$CN6_SET" hash:net family inet6
        iptables  -A "$CHAIN" -m set --match-set "$CN4_SET" dst -j DROP
        ip6tables -A "$CHAIN" -m set --match-set "$CN6_SET" dst -j DROP
    }

    # 放行其他
    iptables  -A "$CHAIN" -j RETURN
    ip6tables -A "$CHAIN" -j RETURN
    echo "防火牆規則已生效。"
}

flush_fw() {
    echo "清除防火牆規則..."
    iptables -D FORWARD -j "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true
    echo "已清除。"
}

# ================= 設定與選單功能 =================

configure_bridges() {
    clear
    echo "=== 網橋設定模式 ==="
    echo "目前系統網橋："
    ip -o link show type bridge | awk -F': ' '{print $2}'
    echo "-------------------"
    echo "1) 監控【所有網橋】 (vmbr+)"
    echo "2) 監控【指定網橋】"
    read -rp "請選擇 [1-2]: " choice
    
    case "$choice" in
        1)
            sed -i 's/^BRIDGE_MODE=.*/BRIDGE_MODE="all"/' "$CONF_FILE"
            sed -i 's/^VM_BRIDGES=.*/VM_BRIDGES=()/' "$CONF_FILE"
            echo "已設定為：所有網橋"
            ;;
        2)
            read -rp "請輸入網橋名稱 (空白分隔，例: vmbr0 vmbr1): " input_bridges
            sed -i 's/^BRIDGE_MODE=.*/BRIDGE_MODE="specific"/' "$CONF_FILE"
            sed -i "s/^VM_BRIDGES=.*/VM_BRIDGES=($input_bridges)/" "$CONF_FILE"
            echo "已設定為：$input_bridges"
            ;;
        *) echo "無效選項"; sleep 1 ;;
    esac
    # 重新載入設定
    source "$CONF_FILE"
}

show_menu() {
    while true; do
        clear
        echo "========================================"
        echo "   Fachost Block Tools v2.0 (Proxmox)   "
        echo "========================================"
        echo "目前模式: $BRIDGE_MODE"
        echo "監控網橋: ${VM_BRIDGES[*]}"
        echo "----------------------------------------"
        echo "1. 啟動防護 (Apply Rules)"
        echo "2. 更新規則庫 (Update Lists)"
        echo "3. 清除規則 (Flush)"
        echo "4. 設定網橋監控範圍"
        echo "5. 查看 iptables 狀態"
        echo "0. 退出"
        echo "========================================"
        read -rp "請輸入選項: " opt
        
        case "$opt" in
            1) apply_fw; read -rp "按 Enter 繼續..." ;;
            2) do_update; read -rp "按 Enter 繼續..." ;;
            3) flush_fw; read -rp "按 Enter 繼續..." ;;
            4) configure_bridges ;;
            5) iptables -L "$CHAIN" -v -n | head -n 20; read -rp "按 Enter 繼續..." ;;
            0) exit 0 ;;
            *) echo "無效選項"; sleep 1 ;;
        esac
    done
}

# ================= 主程式入口 =================

check_root

# 如果有參數，執行 CLI 模式 (給 systemd 或排程用)
if [ -n "${1:-}" ]; then
    case "$1" in
        apply) apply_fw ;;
        update) do_update ;;
        flush) flush_fw ;;
        *) echo "Usage: block-fw {apply|update|flush}" ;;
    esac
else
    # 沒有參數，進入選單模式
    show_menu
fi
