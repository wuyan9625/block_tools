#!/bin/bash
# ==============================================================================
# 腳本名稱：PVE/Debian 阻斷大陸流量一鍵安裝包 (Bilibili 自動更新版)
# 說明：此腳本會自動安裝依賴、部署核心邏輯、寫入 Systemd 服務檔並設定開機自啟。
# ==============================================================================

# 0. 權限檢查
if [ "$EUID" -ne 0 ]; then
  echo "❌ 錯誤：請使用 root 權限執行此腳本 (sudo -i)"
  exit 1
fi

echo "🚀 開始部署 Block CN 策略 (含 Bilibili 自動白名單)..."

# 1. 安裝必要套件
if ! command -v ipset &> /dev/null; then
    echo "📦 正在安裝 ipset / curl / dnsutils..."
    apt-get update -qq && apt-get install -y -qq ipset curl dnsutils
fi

# 2. 寫入核心邏輯腳本 (寫入到 /usr/local/bin/block_cn.sh)
# 注意：這裡使用 EOF 來寫入文件
cat << 'EOF' > /usr/local/bin/block_cn.sh
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- 變數定義 ---
CN_IP_URL="http://www.ipdeny.com/ipblocks/data/countries/cn.zone"
BILI_RULE_URL="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/bilibili"

# --- 初始化 ipset ---
ipset create -exist cn_block hash:net
ipset create -exist bilibili_whitelist hash:ip

# --- (A) 更新大陸 IP ---
curl -sL "$CN_IP_URL" -o /tmp/cn.zone
if [ -s /tmp/cn.zone ]; then
    ipset flush cn_block
    while read -r net; do ipset add cn_block "$net" -exist; done < /tmp/cn.zone
fi

# --- (B) 更新 Bilibili 白名單 (從 v2fly 社群清單) ---
ipset flush bilibili_whitelist
curl -sL "$BILI_RULE_URL" | grep -vE "^#|include:" > /tmp/bilibili_domains_raw.txt

if [ -s /tmp/bilibili_domains_raw.txt ]; then
    while read -r domain; do
        # 自動補全常見前綴以覆蓋 CDN
        for prefix in "" "www." "api." "upos-sz-mirrorali."; do
             target="$prefix$domain"
             getent ahostsv4 "$target" | awk '{print $1}' | sort -u | while read -r ip; do
                 ipset add bilibili_whitelist "$ip" -exist
             done
        done
    done < /tmp/bilibili_domains_raw.txt
fi

# --- (C) 配置 iptables (安全鏈模式) ---
CHAIN_NAME="BLOCK_CN_OUT"
iptables -N $CHAIN_NAME 2>/dev/null
iptables -F $CHAIN_NAME
if ! iptables -C FORWARD -j $CHAIN_NAME 2>/dev/null; then iptables -I FORWARD 1 -j $CHAIN_NAME; fi

# --- (D) 規則寫入 ---
# 1. 放行回程與內網
iptables -A $CHAIN_NAME -m state --state ESTABLISHED,RELATED -j RETURN
iptables -A $CHAIN_NAME -s 127.0.0.0/8 -j RETURN
iptables -A $CHAIN_NAME -s 10.0.0.0/8 -j RETURN
iptables -A $CHAIN_NAME -d 10.0.0.0/8 -j RETURN
iptables -A $CHAIN_NAME -s 172.16.0.0/12 -j RETURN
iptables -A $CHAIN_NAME -d 172.16.0.0/12 -j RETURN
iptables -A $CHAIN_NAME -s 192.168.0.0/16 -j RETURN
iptables -A $CHAIN_NAME -d 192.168.0.0/16 -j RETURN
iptables -A $CHAIN_NAME -s 100.64.0.0/10 -j RETURN
iptables -A $CHAIN_NAME -d 100.64.0.0/10 -j RETURN
# 2. 放行 DNS
iptables -A $CHAIN_NAME -p udp --dport 53 -j RETURN
iptables -A $CHAIN_NAME -p tcp --dport 53 -j RETURN
# 3. 放行 B站
iptables -A $CHAIN_NAME -m set --match-set bilibili_whitelist dst -j RETURN
# 4. 阻斷其他 CN IP
iptables -A $CHAIN_NAME -m set --match-set cn_block dst -j LOG --log-prefix "BLOCK_CN_OUT: " --log-level 4
iptables -A $CHAIN_NAME -m set --match-set cn_block dst -j DROP
# 5. 預設放行
iptables -A $CHAIN_NAME -j RETURN
EOF

chmod +x /usr/local/bin/block_cn.sh
echo "✅ 核心腳本已寫入 /usr/local/bin/block_cn.sh"

# 3. 寫入 Systemd 服務檔 (寫入到 /etc/systemd/system/block_cn.service)
cat << 'EOF' > /etc/systemd/system/block_cn.service
[Unit]
Description=Block Outgoing Traffic to China
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/block_cn.sh
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
echo "✅ 服務檔已寫入 /etc/systemd/system/block_cn.service"

# 4. 設定每日自動更新 (Crontab)
(crontab -l 2>/dev/null | grep -v "block_cn.sh"; echo "0 4 * * * /usr/local/bin/block_cn.sh > /dev/null 2>&1") | crontab -
echo "✅ 自動更新排程已設定 (每日 04:00)"

# 5. 啟動服務
systemctl daemon-reload
systemctl enable --now block_cn.service

echo "========================================================"
echo "🎉 部署完成！"
echo "狀態檢查："
systemctl status block_cn.service --no-pager | grep Active
echo "========================================================"
