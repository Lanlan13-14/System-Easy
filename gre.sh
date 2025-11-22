#!/bin/bash
# GRE-Easy — 默认 GRE over IPsec (Ubuntu/Debian) 最终优化版
# 修改说明：
# - 临时下发服务：随机端口(10000-60000)，要求输入允许访问的对端公网 IP，仅允许该 IP 访问
# - 若无 python3 自动尝试 apt 安装
# - 服务为一次性：首个成功拉取后会自动退出，并删除对应的 iptables/ip6tables 规则与临时目录

CONFIG_DIR="/etc/gre-easy"
CONFIG_FILE="$CONFIG_DIR/config"
SCRIPT_PATH="/usr/bin/gre-easy"
TABLE_ID=100
LOG_FILE="/var/log/gre-easy.log"

mkdir -p "$CONFIG_DIR"
touch "$LOG_FILE"

header() { clear; echo "──────── GRE-Easy (GRE over IPsec) ────────"; }
pause() { read -rp "按回车继续..."; }
check_root() { [[ $EUID -ne 0 ]] && echo "请使用 sudo 运行此脚本" && exit 1; }
install_self() { cp "$0" "$SCRIPT_PATH"; chmod +x "$SCRIPT_PATH"; }

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
log_err() { echo "[$(date '+%F %T')] ERROR: $*" | tee -a "$LOG_FILE" >&2; }

valid_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_ipv6() { [[ $1 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; }

get_public_ip() {
    type="$1"; ips=()
    if [[ "$type" == "v4" ]]; then
        mapfile -t ips < <(ip -4 addr show | grep inet | grep -v '127.0.0.1' | grep -v docker | awk '{print $2,$NF}')
    else
        mapfile -t ips < <(ip -6 addr show | grep inet6 | grep -v '::1' | grep -v docker | awk '{print $2,$NF}')
    fi
    if [[ ${#ips[@]} -gt 0 ]]; then
        echo "可用公网 $type IP："
        for i in "${!ips[@]}"; do echo "[$i] ${ips[$i]}"; done
        read -rp "选择编号（回车手动输入）：" idx
        if [[ -n "$idx" && "$idx" =~ ^[0-9]+$ && $idx -lt ${#ips[@]} ]]; then
            echo "${ips[$idx]%%/*}"; return
        fi
    fi
    while true; do
        read -rp "手动输入公网 $type IP（可留空）： " manual
        [[ -z "$manual" ]] && break
        if [[ "$type" == "v4" && valid_ipv4 "$manual" ]] || [[ "$type" == "v6" && valid_ipv6 "$manual" ]]; then
            echo "$manual"; break
        else
            echo "❌ IP 格式不合法，请重新输入"
        fi
    done
}

install_strongswan() {
    log "安装 strongSwan..."
    apt update && apt install -y strongswan

    # 防火墙规则
    iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 500 -j ACCEPT
    iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 4500 -j ACCEPT
    iptables -C INPUT -p esp -j ACCEPT 2>/dev/null || iptables -I INPUT -p esp -j ACCEPT
    log "IPsec 必要防火墙规则已设置"
}

setup_ipsec() {
    LOCAL_IP="$1"; REMOTE_IP="$2"

    read -rp "IKE 加密算法 (默认 aes256-sha256-modp2048): " IKE_ALGO
    IKE_ALGO="${IKE_ALGO:-aes256-sha256-modp2048}"

    read -rp "ESP 加密算法 (默认 aes256-sha256): " ESP_ALGO
    ESP_ALGO="${ESP_ALGO:-aes256-sha256}"

    PSK=$(openssl rand -hex 16)
    cat >/etc/ipsec.secrets <<EOF
$LOCAL_IP $REMOTE_IP : PSK "$PSK"
EOF
    chmod 600 /etc/ipsec.secrets
    log "PSK 文件权限设置为 600"

    cat >/etc/ipsec.conf <<EOF
config setup
    charondebug="all"
    uniqueids=yes

conn gre-ipsec
    left=$LOCAL_IP
    leftsubnet=0.0.0.0/0
    right=$REMOTE_IP
    rightsubnet=0.0.0.0/0
    auto=start
    keyexchange=ikev2
    authby=psk
    ike=$IKE_ALGO
    esp=$ESP_ALGO
EOF

    systemctl restart strongswan
    log "IPsec 配置完成，GRE 流量将加密传输"
}

setup_gre_tunnel() {
    local local_ip="$1" remote_ip="$2" inner4="$3" inner6="$4" peer6="$5"
    ip tunnel show | grep -q gre-easy && ip tunnel del gre-easy
    ip tunnel add gre-easy mode gre local "$local_ip" remote "$remote_ip"
    [[ -n "$inner4" ]] && ip addr add "$inner4" dev gre-easy
    [[ -n "$inner6" ]] && ip addr add "$inner6" dev gre-easy peer "$peer6"
    ip link set gre-easy up
    ip link set dev gre-easy mtu 1400
    log "GRE 隧道 $local_ip -> $remote_ip 配置完成 (over IPsec), MTU=1400"
}

setup_nat() {
    local type="$1" net="$2"
    if [[ "$type" == "ipv4" ]]; then
        iptables -t nat -C POSTROUTING -s "$net" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$net" -j MASQUERADE
    else
        modprobe nf_nat_ipv6
        ip6tables -t nat -C POSTROUTING -s "$net" -j MASQUERADE 2>/dev/null || \
            ip6tables -t nat -A POSTROUTING -s "$net" -j MASQUERADE
    fi
    log "NAT $type $net 配置完成"
}

# 新增：临时 HTTP 服务，把 /etc/gre-easy/config 分享给对端（一次性下载）
# 要求：输入允许访问的对端公网 IP，仅允许该 IP 访问；随机选择 10000-60000 端口（未占用）
# 首次成功拉取后，服务自动退出并删除该 iptables/ip6tables 规则与临时目录
serve_config_http() {
    local local_ip="$1"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "⚠ 系统未检测到 python3，尝试自动安装 python3..."
        apt update && apt install -y python3 || {
            echo "❌ 自动安装 python3 失败，请手动安装或使用 scp 传输配置。"
            return
        }
        echo "✔ python3 已安装"
    fi

    read -rp "是否启动临时 HTTP 服务以分享配置给另一端？ (y/N): " ans
    [[ ! "$ans" =~ ^[Yy] ]] && return

    # 要求输入允许访问的对端公网 IP（必填）
    while true; do
        read -rp "请输入允许拉取配置的对端公网 IP（必填）: " ALLOWED_IP
        if [[ -z "$ALLOWED_IP" ]]; then
            echo "请填写对端 IP。"
            continue
        fi
        if valid_ipv4 "$ALLOWED_IP" || valid_ipv6 "$ALLOWED_IP"; then break; else
            echo "IP 格式不合法，请重新输入"
        fi
    done

    # 随机选端口（10000-60000），并确保未被监听
    if ! command -v shuf >/dev/null 2>&1; then
        echo "⚠ 系统未检测到 shuf，使用备用随机方式选端口。"
    fi
    while true; do
        if command -v shuf >/dev/null 2>&1; then
            PORT=$(shuf -i 10000-60000 -n1)
        else
            PORT=$((10000 + RANDOM % 50000))
            ((PORT>60000)) && PORT=10000
        fi
        # 检查端口是否被占用 (适配 IPv4/IPv6 本地监听列)
        if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT$"; then
            break
        fi
    done

    TOKEN=$(openssl rand -hex 12)

    TMPDIR=$(mktemp -d)
    cp "$CONFIG_FILE" "$TMPDIR/config"

    # 写入 Python 服务脚本（带 token 校验、来源 IP 校验，首次成功返回后自动退出并清理 iptables 与临时目录）
    cat >"$TMPDIR/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys, urllib.parse, os, threading, subprocess, shutil

TOKEN = sys.argv[1]
CONFIG = sys.argv[2]
PORT = int(sys.argv[3])
ALLOWED = sys.argv[4]
TMPDIR = sys.argv[5]

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        client_ip = self.client_address[0]
        if client_ip != ALLOWED:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'Forbidden: source IP not allowed')
            return
        q=urllib.parse.urlparse(self.path)
        params=urllib.parse.parse_qs(q.query)
        if 'token' not in params or params['token'][0]!=TOKEN:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'Forbidden: invalid token')
            return
        try:
            with open(CONFIG,'rb') as f:
                data=f.read()
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'Internal Server Error')
            return
        self.send_response(200)
        self.send_header('Content-Type','text/plain')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        # 在响应后异步关闭服务器（一次性）
        def stop_server(srv):
            try:
                srv.shutdown()
            except:
                pass
        threading.Thread(target=stop_server,args=(self.server,)).start()

if __name__=='__main__':
    port=PORT
    try:
        server=HTTPServer(('',port),Handler)
        server.serve_forever()
    finally:
        # 清理：删除为该服务添加的 iptables/ip6tables 规则，并移除临时目录
        try:
            if ':' in ALLOWED:  # IPv6
                subprocess.run(["ip6tables","-D","INPUT","-p","tcp","-s",ALLOWED,"--dport",str(port),"-j","ACCEPT"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                subprocess.run(["iptables","-D","INPUT","-p","tcp","-s",ALLOWED,"--dport",str(port),"-j","ACCEPT"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        try:
            shutil.rmtree(TMPDIR, ignore_errors=True)
        except Exception:
            pass
PY

    # 添加 iptables 规则，仅允许 ALLOWED_IP 访问该端口（根据 IPv4/IPv6）
    if valid_ipv6 "$ALLOWED_IP"; then
        ip6tables -C INPUT -p tcp -s "$ALLOWED_IP" --dport "$PORT" -j ACCEPT 2>/dev/null || \
            ip6tables -I INPUT -p tcp -s "$ALLOWED_IP" --dport "$PORT" -j ACCEPT
        log "已在本机 ip6tables 打开端口 $PORT（仅允许 $ALLOWED_IP）"
    else
        iptables -C INPUT -p tcp -s "$ALLOWED_IP" --dport "$PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp -s "$ALLOWED_IP" --dport "$PORT" -j ACCEPT
        log "已在本机 iptables 打开端口 $PORT（仅允许 $ALLOWED_IP）"
    fi

    # 后台运行服务（传入 TMPDIR 以便 server 在退出时删除临时文件）
    nohup python3 "$TMPDIR/server.py" "$TOKEN" "$TMPDIR/config" "$PORT" "$ALLOWED_IP" "$TMPDIR" >/var/log/gre-easy-http.log 2>&1 &

    echo "✔ 临时 HTTP 服务已启动（一次性）。"
    echo "请在对端（仅允许 IP: $ALLOWED_IP）使用 curl/wget 下载："
    echo "  curl -s \"http://$local_ip:$PORT/?token=$TOKEN\" -o /tmp/gre-config"
    echo "或："
    echo "  wget -qO- \"http://$local_ip:$PORT/?token=$TOKEN\" > /tmp/gre-config"
    echo "首个成功拉取后服务会自动退出并删除 iptables/ip6tables 规则。"
    echo "日志: /var/log/gre-easy-http.log"
    pause
}

restore_system() {
    log "开始恢复系统..."
    ip tunnel show | grep -q gre-easy && ip tunnel del gre-easy
    ip addr flush dev gre-easy >/dev/null 2>&1
    ip route flush table $TABLE_ID 2>/dev/null
    ip -6 route flush table $TABLE_ID 2>/dev/null
    ip rule del from 100.64.0.0/24 table $TABLE_ID 2>/dev/null
    ip -6 rule del from fd00:100:64::/64 table $TABLE_ID 2>/dev/null
    iptables -t nat -D POSTROUTING -s 100.64.0.0/24 -j MASQUERADE 2>/dev/null
    ip6tables -t nat -D POSTROUTING -s fd00:100:64::/64 -j MASQUERADE 2>/dev/null
    sed -i '/gre-easy/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    systemctl stop gre-easy.service 2>/dev/null
    systemctl disable gre-easy.service 2>/dev/null
    rm -f /etc/systemd/system/gre-easy.service
    rm -rf "$CONFIG_DIR"
    log "系统恢复完成"
    echo "✔ 系统已恢复到干净状态"
}

make_service() {
cat >/etc/systemd/system/gre-easy.service <<EOF
[Unit]
Description=GRE-Easy Tunnel Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/gre-easy --autostart
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gre-easy.service
}

if [[ "$1" == "--autostart" ]]; then
    [[ ! -f "$CONFIG_FILE" ]] && exit 0
    source "$CONFIG_FILE"
    setup_ipsec "$LOCAL_IP" "$REMOTE_IP"
    setup_gre_tunnel "$LOCAL_IP" "$REMOTE_IP" "$LOCAL_INNER4" "$LOCAL_INNER6" "$REMOTE_INNER6"
    [[ "$NAT4" == "yes" ]] && setup_nat ipv4 "$INNER4_NET"
    [[ "$NAT6" == "yes" ]] && setup_nat ipv6 "$INNER6_NET"
    [[ -n "$LOCAL_INNER4" ]] && ip rule add from "${LOCAL_INNER4%/*}" table $TABLE_ID 2>/dev/null
    [[ -n "$LOCAL_INNER6" ]] && ip -6 rule add from "${LOCAL_INNER6%/*}" table $TABLE_ID 2>/dev/null
    exit 0
fi

configure_tunnel() {
    header
    echo "🌐 配置 GRE over IPsec 隧道"
    LOCAL4=$(get_public_ip v4)
    LOCAL6=$(get_public_ip v6)
    read -rp "请输入远端 VPS 公网 IP: " REMOTE
    LOCAL_IP="${LOCAL4:-$LOCAL6}"
    LOCAL_INNER4="100.64.0.1/24"
    LOCAL_INNER6="fd00:100:64::1/64"
    REMOTE_INNER6="fd00:100:64::2/64"
    INNER4_NET="100.64.0.0/24"
    INNER6_NET="fd00:100:64::/64"
    NAT4=yes; NAT6=yes

    mkdir -p "$CONFIG_DIR"
    echo "LOCAL_IP=\"$LOCAL_IP\"" >"$CONFIG_FILE"
    echo "REMOTE_IP=\"$REMOTE\"" >>"$CONFIG_FILE"
    echo "LOCAL_INNER4=\"$LOCAL_INNER4\"" >>"$CONFIG_FILE"
    echo "LOCAL_INNER6=\"$LOCAL_INNER6\"" >>"$CONFIG_FILE"
    echo "REMOTE_INNER6=\"$REMOTE_INNER6\"" >>"$CONFIG_FILE"
    echo "INNER4_NET=\"$INNER4_NET\"" >>"$CONFIG_FILE"
    echo "INNER6_NET=\"$INNER6_NET\"" >>"$CONFIG_FILE"
    echo "NAT4=\"$NAT4\"" >>"$CONFIG_FILE"
    echo "NAT6=\"$NAT6\"" >>"$CONFIG_FILE"

    # 提示并可选择启动临时 HTTP 服务把配置/PSK 分享给对端（一次性）
    echo "提示：脚本已把配置写入 $CONFIG_FILE"
    echo "你可以手动将 /etc/ipsec.secrets 中的 PSK 复制到对端，或者使用临时 HTTP 服务让对端来拉取配置（一次性、基于来源 IP 白名单）。"
    serve_config_http "$LOCAL_IP"

    install_strongswan
    setup_ipsec "$LOCAL_IP" "$REMOTE"
    setup_gre_tunnel "$LOCAL_IP" "$REMOTE" "$LOCAL_INNER4" "$LOCAL_INNER6" "$REMOTE_INNER6"
    setup_nat ipv4 "$INNER4_NET"
    setup_nat ipv6 "$INNER6_NET"
    echo "net.ipv4.ip_forward=1 # gre-easy" >>/etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1 # gre-easy" >>/etc/sysctl.conf
    sysctl -p >/dev/null
    make_service
    echo "✔ GRE over IPsec 隧道配置完成"; pause
}

show_status() { header; ip tunnel show | grep gre-easy; ip addr show gre-easy; ipsec statusall; pause; }
remove_script() { echo "❌ 正在删除脚本..."; rm -f "$SCRIPT_PATH"; echo "✔ 已删除 gre-easy"; pause; }
remove_all() { restore_system; remove_script; }

main_menu() {
    while true; do
        header
        cat <<EOF
GRE-Easy (默认 GRE over IPsec)：
  [1] 🌐 配置 GRE over IPsec 隧道
  [2] 🧹 恢复系统
  [3] 📊 查看状态
  [4] ❌ 删除脚本
  [5] 🧹❌ 恢复 + 删除脚本
  [0] 退出
EOF
        read -rp "选择： " opt
        if [[ ! $opt =~ ^[0-9]+$ ]] || ((opt<0 || opt>5)); then
            echo "❌ 无效选项，请重新输入"; continue; fi
        case "$opt" in
            1) configure_tunnel ;;
            2) restore_system ;;
            3) show_status ;;
            4) remove_script ;;
            5) remove_all ;;
            0) echo "下次使用请输入： sudo gre-easy"; exit 0 ;;
        esac
    done
}

install_self
main_menu
