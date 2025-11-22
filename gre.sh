#!/bin/bash
# GRE-Easy — 最终版（修复 IPv6 peer、策略路由、NAT 去重、多网卡选择）
CONFIG_DIR="/etc/gre-easy"
CONFIG_FILE="$CONFIG_DIR/config"
SCRIPT_PATH="/usr/bin/gre-easy"
SERVICE_NAME="gre-easy"
TABLE_ID=100  # 策略路由表ID

mkdir -p "$CONFIG_DIR"

header() {
    clear
    echo "──────── GRE-Easy — Menu ────────"
}

pause() { read -rp "按回车继续..."; }

check_root() { [[ $EUID -ne 0 ]] && echo "请使用 sudo 运行此脚本" && exit 1; }

install_self() { cp "$0" "$SCRIPT_PATH"; chmod +x "$SCRIPT_PATH"; }

# =========================================
# 公网 IP 自动检测 & 用户选择
# type: v4 / v6
get_public_ip() {
    type="$1"
    mapfile -t ips < <(
        if [[ "$type" == "v4" ]]; then
            ip -4 addr show | grep inet | grep -v '127.0.0.1' | grep -v docker | awk '{print $2,$NF}'
        else
            ip -6 addr show | grep inet6 | grep -v '::1' | grep -v docker | awk '{print $2,$NF}'
        fi
    )
    if [[ ${#ips[@]} -eq 0 ]]; then
        echo ""
        return
    fi
    echo "可用公网 $type IP："
    for i in "${!ips[@]}"; do echo "[$i] ${ips[$i]}"; done
    read -rp "选择编号（回车手动输入）：" idx
    if [[ -n "$idx" && "$idx" =~ ^[0-9]+$ && $idx -lt ${#ips[@]} ]]; then
        echo "${ips[$idx]%%/*}"
    else
        read -rp "手动输入公网 $type IP（可留空）：" manual
        echo "$manual"
    fi
}

# =========================================
# 系统恢复
# =========================================
restore_system() {
    echo "🧹 正在恢复系统..."
    for t in $(ip tunnel show | grep gre-easy | awk '{print $1}'); do ip tunnel del "$t" 2>/dev/null; done
    ip addr flush dev gre-easy >/dev/null 2>&1
    ip route del default table $TABLE_ID 2>/dev/null
    ip -6 route del default table $TABLE_ID 2>/dev/null
    iptables -t nat -D POSTROUTING -s 100.64.0.0/24 -j MASQUERADE 2>/dev/null
    ip6tables -t nat -D POSTROUTING -s fd00:100:64::/64 -j MASQUERADE 2>/dev/null
    sed -i '/gre-easy/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    systemctl stop gre-easy.service 2>/dev/null
    systemctl disable gre-easy.service 2>/dev/null
    rm -f /etc/systemd/system/gre-easy.service
    rm -rf "$CONFIG_DIR"
    echo "✔ 系统已恢复到从未使用 GRE-Easy 的状态"
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

# =========================================
# 自动启动
# =========================================
if [[ "$1" == "--autostart" ]]; then
    [[ ! -f "$CONFIG_FILE" ]] && exit 0
    source "$CONFIG_FILE"
    ip tunnel show | grep -q gre-easy && ip tunnel del gre-easy
    ip tunnel add gre-easy mode gre local "$LOCAL_IP" remote "$REMOTE_IP"
    [[ -n "$LOCAL_INNER4" ]] && ip addr add "$LOCAL_INNER4" dev gre-easy 2>/dev/null
    [[ -n "$LOCAL_INNER6" ]] && ip addr add "$LOCAL_INNER6" dev gre-easy peer "$REMOTE_INNER6" 2>/dev/null
    ip link set gre-easy up
    [[ "$NAT4" == "yes" ]] && iptables -t nat -C POSTROUTING -s "$INNER4_NET" -j MASQUERADE 2>/dev/null || \
        [[ "$NAT4" == "yes" ]] && iptables -t nat -A POSTROUTING -s "$INNER4_NET" -j MASQUERADE
    [[ "$NAT6" == "yes" ]] && modprobe nf_nat_ipv6
    [[ "$NAT6" == "yes" ]] && ip6tables -t nat -C POSTROUTING -s "$INNER6_NET" -j MASQUERADE 2>/dev/null || \
        [[ "$NAT6" == "yes" ]] && ip6tables -t nat -A POSTROUTING -s "$INNER6_NET" -j MASQUERADE
    [[ -n "$LOCAL_INNER4" ]] && ip rule add from "${LOCAL_INNER4%/*}" table $TABLE_ID 2>/dev/null
    [[ -n "$LOCAL_INNER6" ]] && ip -6 rule add from "${LOCAL_INNER6%/*}" table $TABLE_ID 2>/dev/null
    exit 0
fi

# =========================================
# 在线更新（保持原样）
# =========================================
update_script() {
    TMP="/tmp/gre-easy.new"
    echo "🔄 正在下载最新脚本..."
    URL="https://raw.githubusercontent.com/Lanlan13-14/GRE-Easy/refs/heads/main/gre.sh"
    if ! curl -fsSL "$URL" -o "$TMP"; then echo "❌ 下载失败"; return; fi
    echo "🔍 检查语法..."
    if ! bash -n "$TMP"; then echo "❌ 新脚本存在语法错误，已取消更新。"; rm -f "$TMP"; return; fi
    echo "✔ 语法正常，正在更新..."
    mv "$TMP" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✔ 更新成功！"
}

# =========================================
# 出站配置
# =========================================
outbound_config() {
    MODE="$1"
    header; echo "🌐 出站（出口）VPS 配置"
    LOCAL4=$(get_public_ip v4)
    LOCAL6=$(get_public_ip v6)
    read -rp "请输入入口 VPS 公网地址: " REMOTE
    LOCAL_IP="${LOCAL4:-$LOCAL6}"
    NAT4=no; NAT6=no
    case "$MODE" in
        1) NAT6=yes ;;
        2) NAT4=yes ;;
        3) NAT4=yes; NAT6=yes ;;
        4) NAT6=yes ;;
        5) NAT4=yes ;;
    esac
    LOCAL_INNER4="100.64.0.1/24"
    LOCAL_INNER6="fd00:100:64::1/64"
    REMOTE_INNER6="fd00:100:64::2/64"
    INNER4_NET="100.64.0.0/24"
    INNER6_NET="fd00:100:64::/64"
    echo "LOCAL_IP=\"$LOCAL_IP\"" >"$CONFIG_FILE"
    echo "REMOTE_IP=\"$REMOTE\"" >>"$CONFIG_FILE"
    echo "LOCAL_INNER4=\"$LOCAL_INNER4\"" >>"$CONFIG_FILE"
    echo "LOCAL_INNER6=\"$LOCAL_INNER6\"" >>"$CONFIG_FILE"
    echo "REMOTE_INNER6=\"$REMOTE_INNER6\"" >>"$CONFIG_FILE"
    echo "INNER4_NET=\"$INNER4_NET\"" >>"$CONFIG_FILE"
    echo "INNER6_NET=\"$INNER6_NET\"" >>"$CONFIG_FILE"
    echo "NAT4=\"$NAT4\"" >>"$CONFIG_FILE"
    echo "NAT6=\"$NAT6\"" >>"$CONFIG_FILE"
    ip tunnel show | grep -q gre-easy && ip tunnel del gre-easy
    ip tunnel add gre-easy mode gre local "$LOCAL_IP" remote "$REMOTE"
    ip addr add "$LOCAL_INNER4" dev gre-easy 2>/dev/null
    ip addr add "$LOCAL_INNER6" dev gre-easy peer "$REMOTE_INNER6" 2>/dev/null
    ip link set gre-easy up
    [[ "$NAT4" == "yes" ]] && iptables -t nat -C POSTROUTING -s "$INNER4_NET" -j MASQUERADE 2>/dev/null || \
        [[ "$NAT4" == "yes" ]] && iptables -t nat -A POSTROUTING -s "$INNER4_NET" -j MASQUERADE
    [[ "$NAT6" == "yes" ]] && modprobe nf_nat_ipv6
    [[ "$NAT6" == "yes" ]] && ip6tables -t nat -C POSTROUTING -s "$INNER6_NET" -j MASQUERADE 2>/dev/null || \
        [[ "$NAT6" == "yes" ]] && ip6tables -t nat -A POSTROUTING -s "$INNER6_NET" -j MASQUERADE
    echo "net.ipv4.ip_forward=1 # gre-easy" >>/etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1 # gre-easy" >>/etc/sysctl.conf
    sysctl -p >/dev/null
    make_service
    echo "✔ 出站配置完成"; pause
}

# =========================================
# 入站配置
# =========================================
inbound_config() {
    MODE="$1"
    header; echo "📡 入站（入口）VPS 配置"
    LOCAL4=$(get_public_ip v4)
    LOCAL6=$(get_public_ip v6)
    read -rp "请输入出口 VPS 公网地址: " REMOTE
    LOCAL_IP="${LOCAL4:-$LOCAL6}"
    LOCAL_INNER4="100.64.0.2/24"
    LOCAL_INNER6="fd00:100:64::2/64"
    REMOTE_INNER6="fd00:100:64::1/64"
    echo "LOCAL_IP=\"$LOCAL_IP\"" >"$CONFIG_FILE"
    echo "REMOTE_IP=\"$REMOTE\"" >>"$CONFIG_FILE"
    echo "LOCAL_INNER4=\"$LOCAL_INNER4\"" >>"$CONFIG_FILE"
    echo "LOCAL_INNER6=\"$LOCAL_INNER6\"" >>"$CONFIG_FILE"
    echo "REMOTE_INNER6=\"$REMOTE_INNER6\"" >>"$CONFIG_FILE"
    ip tunnel show | grep -q gre-easy && ip tunnel del gre-easy
    ip tunnel add gre-easy mode gre local "$LOCAL_IP" remote "$REMOTE"
    ip addr add "$LOCAL_INNER4" dev gre-easy 2>/dev/null
    ip addr add "$LOCAL_INNER6" dev gre-easy peer "$REMOTE_INNER6" 2>/dev/null
    ip link set gre-easy up
    case "$MODE" in
        6) ip -6 route add default via fd00:100:64::1 dev gre-easy table $TABLE_ID 2>/dev/null
           ip -6 rule add from 100.64.0.2 table $TABLE_ID 2>/dev/null ;;
        7) ip route add default via 100.64.0.1 dev gre-easy table $TABLE_ID 2>/dev/null
           ip rule add from 100.64.0.2 table $TABLE_ID 2>/dev/null ;;
        8) ip route add default via 100.64.0.1 dev gre-easy table $TABLE_ID 2>/dev/null
           ip -6 route add default via fd00:100:64::1 dev gre-easy table $TABLE_ID 2>/dev/null
           ip rule add from 100.64.0.2 table $TABLE_ID 2>/dev/null
           ip -6 rule add from fd00:100:64::2 table $TABLE_ID 2>/dev/null ;;
        9) ip -6 route add default via fd00:100:64::1 dev gre-easy table $TABLE_ID 2>/dev/null
           ip -6 rule add from fd00:100:64::2 table $TABLE_ID 2>/dev/null ;;
        10) ip route add default via 100.64.0.1 dev gre-easy table $TABLE_ID 2>/dev/null
            ip rule add from 100.64.0.2 table $TABLE_ID 2>/dev/null ;;
    esac
    echo "✔ 入站配置完成"; pause
}

show_status() { header; ip tunnel show | grep gre-easy; ip addr show gre-easy; pause; }
remove_script() { echo "❌ 正在删除脚本..."; rm -f "$SCRIPT_PATH"; echo "✔ 已删除 gre-easy"; pause; }
remove_all() { restore_system; remove_script; }

main_menu() {
    header
cat <<EOF
出站（出口）VPS：
  [1] 🌐→🌐 IPv6 出站
  [2] 📡→📡 IPv4 出站
  [3] 🔁→🔁 双栈出站
  [4] 📡➕🌐 IPv4-only + IPv6 出站
  [5] 🌐➕📡 IPv6-only + IPv4 出站

入站（入口）VPS：
  [6] 🌐→🌐 IPv6 入口
  [7] 📡→📡 IPv4 入口
  [8] 🔁→🔁 双栈入口
  [9] 📡➕🌐 IPv4-only 使用 IPv6 出站
  [10] 🌐➕📡 IPv6-only 使用 IPv4 出站

系统管理：
  [11] 🧹 恢复系统
  [12] 🔄 在线更新脚本
  [13] 📊 查看状态

卸载：
  [14] ❌ 删除脚本
  [15] 🧹❌ 恢复 + 删除脚本

[0] 退出
EOF
    read -rp "选择： " opt
    case "$opt" in
        1|2|3|4|5) outbound_config "$opt" ;;
        6|7|8|9|10) inbound_config "$opt" ;;
        11) restore_system ;;
        12) update_script ;;
        13) show_status ;;
        14) remove_script ;;
        15) remove_all ;;
        0) echo "下次使用请输入： sudo gre-easy"; exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

install_self
while true; do main_menu; done