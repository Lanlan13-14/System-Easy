#!/bin/bash

# 颜色定义（标准ANSI，白底可见）
RED='\033[0;31m'          # 红色
GREEN='\033[0;32m'        # 绿色
YELLOW='\033[1;33m'       # 亮黄色
BLUE='\033[0;34m'         # 蓝色
PURPLE='\033[0;35m'       # 紫色
CYAN='\033[0;36m'         # 青色
WHITE='\033[1;37m'        # 亮白色
NC='\033[0m'              # 重置颜色

# 检查是否以root身份运行 🚨
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root身份运行 🚨" 1>&2
   exit 1
fi

# 脚本URL
SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/system.sh"

# 系统信息显示函数 📊（无框无横线版）
show_system_info() {
    clear
    
    # --- 静态信息（只在脚本启动时获取）---
    if [ -z "$STATIC_INFO_LOADED" ]; then
        OS_INFO=$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
        KERNEL=$(uname -r)
        ARCH=$(uname -m)
        HOSTNAME=$(hostname)
        USER=$(whoami)
        CPU_MODEL=$(lscpu | grep "Model name" | cut -d':' -f2 | xargs)
        CPU_CORES=$(nproc)
        STATIC_INFO_LOADED=1
    fi
    
    # --- 动态信息（每次刷新都更新）---
    CPU_FREQ=$(lscpu | grep "CPU MHz" | awk '{print $3}' | head -n1)
    [ -z "$CPU_FREQ" ] && CPU_FREQ=$(lscpu | grep "CPU max MHz" | awk '{print $4}' | head -n1)
    
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    
    DISK_TOTAL=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
    DISK_USED=$(df -BG / | awk 'NR==2 {print $3}' | sed 's/G//')
    DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    
    MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -n "$MAIN_IF" ] && [ -f "/sys/class/net/$MAIN_IF/statistics/rx_bytes" ]; then
        RX_BYTES=$(cat /sys/class/net/$MAIN_IF/statistics/rx_bytes)
        TX_BYTES=$(cat /sys/class/net/$MAIN_IF/statistics/tx_bytes)
        RX_READABLE=$(numfmt --to=iec --suffix=B $RX_BYTES 2>/dev/null || echo "N/A")
        TX_READABLE=$(numfmt --to=iec --suffix=B $TX_BYTES 2>/dev/null || echo "N/A")
    else
        RX_READABLE="N/A"
        TX_READABLE="N/A"
    fi
    
    LOAD_1=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | xargs)
    LOAD_5=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $2}' | xargs)
    LOAD_15=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $3}' | xargs)
    LOAD_1_PERCENT=$(awk "BEGIN {printf \"%.0f\", ($LOAD_1 / $CPU_CORES) * 100}")
    [ $LOAD_1_PERCENT -gt 100 ] && LOAD_1_PERCENT=100
    
    PROCESSES=$(ps aux | wc -l)
    UPTIME=$(uptime -p | sed 's/up //')
    
    # --- 获取公网 IP（使用 ip.sb）---
    IPV4_PUBLIC=$(curl -4 -s --connect-timeout 3 https://ip.sb 2>/dev/null)
    if [ -n "$IPV4_PUBLIC" ] && [[ "$IPV4_PUBLIC" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IPV4_DISPLAY="$IPV4_PUBLIC"
    else
        IPV4_LOCAL=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n1)
        IPV4_DISPLAY="${IPV4_LOCAL:-未分配} (本地)"
    fi
    
    IPV6_PUBLIC=$(curl -6 -s --connect-timeout 3 https://ip.sb 2>/dev/null)
    if [ -n "$IPV6_PUBLIC" ] && [[ "$IPV6_PUBLIC" =~ ^[0-9a-f:]+$ ]]; then
        IPV6_DISPLAY="$IPV6_PUBLIC"
    else
        IPV6_LOCAL=$(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1' | grep -v '^fe80' | head -n1)
        IPV6_DISPLAY="${IPV6_LOCAL:-未分配} (本地)"
    fi
    
    # --- 打印系统信息（无横线，纯颜色标记）---
    # 主机和用户
    echo -e "${YELLOW}➤${NC} ${PURPLE}主机${NC} ${WHITE}$HOSTNAME${NC}  ${YELLOW}➤${NC} ${PURPLE}用户${NC} ${WHITE}$USER${NC}"
    
    # 系统
    echo -e "${YELLOW}➤${NC} ${PURPLE}系统${NC} ${WHITE}${OS_INFO:0:60}${NC}"
    
    # 内核和架构
    echo -e "${YELLOW}➤${NC} ${PURPLE}内核${NC} ${WHITE}$KERNEL${NC}  ${YELLOW}➤${NC} ${PURPLE}架构${NC} ${WHITE}$ARCH${NC}"
    
    # IPv4
    echo -e "${YELLOW}➤${NC} ${PURPLE}IPv4${NC} ${WHITE}$IPV4_DISPLAY${NC}"
    
    # IPv6
    echo -e "${YELLOW}➤${NC} ${PURPLE}IPv6${NC} ${WHITE}$IPV6_DISPLAY${NC}"
    
    # CPU
    echo -e "${YELLOW}➤${NC} ${PURPLE}CPU${NC} ${WHITE}${CPU_MODEL:0:50}${NC}"
    echo -e "  ${CYAN}核心${NC} ${WHITE}$CPU_CORES${NC}  ${CYAN}频率${NC} ${WHITE}$CPU_FREQ MHz${NC}"
    
    # 负载（带进度条）
    if [ $LOAD_1_PERCENT -gt 80 ]; then
        LOAD_COLOR=$RED
    elif [ $LOAD_1_PERCENT -gt 50 ]; then
        LOAD_COLOR=$YELLOW
    else
        LOAD_COLOR=$GREEN
    fi
    LOAD_BAR_WIDTH=30
    LOAD_FILL=$((LOAD_1_PERCENT * LOAD_BAR_WIDTH / 100))
    LOAD_EMPTY=$((LOAD_BAR_WIDTH - LOAD_FILL))
    echo -e "${YELLOW}➤${NC} ${PURPLE}负载${NC} ${WHITE}1min: $LOAD_1  5min: $LOAD_5  15min: $LOAD_15${NC}"
    printf "  ["
    printf "%0.s█" $(seq 1 $LOAD_FILL)
    printf "%0.s░" $(seq 1 $LOAD_EMPTY)
    printf "] ${LOAD_COLOR}%3d%%${NC}\n" $LOAD_1_PERCENT
    
    # 内存（带进度条）
    if [ $MEM_PERCENT -gt 80 ]; then
        MEM_COLOR=$RED
    elif [ $MEM_PERCENT -gt 50 ]; then
        MEM_COLOR=$YELLOW
    else
        MEM_COLOR=$GREEN
    fi
    MEM_BAR_WIDTH=30
    MEM_FILL=$((MEM_PERCENT * MEM_BAR_WIDTH / 100))
    MEM_EMPTY=$((MEM_BAR_WIDTH - MEM_FILL))
    echo -e "${YELLOW}➤${NC} ${PURPLE}内存${NC} ${WHITE}${MEM_USED}MB / ${MEM_TOTAL}MB${NC}"
    printf "  ["
    printf "%0.s█" $(seq 1 $MEM_FILL)
    printf "%0.s░" $(seq 1 $MEM_EMPTY)
    printf "] ${MEM_COLOR}%3d%%${NC}\n" $MEM_PERCENT
    
    # 硬盘（带进度条）
    if [ $DISK_PERCENT -gt 80 ]; then
        DISK_COLOR=$RED
    elif [ $DISK_PERCENT -gt 50 ]; then
        DISK_COLOR=$YELLOW
    else
        DISK_COLOR=$GREEN
    fi
    DISK_BAR_WIDTH=30
    DISK_FILL=$((DISK_PERCENT * DISK_BAR_WIDTH / 100))
    DISK_EMPTY=$((DISK_BAR_WIDTH - DISK_FILL))
    echo -e "${YELLOW}➤${NC} ${PURPLE}硬盘${NC} ${WHITE}${DISK_USED}GB / ${DISK_TOTAL}GB${NC}"
    printf "  ["
    printf "%0.s█" $(seq 1 $DISK_FILL)
    printf "%0.s░" $(seq 1 $DISK_EMPTY)
    printf "] ${DISK_COLOR}%3d%%${NC}\n" $DISK_PERCENT
    
    # 网络流量
    echo -e "${YELLOW}➤${NC} ${PURPLE}网卡${NC} ${WHITE}$MAIN_IF${NC}  ${CYAN}接收${NC} ${WHITE}$RX_READABLE${NC}  ${CYAN}发送${NC} ${WHITE}$TX_READABLE${NC}"
    
    # 运行时间和进程
    echo -e "${YELLOW}➤${NC} ${PURPLE}运行${NC} ${WHITE}$UPTIME${NC}  ${YELLOW}➤${NC} ${PURPLE}进程${NC} ${WHITE}$PROCESSES${NC}"
    
    echo ""  # 空行分隔
}

# 功能1：安装常用工具和依赖 🛠️
install_tools() {
    echo "正在更新软件包列表 📦..."
    apt update -y
    echo "正在安装常用工具和依赖：curl、vim、git、python3-systemd、systemd-journal-remote、cron、at、net-tools、iproute2、unzip、jq 🚀..."
    apt install -y curl vim git python3-systemd systemd-journal-remote cron at net-tools iproute2 unzip jq
    if [ $? -eq 0 ]; then
        echo "所有工具和依赖安装完成 🎉"
    else
        echo "安装失败，请检查网络或软件源 😔"
    fi
}
# 功能2：日志清理子菜单 🗑️
log_cleanup_menu() {
    while true; do
        echo "日志清理菜单 🗑️："
        echo "1. 开启自动日志清理（每天凌晨02:00） ⏰"
        echo "2. 关闭自动日志清理 🚫"
        echo "3. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "正在启用自动日志清理 ⏳..."
                cron_job="0 2 * * * journalctl --vacuum-time=2weeks && find /var/log -type f -name '*.log.*' -exec rm {} \; && find /var/log -type f -name '*.gz' -exec rm {} \;"
                (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
                echo "自动日志清理已启用（每天凌晨02:00） 🎉"
                ;;
            2)
                echo "正在关闭自动日志清理 🚫..."
                crontab -l | grep -v "journalctl --vacuum-time=2weeks" | crontab -
                echo "自动日志清理已关闭 ✅"
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# bbr管理
bbr_menu() {
    BBR_BACKUP_DIR="/etc/sysctl_backup"

    # --- 辅助函数 ---
    check_bbr_loaded() {
        lsmod | grep -q tcp_bbr
    }

    apply_sysctl() {
        sysctl --system >/dev/null 2>&1 || true
    }

    restore_default_tcp() {
        sed -i '/net\.core\.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
        if sysctl net.ipv4.tcp_congestion_control >/dev/null 2>&1; then
            if ! grep -q '^net\.ipv4\.tcp_congestion_control=cubic' /etc/sysctl.conf 2>/dev/null; then
                echo "net.ipv4.tcp_congestion_control=cubic" >> /etc/sysctl.conf
            fi
        else
            sed -i '/^ *net\.ipv4\.tcp_congestion_control/ s/^/# /' /etc/sysctl.conf
        fi
        apply_sysctl
    }

    # 🔥 优化后的清理函数（保留但不用于卸载流程）
    reset_sysctl_d_defaults() {
        echo "🔄 正在彻底清理 sysctl 配置..."

        # 1. 清空 /etc/sysctl.d（保留目录）
        if [ -d /etc/sysctl.d ]; then
            find /etc/sysctl.d -type f -name '*.conf' -delete
        else
            mkdir -p /etc/sysctl.d
        fi

        # 2. 清空 sysctl.conf（保留文件）
        : > /etc/sysctl.conf

        # 3. 卸载 BBR 模块（如已加载）
        if check_bbr_loaded; then
            rmmod tcp_bbr 2>/dev/null || true
        fi

        # 4. 重新加载系统默认 sysctl
        sysctl --system >/dev/null 2>&1 || true
    }

    # --- 主菜单 ---
    while true; do
        clear
        echo "================ BBR管理菜单 ⚡ ================"
        echo "1. 安装BBR v3 🚀"
        echo "2. 应用BBR优化 ⚙️"
        echo "3. 卸载BBR 🗑️"
        echo "4. 恢复备份 🔄"
        echo "5. 重置BBR配置 🔄"
        echo "6. 备份管理 🗂️"
        echo "7. 返回主菜单 🔙"
        echo "=============================================="
        read -p "请输入您的选择: " choice
        case $choice in
            1)
                echo "正在安装BBR v3内核 ⏳..."
                bash <(curl -L -s https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh)
                if check_bbr_loaded; then
                    echo "✅ BBR v3内核安装成功"
                else
                    echo "❌ BBR安装失败"
                fi
                read -p "按回车返回菜单 🔙"
                ;;
            2)
                echo "应用BBR优化配置 ⚙️..."
                if ! sysctl net.ipv4.tcp_available_congestion_control >/dev/null 2>&1; then
                    echo "⚠️ 当前内核不支持 BBR"
                    read -p "按回车返回菜单 🔙"
                    continue
                fi
                if ! check_bbr_loaded; then
                    echo "检测到 BBR 模块未加载，正在尝试加载..."
                    modprobe tcp_bbr 2>/dev/null || echo "⚠️ 模块加载失败"
                fi
                bash -c "$(curl -fsSL https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/bbr.sh)"
                apply_sysctl
                echo "✅ BBR优化配置已应用"
                echo "当前TCP拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未支持')"
                read -p "按回车返回菜单 🔙"
                ;;
            3)
                echo "卸载BBR（将按指定流程删除/清空配置）🗑️"
                echo "将执行以下操作："
                echo "  rm -f /etc/sysctl.d/network-tuning.conf"
                echo "  rm -f /etc/security/limits.d/99-custom-limits.conf"
                echo "  rm -rf /etc/sysctl.d"
                echo "  echo \"\" > /etc/sysctl.conf"
                echo "  sysctl -p"
                echo "  sysctl --system"
                echo "并会尝试卸载 tcp_bbr 模块（如已加载）。"
                read -p "确认执行上述卸载与清理操作？输入 'yes' 以继续: " confirm_uninstall
                if [[ "$confirm_uninstall" != "yes" ]]; then
                    echo "已取消卸载操作。"
                    read -p "按回车返回菜单 🔙"
                    continue
                fi

                # 1) 卸载 BBR 模块（如已加载）
                if check_bbr_loaded; then
                    if rmmod tcp_bbr 2>/dev/null; then
                        echo "✅ BBR 模块已移除"
                    else
                        echo "⚠️ 无法移除 BBR 模块（可能正在使用或内核不允许），继续执行清理"
                    fi
                else
                    echo "BBR 模块未加载，无需卸载 ✅"
                fi

                # 2) 删除指定文件（按你的要求）
                rm -f /etc/sysctl.d/network-tuning.conf 2>/dev/null || true
                rm -f /etc/security/limits.d/99-custom-limits.conf 2>/dev/null || true

                # 3) 删除整个 /etc/sysctl.d 目录（危险操作，按你的要求执行）
                if [ -d /etc/sysctl.d ]; then
                    rm -rf /etc/sysctl.d
                    # 重新创建空目录以避免后续工具报错
                    mkdir -p /etc/sysctl.d
                fi

                # 4) 清空 /etc/sysctl.conf
                : > /etc/sysctl.conf

                # 5) 立即应用 sysctl 配置
                sysctl -p 2>/dev/null || true
                sysctl --system 2>/dev/null || true

                # 6) 恢复默认拥塞控制为 cubic（确保系统有合理默认）
                restore_default_tcp

                echo "✅ 卸载与清理完成，请检查系统并重启以确保所有更改生效。"
                read -p "按回车返回菜单 🔙"
                ;;
            4)
                echo "恢复备份 🔄"
                mkdir -p "$BBR_BACKUP_DIR"
                mapfile -t backups < <(ls "$BBR_BACKUP_DIR"/*.tar.gz 2>/dev/null)
                if [ ${#backups[@]} -eq 0 ]; then
                    echo "⚠️ 无可用备份"
                    read -p "按回车返回菜单 🔙"
                    continue
                fi
                echo "可用备份列表:"
                for i in "${!backups[@]}"; do
                    echo "[$((i+1))] ${backups[$i]}"
                done
                read -p "请输入备份编号: " idx
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ -z "${backups[$((idx-1))]}" ]; then
                    echo "❌ 无效编号"
                    read -p "按回车返回菜单 🔙"
                    continue
                fi
                backup_file="${backups[$((idx-1))]}"
                echo "正在还原 $backup_file ..."
                rm -rf /etc/sysctl.d/*
                if tar -xzf "$backup_file" -C /etc; then
                    apply_sysctl
                    echo "✅ 还原完成: $backup_file"
                else
                    echo "❌ 还原失败"
                fi
                read -p "按回车返回菜单 🔙"
                ;;
            5)
                echo "重置BBR配置 🔄..."
                reset_sysctl_d_defaults
                echo "✅ BBR已彻底重置为系统默认（cubic）"
                read -p "按回车返回菜单 🔙"
                ;;
            6)
                echo "备份管理 🗂️"
                mkdir -p "$BBR_BACKUP_DIR"
                mapfile -t backups < <(ls "$BBR_BACKUP_DIR"/*.tar.gz 2>/dev/null)
                if [ ${#backups[@]} -eq 0 ]; then
                    echo "⚠️ 无可用备份"
                    read -p "按回车返回菜单 🔙"
                    continue
                fi
                echo "可用备份列表:"
                for i in "${!backups[@]}"; do
                    echo "[$((i+1))] ${backups[$i]}"
                done
                echo "[0] 删除全部备份"
                read -p "请输入要删除的备份编号: " del_idx
                if [[ "$del_idx" =~ ^[0-9]+$ ]]; then
                    if [ "$del_idx" -eq 0 ]; then
                        rm -f "$BBR_BACKUP_DIR"/*.tar.gz
                        echo "✅ 已删除所有备份"
                    elif [ "$del_idx" -ge 1 ] && [ "$del_idx" -le "${#backups[@]}" ]; then
                        rm -f "${backups[$((del_idx-1))]}"
                        echo "✅ 已删除备份: ${backups[$((del_idx-1))]}"
                    else
                        echo "⚠️ 无效编号"
                    fi
                fi
                read -p "按回车返回菜单 🔙"
                ;;
            7)
                return
                ;;
            *)
                echo "❌ 无效选择"
                ;;
        esac
    done
}
# 功能4：DNS管理子菜单 🌐
dns_menu() {
    while true; do
        echo "DNS管理菜单 🌐："
        echo "1. 查看当前系统DNS 🔍"
        echo "2. 修改系统DNS（永久更改） ✏️"
        echo "3. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "当前DNS设置："
                cat /etc/resolv.conf
                ;;
            2)
                echo "警告：此操作将永久修改系统DNS ❗"
                read -p "请输入新的DNS服务器（例如8.8.8.8）： " dns1
                read -p "请输入备用DNS服务器（可选，例如8.8.4.4）： " dns2
                echo "nameserver $dns1" > /etc/resolv.conf
                if [ ! -z "$dns2" ]; then
                    echo "nameserver $dns2" >> /etc/resolv.conf
                fi
                chattr +i /etc/resolv.conf
                echo "DNS已永久修改 🎉"
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能5：修改主机名 🖥️
change_hostname() {
    current_hostname=$(hostname)
    echo "当前主机名：$current_hostname"
    read -p "请输入新主机名： " new_hostname
    echo "警告：此操作将永久更改主机名 ❗"
    hostnamectl set-hostname "$new_hostname"
    sed -i "s/$current_hostname/$new_hostname/g" /etc/hosts
    echo "主机名已更改为$new_hostname 🎉"
}
# 功能6：SSH端口管理子菜单 🔒
ssh_port_menu() {
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1 || echo "22")
    echo "当前SSH端口：$current_port 🔍"
    while true; do
        echo "SSH端口管理菜单 🔒："
        echo "1. 修改SSH端口（原端口将立即失效） ✏️"
        echo "2. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                read -p "请输入新的SSH端口号（1-65535）： " new_port
                # 验证端口有效性
                if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                    echo "无效端口号，请输入1-65535之间的数字 😕"
                    continue
                fi
                # 检查端口是否被占用
                if command -v ss >/dev/null && ss -tuln | grep -q ":$new_port "; then
                    echo "端口 $new_port 已被占用，请选择其他端口 😔"
                    continue
                elif command -v netstat >/dev/null && netstat -tuln | grep -q ":$new_port "; then
                    echo "端口 $new_port 已被占用，请选择其他端口 😔"
                    continue
                fi
                # 备份SSH配置文件
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
                # 修改SSH配置文件，替换所有Port配置
                sed -i "/^#*Port /d" /etc/ssh/sshd_config
                echo "Port $new_port" >> /etc/ssh/sshd_config
                # 检查UFW并添加规则
                if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
                    echo "检测到UFW防火墙已启用，正在为新端口 $new_port 添加放行规则 🛡️..."
                    if ufw allow "$new_port"/tcp && ufw reload; then
                        echo "UFW规则已更新，新端口 $new_port 已放行 🎉"
                    else
                        echo "UFW规则添加失败，正在回滚SSH配置 😔"
                        mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                        continue
                    fi
                fi
                # 测试SSH配置
                if sshd -t >/dev/null 2>&1; then
                    # 重启SSH服务
                    if systemctl restart ssh >/dev/null 2>&1; then
                        echo "原端口已失效，SSH端口已修改为 $new_port，请用新端口登录，如无法登录，请检查防火墙是否放行 $new_port 端口 ❗"
                        current_port="$new_port"
                    else
                        echo "SSH服务重启失败 😔 请检查："
                        echo " systemctl status ssh.service"
                        echo " journalctl -xeu ssh.service"
                        mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                        continue
                    fi
                else
                    echo "SSH配置文件测试失败 😔 请检查："
                    echo " sshd -t"
                    mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                    continue
                fi
                ;;
            2)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能7：修改SSH密码 🔑
change_ssh_password() {
    echo "生成一个20位复杂密码 🔐..."
    # 生成复杂密码，包含大小写字母、数字、特殊字符
    new_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!@#%^&*()_+' | head -c 20)
    # 确保密码包含至少1个大写字母、1个小写字母、1个数字、1个特殊字符
    while true; do
        has_upper=$(echo "$new_pass" | grep -q '[A-Z]' && echo "yes" || echo "no")
        has_lower=$(echo "$new_pass" | grep -q '[a-z]' && echo "yes" || echo "no")
        has_digit=$(echo "$new_pass" | grep -q '[0-9]' && echo "yes" || echo "no")
        has_special=$(echo "$new_pass" | grep -q '[!@#%^&*()_+]' && echo "yes" || echo "no")
        if [ "$has_upper" = "yes" ] && [ "$has_lower" = "yes" ] && [ "$has_digit" = "yes" ] && [ "$has_special" = "yes" ]; then
            break
        fi
        new_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!@#%^&*()_+' | head -c 20)
    done
    echo "生成的密码：$new_pass"
    echo "警告：修改后，仅新密码可用于登录，旧密码将失效 ❗"
    echo "您可以直接使用以上生成的密码，或输入自定义密码。"
    read -p "请输入新密码（可见，留空使用生成密码）： " pass1
    if [ -z "$pass1" ]; then
        pass1="$new_pass"
    fi
    read -p "请再次确认新密码（可见）： " pass2
    if [ "$pass1" != "$pass2" ]; then
        echo "两次输入的密码不匹配，操作取消 😔"
        return
    fi
    # 尝试修改密码
    if echo "root:$pass1" | chpasswd; then
        echo "SSH密码已更改，新密码为：$pass1 🎉"
        echo "请保存新密码，并立即测试SSH登录（ssh root@your_server -p $current_port） ❗"
        echo "如果无法登录，请检查："
        echo " journalctl -xeu ssh.service"
    else
        echo "密码修改失败 😔 请检查："
        echo " journalctl -xeu ssh.service"
        echo "您可以尝试手动修改密码：sudo passwd root"
    fi
}
# 功能8：SSH密钥登录管理 🔑
ssh_key_management() {
    echo "正在拉取并执行SSH安全初始化脚本 ⏳..."
    bash <(curl -sL https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/ssh-secure-init.sh)
    if [ $? -eq 0 ]; then
        echo "SSH密钥登录管理完成 🎉"
    else
        echo "执行失败，请检查网络或脚本URL 😔"
    fi
}
# 功能9：卸载脚本 🗑️
uninstall_script() {
    echo "正在卸载脚本（仅删除脚本本身） 🗑️..."
    rm -f "$0"
    echo "脚本已删除，即将退出 🚪"
    exit 0
}
# 功能10：设置系统时区与时间同步 ⏰
set_timezone() {
    while true; do
        echo "系统时区与时间同步管理菜单 ⏰："
        echo "1. 查看当前系统时区 🔍"
        echo "2. 设置系统时区 🌍"
        echo "3. 启用/配置NTP时间同步 🕒"
        echo "4. 禁用NTP时间同步 🚫"
        echo "5. 立即进行时间同步 🔄"
        echo "6. 返回主菜单 🔙"
        read -p "请输入您的选择 [1-6]： " tz_choice
        case $tz_choice in
            1)
                echo "当前系统时区：$(timedatectl show --property=Timezone --value 2>/dev/null || echo '无法获取时区信息')"
                echo "NTP服务状态：$(timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q 'yes' && echo '已同步' || echo '未同步')"
                if systemctl is-active --quiet chronyd 2>/dev/null; then
                    echo "chronyd 服务状态：运行中"
                else
                    echo "chronyd 服务状态：未运行"
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            2)
                echo "请选择时区："
                echo "[1] UTC 🌍"
                echo "[2] Asia/Shanghai（中国标准时间）"
                echo "[3] America/New_York（纽约时间）"
                echo "[4] 手动输入时区 ✏️"
                read -p "请输入您的选择 [1-4]： " tz_subchoice
                case $tz_subchoice in
                    1)
                        if timedatectl set-timezone UTC 2>/dev/null; then
                            echo "时区已设置为UTC 🎉"
                        else
                            echo "时区设置失败，请检查 timedatectl 是否可用 😔"
                        fi
                        ;;
                    2)
                        if timedatectl set-timezone Asia/Shanghai 2>/dev/null; then
                            echo "时区已设置为Asia/Shanghai 🎉"
                        else
                            echo "时区设置失败，请检查 timedatectl 是否可用 😔"
                        fi
                        ;;
                    3)
                        if timedatectl set-timezone America/New_York 2>/dev/null; then
                            echo "时区已设置为America/New_York 🎉"
                        else
                            echo "时区设置失败，请检查 timedatectl 是否可用 😔"
                        fi
                        ;;
                    4)
                        echo "请输入时区（格式示例：Asia/Shanghai 或 Europe/London） 📝"
                        echo "可使用 'timedatectl list-timezones' 查看可用时区 🔍"
                        read -p "请输入时区： " custom_tz
                        if timedatectl set-timezone "$custom_tz" 2>/dev/null; then
                            echo "时区已设置为$custom_tz 🎉"
                        else
                            echo "时区设置失败，请检查输入格式（例如Asia/Shanghai）或 timedatectl 是否可用 😔"
                        fi
                        ;;
                    *)
                        echo "无效选择，时区未更改 😕"
                        ;;
                esac
                echo "按回车键返回菜单 🔙"
                read
                ;;
            3)
                echo "正在启用和配置NTP时间同步 ⏳..."
                # 安装 chrony（如果未安装）
                if ! command -v chronyd >/dev/null; then
                    echo "未检测到chrony，正在安装..."
                    apt update -y && apt install -y chrony
                    if [ $? -eq 0 ]; then
                        echo "chrony 安装成功 🎉"
                    else
                        echo "chrony 安装失败，请检查网络或软件源 😔"
                        continue
                    fi
                fi
                # 提供NTP服务器选择
                echo "请选择NTP服务器："
                echo "[1] ntp.ntsc.ac.cn（中国授时中心）"
                echo "[2] ntp.tencent.com（腾讯公共 NTP 服务器）"
                echo "[3] ntp.aliyun.com（阿里云公共 NTP 服务器）"
                echo "[4] pool.ntp.org（国际 NTP 快速授时服务，默认）"
                echo "[5] time1.google.com（Google公共 NTP 服务器）"
                echo "[6] time.cloudflare.com（Cloudflare公共 NTP 服务器）"
                echo "[7] time.asia.apple.com（Apple公共 NTP 服务器）"
                echo "[8] time.windows.com（Microsoft公共 NTP 服务器）"
                echo "[9] time.facebook.com（Facebook公共 NTP 服务器）"
                echo "[10] 手动输入NTP服务器 ✏️"
                read -p "请输入您的选择 [1-10]（直接回车默认选4）： " ntp_choice
                # 设置默认值为4（pool.ntp.org）
                ntp_choice=${ntp_choice:-4}
                case $ntp_choice in
                    1) ntp_servers=("ntp.ntsc.ac.cn") ;;
                    2) ntp_servers=("ntp.tencent.com") ;;
                    3) ntp_servers=("ntp.aliyun.com") ;;
                    4) ntp_servers=("0.pool.ntp.org" "1.pool.ntp.org" "2.pool.ntp.org" "3.pool.ntp.org") ;;
                    5) ntp_servers=("time1.google.com") ;;
                    6) ntp_servers=("time.cloudflare.com") ;;
                    7) ntp_servers=("time.asia.apple.com") ;;
                    8) ntp_servers=("time.windows.com") ;;
                    9) ntp_servers=("time.facebook.com") ;;
                    10)
                        read -p "请输入NTP服务器地址（多个地址用空格分隔，例如：ntp.example.com ntp2.example.com）： " custom_ntp
                        if [ -z "$custom_ntp" ]; then
                            echo "未输入NTP服务器地址，使用默认 pool.ntp.org 🎯"
                            ntp_servers=("0.pool.ntp.org" "1.pool.ntp.org" "2.pool.ntp.org" "3.pool.ntp.org")
                        else
                            # 将输入的NTP服务器地址分割为数组
                            read -a ntp_servers <<< "$custom_ntp"
                            # 验证输入的NTP服务器地址（简单检查非空和格式）
                            valid_servers=()
                            for server in "${ntp_servers[@]}"; do
                                if [[ "$server" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                                    valid_servers+=("$server")
                                else
                                    echo "警告：'$server' 格式无效，已忽略 😔"
                                fi
                            done
                            if [ ${#valid_servers[@]} -eq 0 ]; then
                                echo "无有效NTP服务器地址，使用默认 pool.ntp.org 🎯"
                                ntp_servers=("0.pool.ntp.org" "1.pool.ntp.org" "2.pool.ntp.org" "3.pool.ntp.org")
                            else
                                ntp_servers=("${valid_servers[@]}")
                            fi
                        fi
                        ;;
                    *)
                        echo "无效选择，使用默认NTP服务器 pool.ntp.org 🎯"
                        ntp_servers=("0.pool.ntp.org" "1.pool.ntp.org" "2.pool.ntp.org" "3.pool.ntp.org")
                        ;;
                esac
                # 配置NTP服务器
                cat > /etc/chrony/chrony.conf << EOF
$(for server in "${ntp_servers[@]}"; do echo "server $server iburst"; done)
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1.0 3
EOF
                # 启用并启动chrony服务
                systemctl enable chronyd >/dev/null 2>&1
                systemctl restart chronyd >/dev/null 2>&1
                if systemctl is-active --quiet chronyd; then
                    echo "NTP服务已启用并配置完成 🎉"
                    echo "使用的NTP服务器：${ntp_servers[*]}"
                    # 尝试启用系统NTP（忽略不支持的情况）
                    if ! timedatectl set-ntp true 2>/dev/null; then
                        echo "警告：系统不支持 timedatectl set-ntp，依赖 chronyd 进行时间同步 ⚠️"
                    fi
                    # 等待时间同步，最多尝试3次，每次10秒
                    echo "等待时间同步（最多30秒） ⏳..."
                    for attempt in {1..3}; do
                        chronyc -a makestep >/dev/null 2>&1
                        sleep 10
                        if chronyc tracking >/dev/null 2>&1; then
                            echo "时间同步成功，当前时间：$(date) ✅"
                            break
                        else
                            if [ $attempt -eq 3 ]; then
                                echo "时间同步尚未完成，请检查以下内容 😔："
                                echo " - 网络连接是否正常"
                                echo " - NTP服务器（${ntp_servers[*]}）是否可达"
                                echo " - 防火墙是否允许 UDP 123 端口"
                                echo " - 日志：journalctl -xeu chronyd"
                                echo "您可以尝试选择'5. 立即进行时间同步'重试 🔄"
                            fi
                        fi
                    done
                else
                    echo "NTP服务启动失败，请检查：journalctl -xeu chronyd 😔"
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            4)
                echo "正在禁用NTP时间同步 🚫..."
                if timedatectl set-ntp false 2>/dev/null; then
                    echo "系统NTP已禁用 🎉"
                else
                    echo "警告：系统不支持 timedatectl set-ntp，尝试停止 chronyd 服务 ⚠️"
                fi
                if systemctl is-active --quiet chronyd; then
                    systemctl stop chronyd >/dev/null 2>&1
                    systemctl disable chronyd >/dev/null 2>&1
                    echo "chronyd 服务已停止并禁用 🎉"
                else
                    echo "chronyd 服务未运行，无需禁用 ✅"
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            5)
                echo "正在进行时间同步 🔄..."
                if ! command -v chronyd >/dev/null; then
                    echo "未检测到chrony，请先选择'3. 启用/配置NTP时间同步' 😕"
                    echo "按回车键返回菜单 🔙"
                    read
                    continue
                fi
                if systemctl is-active --quiet chronyd; then
                    chronyc -a makestep >/dev/null 2>&1
                    sleep 10
                    if chronyc tracking >/dev/null 2>&1; then
                        echo "时间同步成功，当前时间：$(date) 🎉"
                    else
                        echo "时间同步失败，请检查以下内容 😔："
                        echo " - 网络连接是否正常"
                        echo " - NTP服务器是否可达"
                        echo " - 防火墙是否允许 UDP 123 端口"
                        echo " - 日志：journalctl -xeu chronyd"
                    fi
                else
                    echo "NTP服务未运行，请先选择'3. 启用/配置NTP时间同步' 😕"
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            6)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能11：更新脚本 📥
update_script() {
    echo "正在更新脚本 📥..."
    # 备份当前脚本
    backup_file="/tmp/system-easy-backup-$(date +%Y%m%d%H%M%S).sh"
    cp /usr/local/bin/system-easy "$backup_file"
    echo "当前脚本已备份为：$backup_file 📂"
    # 下载新脚本
    echo "正在从 $SCRIPT_URL 下载新脚本 ⏳..."
    if curl -L "$SCRIPT_URL" -o /tmp/system-easy-new; then
        # 检查新脚本语法
        if bash -n /tmp/system-easy-new; then
            echo "新脚本语法检查通过，正在替换 🎉..."
            chmod +x /tmp/system-easy-new
            mv /tmp/system-easy-new /usr/local/bin/system-easy
            rm -f "$backup_file"
            echo "脚本更新成功，备份文件已删除 🗑️"
            echo "正在启动新脚本 🚀..."
            exec /usr/local/bin/system-easy
        else
            echo "新脚本语法检查失败，正在回滚 🔄..."
            mv "$backup_file" /usr/local/bin/system-easy
            rm -f /tmp/system-easy-new
            echo "已回滚到备份脚本，备份文件已恢复到 /usr/local/bin/system-easy 📂"
            exec /usr/local/bin/system-easy
        fi
    else
        echo "下载新脚本失败，正在回滚 🔄..."
        mv "$backup_file" /usr/local/bin/system-easy
        rm -f /tmp/system-easy-new
        echo "已回滚到备份脚本，备份文件已恢复到 /usr/local/bin/system-easy 📂"
        exec /usr/local/bin/system-easy
    fi
}
# 功能12：查看端口占用 🔍
check_port_usage() {
    read -p "请输入要检查的端口号： " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "无效端口号，请输入1-65535之间的数字 😕"
        return
    fi
    echo "端口 $port 的占用情况 🔍："
    echo "PID Process Name Address"
    processes_found=0
    if command -v ss >/dev/null; then
        # 使用 ss 获取监听端口的PID和进程信息
        ss_output=$(ss -tuln -p | grep ":$port ")
        if [ -n "$ss_output" ]; then
            while read -r line; do
                address=$(echo "$line" | awk '{print $5}')
                pid=$(echo "$line" | grep -o 'pid=[0-9]*' | cut -d= -f2)
                if [ -n "$pid" ]; then
                    process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "未知")
                    echo "$pid $process_name $address"
                    processes_found=1
                fi
            done <<< "$ss_output"
        fi
    elif command -v netstat >/dev/null; then
        # 使用 netstat 获取监听端口的PID和进程信息
        netstat_output=$(netstat -tulnp | grep ":$port ")
        if [ -n "$netstat_output" ]; then
            while read -r line; do
                address=$(echo "$line" | awk '{print $4}')
                pid_process=$(echo "$line" | awk '{print $7}')
                pid=$(echo "$pid_process" | cut -d/ -f1)
                process_name=$(echo "$pid_process" | cut -d/ -f2-)
                if [ -n "$pid" ]; then
                    echo "$pid $process_name $address"
                    processes_found=1
                fi
            done <<< "$netstat_output"
        fi
    else
        echo "未安装 ss 或 netstat，无法检查端口占用 😔"
        return
    fi
    if [ $processes_found -eq 0 ]; then
        echo "端口 $port 未被占用 ✅"
        return
    fi
    while true; do
        echo "处理选项："
        echo "1. 关闭程序 🛑"
        echo "2. 重启程序 🔄"
        echo "3. 返回 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                read -p "请输入要关闭的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                if kill -9 "$pid"; then
                    echo "进程 $pid 已关闭 🎉"
                else
                    echo "关闭进程失败，请检查PID是否正确 😔"
                fi
                ;;
            2)
                read -p "请输入要重启的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                process_cmd=$(ps -p "$pid" -o comm=)
                if kill "$pid" && sleep 1 && command -v "$process_cmd" >/dev/null; then
                    "$process_cmd" &
                    echo "进程 $pid 已重启 🎉"
                else
                    echo "重启进程失败，请检查PID或程序是否可重启 😔"
                fi
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能13：查看内存占用最大程序 💾
check_memory_usage() {
    echo "内存占用最大的5个进程 💾："
    ps -eo pid,ppid,cmd,%mem --sort=-%mem | head -n 6
    while true; do
        echo "处理选项："
        echo "1. 关闭程序 🛑"
        echo "2. 重启程序 🔄"
        echo "3. 停止程序 ⏹️"
        echo "4. 返回 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                read -p "请输入要关闭的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                if kill -9 "$pid"; then
                    echo "进程 $pid 已关闭 🎉"
                else
                    echo "关闭进程失败，请检查PID是否正确 😔"
                fi
                ;;
            2)
                read -p "请输入要重启的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                process_cmd=$(ps -p "$pid" -o comm=)
                if kill "$pid" && sleep 1 && command -v "$process_cmd" >/dev/null; then
                    "$process_cmd" &
                    echo "进程 $pid 已重启 🎉"
                else
                    echo "重启进程失败，请检查PID或程序是否可重启 😔"
                fi
                ;;
            3)
                read -p "请输入要停止的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                if kill "$pid"; then
                    echo "进程 $pid 已停止 🎉"
                else
                    echo "停止进程失败，请检查PID是否正确 😔"
                fi
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能14：查看CPU占用最大程序 🖥️
check_cpu_usage() {
    echo "CPU占用最大的5个进程 🖥️："
    ps -eo pid,ppid,cmd,%cpu --sort=-%cpu | head -n 6
    while true; do
        echo "处理选项："
        echo "1. 关闭程序 🛑"
        echo "2. 重启程序 🔄"
        echo "3. 停止程序 ⏹️"
        echo "4. 返回 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                read -p "请输入要关闭的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                if kill -9 "$pid"; then
                    echo "进程 $pid 已关闭 🎉"
                else
                    echo "关闭进程失败，请检查PID是否正确 😔"
                fi
                ;;
            2)
                read -p "请输入要重启的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                process_cmd=$(ps -p "$pid" -o comm=)
                if kill "$pid" && sleep 1 && command -v "$process_cmd" >/dev/null; then
                    "$process_cmd" &
                    echo "进程 $pid 已重启 🎉"
                else
                    echo "重启进程失败，请检查PID或程序是否可重启 😔"
                fi
                ;;
            3)
                read -p "请输入要停止的进程ID（PID）： " pid
                if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
                    echo "无效或不存在的PID：$pid，请检查 😔"
                    continue
                fi
                if kill "$pid"; then
                    echo "进程 $pid 已停止 🎉"
                else
                    echo "停止进程失败，请检查PID是否正确 😔"
                fi
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能15：设置系统定时重启 🔄
set_system_reboot() {
    while true; do
        echo "系统定时重启菜单 🔄："
        echo "1. 设置系统定时重启 ⏰"
        echo "2. 删除系统定时重启任务 🗑️"
        echo "3. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "请选择定时重启方式："
                echo "1. 运行X小时后重启 ⏳"
                echo "2. 每天某时间重启 🌞"
                echo "3. 每周某天某时间重启 📅"
                echo "4. 每月某天某时间重启 📆"
                read -p "请输入您的选择 [1-4]： " reboot_choice
                case $reboot_choice in
                    1)
                        read -p "请输入运行小时数（例如 24）： " hours
                        if [[ "$hours" =~ ^[0-9]+$ ]]; then
                            echo "shutdown -r +$((hours*60))" | at now
                            echo "系统将在 $hours 小时后重启 🎉"
                        else
                            echo "请输入有效的小时数 😕"
                        fi
                        ;;
                    2)
                        read -p "请输入每天重启时间（格式 HH:MM，例如 02:00）： " time
                        if [[ "$time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                            hour=$(echo "$time" | cut -d: -f1)
                            minute=$(echo "$time" | cut -d: -f2)
                            (crontab -l 2>/dev/null; echo "$minute $hour * * * /sbin/shutdown -r now") | crontab -
                            echo "每天 $time 重启任务已设置 🎉"
                        else
                            echo "请输入有效的时间格式（HH:MM） 😕"
                        fi
                        ;;
                    3)
                        echo "请输入星期几（0=周日，1=周一，...，6=周六）："
                        read -p "星期（0-6）： " weekday
                        read -p "重启时间（格式 HH:MM，例如 02:00）： " time
                        if [[ "$weekday" =~ ^[0-6]$ && "$time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                            hour=$(echo "$time" | cut -d: -f1)
                            minute=$(echo "$time" | cut -d: -f2)
                            (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday /sbin/shutdown -r now") | crontab -
                            echo "每周星期 $weekday $time 重启任务已设置 🎉"
                        else
                            echo "请输入有效的星期（0-6）和时间格式（HH:MM） 😕"
                        fi
                        ;;
                    4)
                        read -p "请输入每月第几天（1-31）： " day
                        read -p "重启时间（格式 HH:MM，例如 02:00）： " time
                        if [[ "$day" =~ ^[1-3]?[0-9]$ && "$time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                            hour=$(echo "$time" | cut -d: -f1)
                            minute=$(echo "$time" | cut -d: -f2)
                            (crontab -l 2>/dev/null; echo "$minute $hour $day * * /sbin/shutdown -r now") | crontab -
                            echo "每月 $day 号 $time 重启任务已设置 🎉"
                        else
                            echo "请输入有效的日期（1-31）和时间格式（HH:MM） 😕"
                        fi
                        ;;
                    *)
                        echo "无效选择，请重试 😕"
                        ;;
                esac
                ;;
            2)
                echo "正在删除所有系统定时重启任务 🗑️..."
                crontab -l | grep -v "/sbin/shutdown -r now" | crontab -
                atq | while read -r job; do atrm "$(echo $job | awk '{print $1}')"; done
                echo "所有定时重启任务已删除 🎉"
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能16：Cron任务管理 ⏰
cron_task_menu() {
    # 检查是否安装cron，如果没有，自动安装
    if ! command -v crontab >/dev/null; then
        echo "未检测到cron，正在自动安装... ⏳"
        apt update -y && apt install -y cron
        if [ $? -eq 0 ]; then
            echo "cron 安装成功 🎉"
            systemctl enable cron >/dev/null 2>&1
            systemctl start cron >/dev/null 2>&1
        else
            echo "cron 安装失败，请检查网络或软件源 😔"
            return
        fi
    fi
    while true; do
        echo "Cron任务管理菜单 ⏰："
        echo "1. 查看Cron任务 🔍"
        echo "2. 删除Cron任务 🗑️"
        echo "3. 添加Cron任务 ✏️"
        echo "4. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "当前所有Cron任务："
                task_count=0
                declare -A cron_tasks
                # 遍历所有用户的Crontab
                for user in $(ls /var/spool/cron/crontabs 2>/dev/null); do
                    while IFS= read -r line; do
                        # 跳过空行和注释
                        if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                            task_count=$((task_count + 1))
                            cron_tasks[$task_count]="$user: $line"
                            echo "[$task_count] $user: $line"
                        fi
                    done < "/var/spool/cron/crontabs/$user"
                done
                if [ $task_count -eq 0 ]; then
                    echo "无Cron任务 😕"
                fi
                ;;
            2)
                echo "当前所有Cron任务："
                task_count=0
                declare -A cron_tasks
                declare -A cron_users
                # 列出所有任务并分配编号
                for user in $(ls /var/spool/cron/crontabs 2>/dev/null); do
                    while IFS= read -r line; do
                        if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                            task_count=$((task_count + 1))
                            cron_tasks[$task_count]="$line"
                            cron_users[$task_count]="$user"
                            echo "[$task_count] $user: $line"
                        fi
                    done < "/var/spool/cron/crontabs/$user"
                done
                if [ $task_count -eq 0 ]; then
                    echo "无Cron任务可删除 😕"
                    continue
                fi
                read -p "请输入要删除的任务编号（多个编号用空格隔开，例如 1 3 5）： " delete_ids
                # 验证输入
                for id in $delete_ids; do
                    if ! [[ "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 1 ] || [ "$id" -gt $task_count ]; then
                        echo "无效编号：$id，请输入1-$task_count之间的数字 😕"
                        continue 2
                    fi
                done
                # 删除指定任务
                for user in $(ls /var/spool/cron/crontabs 2>/dev/null); do
                    temp_file=$(mktemp)
                    cp "/var/spool/cron/crontabs/$user" "$temp_file"
                    task_index=0
                    keep_lines=()
                    while IFS= read -r line; do
                        if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                            task_index=$((task_index + 1))
                            keep=1
                            for id in $delete_ids; do
                                if [ "$id" -eq "$task_index" ] && [ "${cron_users[$id]}" = "$user" ]; then
                                    keep=0
                                    break
                                fi
                            done
                            if [ $keep -eq 1 ]; then
                                keep_lines+=("$line")
                            fi
                        else
                            keep_lines+=("$line")
                        fi
                    done < "/var/spool/cron/crontabs/$user"
                    # 写入新Crontab
                    printf "%s\n" "${keep_lines[@]}" > "/var/spool/cron/crontabs/$user"
                    chown "$user:crontab" "/var/spool/cron/crontabs/$user"
                    chmod 600 "/var/spool/cron/crontabs/$user"
                    rm -f "$temp_file"
                done
                echo "已删除指定Cron任务 🎉"
                ;;
            3)
                read -p "请输入完整Cron任务（格式：分钟 小时 日 月 星期 命令，例如 '0 2 * * * /path/to/script'）： " new_cron
                # 基本验证Cron时间格式（5个字段 + 命令）
                if [[ "$new_cron" =~ ^[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-7*,-/]+[[:space:]]+.+ ]]; then
                    read -p "请输入任务所属用户（默认root）： " cron_user
                    cron_user=${cron_user:-root}
                    if id "$cron_user" >/dev/null 2>&1; then
                        (crontab -u "$cron_user" -l 2>/dev/null; echo "$new_cron") | crontab -u "$cron_user" -
                        echo "Cron任务已添加为用户 $cron_user：$new_cron 🎉"
                    else
                        echo "用户 $cron_user 不存在，任务添加失败 😔"
                    fi
                else
                    echo "无效Cron任务格式，请使用正确格式（例如：0 2 * * * /path/to/script） 😕"
                fi
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能17：SWAP管理 💾
swap_menu() {
    while true; do
        echo "SWAP管理菜单 💾："
        echo "1. 添加SWAP（自定义大小，支持小数） ➕"
        echo "2. 删除SWAP 🗑️"
        echo "3. 查看当前SWAP状态 🔍"
        echo "4. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "当前SWAP信息："
                swapon --show || echo "无SWAP分区或文件"
                if swapon --show | grep -q '/swapfile'; then
                    echo "警告：已存在 /swapfile，如果继续将覆盖现有SWAP ❗"
                    read -p "是否继续？(y/n)： " confirm
                    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                        continue
                    fi
                    swapoff /swapfile 2>/dev/null
                    rm -f /swapfile
                    sed -i '/\/swapfile none swap sw 0 0/d' /etc/fstab
                fi
                read -p "请输入SWAP大小（单位GB，可小数，例如 0.5）： " size_gb
                if ! [[ "$size_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    echo "请输入有效的数字 😕"
                    continue
                fi
                # 转换成 MB
                size_mb=$(awk "BEGIN {printf \"%d\", $size_gb*1024}")
                if [ "$size_mb" -lt 1 ]; then
                    echo "SWAP大小不能小于 1MB 😕"
                    continue
                fi
                echo "正在创建 ${size_gb}GB (~${size_mb}MB) SWAP文件 ⏳..."
                fallocate -l ${size_mb}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$size_mb
                if [ $? -ne 0 ]; then
                    echo "创建SWAP文件失败，请检查磁盘空间 😔"
                    continue
                fi
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                if [ $? -eq 0 ]; then
                    echo "/swapfile none swap sw 0 0" >> /etc/fstab
                    echo "SWAP已添加并持久化 🎉"
                    swapon --show
                else
                    echo "启用SWAP失败 😔"
                    rm -f /swapfile
                fi
                ;;
            2)
                echo "正在删除SWAP 🗑️..."
                if swapon --show | grep -q '/swapfile'; then
                    swapoff /swapfile
                    rm -f /swapfile
                    sed -i '/\/swapfile none swap sw 0 0/d' /etc/fstab
                    echo "SWAP已删除 🎉"
                else
                    echo "无SWAP可删除 ✅"
                fi
                ;;
            3)
                echo "当前SWAP信息："
                swapon --show || echo "无SWAP分区或文件"
                free -h | grep Swap
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}
# 功能：运行 DDNS 管理脚本 🌐（自动拉取 + 安装 + 运行）
ddns_menu() {
    echo "正在拉取 DDNS 管理脚本 ⏳..."

    # 下载到临时目录
    curl -fsSL https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/ddns.sh -o /tmp/ddns-easy

    if [ $? -ne 0 ]; then
        echo "❌ 下载失败，请检查网络或脚本URL 😔"
        return
    fi

    # 赋予执行权限
    chmod +x /tmp/ddns-easy

    # 移动到系统路径
    sudo mv /tmp/ddns-easy /usr/local/bin/ddns-easy

    if [ $? -eq 0 ]; then
        echo "🎉 DDNS 管理脚本安装完成！"
        echo "⚡ 正在启动 DDNS 管理菜单..."
        sleep 1
        ddns-easy   # ⭐ 自动跳转执行 DDNS 菜单
    else
        echo "❌ 安装失败，请检查权限或系统状态 😔"
    fi
}
# 新增功能18：TCP Fast Open (TFO) 管理子菜单 🚀
tfo_menu() {
    while true; do
        echo "TCP Fast Open (TFO) 管理菜单 🚀："
        echo "1. 查看当前TFO状态 🔍"
        echo "2. 启用TFO ✅"
        echo "3. 禁用TFO 🚫"
        echo "4. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "当前TCP Fast Open状态："
                tfo_status=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "未知")
                case $tfo_status in
                    0) echo "TFO已禁用 🚫" ;;
                    1) echo "TFO启用（仅客户端） 🌐" ;;
                    2) echo "TFO启用（仅服务器） 🖥️" ;;
                    3) echo "TFO启用（客户端和服务器） 🚀" ;;
                    *) echo "无法获取TFO状态，请检查内核支持 😔" ;;
                esac
                echo "按回车键返回菜单 🔙"
                read
                ;;
            2)
                echo "正在启用TCP Fast Open（客户端和服务器） ⏳..."
                # 备份 sysctl.conf
                cp /etc/sysctl.conf /etc/sysctl.conf.bak
                # 设置 TFO 为 3（启用客户端和服务器）
                sed -i '/net\.ipv4\.tcp_fastopen/d' /etc/sysctl.conf
                echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
                if sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1; then
                    echo "TCP Fast Open 已启用（客户端和服务器） 🎉"
                    echo "当前TFO状态：$(sysctl -n net.ipv4.tcp_fastopen)"
                else
                    echo "启用TFO失败，请检查 /etc/sysctl.conf 或内核是否支持TFO 😔"
                    mv /etc/sysctl.conf.bak /etc/sysctl.conf
                    sysctl -p >/dev/null 2>&1
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            3)
                echo "正在禁用TCP Fast Open 🚫..."
                # 备份 sysctl.conf
                cp /etc/sysctl.conf /etc/sysctl.conf.bak
                # 设置 TFO 为 0（禁用）
                sed -i '/net\.ipv4\.tcp_fastopen/d' /etc/sysctl.conf
                echo "net.ipv4.tcp_fastopen=0" >> /etc/sysctl.conf
                if sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1; then
                    echo "TCP Fast Open 已禁用 🎉"
                    echo "当前TFO状态：$(sysctl -n net.ipv4.tcp_fastopen)"
                else
                    echo "禁用TFO失败，请检查 /etc/sysctl.conf 😔"
                    mv /etc/sysctl.conf.bak /etc/sysctl.conf
                    sysctl -p >/dev/null 2>&1
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择，请重试 😕"
                ;;
        esac
    done
}

# 主菜单（无框无横线版）
while true; do
    # 每次显示菜单前先显示系统信息
    show_system_info
    
    # 菜单标题（仅文字）
    echo -e "${WHITE}功能菜单${NC}"
    
    # 两列菜单（无框，只有颜色标记）
    echo -e "${YELLOW}[1]${NC} 安装常用工具 🛠️       ${YELLOW}[11]${NC} DDNS 管理 🌐"
    echo -e "${YELLOW}[2]${NC} 日志清理管理 🗑️       ${YELLOW}[12]${NC} 更新脚本 📥"
    echo -e "${YELLOW}[3]${NC} BBR管理 ⚡            ${YELLOW}[13]${NC} 查看端口占用 🔍"
    echo -e "${YELLOW}[4]${NC} DNS管理 🌐           ${YELLOW}[14]${NC} 内存占用最大 💾"
    echo -e "${YELLOW}[5]${NC} 修改主机名 🖥️        ${YELLOW}[15]${NC} CPU占用最大 🖥️"
    echo -e "${YELLOW}[6]${NC} SSH端口管理 🔒       ${YELLOW}[16]${NC} 系统定时重启 🔄"
    echo -e "${YELLOW}[7]${NC} 修改SSH密码 🔑       ${YELLOW}[17]${NC} Cron任务管理 ⏰"
    echo -e "${YELLOW}[8]${NC} SSH密钥登录管理 🔑   ${YELLOW}[18]${NC} SWAP管理 💾"
    echo -e "${YELLOW}[9]${NC} 卸载脚本 🗑️          ${YELLOW}[19]${NC} TFO管理 🚀"
    echo -e "${YELLOW}[10]${NC} 时区时间同步 ⏰      ${YELLOW}[20]${NC} 退出 🚪"
    
    echo ""  # 空行
    read -p "请输入您的选择 [1-20]： " main_choice

    case $main_choice in
        1) install_tools ;;
        2) log_cleanup_menu ;;
        3) bbr_menu ;;
        4) dns_menu ;;
        5) change_hostname ;;
        6) ssh_port_menu ;;
        7) change_ssh_password ;;
        8) ssh_key_management ;;
        9) uninstall_script ;;
        10) set_timezone ;;
        11) ddns_menu ;;
        12) update_script ;;
        13) check_port_usage ;;
        14) check_memory_usage ;;
        15) check_cpu_usage ;;
        16) set_system_reboot ;;
        17) cron_task_menu ;;
        18) swap_menu ;;
        19) tfo_menu ;;
        20)
            echo -e "${GREEN}👋 已退出，下次使用直接运行: sudo system-easy${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重试 😕${NC}"
            sleep 1
            ;;
    esac
done