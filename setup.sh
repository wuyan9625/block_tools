#!/bin/bash
# =========================================================
# Block-FW | PVE 自動化出站防火牆 (全域修復版 v2)
# =========================================================

# --- 設定區 ---
SCRIPT_NAME="block-fw"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
DATA_DIR="/var/lib/block-fw"

# --- 你的 GitHub 腳本網址 (用於自我安裝) ---
# 這是修復菜單打不開的關鍵，必須指向你自己的 raw 網址
MY_GITHUB_URL="https://raw.githubusercontent.com/wuyan9625/block_tools/main/setup.sh"

# --- 外部清單來源 (已更換為 GitHub Mirror 穩定源) ---
URL_CN="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
URL_MALWARE="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"
# 更換為 GitHub Mirror 避免 404
URL_P2P="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/iblocklist_level1.netset"

# --- 本地暫存檔 ---
FILE_COMBINED="$DATA_DIR/blocked_combined.list"
IPSET_NAME="fachost_block"
RULE_COMMENT="block-fw"

# --- 顏色 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 檢查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}錯誤：請使用 root 權限執行${PLAIN}"
   exit 1
fi

mkdir -p "$DATA_DIR"

# =======================
# 核心功能
# =======================

# 下載並整合所有清單
fetch_rules() {
    echo -e "${YELLOW}[*] 正在同步清單 (CN + P2P + Malware)...${PLAIN}"
    
    # 建立暫存檔
    > "${FILE_COMBINED}.tmp"

    # 1. 下載 CN IP
    echo -e " -> 下載 CN IP..."
    curl -fsSL "$URL_CN" >> "${FILE_COMBINED}.tmp"

    # 2. 下載 P2P & Malware
    echo -e " -> 下載 P2P 與 惡意 IP..."
    curl -fsSL "$URL_MALWARE" >> "${FILE_COMBINED}.tmp"
    curl -fsSL "$URL_P2P" >> "${FILE_COMBINED}.tmp"
    
    if [ -s "${FILE_COMBINED}.tmp" ]; then
        # 過濾處理：移除註解、空行、私有 IP (避免誤殺內網)
        # 這裡會過濾掉 10.x, 192.168.x, 172.16-31.x, 127.x
        grep -vE "^#|^$|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\." "${FILE_COMBINED}.tmp" > "$FILE_COMBINED"
        rm "${FILE_COMBINED}.tmp"
        echo -e "${GREEN} -> 規則整合完成 (已包含 CN 強制封鎖)${PLAIN}"
    else
        echo -e "${RED} [!] 清單下載失敗，保留舊檔${PLAIN}"
    fi
}

apply_rules() {
    local block_inbound="$1" # yes/no

    if [ ! -f "$FILE_COMBINED" ]; then
        echo -e "${RED}找不到規則檔案，請先執行更新${PLAIN}"
        return
    fi

    echo -e "${YELLOW}[*] 正在載入 IPSET (請稍候)...${PLAIN}"
    ipset create "$IPSET_NAME" hash:net -exist
    ipset flush "$IPSET_NAME"
    # 使用 -exist 靜音重複 IP 的警告
    ipset restore -exist < <(sed "s/^/add $IPSET_NAME /" "$FILE_COMBINED")

    echo -e "${YELLOW}[*] 設定 iptables 全域規則...${PLAIN}"

    # 1. 強力清除舊規則
    iptables-save | grep "$RULE_COMMENT" | sed 's/^-A/-D/' | while read -r line; do
        iptables $line 2>/dev/null
    done
    # 雙重保險
    iptables -D FORWARD -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    iptables -D FORWARD -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true

    # 2. 【強制】封鎖出站 (Forward 到黑名單 IP)
    iptables -I FORWARD -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT"
    
    # 3. 【可選】封鎖入站 (黑名單 IP 連入)
    if [[ "$block_inbound" == "yes" ]]; then
        iptables -I FORWARD -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT"
        echo -e "${GREEN} -> [出站+入站] 全域防護已生效${PLAIN}"
    else
        echo -e "${GREEN} -> [僅出站] 全域防護已生效 (允許 CN 連入)${PLAIN}"
    fi
}

setup_cron() {
    local block_inbound="$1"
    local cron_cmd="0 4 * * * $INSTALL_PATH update $block_inbound > /dev/null 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME"; echo "$cron_cmd") | crontab -
    echo -e "${GREEN}[*] 已設定每日 04:00 自動更新${PLAIN}"
}

install_self() {
    echo -e "${YELLOW}[*] 正在安裝腳本至系統...${PLAIN}"
    # 【關鍵修復】從 GitHub 下載自身，而不是複製 $0
    curl -fsSL "$MY_GITHUB_URL" -o "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}[OK] 安裝完成！輸入 block-fw 即可喚出選單${PLAIN}"
}

uninstall() {
    echo -e "${YELLOW}正在移除規則...${PLAIN}"
    iptables-save | grep "$RULE_COMMENT" | sed 's/^-A/-D/' | while read -r line; do
        iptables $line 2>/dev/null
    done
    
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
    rm -rf "$DATA_DIR"
    rm -f "$INSTALL_PATH"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab -
    echo -e "${GREEN}防護已完全移除${PLAIN}"
}

stats() {
    echo "=== 攔截封包統計 (Global) ==="
    echo "DST match = 攔截 VM 訪問外部 (出站)"
    echo "SRC match = 攔截 外部 訪問 VM (入站)"
    iptables -L FORWARD -v -n | grep "$RULE_COMMENT"
    echo -e "\n=== IPSET 條目數 ==="
    ipset list "$IPSET_NAME" | grep "Number of entries"
}

# =======================
# 主流程
# =======================

# Cron 自動更新模式
if [[ "$1" == "update" ]]; then
    block_inbound=${2:-no}
    fetch_rules
    apply_rules "$block_inbound"
    exit 0
fi

clear
echo -e "==========================================="
echo -e " Block-FW | PVE 防火牆 (全域修復版 v2)"
echo -e "==========================================="
echo -e " 1. 部署防護 (修復 404 及 菜單失效問題)"
echo -e " 2. 查看統計"
echo -e " 3. 手動更新清單"
echo -e " 4. 移除防護"
echo -e " 0. 離開"
echo -e "==========================================="
read -p "選項: " opt

case "$opt" in
    1)
        install_self
        
        echo -e "\n${YELLOW}關於流量方向設定：${PLAIN}"
        echo -e "1. ${GREEN}出站 (Outbound)${PLAIN}: VM -> CN/P2P。 ${RED}[強制封鎖]${PLAIN}"
        
        read -p "是否也要封鎖【入站 (Inbound)】流量? [y/N]: " in_opt
        if [[ "$in_opt" == "y" || "$in_opt" == "Y" ]]; then
            block_inbound="yes"
        else
            block_inbound="no"
        fi
        
        fetch_rules
        apply_rules "$block_inbound"
        setup_cron "$block_inbound"
        ;;
    2)
        stats
        ;;
    3)
        fetch_rules
        echo -e "${GREEN}清單已下載，請重新部署以套用。${PLAIN}"
        ;;
    4)
        uninstall
        ;;
    0)
        exit 0
        ;;
    *)
        echo "無效選項"
        ;;
esac
