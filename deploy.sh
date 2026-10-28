#!/usr/bin/env bash
# ============================================================
# Xray VLESS + Reality 一键部署（固定出口 IP 优化版）
#
# 适用：Ubuntu 22.04 / 24.04、Debian 12（全新机器）
# 用法：bash deploy.sh
#
# 设计目标：
#   1. 出口 IP 永远只有一个 —— 单节点、单入站、单 IP
#   2. 抗封锁 —— Reality 不需要域名和证书，伪装成访问真实站点
#   3. 两人共用 —— 两个 UUID，可分别统计流量，出口 IP 相同
#   4. 关掉 IPv6 出口，避免客户端走 v6 导致"看起来 IP 变了"
# ============================================================
set -euo pipefail

PORT=443
DEST="www.microsoft.com:443"   # 伪装目标，必须支持 TLS1.3 + HTTP/2
SNI="www.microsoft.com"
XRAY_CONF="/usr/local/etc/xray/config.json"

green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

[[ $EUID -ne 0 ]] && { echo "请用 root 运行（sudo -i）"; exit 1; }

green "[1/6] 更新系统并安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates jq qrencode >/dev/null

green "[2/6] 开启 BBR（吞吐提升关键）"
if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
  cat >> /etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
fi
sysctl -p >/dev/null 2>&1 || true

# 强制 IPv4 优先出站：避免某些目标解析到 v6 后出口 IP 变成 IPv6
if ! grep -q "precedence ::ffff:0:0/96" /etc/gai.conf 2>/dev/null; then
  echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
fi

green "[3/6] 安装 Xray"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
XRAY_BIN="/usr/local/bin/xray"
[[ -x "$XRAY_BIN" ]] || { echo "Xray 安装失败"; exit 1; }

green "[4/6] 生成本机密钥与两个用户"
KEYS=$($XRAY_BIN x25519)
PRIV=$(echo "$KEYS" | awk -F': ' '/[Pp]rivate/{print $2}' | tr -d ' ')
PUB=$(echo "$KEYS"  | awk -F': ' '/[Pp]ublic/{print $2}'  | tr -d ' ')
UUID_A=$($XRAY_BIN uuid)
UUID_B=$($XRAY_BIN uuid)
SID=$(openssl rand -hex 8)
[[ -n "$PRIV" && -n "$PUB" ]] || { echo "密钥生成失败"; exit 1; }

green "[5/6] 写入配置"
mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID_A", "flow": "xtls-rprx-vision", "email": "user-a" },
          { "id": "$UUID_B", "flow": "xtls-rprx-vision", "email": "user-b" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIV",
          "shortIds": ["$SID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF

systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "Xray 启动失败，查看: journalctl -u xray -n 30"; exit 1; }

green "[6/6] 生成客户端链接"
VPS_IP=$(curl -s4 --max-time 10 https://api.ipify.org || curl -s4 --max-time 10 https://ifconfig.me || echo "")
[[ -n "$VPS_IP" ]] || { echo "无法获取公网 IP，请手动查看"; VPS_IP="<你的VPS_IP>"; }

mk_link() {
  local uuid="$1" tag="$2"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$uuid" "$VPS_IP" "$PORT" "$SNI" "$PUB" "$SID" "$tag"
}

LINK_A=$(mk_link "$UUID_A" "SG-A")
LINK_B=$(mk_link "$UUID_B" "SG-B")

echo ""
echo "============================================================"
green "部署完成"
echo "============================================================"
echo "VPS 固定出口 IP : $VPS_IP"
echo "端口            : $PORT (TCP)"
echo "伪装目标        : $SNI"
echo ""
echo "--- 你的链接（用户 A）---"
echo "$LINK_A"
echo ""
echo "--- 朋友链接（用户 B）---"
echo "$LINK_B"
echo ""
echo "--- 以下信息请自行留档，重装系统后会变 ---"
echo "PrivateKey : $PRIV"
echo "PublicKey  : $PUB"
echo "shortId    : $SID"
echo "UUID-A     : $UUID_A"
echo "UUID-B     : $UUID_B"
echo "============================================================"
echo ""
yellow "手机扫码导入（两个都扫一次会重复，扫你要用的那个）："
echo "--- 用户 A 二维码 ---"
qrencode -t ANSIUTF8 "$LINK_A" 2>/dev/null || echo "(qrencode 不可用，请复制链接)"
echo ""
echo "--- 用户 B 二维码 ---"
qrencode -t ANSIUTF8 "$LINK_B" 2>/dev/null || echo "(qrencode 不可用，请复制链接)"

# 保存到文件，方便 scp 取回
cat > /root/vless-info.txt <<EOF
VPS_IP=$VPS_IP
PORT=$PORT
SNI=$SNI
PUBLIC_KEY=$PUB
SHORT_ID=$SID
UUID_A=$UUID_A
UUID_B=$UUID_B
LINK_A=$LINK_A
LINK_B=$LINK_B
EOF
chmod 600 /root/vless-info.txt
green "信息已保存到 /root/vless-info.txt"
