#!/usr/bin/env bash
# ============================================================
# 双协议一键部署：VLESS+Reality(TCP) + Hysteria2(UDP)
#
# 为什么两个协议：
#   Reality (TCP 443) → 网页、AI 服务、论文下载，抗封锁最强
#   Hysteria2 (UDP 443) → 游戏、视频，QUIC 抗丢包，弱网下延迟更稳
#
# 两者出口 IP 完全相同（同一台机器），切换协议不会变 IP
#
# 适用：Ubuntu 22.04 / 24.04、Debian 12
# 用法：sudo -i 后 bash <(curl -fsSL <脚本地址>)
# 前置：云厂商安全组需放行 TCP 443 与 UDP 443
# ============================================================
set -euo pipefail

XRAY_PORT=443
HY2_PORT=443
DEST="www.microsoft.com:443"
SNI="www.microsoft.com"
XRAY_CONF="/usr/local/etc/xray/config.json"
HY2_CONF="/etc/hysteria/config.yaml"

green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行（sudo -i）"
  exit 1
fi

green "[1/7] 系统准备"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates jq qrencode uuid-runtime >/dev/null

green "[2/7] 网络调优（BBR + IPv4 优先）"
if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
  cat >> /etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
fi
sysctl -p >/dev/null 2>&1 || true
# 强制 IPv4 优先：避免出口 IP 突然变成 IPv6
if ! grep -q "precedence ::ffff:0:0/96" /etc/gai.conf 2>/dev/null; then
  echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
fi

green "[3/7] 安装 Xray（VLESS + Reality）"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
XRAY_BIN="/usr/local/bin/xray"
if [[ ! -x "$XRAY_BIN" ]]; then
  red "Xray 安装失败"
  exit 1
fi

KEYS=$($XRAY_BIN x25519)
PRIV=$(echo "$KEYS" | awk -F': ' '/[Pp]rivate/{print $2}' | tr -d ' ')
PUB=$(echo "$KEYS"  | awk -F': ' '/[Pp]ublic/{print $2}'  | tr -d ' ')
UUID_A=$($XRAY_BIN uuid)
UUID_B=$($XRAY_BIN uuid)
SID=$(openssl rand -hex 8)
if [[ -z "$PRIV" || -z "$PUB" ]]; then
  red "Reality 密钥生成失败"
  exit 1
fi

mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
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
if ! systemctl is-active --quiet xray; then
  red "Xray 启动失败，查看: journalctl -u xray -n 30"
  exit 1
fi
green "    Reality 已就绪 (TCP $XRAY_PORT)"

green "[4/7] 安装 Hysteria2"
bash -c "$(curl -fsSL https://get.hy2.sh/)" >/dev/null 2>&1 || true
if [[ ! -x "/usr/local/bin/hysteria" ]]; then
  red "Hysteria2 安装失败，跳过（Reality 仍可用）"
  HY2_OK=0
else
  HY2_OK=1
fi

green "[5/7] 配置 Hysteria2"
HY2_PASS_A=$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
if [[ "$HY2_OK" == "1" ]]; then
  mkdir -p /etc/hysteria
  # 自签证书（客户端 skip-cert-verify 即可，不需要域名）
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
    -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1

  cat > "$HY2_CONF" <<EOF
listen: :$HY2_PORT

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

auth:
  type: password
  password: "$HY2_PASS_A"

# 带宽声明：帮助拥塞控制，不是硬限速
# 上行 100Mbps 下行 500Mbps 是 $3.5 套餐的合理值
bandwidth:
  up: 100 mbps
  down: 500 mbps

# 伪装：未通过认证的访问会看到真实网站
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

sniff:
  enabled: true
  timeout: 300ms
EOF
  systemctl enable hysteria-server >/dev/null 2>&1 || true
  systemctl restart hysteria-server 2>/dev/null || systemctl restart hysteria 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet hysteria-server 2>/dev/null || systemctl is-active --quiet hysteria 2>/dev/null; then
    green "    Hysteria2 已就绪 (UDP $HY2_PORT)"
  else
    yellow "    Hysteria2 未启动，请检查: journalctl -u hysteria-server -n 20"
  fi
fi

green "[6/7] 获取公网 IP"
VPS_IP=$(curl -s4 --max-time 10 https://api.ipify.org || true)
if [[ -z "$VPS_IP" ]]; then
  VPS_IP=$(curl -s4 --max-time 10 https://ifconfig.me || true)
fi
if [[ -z "$VPS_IP" ]]; then
  red "无法获取公网 IP，请手动确认"
  VPS_IP="REPLACE_ME"
fi

green "[7/7] 输出链接"

mk_reality() {
  local uuid="$1" tag="$2"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$uuid" "$VPS_IP" "$XRAY_PORT" "$SNI" "$PUB" "$SID" "$tag"
}

mk_hy2() {
  local tag="$1"
  printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1#%s' \
    "$HY2_PASS_A" "$VPS_IP" "$HY2_PORT" "$SNI" "$tag"
}

LINK_A=$(mk_reality "$UUID_A" "SG-A-Relay")
LINK_B=$(mk_reality "$UUID_B" "SG-B-Relay")
LINK_GAME=$(mk_hy2 "SG-Game")

echo ""
echo "============================================================"
green "部署完成"
echo "============================================================"
echo "固定出口 IP : $VPS_IP"
echo "Reality     : TCP $XRAY_PORT  (网页/AI/下载，抗封锁强)"
echo "Hysteria2   : UDP $HY2_PORT  (游戏/视频，延迟更稳)"
echo "伪装目标    : $SNI"
echo ""
echo "--- [用户A] 日常（AI / 论文 / 网页）---"
echo "$LINK_A"
echo ""
echo "--- [用户B] 日常（网页）---"
echo "$LINK_B"
echo ""
echo "--- [用户B] 游戏 / 视频（UDP，延迟优先）---"
echo "$LINK_GAME"
echo ""
yellow "两个协议出口 IP 相同，切换不会导致 IP 变化。"
yellow "重要：云厂商安全组必须放行 TCP 443 和 UDP 443，否则游戏那条连不上。"
echo "============================================================"
echo ""

yellow "扫码导入（挑你要用的扫）："
echo "--- 用户A 日常 ---"
qrencode -t ANSIUTF8 "$LINK_A" 2>/dev/null || echo "(qrencode 不可用)"
echo ""
yellow "--- 用户B 游戏/视频 ---"
qrencode -t ANSIUTF8 "$LINK_GAME" 2>/dev/null || echo "(qrencode 不可用)"

cat > /root/vless-info.txt <<EOF
VPS_IP=$VPS_IP
REALITY_PORT=$XRAY_PORT
HY2_PORT=$HY2_PORT
SNI=$SNI
PUBLIC_KEY=$PUB
SHORT_ID=$SID
UUID_A=$UUID_A
UUID_B=$UUID_B
HY2_PASSWORD=$HY2_PASS_A
LINK_A=$LINK_A
LINK_B=$LINK_B
LINK_GAME=$LINK_GAME
EOF
chmod 600 /root/vless-info.txt
green "全部信息已存 /root/vless-info.txt"

# 自检：确认监听端口
echo ""
green "端口监听自检："
ss -lntup 2>/dev/null | grep -E ":(443)\b" || true
