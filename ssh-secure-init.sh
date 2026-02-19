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

# 获取当前 SSH 实际端口
get_ssh_port() {
    # 优先从当前 SSH 会话获取
    if [[ -n "$SSH_CONNECTION" ]]; then
        echo "$SSH_CONNECTION" | awk '{print $4}'
        return
    fi

    # 从 sshd_config 读取
    if grep -qiE '^[[:space:]]*Port[[:space:]]+' "$SSH_CONFIG"; then
        grep -iE '^[[:space:]]*Port[[:space:]]+' "$SSH_CONFIG" \
            | tail -n1 | awk '{print $2}'
        return
    fi

    # 兜底
    echo 22
}

# ================= SSH 密钥 =================

KEY_COMMENT="auto-generated-by-$(hostname)-$(date +%Y%m%d)"

ensure_key() {
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"

    if [[ ! -f "$KEY_FILE" ]]; then
        echo "🔑 生成 SSH 密钥..."
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q -C "$KEY_COMMENT"
    fi

    touch "$AUTHORIZED"
    chmod 600 "$AUTHORIZED"

    grep -q "$(cat "$PUB_FILE")" "$AUTHORIZED" || cat "$PUB_FILE" >> "$AUTHORIZED"

    echo "[✅] SSH 密钥已就绪"
    echo "[📍] 私钥位置: $KEY_FILE"
    echo "[📍] 公钥位置: $PUB_FILE"
}

reset_key() {
    echo "[⚠️] 即将重置 SSH 密钥（泄漏应急）"
    read -rp "确认请输入 yes: " c
    [[ "$c" == "yes" ]] || return

    rm -f "$KEY_FILE" "$PUB_FILE" "$AUTHORIZED"
    ensure_key
    echo "[🔄] SSH 密钥已重置"
}

# ================= 临时密钥分发（端口转发） =================

temp_key_server() {
    ensure_key
    ensure_nc

    REMOTE_PORT=$(random_port)
    LOCAL_PORT=$(random_port)
    SERVER_IP=$(get_ip)
    SSH_PORT=$(get_ssh_port)
    
    echo "[⏱️]  设置临时密钥有效期（秒）"
    read -rp "默认120秒，最长300秒: " expire_time
    expire_time=${expire_time:-120}
    if [[ $expire_time -gt 300 ]]; then
        echo "[⚠️] 超过300秒，使用最大值300秒"
        expire_time=300
    fi

    echo
    echo "[🖥️] 启动【仅本地监听】临时密钥服务"
    echo "[🔗] 服务器监听: 127.0.0.1:$REMOTE_PORT"
    echo "[🔗] 客户端本地端口: 127.0.0.1:$LOCAL_PORT"
    echo "[🔐] 当前 SSH 端口: $SSH_PORT"
    echo "[⏳] 有效期: ${expire_time}秒"
    echo

    timeout ${expire_time}s bash -c "
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
    echo "[⚠️⚠️] 高危操作：直接打印 SSH 私钥 ⚠️⚠️"
    echo "仅在【无法使用 SSH 端口转发】时使用"
    read -rp "输入 yes 确认: " c

    [[ "$c" == "yes" ]] || {
        echo "[❌] 已取消"
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

    echo "[✅] SSH 端口已修改为: $NEW_PORT"
    echo "[⚠️] 请确保你已获取私钥再断开连接"
}

disable_password() {
    cp "$SSH_CONFIG" "$BACKUP"

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"

    systemctl restart sshd
    echo "[🔒] SSH 密码登录已禁用"
}

enable_password() {
    cp "$SSH_CONFIG" "$BACKUP"

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' "$SSH_CONFIG"

    systemctl restart sshd
    echo "[🔓] SSH 密码登录已开启（应急）"
}

# ================= 公钥管理 =================

# 获取所有公钥列表
list_keys() {
    ensure_key
    
    echo "========================================="
    echo "[📋] 当前 authorized_keys 中的公钥列表"
    echo "========================================="
    
    if [[ ! -s "$AUTHORIZED" ]]; then
        echo "暂无公钥"
        return
    fi
    
    local i=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        # 提取注释（最后一部分）
        local comment=$(echo "$line" | awk '{print $NF}')
        
        # 检查是否为脚本自动生成
        if [[ "$comment" == *"auto-generated"* ]]; then
            echo "[$i] 🔑 [本机生成] $comment"
        else
            echo "[$i] 🔐 [外部添加] $comment"
        fi
        
        # 显示密钥类型
        if [[ "$line" == ssh-rsa* ]]; then
            local key_type="RSA"
        elif [[ "$line" == ssh-ed25519* ]]; then
            local key_type="ED25519"
        elif [[ "$line" == ecdsa* ]]; then
            local key_type="ECDSA"
        else
            local key_type="未知"
        fi
        echo "   类型: $key_type"
        # 显示指纹
        local fingerprint=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')
        if [[ -n "$fingerprint" ]]; then
            echo "   指纹: $fingerprint"
        fi
        echo "-----------------------------------------"
        
        ((i++))
    done < "$AUTHORIZED"
    
    echo "========================================="
    echo "总计: $((i-1)) 个公钥"
    echo
}

# 添加其他用户的公钥
add_user_key() {
    ensure_key
    
    echo "[🔐] 添加其他用户的公钥"
    echo "----------------------"
    echo "请选择输入方式："
    echo "[1] 直接粘贴公钥字符串"
    echo "[2] 从文件读取"
    echo "[3] 从远程主机获取 (ssh)"
    read -rp "请选择 [1-3]: " input_method
    
    local new_key=""
    
    case "$input_method" in
        1)
            echo "请输入公钥内容 (以 ssh-rsa/ssh-ed25519 开头，Ctrl+D 结束):"
            new_key=$(cat)
            ;;
        2)
            read -rp "请输入公钥文件路径: " key_file
            if [[ -f "$key_file" ]]; then
                new_key=$(cat "$key_file")
            else
                echo "[❌] 文件不存在"
                return
            fi
            ;;
        3)
            read -rp "请输入远程主机 (user@host): " remote_host
            read -rp "请输入远程主机的SSH端口 [22]: " remote_port
            remote_port=${remote_port:-22}
            
            echo "正在获取远程主机公钥..."
            new_key=$(ssh -p "$remote_port" "$remote_host" "cat ~/.ssh/id_*.pub 2>/dev/null | head -n1" 2>/dev/null)
            
            if [[ -z "$new_key" ]]; then
                echo "[❌] 获取失败，请确保远程主机有公钥且可访问"
                return
            fi
            ;;
        *)
            echo "[❌] 无效选择"
            return
            ;;
    esac
    
    # 验证公钥格式
    if ! echo "$new_key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)'; then
        echo "[❌] 无效的公钥格式"
        return
    fi
    
    # 检查是否已存在
    if grep -qF "$(echo "$new_key" | awk '{print $2}')" "$AUTHORIZED"; then
        echo "[⚠️] 该公钥已存在，跳过添加"
        return
    fi
    
    # 添加注释（如果没有）
    if [[ $(echo "$new_key" | wc -w) -lt 3 ]]; then
        read -rp "请输入该公钥的备注信息: " key_note
        new_key="$new_key $key_note"
    fi
    
    echo "$new_key" >> "$AUTHORIZED"
    echo "[✅] 公钥已添加"
}

# 删除公钥
delete_key() {
    ensure_key
    
    list_keys
    
    local total=$(grep -c '^ssh' "$AUTHORIZED" 2>/dev/null || echo 0)
    if [[ $total -eq 0 ]]; then
        echo "暂无公钥可删除"
        return
    fi
    
    echo "请选择删除方式："
    echo "[1] 删除单个公钥"
    echo "[2] 删除多个公钥（逐个确认）"
    echo "[3] 删除所有外部公钥"
    read -rp "请选择 [1-3]: " delete_method
    
    case "$delete_method" in
        1)
            read -rp "请输入要删除的公钥编号: " num
            delete_single_key "$num"
            ;;
        2)
            echo "输入要删除的公钥编号（输入0结束）:"
            while true; do
                read -rp "编号: " num
                [[ "$num" == "0" ]] && break
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    delete_single_key "$num" "no_list"
                else
                    echo "无效编号"
                fi
            done
            ;;
        3)
            read -rp "[⚠️] 确认删除所有外部公钥？输入 yes 确认: " confirm
            if [[ "$confirm" == "yes" ]]; then
                local tmp_file=$(mktemp)
                local deleted=0
                
                while IFS= read -r line; do
                    # 保留本机生成的公钥
                    if [[ "$line" == *"auto-generated"* ]]; then
                        echo "$line" >> "$tmp_file"
                    else
                        ((deleted++))
                    fi
                done < "$AUTHORIZED"
                
                mv "$tmp_file" "$AUTHORIZED"
                chmod 600 "$AUTHORIZED"
                echo "[✅] 已删除 $deleted 个外部公钥"
            fi
            ;;
        *)
            echo "[❌] 无效选择"
            ;;
    esac
}

# 删除单个公钥
delete_single_key() {
    local num=$1
    local no_list=${2:-""}
    
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        local tmp_file=$(mktemp)
        local i=1
        local is_auto_generated=false
        local deleted=false
        
        while IFS= read -r line; do
            if [[ $i -eq $num ]]; then
                # 检查是否本机生成的公钥
                if [[ "$line" == *"auto-generated"* ]]; then
                    is_auto_generated=true
                    echo "[⚠️] 警告：正在删除本机生成的公钥"
                    read -rp "请再次输入 yes 确认删除: " confirm
                    if [[ "$confirm" == "yes" ]]; then
                        read -rp "最后一次确认？输入 yes 删除: " confirm2
                        if [[ "$confirm2" == "yes" ]]; then
                            deleted=true
                            echo "[🗑️] 已删除本机公钥"
                        else
                            echo "$line" >> "$tmp_file"
                        fi
                    else
                        echo "$line" >> "$tmp_file"
                    fi
                else
                    # 外部公钥，只需一次确认
                    read -rp "确认删除此公钥？输入 yes 确认: " confirm
                    if [[ "$confirm" == "yes" ]]; then
                        deleted=true
                        echo "[🗑️] 已删除外部公钥"
                    else
                        echo "$line" >> "$tmp_file"
                    fi
                fi
            else
                echo "$line" >> "$tmp_file"
            fi
            ((i++))
        done < "$AUTHORIZED"
        
        mv "$tmp_file" "$AUTHORIZED"
        chmod 600 "$AUTHORIZED"
        
        if [[ "$deleted" == false && "$is_auto_generated" == true ]]; then
            echo "[ℹ️] 取消删除本机公钥"
        elif [[ "$deleted" == false ]]; then
            echo "[ℹ️] 取消删除"
        fi
        
        if [[ -z "$no_list" ]]; then
            list_keys
        fi
    fi
}

# 备份所有公钥
backup_keys() {
    ensure_key
    
    local backup_dir="/root/.ssh/backups"
    mkdir -p "$backup_dir"
    
    local backup_file="$backup_dir/authorized_keys.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$AUTHORIZED" "$backup_file"
    
    echo "[✅] 公钥已备份到: $backup_file"
    
    # 也备份私钥（加密提示）
    if [[ -f "$KEY_FILE" ]]; then
        echo "[⚠️] 私钥位置: $KEY_FILE"
        echo "   请手动备份此文件到安全位置"
    fi
}

# 恢复公钥
restore_keys() {
    local backup_dir="/root/.ssh/backups"
    
    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir")" ]]; then
        echo "[❌] 没有找到备份文件"
        return
    fi
    
    echo "可用的备份文件："
    ls -1 "$backup_dir" | nl -w2 -s') '
    
    read -rp "请输入要恢复的备份文件编号: " num
    
    local backup_file=$(ls -1 "$backup_dir" | sed -n "${num}p")
    if [[ -n "$backup_file" ]]; then
        cp "$backup_dir/$backup_file" "$AUTHORIZED"
        chmod 600 "$AUTHORIZED"
        echo "[✅] 已恢复公钥"
    else
        echo "[❌] 无效选择"
    fi
}

# 删除备份
delete_backups() {
    local backup_dir="/root/.ssh/backups"
    
    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir")" ]]; then
        echo "[❌] 没有找到备份文件"
        return
    fi
    
    echo "可用的备份文件："
    ls -1 "$backup_dir" | nl -w2 -s') '
    
    echo "请选择删除方式："
    echo "[1] 删除单个备份"
    echo "[2] 删除多个备份（逐个确认）"
    echo "[3] 删除所有备份"
    read -rp "请选择 [1-3]: " delete_method
    
    case "$delete_method" in
        1)
            read -rp "请输入要删除的备份编号: " num
            if [[ "$num" =~ ^[0-9]+$ ]]; then
                local backup_file=$(ls -1 "$backup_dir" | sed -n "${num}p")
                rm -i "$backup_dir/$backup_file"
            fi
            ;;
        2)
            echo "输入要删除的备份编号（输入0结束）:"
            while true; do
                read -rp "编号: " num
                [[ "$num" == "0" ]] && break
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    local backup_file=$(ls -1 "$backup_dir" | sed -n "${num}p")
                    rm -i "$backup_dir/$backup_file"
                else
                    echo "无效编号"
                fi
            done
            ;;
        3)
            read -rp "[⚠️] 确认删除所有备份？输入 yes 确认: " confirm
            if [[ "$confirm" == "yes" ]]; then
                rm -f "$backup_dir"/*
                echo "[✅] 已删除所有备份"
            fi
            ;;
        *)
            echo "[❌] 无效选择"
            ;;
    esac
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
-------------------------------------
[8] 📋 列出所有公钥
[9] ➕ 添加其他用户的公钥
[10] ❌ 删除公钥
[11] 💾 备份公钥
[12] 🔄 恢复公钥
[13] 🗑️ 删除备份
-------------------------------------
[0] ❌ 退出

=====================================
EOF
}

# ================= 主循环 =================

while true; do
    menu
    read -rp "请选择 [0-13]: " choice
    case "$choice" in
        1) ensure_key; pause ;;
        2) temp_key_server; pause ;;
        3) print_private_key; pause ;;
        4) reset_key; pause ;;
        5) change_ssh_port; pause ;;
        6) disable_password; pause ;;
        7) enable_password; pause ;;
        8) list_keys; pause ;;
        9) add_user_key; pause ;;
        10) delete_key; pause ;;
        11) backup_keys; pause ;;
        12) restore_keys; pause ;;
        13) delete_backups; pause ;;
        0) exit 0 ;;
        *) echo "[⚠️] 无效选项"; pause ;;
    esac
done