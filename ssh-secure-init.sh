#!/bin/bash
set -e
set -o pipefail

SSH_CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak"

KEY_DIR="/root/.ssh"
KEY_FILE="$KEY_DIR/id_rsa"
PUB_FILE="$KEY_FILE.pub"
AUTHORIZED="$KEY_DIR/authorized_keys"

# ================= 工具函数 =================

random_port() {
    shuf -i 20000-60000 -n 1
}

get_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
}

pause() {
    read -rp "💡 按回车继续..."
}

ensure_nc() {
    if ! command -v nc >/dev/null 2>&1; then
        echo "📦 未检测到 netcat，正在安装..."
        apt update
        apt install -y netcat-openbsd
    fi
}

# ✅ 获取当前 SSH 实际端口（核心新增）
get_ssh_port() {
    # 1️⃣ 优先从当前 SSH 会话获取（最准确）
    if [[ -n "$SSH_CONNECTION" ]]; then
        echo "$SSH_CONNECTION" | awk '{print $4}'
        return
    fi

    # 2️⃣ 从 sshd_config 读取
    if grep -qiE '^[[:space:]]*Port[[:space:]]+' "$SSH_CONFIG"; then
        grep -iE '^[[:space:]]*Port[[:space:]]+' "$SSH_CONFIG" \
            | tail -n1 | awk '{print $2}'
        return
    fi

    # 3️⃣ 兜底
    echo 22
}

# ================= SSH 密钥 =================

ensure_key() {
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"

    if [[ ! -f "$KEY_FILE" ]]; then
        echo "🔑 生成 SSH 密钥..."
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q
    fi

    touch "$AUTHORIZED"
    chmod 600 "$AUTHORIZED"

    grep -q "$(cat "$PUB_FILE")" "$AUTHORIZED" || cat "$PUB_FILE" >> "$AUTHORIZED"

    echo "✅ SSH 密钥已就绪"
    echo "📍 私钥位置: $KEY_FILE"
    echo "📍 公钥位置: $PUB_FILE"
}

reset_key() {
    echo "⚠️ 即将重置 SSH 密钥（泄漏应急）"
    read -rp "确认请输入 yes: " c
    [[ "$c" == "yes" ]] || return

    rm -f "$KEY_FILE" "$PUB_FILE" "$AUTHORIZED"
    ensure_key
    echo "🔄 SSH 密钥已重置"
}

# ================= 临时密钥分发（端口转发） =================

temp_key_server() {
    ensure_key
    ensure_nc

    REMOTE_PORT=$(random_port)
    LOCAL_PORT=$(random_port)
    SERVER_IP=$(get_ip)
    SSH_PORT=$(get_ssh_port)

    echo
    echo "🖥️ 启动【仅本地监听】临时密钥服务"
    echo "🔗 服务器监听: 127.0.0.1:$REMOTE_PORT"
    echo "🔗 客户端本地端口: 127.0.0.1:$LOCAL_PORT"
    echo "🔐 当前 SSH 端口: $SSH_PORT"
    echo "⏳ 有效期: 60 秒"
    echo

    timeout 60s bash -c "
        while true; do
            echo -e 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$(cat $KEY_FILE)' \
            | nc -l 127.0.0.1 $REMOTE_PORT
        done
    " >/dev/null 2>&1 &

    sleep 1

    cat <<EOF
=================【客户端执行】=================

ssh -p $SSH_PORT \\
    -L 127.0.0.1:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT \\
    root@$SERVER_IP

浏览器访问：
http://127.0.0.1:$LOCAL_PORT

===============================================
EOF
}

# ================= 高危兜底 =================

print_private_key() {
    ensure_key

    echo
    echo "⚠️⚠️ 高危操作：直接打印 SSH 私钥 ⚠️⚠️"
    echo "仅在【无法使用 SSH 端口转发】时使用"
    read -rp "输入 yes 确认: " c

    [[ "$c" == "yes" ]] || {
        echo "❌ 已取消"
        return
    }

    echo
    echo "================ SSH 私钥开始 ================"
    cat "$KEY_FILE"
    echo "================ SSH 私钥结束 ================"
    echo
}

# ================= SSH 配置 =================

change_ssh_port() {
    NEW_PORT=$(random_port)
    cp "$SSH_CONFIG" "$BACKUP"

    sed -i "s/^#\?Port .*/Port $NEW_PORT/" "$SSH_CONFIG" || echo "Port $NEW_PORT" >> "$SSH_CONFIG"
    systemctl restart sshd

    echo "✅ SSH 端口已修改为: $NEW_PORT"
    echo "⚠️ 请确保你已获取私钥再断开连接"
}

disable_password() {
    cp "$SSH_CONFIG" "$BACKUP"

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"

    systemctl restart sshd
    echo "🔒 SSH 密码登录已禁用"
}

enable_password() {
    cp "$SSH_CONFIG" "$BACKUP"

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' "$SSH_CONFIG"

    systemctl restart sshd
    echo "🔓 SSH 密码登录已开启（应急）"
}

# ================= 菜单 =================

menu() {
    clear
    cat <<EOF
=====================================
🛡️  SSH 安全初始化 / 管理菜单
=====================================

[1] 🔑 生成 / 确认 SSH 密钥
[2] 🌐 通过 SSH 端口转发获取私钥（推荐）
[3] 🧾 直接打印 SSH 私钥（兜底/高危）
[4] 🔄 重置 SSH 密钥（泄漏应急）
[5] 🔧 修改 SSH 端口
[6] 🚫 禁用 SSH 密码登录
[7] 🔓 启用 SSH 密码登录（应急）
[0] ❌ 退出

EOF
}

# ================= 主循环 =================

while true; do
    menu
    read -rp "请选择 [0-7]: " choice
    case "$choice" in
        1) ensure_key; pause ;;
        2) temp_key_server; pause ;;
        3) print_private_key; pause ;;
        4) reset_key; pause ;;
        5) change_ssh_port; pause ;;
        6) disable_password; pause ;;
        7) enable_password; pause ;;
        0) exit 0 ;;
        *) echo "⚠️ 无效选项"; pause ;;
    esac
done