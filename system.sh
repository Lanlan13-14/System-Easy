#!/bin/bash

# ==================================================
# System-Easy 综合管理脚本
# 优化版：集成 SSH 管理、GitHub 镜像加速、依赖自动安装
# ==================================================

# ---------- 颜色定义 ----------
RED='\033[0;31m'          # 红色
GREEN='\033[0;32m'        # 绿色
YELLOW='\033[1;33m'       # 亮黄色
BLUE='\033[0;34m'         # 蓝色
PURPLE='\033[0;35m'       # 紫色
CYAN='\033[0;36m'         # 青色
WHITE='\033[1;37m'        # 亮白色
NC='\033[0m'              # 重置颜色

# ---------- 全局变量 ----------
SCRIPT_NAME="system-easy"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/system.sh"
GITHUB_PROXY_FILE="/etc/system-easy/proxy.conf"
GITHUB_PROXY=""
if [[ -f "$GITHUB_PROXY_FILE" ]]; then
    GITHUB_PROXY=$(cat "$GITHUB_PROXY_FILE")
fi

# ---------- 辅助函数 ----------
# 确保命令存在，不存在则自动安装
ensure_command() {
    local cmd=$1
    local pkg=${2:-$1}
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${YELLOW}📦 未检测到 $cmd，正在安装 $pkg ...${NC}"
        apt update -y && apt install -y "$pkg"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}❌ 安装 $pkg 失败，请手动安装${NC}"
            return 1
        fi
    fi
    return 0
}

# 获取带 GitHub 加速的 URL
github_raw_url() {
    local path=$1
    local raw_url="https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/$path"
    if [[ -n "$GITHUB_PROXY" ]]; then
        echo "${GITHUB_PROXY}${raw_url}"
    else
        echo "$raw_url"
    fi
}

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}此脚本必须以 root 身份运行 🚨${NC}" 1>&2
    exit 1
fi

# ---------- 系统信息显示函数 ----------
show_system_info() {
    # --- 静态信息（只在脚本启动时获取）---
    if [ -z "$STATIC_INFO_LOADED" ]; then
        OS_INFO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
        KERNEL=$(uname -r)
        ARCH=$(uname -m)
        HOSTNAME=$(hostname)
        USER=$(whoami)
        CPU_MODEL=$(lscpu | awk -F: '/Model name/ {print $2}' | xargs)
        CPU_CORES=$(nproc)
        STATIC_INFO_LOADED=1
    fi

    # --- CPU 频率修复 ---
    CPU_FREQ=$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | xargs)
    if [ -z "$CPU_FREQ" ] && [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        CPU_FREQ=$(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    fi
    if [ -z "$CPU_FREQ" ]; then
        CPU_FREQ=$(lscpu | awk -F: '/CPU max MHz/ {print $2}' | xargs | cut -d. -f1)
    fi
    [ -z "$CPU_FREQ" ] && CPU_FREQ="N/A"

    # --- 内存 ---
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))

    # --- 硬盘 ---
    DISK_TOTAL=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
    DISK_USED=$(df -BG / | awk 'NR==2 {print $3}' | sed 's/G//')
    DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

    # --- 网卡 ---
    MAIN_IF=$(ip route | awk '/default/ {print $5; exit}')
    if [ -n "$MAIN_IF" ] && [ -f "/sys/class/net/$MAIN_IF/statistics/rx_bytes" ]; then
        RX_BYTES=$(cat /sys/class/net/$MAIN_IF/statistics/rx_bytes)
        TX_BYTES=$(cat /sys/class/net/$MAIN_IF/statistics/tx_bytes)
        RX_READABLE=$(numfmt --to=iec --suffix=B $RX_BYTES 2>/dev/null || echo "N/A")
        TX_READABLE=$(numfmt --to=iec --suffix=B $TX_BYTES 2>/dev/null || echo "N/A")
    else
        RX_READABLE="N/A"
        TX_READABLE="N/A"
    fi

    # --- 负载 ---
    LOAD_1=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | xargs)
    LOAD_5=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $2}' | xargs)
    LOAD_15=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $3}' | xargs)
    LOAD_1_PERCENT=$(awk "BEGIN {printf \"%.0f\", ($LOAD_1 / $CPU_CORES) * 100}")
    [ "$LOAD_1_PERCENT" -gt 100 ] && LOAD_1_PERCENT=100

    PROCESSES=$(ps aux | wc -l)
    UPTIME=$(uptime -p | sed 's/up //')

    # --- 公网 IP ---
    is_private_ip() {
        [[ $1 =~ ^10\. ]] || [[ $1 =~ ^192\.168\. ]] || [[ $1 =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]
    }
    get_public_ipv4() {
        for api in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ipinfo.io/ip" "https://ip.sb"; do
            ip=$(curl -s --connect-timeout 2 "$api" | tr -d '\n')
            if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! is_private_ip "$ip"; then
                echo "$ip"
                return
            fi
        done
    }
    IPV4_PUBLIC=$(get_public_ipv4)
    if [ -n "$IPV4_PUBLIC" ]; then
        IPV4_DISPLAY="$IPV4_PUBLIC"
    else
        IPV4_LOCAL=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n1)
        IPV4_DISPLAY="${IPV4_LOCAL:-未分配} (本地)"
    fi

    IPV6_PUBLIC=$(curl -6 -s --connect-timeout 2 https://api64.ipify.org 2>/dev/null)
    if [[ $IPV6_PUBLIC =~ : ]]; then
        IPV6_DISPLAY="$IPV6_PUBLIC"
    else
        IPV6_DISPLAY="未分配 (本地)"
    fi

    # --- 输出 ---
    echo -e "${YELLOW}➤${NC} ${PURPLE}主机${NC} ${WHITE}$HOSTNAME${NC}  ${YELLOW}➤${NC} ${PURPLE}用户${NC} ${WHITE}$USER${NC}"
    echo -e "${YELLOW}➤${NC} ${PURPLE}系统${NC} ${WHITE}${OS_INFO:0:60}${NC}"
    echo -e "${YELLOW}➤${NC} ${PURPLE}内核${NC} ${WHITE}$KERNEL${NC}  ${YELLOW}➤${NC} ${PURPLE}架构${NC} ${WHITE}$ARCH${NC}"
    echo -e "${YELLOW}➤${NC} ${PURPLE}IPv4${NC} ${WHITE}$IPV4_DISPLAY${NC}"
    echo -e "${YELLOW}➤${NC} ${PURPLE}IPv6${NC} ${WHITE}$IPV6_DISPLAY${NC}"
    echo -e "${YELLOW}➤${NC} ${PURPLE}CPU${NC} ${WHITE}${CPU_MODEL:0:50}${NC}"
    echo -e "  ${CYAN}核心${NC} ${WHITE}$CPU_CORES${NC}  ${CYAN}频率${NC} ${WHITE}$CPU_FREQ MHz${NC}"

    # 负载条
    if [ "$LOAD_1_PERCENT" -gt 80 ]; then LOAD_COLOR=$RED
    elif [ "$LOAD_1_PERCENT" -gt 50 ]; then LOAD_COLOR=$YELLOW
    else LOAD_COLOR=$GREEN; fi
    LOAD_BAR_WIDTH=30
    LOAD_FILL=$((LOAD_1_PERCENT * LOAD_BAR_WIDTH / 100))
    LOAD_EMPTY=$((LOAD_BAR_WIDTH - LOAD_FILL))
    echo -e "${YELLOW}➤${NC} ${PURPLE}负载${NC} ${WHITE}1min: $LOAD_1  5min: $LOAD_5  15min: $LOAD_15${NC}"
    printf "  ["
    printf "%0.s█" $(seq 1 $LOAD_FILL)
    printf "%0.s░" $(seq 1 $LOAD_EMPTY)
    printf "] ${LOAD_COLOR}%3d%%${NC}\n" $LOAD_1_PERCENT

    # 内存条
    if [ "$MEM_PERCENT" -gt 80 ]; then MEM_COLOR=$RED
    elif [ "$MEM_PERCENT" -gt 50 ]; then MEM_COLOR=$YELLOW
    else MEM_COLOR=$GREEN; fi
    MEM_BAR_WIDTH=30
    MEM_FILL=$((MEM_PERCENT * MEM_BAR_WIDTH / 100))
    MEM_EMPTY=$((MEM_BAR_WIDTH - MEM_FILL))
    echo -e "${YELLOW}➤${NC} ${PURPLE}内存${NC} ${WHITE}${MEM_USED}MB / ${MEM_TOTAL}MB${NC}"
    printf "  ["
    printf "%0.s█" $(seq 1 $MEM_FILL)
    printf "%0.s░" $(seq 1 $MEM_EMPTY)
    printf "] ${MEM_COLOR}%3d%%${NC}\n" $MEM_PERCENT

    # 硬盘条
    if [ "$DISK_PERCENT" -gt 80 ]; then DISK_COLOR=$RED
    elif [ "$DISK_PERCENT" -gt 50 ]; then DISK_COLOR=$YELLOW
    else DISK_COLOR=$GREEN; fi
    DISK_BAR_WIDTH=30
    DISK_FILL=$((DISK_PERCENT * DISK_BAR_WIDTH / 100))
    DISK_EMPTY=$((DISK_BAR_WIDTH - DISK_FILL))
    echo -e "${YELLOW}➤${NC} ${PURPLE}硬盘${NC} ${WHITE}${DISK_USED}GB / ${DISK_TOTAL}GB${NC}"
    printf "  ["
    printf "%0.s█" $(seq 1 $DISK_FILL)
    printf "%0.s░" $(seq 1 $DISK_EMPTY)
    printf "] ${DISK_COLOR}%3d%%${NC}\n" $DISK_PERCENT

    echo -e "${YELLOW}➤${NC} ${PURPLE}网卡${NC} ${WHITE}$MAIN_IF${NC}  ${CYAN}接收${NC} ${WHITE}$RX_READABLE${NC}  ${CYAN}发送${NC} ${WHITE}$TX_READABLE${NC}"
    echo -e "${YELLOW}➤${NC} ${PURPLE}运行${NC} ${WHITE}$UPTIME${NC}  ${YELLOW}➤${NC} ${PURPLE}进程${NC} ${WHITE}$PROCESSES${NC}"
    echo ""
}

# ---------- 功能函数 ----------

# 功能1：安装常用工具
install_tools() {
    clear
    echo "========== 安装常用工具 =========="
    echo "正在更新软件包列表 📦..."
    apt update -y
    echo "正在安装常用工具和依赖：curl、vim、git、python3-systemd、systemd-journal-remote、cron、at、net-tools、iproute2、unzip、jq 🚀..."
    apt install -y curl vim git python3-systemd systemd-journal-remote cron at net-tools iproute2 unzip jq
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}所有工具和依赖安装完成 🎉${NC}"
    else
        echo -e "${RED}安装失败，请检查网络或软件源 😔${NC}"
    fi
    echo ""
    read -rp "按回车键返回主菜单..." _
}

# 功能2：日志清理管理
log_cleanup_menu() {
    while true; do
        clear
        cat <<EOF
========== 日志清理管理 ==========
[1] 开启自动日志清理（每天02:00）
[2] 关闭自动日志清理
[0] 返回主菜单
==================================
EOF
        read -rp "请输入您的选择 [0-2]: " choice
        case $choice in
            1)
                echo "正在启用自动日志清理 ⏳..."
                cron_job="0 2 * * * journalctl --vacuum-time=2weeks && find /var/log -type f -name '*.log.*' -exec rm {} \; && find /var/log -type f -name '*.gz' -exec rm {} \;"
                (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
                echo -e "${GREEN}自动日志清理已启用（每天凌晨02:00） 🎉${NC}"
                read -rp "按回车键继续..." _
                ;;
            2)
                echo "正在关闭自动日志清理 🚫..."
                crontab -l | grep -v "journalctl --vacuum-time=2weeks" | crontab -
                echo -e "${GREEN}自动日志清理已关闭 ✅${NC}"
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择，请重试 😕${NC}"; sleep 1 ;;
        esac
    done
}

# 功能3：BBR管理
bbr_menu() {
    BBR_BACKUP_DIR="/etc/sysctl_backup"
    check_bbr_loaded() { lsmod | grep -q tcp_bbr; }
    apply_sysctl() { sysctl --system >/dev/null 2>&1 || true; }
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
    reset_sysctl_d_defaults() {
        echo "🔄 正在彻底清理 sysctl 配置..."
        if [ -d /etc/sysctl.d ]; then
            find /etc/sysctl.d -type f -name '*.conf' -delete
        else
            mkdir -p /etc/sysctl.d
        fi
        : > /etc/sysctl.conf
        if check_bbr_loaded; then
            rmmod tcp_bbr 2>/dev/null || true
        fi
        sysctl --system >/dev/null 2>&1 || true
    }

    while true; do
        clear
        cat <<EOF
========== BBR 管理菜单 ⚡ ==========
[1] 安装BBR v3内核
[2] 应用BBR优化配置
[3] 卸载BBR
[4] 恢复备份
[5] 重置BBR配置
[6] 备份管理
[0] 返回主菜单
=====================================
EOF
        read -rp "请输入您的选择 [0-6]: " choice
        case $choice in
            1)
                echo "正在安装BBR v3内核 ⏳..."
                bash <(curl -L -s "$(github_raw_url install.sh)")
                if check_bbr_loaded; then
                    echo -e "${GREEN}✅ BBR v3内核安装成功${NC}"
                else
                    echo -e "${RED}❌ BBR安装失败${NC}"
                fi
                read -rp "按回车返回菜单..." _
                ;;
            2)
                echo "应用BBR优化配置 ⚙️..."
                if ! sysctl net.ipv4.tcp_available_congestion_control >/dev/null 2>&1; then
                    echo -e "${YELLOW}⚠️ 当前内核不支持 BBR${NC}"
                    read -rp "按回车返回菜单..." _
                    continue
                fi
                if ! check_bbr_loaded; then
                    echo "检测到 BBR 模块未加载，正在尝试加载..."
                    modprobe tcp_bbr 2>/dev/null || echo -e "${YELLOW}⚠️ 模块加载失败${NC}"
                fi
                bash -c "$(curl -fsSL "$(github_raw_url bbr.sh)")"
                apply_sysctl
                echo -e "${GREEN}✅ BBR优化配置已应用${NC}"
                echo "当前TCP拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未支持')"
                read -rp "按回车返回菜单..." _
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
                read -rp "确认执行上述卸载与清理操作？输入 'yes' 以继续: " confirm_uninstall
                if [[ "$confirm_uninstall" != "yes" ]]; then
                    echo "已取消卸载操作。"
                    read -rp "按回车返回菜单..." _
                    continue
                fi
                if check_bbr_loaded; then
                    if rmmod tcp_bbr 2>/dev/null; then
                        echo "✅ BBR 模块已移除"
                    else
                        echo "⚠️ 无法移除 BBR 模块（可能正在使用或内核不允许），继续执行清理"
                    fi
                else
                    echo "BBR 模块未加载，无需卸载 ✅"
                fi
                rm -f /etc/sysctl.d/network-tuning.conf 2>/dev/null || true
                rm -f /etc/security/limits.d/99-custom-limits.conf 2>/dev/null || true
                if [ -d /etc/sysctl.d ]; then
                    rm -rf /etc/sysctl.d
                    mkdir -p /etc/sysctl.d
                fi
                : > /etc/sysctl.conf
                sysctl -p 2>/dev/null || true
                sysctl --system 2>/dev/null || true
                restore_default_tcp
                echo -e "${GREEN}✅ 卸载与清理完成，请检查系统并重启以确保所有更改生效。${NC}"
                read -rp "按回车返回菜单..." _
                ;;
            4)
                echo "恢复备份 🔄"
                mkdir -p "$BBR_BACKUP_DIR"
                mapfile -t backups < <(ls "$BBR_BACKUP_DIR"/*.tar.gz 2>/dev/null)
                if [ ${#backups[@]} -eq 0 ]; then
                    echo -e "${YELLOW}⚠️ 无可用备份${NC}"
                    read -rp "按回车返回菜单..." _
                    continue
                fi
                echo "可用备份列表:"
                for i in "${!backups[@]}"; do
                    echo "[$((i+1))] ${backups[$i]}"
                done
                read -rp "请输入备份编号: " idx
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ -z "${backups[$((idx-1))]}" ]; then
                    echo -e "${RED}❌ 无效编号${NC}"
                    read -rp "按回车返回菜单..." _
                    continue
                fi
                backup_file="${backups[$((idx-1))]}"
                echo "正在还原 $backup_file ..."
                rm -rf /etc/sysctl.d/*
                if tar -xzf "$backup_file" -C /etc; then
                    apply_sysctl
                    echo -e "${GREEN}✅ 还原完成: $backup_file${NC}"
                else
                    echo -e "${RED}❌ 还原失败${NC}"
                fi
                read -rp "按回车返回菜单..." _
                ;;
            5)
                echo "重置BBR配置 🔄..."
                reset_sysctl_d_defaults
                echo -e "${GREEN}✅ BBR已彻底重置为系统默认（cubic）${NC}"
                read -rp "按回车返回菜单..." _
                ;;
            6)
                echo "备份管理 🗂️"
                mkdir -p "$BBR_BACKUP_DIR"
                mapfile -t backups < <(ls "$BBR_BACKUP_DIR"/*.tar.gz 2>/dev/null)
                if [ ${#backups[@]} -eq 0 ]; then
                    echo -e "${YELLOW}⚠️ 无可用备份${NC}"
                    read -rp "按回车返回菜单..." _
                    continue
                fi
                echo "可用备份列表:"
                for i in "${!backups[@]}"; do
                    echo "[$((i+1))] ${backups[$i]}"
                done
                echo "[0] 删除全部备份"
                read -rp "请输入要删除的备份编号: " del_idx
                if [[ "$del_idx" =~ ^[0-9]+$ ]]; then
                    if [ "$del_idx" -eq 0 ]; then
                        rm -f "$BBR_BACKUP_DIR"/*.tar.gz
                        echo -e "${GREEN}✅ 已删除所有备份${NC}"
                    elif [ "$del_idx" -ge 1 ] && [ "$del_idx" -le "${#backups[@]}" ]; then
                        rm -f "${backups[$((del_idx-1))]}"
                        echo -e "${GREEN}✅ 已删除备份: ${backups[$((del_idx-1))]}${NC}"
                    else
                        echo -e "${YELLOW}⚠️ 无效编号${NC}"
                    fi
                fi
                read -rp "按回车返回菜单..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择，请重试 😕${NC}"; sleep 1 ;;
        esac
    done
}

# 功能4：DNS管理
dns_menu() {
    while true; do
        clear
        cat <<EOF
========== DNS 管理菜单 🌐 ==========
[1] 查看当前系统DNS
[2] 修改系统DNS（支持LXC）
[3] 重置DNS配置（取消不可变属性）
[0] 返回主菜单
======================================
EOF
        read -rp "请输入您的选择 [0-3]: " choice
        case $choice in
            1)
                echo "当前DNS设置："
                if command -v resolvectl &>/dev/null; then
                    echo "--- systemd-resolve 状态 ---"
                    resolvectl status | grep -A3 "DNS Servers" || true
                fi
                echo "--- /etc/resolv.conf 内容 ---"
                cat /etc/resolv.conf
                echo "--- resolv.conf 属性 ---"
                lsattr /etc/resolv.conf 2>/dev/null || echo "无法查看文件属性"
                read -rp "按回车键继续..." _
                ;;
            2)
                echo "警告：此操作将修改系统DNS ❗"
                read -rp "请输入新的DNS服务器（例如8.8.8.8）： " dns1
                read -rp "请输入备用DNS服务器（可选，例如8.8.4.4）： " dns2
                # 检查是否为LXC容器
                if grep -q "container=lxc" /proc/1/environ 2>/dev/null || [ -f /.lxc-boot-id ]; then
                    echo "检测到LXC容器环境，使用LXC兼容的DNS配置方式..."
                    if command -v resolvectl &>/dev/null; then
                        echo "通过systemd-resolved配置DNS..."
                        resolvectl dns eth0 "$dns1" 2>/dev/null || resolvectl dns "$dns1"
                        [ ! -z "$dns2" ] && resolvectl dns eth0 "$dns1 $dns2" 2>/dev/null || true
                    fi
                    if [ -f /etc/resolv.conf ]; then
                        chattr -i /etc/resolv.conf 2>/dev/null || true
                        cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d%H%M%S)
                        echo "# Generated by system script at $(date)" > /etc/resolv.conf
                        echo "nameserver $dns1" >> /etc/resolv.conf
                        if [ ! -z "$dns2" ]; then
                            echo "nameserver $dns2" >> /etc/resolv.conf
                        fi
                        echo "DNS配置已写入 /etc/resolv.conf"
                    fi
                    if command -v nmcli &>/dev/null; then
                        echo "检测到NetworkManager，尝试配置..."
                        connection=$(nmcli -t -f NAME con show --active | head -n1)
                        if [ ! -z "$connection" ]; then
                            nmcli con mod "$connection" ipv4.dns "$dns1 ${dns2:-}"
                            nmcli con up "$connection"
                        fi
                    fi
                    echo -e "${GREEN}LXC容器DNS配置完成 🎉${NC}"
                else
                    echo "检测到非LXC环境，使用标准DNS配置..."
                    chattr -i /etc/resolv.conf 2>/dev/null || true
                    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d%H%M%S)
                    echo "# Generated by system script at $(date)" > /etc/resolv.conf
                    echo "nameserver $dns1" >> /etc/resolv.conf
                    if [ ! -z "$dns2" ]; then
                        echo "nameserver $dns2" >> /etc/resolv.conf
                    fi
                    chattr +i /etc/resolv.conf 2>/dev/null && echo "已设置DNS文件保护" || echo "警告：无法设置文件保护"
                    echo -e "${GREEN}DNS已永久修改 🎉${NC}"
                fi
                echo "测试DNS解析..."
                nslookup baidu.com 2>/dev/null || dig baidu.com 2>/dev/null || echo "DNS测试失败，请检查配置"
                read -rp "按回车键继续..." _
                ;;
            3)
                if [ -f /etc/resolv.conf ]; then
                    chattr -i /etc/resolv.conf 2>/dev/null && echo "已移除DNS文件保护属性" || echo "无法移除文件保护属性"
                    latest_backup=$(ls -t /etc/resolv.conf.backup.* 2>/dev/null | head -n1)
                    if [ ! -z "$latest_backup" ]; then
                        cp "$latest_backup" /etc/resolv.conf
                        echo "已恢复DNS配置备份: $latest_backup"
                    else
                        echo "没有找到备份，请手动编辑 /etc/resolv.conf"
                    fi
                fi
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择，请重试 😕${NC}"; sleep 1 ;;
        esac
    done
}

# 功能5：修改主机名
change_hostname() {
    clear
    echo "========== 修改主机名 =========="
    current_hostname=$(hostname)
    echo "当前主机名：$current_hostname"
    read -rp "请输入新主机名： " new_hostname
    
    # 输入验证
    if [ -z "$new_hostname" ]; then
        echo -e "${RED}主机名不能为空${NC}"
        read -rp "按回车键返回主菜单..." _
        return
    fi
    
    # 额外验证：检查主机名格式（可选）
    if ! echo "$new_hostname" | grep -qE '^[a-zA-Z0-9.-]+$'; then
        echo -e "${RED}主机名包含非法字符（只允许字母、数字、点和连字符）${NC}"
        read -rp "按回车键返回主菜单..." _
        return
    fi
    
    echo "警告：此操作将永久更改主机名 ❗"
    
    # 备份 /etc/hosts
    if [ -f /etc/hosts ]; then
        backup_file="/etc/hosts.backup.$(date +%Y%m%d%H%M%S)"
        cp /etc/hosts "$backup_file"
        echo "已备份 /etc/hosts 到 $backup_file"
    fi

    # 更新 /etc/hosts
    # 删除旧主机名的所有映射（包括带点和带短横的变体）
    sed -i "/[[:space:]]$current_hostname\([[:space:]]\|$\)/d" /etc/hosts
    
    # 确保 127.0.0.1 映射存在
    if grep -q "^127.0.0.1[[:space:]]" /etc/hosts; then
        # 在现有的 127.0.0.1 行添加新主机名
        sed -i "s/^\(127.0.0.1[[:space:]]*.*\)/\1 $new_hostname/" /etc/hosts
    else
        # 添加新的 127.0.0.1 行
        echo "127.0.0.1   localhost $new_hostname" >> /etc/hosts
    fi
    
    # 确保 localhost 解析
    if ! grep -q "^127.0.0.1[[:space:]]*localhost" /etc/hosts; then
        echo "127.0.0.1   localhost" >> /etc/hosts
    fi

    # 修改 /etc/hostname
    echo "$new_hostname" > /etc/hostname

    # 修改内核主机名（立即生效）
    hostname "$new_hostname"

    # 同步 hostnamectl（如果可用）
    if command -v hostnamectl &>/dev/null; then
        hostnamectl set-hostname "$new_hostname"
    fi

    echo -e "${GREEN}主机名已成功更改为 $new_hostname 🎉${NC}"
    echo "当前内核主机名：$(hostname)"
    echo "当前 /etc/hostname：$(cat /etc/hostname)"
    echo -e "\n/etc/hosts 中包含主机名的行："
    grep "$new_hostname" /etc/hosts || echo "未找到"
    
    # 验证 sudo 是否正常工作
    if command -v sudo &>/dev/null; then
        echo -e "\n测试 sudo 解析："
        sudo -V | head -n 1 || echo "sudo 可能有问题"
    fi
    
    read -rp "按回车键返回主菜单..." _
}

# ---------- SSH 综合管理 ----------
# 内部函数：获取当前 SSH 端口
get_ssh_port() {
    if [[ -n "$SSH_CONNECTION" ]]; then
        echo "$SSH_CONNECTION" | awk '{print $4}'
        return
    fi
    if grep -qiE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
        grep -iE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config | tail -n1 | awk '{print $2}'
        return
    fi
    echo 22
}

# 生成随机端口
random_port() {
    shuf -i 20000-60000 -n 1
}

# 重启 SSH 服务（兼容 socket 和 service）
restart_ssh() {
    if systemctl list-units --full -all 2>/dev/null | grep -q "ssh.socket"; then
        systemctl restart ssh.socket
    else
        systemctl restart ssh
    fi
}

# SSH 端口管理子菜单
ssh_port_submenu() {
    local is_lxc=false
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null || [ -f /.lxc-boot-id ]; then
        is_lxc=true
    fi
    local has_socket=false
    local ssh_service="ssh"
    local socket_active=false
    if systemctl list-units --full -all 2>/dev/null | grep -q "ssh.service"; then
        ssh_service="ssh"
    elif systemctl list-units --full -all 2>/dev/null | grep -q "sshd.service"; then
        ssh_service="sshd"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "ssh.socket"; then
        has_socket=true
        if systemctl is-active ssh.socket >/dev/null 2>&1; then
            socket_active=true
        fi
    fi
    local current_port=$(get_ssh_port)

    while true; do
        clear
        cat <<EOF
========== SSH 端口管理 ==========
当前端口: $current_port
Socket激活: $([ "$socket_active" = true ] && echo "启用" || echo "停用")

[1] 修改SSH端口
[2] 查看SSH服务状态
[3] 测试SSH配置
[4] 切换监听模式 (socket/daemon)
[0] 返回上一级
==================================
EOF
        read -rp "请选择 [0-4]: " sub_choice
        case $sub_choice in
            1)
                echo ""
                read -rp "请输入新的SSH端口号 (1-65535): " new_port
                if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                    echo -e "${RED}❌ 无效端口号${NC}"; sleep 2; continue
                fi
                # 检查端口占用
                if command -v ss >/dev/null 2>&1; then
                    if ss -tuln 2>/dev/null | grep -q ":$new_port "; then
                        echo -e "${RED}❌ 端口 $new_port 已被占用${NC}"; sleep 2; continue
                    fi
                fi
                local backup_dir="/root/ssh_backups"
                mkdir -p "$backup_dir"
                local timestamp=$(date +%Y%m%d_%H%M%S)
                cp /etc/ssh/sshd_config "$backup_dir/sshd_config_${timestamp}.bak"
                if grep -q -E "^\s*Port\s+" /etc/ssh/sshd_config; then
                    sed -i "s/^\s*Port\s\+.*/Port $new_port/" /etc/ssh/sshd_config
                else
                    echo "Port $new_port" >> /etc/ssh/sshd_config
                fi
                if [ "$has_socket" = true ] && [ -f /lib/systemd/system/ssh.socket ]; then
                    cp /lib/systemd/system/ssh.socket "$backup_dir/ssh.socket_${timestamp}.bak"
                    if grep -q "ListenStream=" /lib/systemd/system/ssh.socket; then
                        sed -i "s/ListenStream=.*/ListenStream=$new_port/" /lib/systemd/system/ssh.socket
                    else
                        echo "ListenStream=$new_port" >> /lib/systemd/system/ssh.socket
                    fi
                    systemctl daemon-reload
                fi
                # 防火墙配置（略，保留原逻辑）
                if [ "$is_lxc" = false ]; then
                    if command -v ufw >/dev/null 2>&1; then
                        ufw allow "$new_port"/tcp
                    fi
                    if command -v firewall-cmd >/dev/null 2>&1; then
                        firewall-cmd --permanent --add-port="$new_port/tcp"
                        firewall-cmd --reload
                    fi
                fi
                if ! sshd -t >/dev/null 2>&1; then
                    echo -e "${RED}❌ SSH配置测试失败，正在恢复备份...${NC}"
                    cp "$backup_dir/sshd_config_${timestamp}.bak" /etc/ssh/sshd_config
                    if [ "$has_socket" = true ]; then
                        cp "$backup_dir/ssh.socket_${timestamp}.bak" /lib/systemd/system/ssh.socket
                        systemctl daemon-reload
                    fi
                    sleep 2
                    continue
                fi
                if [ "$socket_active" = true ]; then
                    systemctl stop ssh.socket
                    systemctl stop ssh.service
                    systemctl start ssh.socket
                else
                    systemctl restart "$ssh_service"
                fi
                echo -e "${GREEN}✅ SSH端口已修改为 $new_port${NC}"
                current_port="$new_port"
                read -rp "按回车键继续..." _
                ;;
            2)
                echo ""
                echo "📊 SSH服务详细状态："
                systemctl status ssh.service --no-pager -l | head -n 20
                if [ "$has_socket" = true ]; then
                    echo ""
                    echo "🔹 Socket状态："
                    systemctl status ssh.socket --no-pager -l | head -n 10
                fi
                read -rp "按回车键继续..." _
                ;;
            3)
                echo ""
                echo -n "配置文件语法检查: "
                if sshd -t >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ 通过${NC}"
                else
                    echo -e "${RED}❌ 失败${NC}"
                    sshd -t
                fi
                read -rp "按回车键继续..." _
                ;;
            4)
                if [ "$has_socket" = false ]; then
                    echo -e "${YELLOW}⚠️ 系统不支持ssh.socket模式${NC}"
                    sleep 2; continue
                fi
                echo "当前模式: $([ "$socket_active" = true ] && echo "Socket激活模式" || echo "传统Daemon模式")"
                echo "1) 切换到Socket激活模式"
                echo "2) 切换到传统Daemon模式"
                echo "0) 取消"
                read -rp "请选择 [0-2]: " mode_choice
                case $mode_choice in
                    1)
                        if [ "$socket_active" = true ]; then
                            echo "已经是Socket激活模式"; sleep 2; continue
                        fi
                        config_port=$(grep -E "^\s*Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
                        config_port=${config_port:-22}
                        if [ -f /lib/systemd/system/ssh.socket ]; then
                            sed -i "s/ListenStream=.*/ListenStream=$config_port/" /lib/systemd/system/ssh.socket
                        else
                            echo "ListenStream=$config_port" > /lib/systemd/system/ssh.socket
                        fi
                        systemctl daemon-reload
                        systemctl stop ssh.service
                        systemctl enable --now ssh.socket
                        socket_active=true
                        echo -e "${GREEN}✅ 已切换到Socket激活模式${NC}"
                        ;;
                    2)
                        if [ "$socket_active" = false ]; then
                            echo "已经是传统Daemon模式"; sleep 2; continue
                        fi
                        systemctl stop ssh.socket
                        systemctl disable ssh.socket
                        systemctl enable --now ssh.service
                        socket_active=false
                        echo -e "${GREEN}✅ 已切换到传统Daemon模式${NC}"
                        ;;
                    0) ;;
                    *) echo -e "${RED}无效选择${NC}" ;;
                esac
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# SSH 密码管理子菜单
ssh_password_submenu() {
    while true; do
        clear
        cat <<EOF
========== SSH 密码管理 ==========
[1] 修改当前用户密码
[2] 启用密码登录（应急）
[3] 禁用密码登录（仅密钥）
[0] 返回上一级
==================================
EOF
        read -rp "请选择 [0-3]: " sub_choice
        case $sub_choice in
            1)
                echo ""
                read -rp "请输入要修改密码的用户名 [默认: root]: " target_user
                target_user=${target_user:-root}
                if ! id "$target_user" >/dev/null 2>&1; then
                    echo -e "${RED}❌ 用户 $target_user 不存在${NC}"
                    sleep 2; continue
                fi
                # 生成复杂密码（可选）
                echo "生成强密码..."
                upper_chars='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
                lower_chars='abcdefghijklmnopqrstuvwxyz'
                digit_chars='0123456789'
                special_chars='!@#$%^&*()_+-='
                password=""
                password="${password}${upper_chars:$((RANDOM % ${#upper_chars})):1}"
                password="${password}${lower_chars:$((RANDOM % ${#lower_chars})):1}"
                password="${password}${digit_chars:$((RANDOM % ${#digit_chars})):1}"
                password="${password}${special_chars:$((RANDOM % ${#special_chars})):1}"
                all_chars="${upper_chars}${lower_chars}${digit_chars}${special_chars}"
                for i in {1..16}; do
                    password="${password}${all_chars:$((RANDOM % ${#all_chars})):1}"
                done
                password=$(echo "$password" | fold -w1 | shuf | tr -d '\n')
                echo "生成密码：$password"
                echo "请选择："
                echo "  1. 使用生成的密码"
                echo "  2. 手动输入密码"
                echo "  0. 取消"
                read -rp "请选择 [0-2]: " pass_choice
                case $pass_choice in
                    1) pass1="$password" ;;
                    2)
                        read -sp "请输入新密码: " pass1; echo
                        read -sp "请再次确认: " pass2; echo
                        if [ "$pass1" != "$pass2" ] || [ -z "$pass1" ]; then
                            echo -e "${RED}❌ 密码不匹配或为空${NC}"; sleep 2; continue
                        fi
                        ;;
                    0) continue ;;
                    *) echo -e "${RED}无效选择${NC}"; sleep 2; continue ;;
                esac
                if echo "$target_user:$pass1" | chpasswd 2>/dev/null; then
                    echo -e "${GREEN}✅ 密码修改成功！${NC}"
                    echo "用户: $target_user"
                    echo "新密码: $pass1"
                else
                    echo -e "${RED}❌ 密码修改失败${NC}"
                fi
                read -rp "按回车键继续..." _
                ;;
            2)
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
                sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
                restart_ssh
                echo -e "${GREEN}✅ SSH密码登录已启用${NC}"
                read -rp "按回车键继续..." _
                ;;
            3)
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
                sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
                restart_ssh
                echo -e "${GREEN}✅ SSH密码登录已禁用${NC}"
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# SSH 密钥管理（生成、临时获取、打印、重置）
ssh_key_management_submenu() {
    local KEY_DIR="/root/.ssh"
    local KEY_FILE="$KEY_DIR/id_rsa"
    local PUB_FILE="$KEY_FILE.pub"
    local AUTHORIZED="$KEY_DIR/authorized_keys"
    local KEY_COMMENT="auto-generated-by-$(hostname)-$(date +%Y%m%d)"

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
        echo -e "${GREEN}✅ SSH 密钥已就绪${NC}"
        echo "[📍] 私钥位置: $KEY_FILE"
        echo "[📍] 公钥位置: $PUB_FILE"
    }

    temp_key_server() {
        ensure_key
        ensure_command nc netcat-openbsd
        local REMOTE_PORT=$(random_port)
        local LOCAL_PORT=$(random_port)
        local SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
        local SSH_PORT=$(get_ssh_port)
        echo "[⏱️]  设置临时密钥有效期（秒）"
        read -rp "默认120秒，最长300秒: " expire_time
        expire_time=${expire_time:-120}
        if [[ $expire_time -gt 300 ]]; then
            echo "[⚠️] 超过300秒，使用最大值300秒"
            expire_time=300
        fi
        echo ""
        echo "[🖥️] 启动【仅本地监听】临时密钥服务"
        echo "[🔗] 服务器监听: 127.0.0.1:$REMOTE_PORT"
        echo "[🔗] 客户端本地端口: 127.0.0.1:$LOCAL_PORT"
        echo "[🔐] 当前 SSH 端口: $SSH_PORT"
        echo "[⏳] 有效期: ${expire_time}秒"
        echo ""
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
        read -rp "按回车键继续..." _
    }

    print_private_key() {
        ensure_key
        echo ""
        echo -e "${RED}[⚠️⚠️] 高危操作：直接打印 SSH 私钥 ⚠️⚠️${NC}"
        read -rp "输入 yes 确认: " c
        [[ "$c" != "yes" ]] && return
        echo ""
        echo "================ SSH 私钥开始 ================"
        cat "$KEY_FILE"
        echo "================ SSH 私钥结束 ================"
        read -rp "按回车键继续..." _
    }

    reset_key() {
        echo -e "${YELLOW}[⚠️] 即将重置 SSH 密钥（泄漏应急）${NC}"
        read -rp "确认请输入 yes: " c
        [[ "$c" != "yes" ]] && return
        rm -f "$KEY_FILE" "$PUB_FILE" "$AUTHORIZED"
        ensure_key
        echo -e "${GREEN}[🔄] SSH 密钥已重置${NC}"
        read -rp "按回车键继续..." _
    }

    while true; do
        clear
        cat <<EOF
========== SSH 密钥管理 ==========
[1] 生成/确认 SSH 密钥
[2] 通过端口转发获取私钥（推荐）
[3] 直接打印 SSH 私钥（高危）
[4] 重置 SSH 密钥（泄漏应急）
[0] 返回上一级
==================================
EOF
        read -rp "请选择 [0-4]: " sub_choice
        case $sub_choice in
            1) ensure_key; read -rp "按回车键继续..." _ ;;
            2) temp_key_server ;;
            3) print_private_key ;;
            4) reset_key ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# SSH 公钥管理子菜单
ssh_pubkey_submenu() {
    local KEY_DIR="/root/.ssh"
    local AUTHORIZED="$KEY_DIR/authorized_keys"

    list_keys() {
        if [[ ! -s "$AUTHORIZED" ]]; then
            echo "暂无公钥"
            return
        fi
        local i=1
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local comment=$(echo "$line" | awk '{print $NF}')
            if [[ "$comment" == *"auto-generated"* ]]; then
                echo "[$i] 🔑 [本机生成] $comment"
            else
                echo "[$i] 🔐 [外部添加] $comment"
            fi
            local fingerprint=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')
            [[ -n "$fingerprint" ]] && echo "   指纹: $fingerprint"
            echo "-----------------------------------------"
            ((i++))
        done < "$AUTHORIZED"
        echo "总计: $((i-1)) 个公钥"
    }

    add_user_key() {
        echo "[🔐] 添加其他用户的公钥"
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
                [[ -f "$key_file" ]] && new_key=$(cat "$key_file") || { echo -e "${RED}文件不存在${NC}"; return; }
                ;;
            3)
                read -rp "请输入远程主机 (user@host): " remote_host
                read -rp "请输入远程主机的SSH端口 [22]: " remote_port
                remote_port=${remote_port:-22}
                echo "正在获取远程主机公钥..."
                new_key=$(ssh -p "$remote_port" "$remote_host" "cat ~/.ssh/id_*.pub 2>/dev/null | head -n1" 2>/dev/null)
                if [[ -z "$new_key" ]]; then
                    echo -e "${RED}获取失败${NC}"; return
                fi
                ;;
            *) echo -e "${RED}无效选择${NC}"; return ;;
        esac
        if ! echo "$new_key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)'; then
            echo -e "${RED}无效的公钥格式${NC}"; return
        fi
        if grep -qF "$(echo "$new_key" | awk '{print $2}')" "$AUTHORIZED"; then
            echo -e "${YELLOW}该公钥已存在，跳过添加${NC}"; return
        fi
        if [[ $(echo "$new_key" | wc -w) -lt 3 ]]; then
            read -rp "请输入该公钥的备注信息: " key_note
            new_key="$new_key $key_note"
        fi
        echo "$new_key" >> "$AUTHORIZED"
        echo -e "${GREEN}✅ 公钥已添加${NC}"
        read -rp "是否立即重启 SSH 服务以使生效？(y/n): " restart_confirm
        if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
            restart_ssh
            echo "SSH 服务已重启"
        fi
    }

    delete_key() {
        list_keys
        local total=$(grep -c '^ssh' "$AUTHORIZED" 2>/dev/null || echo 0)
        [[ $total -eq 0 ]] && { echo "暂无公钥可删除"; return; }
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
                    delete_single_key "$num" "no_list"
                done
                ;;
            3)
                read -rp "[⚠️] 确认删除所有外部公钥？输入 yes 确认: " confirm
                if [[ "$confirm" == "yes" ]]; then
                    local tmp_file=$(mktemp)
                    local deleted=0
                    while IFS= read -r line; do
                        if [[ "$line" == *"auto-generated"* ]]; then
                            echo "$line" >> "$tmp_file"
                        else
                            ((deleted++))
                        fi
                    done < "$AUTHORIZED"
                    mv "$tmp_file" "$AUTHORIZED"
                    chmod 600 "$AUTHORIZED"
                    echo -e "${GREEN}✅ 已删除 $deleted 个外部公钥${NC}"
                    read -rp "是否重启 SSH 服务？(y/n): " restart_confirm
                    [[ "$restart_confirm" =~ ^[Yy]$ ]] && restart_ssh
                fi
                ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    }

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
                    if [[ "$line" == *"auto-generated"* ]]; then
                        is_auto_generated=true
                        echo -e "${YELLOW}⚠️ 警告：正在删除本机生成的公钥${NC}"
                        read -rp "请再次输入 yes 确认删除: " confirm
                        if [[ "$confirm" == "yes" ]]; then
                            read -rp "最后一次确认？输入 yes 删除: " confirm2
                            if [[ "$confirm2" == "yes" ]]; then
                                deleted=true
                                echo -e "${GREEN}[🗑️] 已删除本机公钥${NC}"
                            else
                                echo "$line" >> "$tmp_file"
                            fi
                        else
                            echo "$line" >> "$tmp_file"
                        fi
                    else
                        read -rp "确认删除此公钥？输入 yes 确认: " confirm
                        if [[ "$confirm" == "yes" ]]; then
                            deleted=true
                            echo -e "${GREEN}[🗑️] 已删除外部公钥${NC}"
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
            if [[ "$deleted" == true ]]; then
                read -rp "是否重启 SSH 服务？(y/n): " restart_confirm
                [[ "$restart_confirm" =~ ^[Yy]$ ]] && restart_ssh
            fi
            [[ -z "$no_list" ]] && list_keys
        fi
    }

    backup_keys() {
        local backup_dir="$KEY_DIR/backups"
        mkdir -p "$backup_dir"
        local backup_file="$backup_dir/authorized_keys.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$AUTHORIZED" "$backup_file"
        echo -e "${GREEN}✅ 公钥已备份到: $backup_file${NC}"
        echo "[⚠️] 私钥位置: $KEY_FILE，请手动备份"
        read -rp "按回车键继续..." _
    }

    restore_keys() {
        local backup_dir="$KEY_DIR/backups"
        if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir")" ]]; then
            echo -e "${RED}❌ 没有找到备份文件${NC}"; return
        fi
        echo "可用的备份文件："
        ls -1 "$backup_dir" | nl -w2 -s') '
        read -rp "请输入要恢复的备份文件编号: " num
        local backup_file=$(ls -1 "$backup_dir" | sed -n "${num}p")
        if [[ -n "$backup_file" ]]; then
            cp "$backup_dir/$backup_file" "$AUTHORIZED"
            chmod 600 "$AUTHORIZED"
            echo -e "${GREEN}✅ 已恢复公钥${NC}"
            read -rp "是否重启 SSH 服务？(y/n): " restart_confirm
            [[ "$restart_confirm" =~ ^[Yy]$ ]] && restart_ssh
        else
            echo -e "${RED}无效选择${NC}"
        fi
    }

    delete_backups() {
        local backup_dir="$KEY_DIR/backups"
        if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir")" ]]; then
            echo -e "${RED}❌ 没有找到备份文件${NC}"; return
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
                [[ "$num" =~ ^[0-9]+$ ]] && rm -i "$backup_dir/$(ls -1 "$backup_dir" | sed -n "${num}p")"
                ;;
            2)
                echo "输入要删除的备份编号（输入0结束）:"
                while true; do
                    read -rp "编号: " num
                    [[ "$num" == "0" ]] && break
                    [[ "$num" =~ ^[0-9]+$ ]] && rm -i "$backup_dir/$(ls -1 "$backup_dir" | sed -n "${num}p")"
                done
                ;;
            3)
                read -rp "[⚠️] 确认删除所有备份？输入 yes 确认: " confirm
                [[ "$confirm" == "yes" ]] && rm -f "$backup_dir"/* && echo -e "${GREEN}✅ 已删除所有备份${NC}"
                ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
        read -rp "按回车键继续..." _
    }

    while true; do
        clear
        cat <<EOF
========== SSH 公钥管理 ==========
[1] 列出所有公钥
[2] 添加其他用户的公钥
[3] 删除公钥
[4] 备份公钥
[5] 恢复公钥
[6] 删除备份
[0] 返回上一级
===================================
EOF
        read -rp "请选择 [0-6]: " sub_choice
        case $sub_choice in
            1) list_keys; read -rp "按回车键继续..." _ ;;
            2) add_user_key; read -rp "按回车键继续..." _ ;;
            3) delete_key; read -rp "按回车键继续..." _ ;;
            4) backup_keys ;;
            5) restore_keys ;;
            6) delete_backups ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# SSH 综合管理主菜单
ssh_integrated_menu() {
    while true; do
        clear
        cat <<EOF
========== SSH 综合管理 🔒 ==========
[1] SSH 端口管理
[2] SSH 密码管理
[3] SSH 密钥管理
[4] SSH 公钥管理
[0] 返回主菜单
=====================================
EOF
        read -rp "请选择 [0-4]: " main_choice
        case $main_choice in
            1) ssh_port_submenu ;;
            2) ssh_password_submenu ;;
            3) ssh_key_management_submenu ;;
            4) ssh_pubkey_submenu ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# 功能7：卸载脚本
uninstall_script() {
    clear
    echo "========== 卸载脚本 =========="
    read -rp "确认卸载脚本（仅删除自身）？输入 yes 确认: " confirm
    if [[ "$confirm" == "yes" ]]; then
        rm -f "$0"
        echo -e "${GREEN}脚本已删除，即将退出 🚪${NC}"
        exit 0
    else
        echo "取消卸载"
        read -rp "按回车键返回主菜单..." _
    fi
}

# 功能8：设置时区与时间同步
set_timezone() {
    # 定义颜色变量（使用$'...'格式，最稳写法）
    local RED=$'\033[0;31m'
    local GREEN=$'\033[0;32m'
    local YELLOW=$'\033[1;33m'
    local BLUE=$'\033[0;34m'
    local PURPLE=$'\033[0;35m'
    local CYAN=$'\033[0;36m'
    local WHITE=$'\033[0;37m'
    local NC=$'\033[0m' # No Color
    
    # 定义NTP服务器列表（全局，供延迟测试使用）
    local -A ntp_servers=(
        [1]="ntp.ntsc.ac.cn|国家授时中心"
        [2]="ntp.cnnic.cn|中国互联网信息中心"
        [3]="cn.ntp.org.cn|中国NTP快速授时"
        [4]="ntp.aliyun.com|阿里云"
        [5]="ntp.tencent.com|腾讯云"
        [6]="cn.pool.ntp.org|中国池"
        [7]="pool.ntp.org|国际池"
        [8]="0.pool.ntp.org|池0"
        [9]="1.pool.ntp.org|池1"
        [10]="2.pool.ntp.org|池2"
        [11]="3.pool.ntp.org|池3"
        [12]="time1.google.com|Google 1"
        [13]="time2.google.com|Google 2"
        [14]="time3.google.com|Google 3"
        [15]="time4.google.com|Google 4"
        [16]="time.apple.com|Apple 1"
        [17]="time.asia.apple.com|Apple 2"
        [18]="time.euro.apple.com|Apple 3"
        [19]="time.aws.com|Amazon 1"
        [20]="amazon.pool.ntp.org|Amazon 2"
        [21]="time.cloudflare.com|Cloudflare"
        [22]="time.windows.com|Microsoft"
    )
    
    # 测试NTP服务器延迟的函数
    test_ntp_delay() {
        local server=$1
        local timeout=2
        
        # 方法1：使用chronyd测试（最准确）
        if command -v chronyd >/dev/null 2>&1; then
            local result=$(timeout $timeout chronyd -Q "server $server iburst" 2>&1 | grep "offset" | awk '{print $2}')
            if [ -n "$result" ]; then
                # 转换为毫秒并取绝对值
                local ms=$(echo "$result" | sed 's/s//' | awk '{printf "%.0f", sqrt($1*$1)*1000}')
                echo "$ms"
                return
            fi
        fi
        
        # 方法2：使用ping测试（备选）
        if command -v ping >/dev/null 2>&1; then
            local ping_result=$(ping -c 2 -W 1 $server 2>/dev/null | tail -1 | awk -F '/' '{print $5}' | cut -d'.' -f1)
            if [ -n "$ping_result" ] && [ "$ping_result" -eq "$ping_result" ] 2>/dev/null; then
                echo "$ping_result"
                return
            fi
        fi
        
        # 方法3：使用ntpdate测试
        if command -v ntpdate >/dev/null 2>&1; then
            local result=$(timeout $timeout ntpdate -q $server 2>&1 | grep "offset" | awk '{print $10}' | sed 's/://')
            if [ -n "$result" ]; then
                local ms=$(echo "$result" | awk '{printf "%.0f", sqrt($1*$1)}')
                echo "$ms"
                return
            fi
        fi
        
        echo "999"  # 超时或不可达
    }
    
    while true; do
        clear
        # 检查chrony是否安装
        local chrony_installed=false
        if command -v chronyd >/dev/null 2>&1 || command -v chronyc >/dev/null 2>&1; then
            chrony_installed=true
        fi
        
        # 获取NTP状态
        local ntp_status="未安装"
        local ntp_sync_status="未知"
        local time_offset="未知"
        local last_offset="未知"
        
        if $chrony_installed; then
            if systemctl is-active --quiet chronyd 2>/dev/null; then
                ntp_status="${GREEN}运行中${NC}"
                # 检查是否已同步
                if chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
                    ntp_sync_status="${GREEN}已同步${NC}"
                    # 获取时间偏差信息
                    time_offset=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4, $5, $6}')
                    last_offset=$(chronyc tracking 2>/dev/null | grep "Last offset" | awk '{print $4, $5}')
                else
                    ntp_sync_status="${YELLOW}未同步${NC}"
                fi
            else
                ntp_status="${YELLOW}已安装但未运行${NC}"
                ntp_sync_status="${YELLOW}未同步${NC}"
            fi
        else
            ntp_status="${RED}未安装 chrony${NC}"
            ntp_sync_status="${RED}不可用${NC}"
        fi
        
        # 主界面
        echo -e "${CYAN}========== 时区与时间同步 ==========${NC}"
        echo -e "${CYAN}当前时区:${NC} $(timedatectl show --property=Timezone --value 2>/dev/null || echo '无法获取')"
        echo -e "${CYAN}当前时间:${NC} $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo -e "${CYAN}NTP服务状态:${NC} $ntp_status"
        echo -e "${CYAN}NTP同步状态:${NC} $ntp_sync_status"
        echo -e "${CYAN}时间偏差:${NC} $time_offset"
        echo -e "${CYAN}上次偏差:${NC} $last_offset"
        echo ""
        echo -e "${GREEN}[1]${NC} 设置系统时区"
        echo -e "${GREEN}[2]${NC} 配置NTP时间同步"
        echo -e "${YELLOW}[3]${NC} 禁用NTP时间同步"
        echo -e "${GREEN}[4]${NC} 立即进行时间同步"
        echo -e "${GREEN}[5]${NC} 查看NTP同步状态"
        echo -e "${RED}[0]${NC} 返回主菜单"
        echo -e "${CYAN}=====================================${NC}"
        read -rp "请选择 [0-5]: " tz_choice
        
        case $tz_choice in
            1)
                echo -e "${GREEN}请选择时区：${NC}"
                echo -e "${GREEN}[1]${NC} UTC"
                echo -e "${GREEN}[2]${NC} Asia/Shanghai (上海)"
                echo -e "${GREEN}[3]${NC} Asia/Hong_Kong (香港)"
                echo -e "${GREEN}[4]${NC} Asia/Taipei (台北)"
                echo -e "${GREEN}[5]${NC} Asia/Tokyo (东京)"
                echo -e "${GREEN}[6]${NC} Asia/Singapore (新加坡)"
                echo -e "${GREEN}[7]${NC} America/New_York (纽约)"
                echo -e "${GREEN}[8]${NC} Europe/London (伦敦)"
                echo -e "${GREEN}[9]${NC} 手动输入"
                read -rp "请选择 [1-9]: " tz_sub
                case $tz_sub in
                    1) timedatectl set-timezone UTC ;;
                    2) timedatectl set-timezone Asia/Shanghai ;;
                    3) timedatectl set-timezone Asia/Hong_Kong ;;
                    4) timedatectl set-timezone Asia/Taipei ;;
                    5) timedatectl set-timezone Asia/Tokyo ;;
                    6) timedatectl set-timezone Asia/Singapore ;;
                    7) timedatectl set-timezone America/New_York ;;
                    8) timedatectl set-timezone Europe/London ;;
                    9)
                        read -rp "请输入时区（如 Europe/London）: " custom_tz
                        timedatectl set-timezone "$custom_tz" 2>/dev/null || echo -e "${RED}设置失败，时区格式错误${NC}"
                        ;;
                    *) echo -e "${RED}无效选择${NC}"; sleep 2; continue ;;
                esac
                echo -e "${GREEN}时区已设置为: $(timedatectl show --property=Timezone --value)${NC}"
                echo -e "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
                read -rp "按回车键继续..." _
                ;;
            2)
                # 检查并安装chrony
                if ! $chrony_installed; then
                    echo -e "${GREEN}正在安装chrony时间同步服务...${NC}"
                    if command -v apt >/dev/null 2>&1; then
                        apt update && apt install -y chrony
                    elif command -v yum >/dev/null 2>&1; then
                        yum install -y chrony
                    elif command -v dnf >/dev/null 2>&1; then
                        dnf install -y chrony
                    elif command -v zypper >/dev/null 2>&1; then
                        zypper install -y chrony
                    else
                        echo -e "${RED}无法安装chrony，不支持的包管理器${NC}"
                        read -rp "按回车键继续..." _
                        continue
                    fi
                    chrony_installed=true
                fi
                
                echo -e "${GREEN}正在测试NTP服务器延迟...${NC}"
                echo -e "${YELLOW}这可能需要几秒钟时间...${NC}"
                echo ""
                
                # 创建临时文件存储测试结果
                local tmp_results=$(mktemp)
                
                # 测试所有服务器的延迟
                local total=${#ntp_servers[@]}
                local current=0
                
                for key in $(echo "${!ntp_servers[@]}" | tr ' ' '\n' | sort -n); do
                    current=$((current + 1))
                    IFS='|' read -r server desc <<< "${ntp_servers[$key]}"
                    
                    # 显示进度
                    printf "\r${CYAN}正在测试 [%2d/%d]: %-30s${NC}" $current $total "$server"
                    
                    # 测试延迟
                    local delay=$(test_ntp_delay "$server")
                    echo "$key:$delay:$server:$desc" >> "$tmp_results"
                done
                echo -e "\n"
                
                # 按延迟排序并显示结果
                echo -e "${GREEN}NTP服务器延迟测试结果（按延迟排序）：${NC}"
                echo -e "${CYAN}-------------------------------------------------------------------------${NC}"
                printf "${GREEN}%-4s %-30s %-20s %-10s${NC}\n" "编号" "服务器" "描述" "延迟(ms)"
                echo -e "${CYAN}-------------------------------------------------------------------------${NC}"
                
                # 按延迟排序（排除999的放在最后）
                local sorted_results=$(sort -t':' -k2 -n "$tmp_results" | grep -v ":999:")
                local failed_results=$(grep ":999:" "$tmp_results")
                
                # 显示正常结果
                local display_num=1
                declare -A display_map
                
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    IFS=':' read -r key delay server desc <<< "$line"
                    
                    # 根据延迟显示颜色
                    if [ "$delay" -lt 20 ]; then
                        local color="${GREEN}"
                    elif [ "$delay" -lt 50 ]; then
                        local color="${YELLOW}"
                    else
                        local color="${RED}"
                    fi
                    
                    printf "${color}[%2d]${NC} %-30s %-20s ${color}%4d ms${NC}\n" "$display_num" "$server" "$desc" "$delay"
                    display_map[$display_num]="$key:$server"  # 保存映射关系
                    display_num=$((display_num + 1))
                done <<< "$sorted_results"
                
                # 显示失败的服务器
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    IFS=':' read -r key delay server desc <<< "$line"
                    printf "${RED}[%2d]${NC} %-30s %-20s ${RED}超时/不可达${NC}\n" "$display_num" "$server" "$desc"
                    display_map[$display_num]="$key:$server"
                    display_num=$((display_num + 1))
                done <<< "$failed_results"
                
                echo -e "${CYAN}-------------------------------------------------------------------------${NC}"
                echo ""
                
                # 用户选择
                echo -e "${YELLOW}请选择要使用的NTP服务器（可多选，用空格分隔，例如：1 3 5）：${NC}"
                echo -e "${GREEN}提示：建议选择2-4个延迟最低的服务器${NC}"
                read -rp "请输入选项 (默认: 1 2 3): " selected_options
                
                if [ -z "$selected_options" ]; then
                    selected_options="1 2 3"
                fi
                
                # 构建服务器列表（正确的格式）
                servers=()
                for opt in $selected_options; do
                    if [[ -n "${display_map[$opt]}" ]]; then
                        IFS=':' read -r key server <<< "${display_map[$opt]}"
                        # 正确的格式：server xxx.xxx.xxx iburst minpoll 3 maxpoll 6
                        servers+=("server $server iburst minpoll 3 maxpoll 6")
                    fi
                done
                
                # 清理临时文件
                rm -f "$tmp_results"
                
                # 如果没有选择任何服务器，使用默认
                if [ ${#servers[@]} -eq 0 ]; then
                    echo -e "${YELLOW}未选择有效服务器，使用默认配置${NC}"
                    servers=(
                        "server ntp.ntsc.ac.cn iburst minpoll 3 maxpoll 6"
                        "server ntp.aliyun.com iburst minpoll 3 maxpoll 6"
                        "server ntp.tencent.com iburst minpoll 3 maxpoll 6"
                        "server pool.ntp.org iburst minpoll 3 maxpoll 6"
                    )
                fi
                
                # 备份原有配置
                if [ -f /etc/chrony/chrony.conf ]; then
                    local backup_file="/etc/chrony/chrony.conf.bak.$(date +%Y%m%d%H%M%S)"
                    cp /etc/chrony/chrony.conf "$backup_file"
                    echo -e "${GREEN}原配置已备份为 $(basename $backup_file)${NC}"
                fi
                
                # 创建新的配置文件（正确的格式）
                cat > /etc/chrony/chrony.conf <<EOF
# 由系统管理脚本自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 同步策略：偏差超过1秒立即校正

# 服务器配置（自动选择，带轮询间隔）
$(printf '%s\n' "${servers[@]}")

# 指定密钥文件
keyfile /etc/chrony/chrony.keys

# 指定漂移文件
driftfile /var/lib/chrony/chrony.drift

# 日志目录
logdir /var/log/chrony

# 最大时钟偏差更新斜率
maxupdateskew 100.0

# 启用硬件时钟同步
rtcsync

# 偏差超过1秒立即校正（-1表示永久有效）
makestep 1.0 -1

# 允许NTP客户端访问（如果需要）
#allow 127.0.0.1
#local stratum 10
EOF

                # 验证配置文件语法
                echo -e "${CYAN}正在验证配置文件语法...${NC}"
                if chronyd -Q -q -t 1 >/dev/null 2>&1; then
                    echo -e "${GREEN}配置文件语法正确${NC}"
                else
                    echo -e "${YELLOW}警告：配置文件语法验证失败，请检查配置${NC}"
                fi
                
                # 启用并启动服务
                systemctl enable chronyd >/dev/null 2>&1
                systemctl restart chronyd
                
                echo -e "${GREEN}NTP服务已配置并启动${NC}"
                echo -e "${GREEN}同步策略：偏差超过1秒立即校正${NC}"
                echo -e "${GREEN}轮询间隔：minpoll 3 (8秒), maxpoll 6 (64秒)${NC}"
                echo -e "${CYAN}已选择的服务器：${NC}"
                for s in "${servers[@]}"; do
                    echo -e "  ${GREEN}✓${NC} $s"
                done
                
                sleep 2
                # 尝试立即同步
                chronyc -a makestep >/dev/null 2>&1
                
                echo -e "${GREEN}当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
                read -rp "按回车键继续..." _
                ;;
            3)
                if systemctl is-active --quiet chronyd 2>/dev/null; then
                    systemctl stop chronyd
                    systemctl disable chronyd
                fi
                timedatectl set-ntp false 2>/dev/null
                echo -e "${YELLOW}NTP已禁用${NC}"
                read -rp "按回车键继续..." _
                ;;
            4)
                if systemctl is-active --quiet chronyd 2>/dev/null; then
                    echo -e "${GREEN}正在进行时间同步...${NC}"
                    chronyc -a makestep >/dev/null 2>&1
                    sleep 2
                    
                    # 获取同步后的状态
                    local current_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
                    local sync_status=$(chronyc tracking 2>/dev/null | grep "Leap status" | cut -d':' -f2 | xargs)
                    local system_offset=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4, $5, $6}')
                    
                    echo -e "${GREEN}当前时间: $current_time${NC}"
                    
                    if [[ "$sync_status" == "Normal" ]]; then
                        echo -e "${GREEN}✓ 时间已同步${NC}"
                        echo -e "系统时间偏差: $system_offset"
                    else
                        echo -e "${YELLOW}⚠ 正在同步中...${NC}"
                    fi
                else
                    if $chrony_installed; then
                        echo -e "${YELLOW}chronyd 未运行，正在启动...${NC}"
                        systemctl start chronyd
                        sleep 2
                    else
                        echo -e "${RED}chrony 未安装，请先安装${NC}"
                    fi
                fi
                read -rp "按回车键继续..." _
                ;;
            5)
                if $chrony_installed && systemctl is-active --quiet chronyd 2>/dev/null; then
                    echo -e "${GREEN}========== NTP同步状态 ==========${NC}"
                    echo ""
                    
                    echo -e "${CYAN}【时间源信息】${NC}"
                    chronyc sources -v
                    echo ""
                    
                    echo -e "${CYAN}【同步详情】${NC}"
                    chronyc tracking | while IFS= read -r line; do
                        if [[ "$line" == *"Leap status"* ]]; then
                            if [[ "$line" == *"Normal"* ]]; then
                                echo -e " ${GREEN}✓${NC} $line"
                            else
                                echo -e " ${YELLOW}⚠${NC} $line"
                            fi
                        elif [[ "$line" == *"System time"* ]] || [[ "$line" == *"Last offset"* ]]; then
                            if [[ "$line" == *"slow"* ]]; then
                                echo -e " ${YELLOW}↓${NC} $line"
                            elif [[ "$line" == *"fast"* ]]; then
                                echo -e " ${YELLOW}↑${NC} $line"
                            else
                                echo "   $line"
                            fi
                        else
                            echo "   $line"
                        fi
                    done
                    echo ""
                    
                    echo -e "${CYAN}【当前同步策略】${NC}"
                    local makestep=$(grep -E "^makestep" /etc/chrony/chrony.conf 2>/dev/null | head -1 || echo "未配置")
                    echo "  同步策略: $makestep"
                    echo ""
                    
                    echo -e "${CYAN}【服务器延迟统计】${NC}"
                    chronyc sourcestats -v 2>/dev/null | head -20 | while IFS= read -r line; do
                        if [[ "$line" == *"^*"* ]] && [[ ! "$line" == *"Name/IP"* ]]; then
                            echo -e " ${GREEN}★${NC} $line"
                        elif [[ "$line" == *"^+"* ]] && [[ ! "$line" == *"Name/IP"* ]]; then
                            echo -e " ${CYAN}✓${NC} $line"
                        elif [[ "$line" =~ ^[0-9] ]] || [[ "$line" =~ ^[a-zA-Z] ]]; then
                            echo "   $line"
                        else
                            echo "$line"
                        fi
                    done
                    
                else
                    echo -e "${RED}chrony服务未运行或未安装${NC}"
                fi
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# 功能9：更新脚本
update_script() {
    clear
    echo "========== 更新脚本 =========="
    backup_file="/tmp/system-easy-backup-$(date +%Y%m%d%H%M%S).sh"
    cp "$0" "$backup_file"
    echo "当前脚本已备份为：$backup_file"
    echo "正在从 $SCRIPT_URL 下载新脚本..."
    if curl -L "$(github_raw_url system.sh)" -o /tmp/system-easy-new; then
        if bash -n /tmp/system-easy-new; then
            echo -e "${GREEN}新脚本语法检查通过，正在替换...${NC}"
            chmod +x /tmp/system-easy-new
            mv /tmp/system-easy-new "$INSTALL_PATH"
            rm -f "$backup_file"
            echo "脚本更新成功，备份已删除"
            echo "正在启动新脚本..."
            exec "$INSTALL_PATH"
        else
            echo -e "${RED}新脚本语法错误，回滚${NC}"
            mv "$backup_file" "$INSTALL_PATH"
            exec "$INSTALL_PATH"
        fi
    else
        echo -e "${RED}下载失败，回滚${NC}"
        mv "$backup_file" "$INSTALL_PATH"
        exec "$INSTALL_PATH"
    fi
}

# 功能10：查看内存占用最大程序
check_memory_usage() {
    clear
    echo "========== 内存占用最大5个进程 =========="
    ps -eo pid,ppid,cmd,%mem --sort=-%mem | head -n 6
    echo ""
    read -rp "按回车键返回主菜单..." _
}

# 功能11：查看端口占用
check_port_usage() {
    clear
    echo "========== 端口占用检查 =========="
    read -rp "请输入要检查的端口号: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}无效端口号，请输入1-65535之间的数字${NC}"
        read -rp "按回车键返回主菜单..." _
        return
    fi
    echo "端口 $port 占用情况："
    local found=0
    if command -v ss >/dev/null; then
        ss -tulnp | grep ":$port " && found=1
    elif command -v netstat >/dev/null; then
        netstat -tulnp | grep ":$port " && found=1
    fi
    if [ $found -eq 0 ]; then
        echo "端口 $port 未被占用"
    fi
    
    # 询问是否继续操作
    while true; do
        echo ""
        echo "请选择："
        echo "1. 检查其他端口"
        echo "0. 返回主菜单"
        read -rp "请输入选择 [0-1]: " sub_choice
        case $sub_choice in
            1)
                clear
                echo "========== 端口占用检查 =========="
                read -rp "请输入要检查的端口号: " port
                if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                    echo -e "${RED}无效端口号${NC}"
                    continue
                fi
                echo "端口 $port 占用情况："
                if command -v ss >/dev/null; then
                    ss -tulnp | grep ":$port "
                else
                    netstat -tulnp | grep ":$port "
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 功能12：查看CPU占用最大程序
check_cpu_usage() {
    clear
    echo "========== CPU占用最大5个进程 =========="
    ps -eo pid,ppid,cmd,%cpu --sort=-%cpu | head -n 6
    echo ""
    read -rp "按回车键返回主菜单..." _
}

# 功能13：系统定时重启
set_system_reboot() {
    while true; do
        clear
        cat <<EOF
========== 系统定时重启 ==========
[1] 设置定时重启
[2] 删除所有定时重启任务
[0] 返回主菜单
==================================
EOF
        read -rp "请选择 [0-2]: " choice
        case $choice in
            1)
                echo "请选择重启方式："
                echo "[1] X小时后重启"
                echo "[2] 每天某时间重启"
                echo "[3] 每周某天某时间重启"
                echo "[4] 每月某天某时间重启"
                read -rp "请选择 [1-4]: " reboot_choice
                case $reboot_choice in
                    1)
                        read -rp "请输入小时数: " hours
                        echo "shutdown -r +$((hours*60))" | at now
                        echo -e "${GREEN}系统将在 $hours 小时后重启${NC}"
                        ;;
                    2)
                        read -rp "请输入每天重启时间（HH:MM）: " time
                        if [[ "$time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                            hour=$(echo "$time" | cut -d: -f1)
                            minute=$(echo "$time" | cut -d: -f2)
                            (crontab -l 2>/dev/null; echo "$minute $hour * * * /sbin/shutdown -r now") | crontab -
                            echo -e "${GREEN}每天 $time 重启任务已设置${NC}"
                        else
                            echo -e "${RED}时间格式错误${NC}"
                        fi
                        ;;
                    3)
                        read -rp "请输入星期几（0-6，0=周日）: " weekday
                        read -rp "重启时间（HH:MM）: " time
                        if [[ "$weekday" =~ ^[0-6]$ && "$time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                            hour=$(echo "$time" | cut -d: -f1)
                            minute=$(echo "$time" | cut -d: -f2)
                            (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday /sbin/shutdown -r now") | crontab -
                            echo -e "${GREEN}每周 $weekday $time 重启任务已设置${NC}"
                        else
                            echo -e "${RED}输入错误${NC}"
                        fi
                        ;;
                    4)
                        read -rp "请输入每月第几天（1-31）: " day
                        read -rp "重启时间（HH:MM）: " time
                        if [[ "$day" =~ ^[1-3]?[0-9]$ && "$time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                            hour=$(echo "$time" | cut -d: -f1)
                            minute=$(echo "$time" | cut -d: -f2)
                            (crontab -l 2>/dev/null; echo "$minute $hour $day * * /sbin/shutdown -r now") | crontab -
                            echo -e "${GREEN}每月 $day 号 $time 重启任务已设置${NC}"
                        else
                            echo -e "${RED}输入错误${NC}"
                        fi
                        ;;
                    *) echo -e "${RED}无效选择${NC}" ;;
                esac
                read -rp "按回车键继续..." _
                ;;
            2)
                crontab -l | grep -v "/sbin/shutdown -r now" | crontab -
                atq | while read -r job; do atrm "$(echo $job | awk '{print $1}')"; done
                echo -e "${GREEN}所有定时重启任务已删除${NC}"
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# 功能14：Cron任务管理
cron_task_menu() {
    ensure_command crontab cron
    while true; do
        clear
        cat <<EOF
========== Cron任务管理 ==========
[1] 查看Cron任务
[2] 删除Cron任务
[3] 添加Cron任务
[0] 返回主菜单
==================================
EOF
        read -rp "请选择 [0-3]: " choice
        case $choice in
            1)
                echo "当前所有Cron任务："
                for user in $(ls /var/spool/cron/crontabs 2>/dev/null); do
                    echo "用户 $user:"
                    crontab -u "$user" -l 2>/dev/null | grep -v '^#' | sed 's/^/  /' || echo "  无任务"
                done
                read -rp "按回车键继续..." _
                ;;
            2)
                # 简化：直接编辑当前用户的 crontab
                echo "编辑当前用户的 crontab (使用 crontab -e)"
                crontab -e
                ;;
            3)
                read -rp "请输入完整Cron任务（格式：分 时 日 月 周 命令）: " new_cron
                if [[ "$new_cron" =~ ^[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-7*,-/]+[[:space:]]+.+ ]]; then
                    (crontab -l 2>/dev/null; echo "$new_cron") | crontab -
                    echo -e "${GREEN}Cron任务已添加${NC}"
                else
                    echo -e "${RED}格式错误${NC}"
                fi
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# 功能15：SWAP管理
swap_menu() {
    while true; do
        clear
        cat <<EOF
========== SWAP管理 ==========
[1] 添加SWAP（自定义大小）
[2] 删除SWAP
[3] 查看当前SWAP状态
[0] 返回主菜单
==============================
EOF
        read -rp "请选择 [0-3]: " choice
        case $choice in
            1)
                echo "当前SWAP信息："
                swapon --show || echo "无SWAP"
                if swapon --show | grep -q '/swapfile'; then
                    read -rp "已存在 /swapfile，覆盖？(y/n): " confirm
                    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && continue
                    swapoff /swapfile 2>/dev/null
                    rm -f /swapfile
                    sed -i '/\/swapfile/d' /etc/fstab
                fi
                read -rp "请输入SWAP大小（GB，可小数）: " size_gb
                if ! [[ "$size_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    echo -e "${RED}无效数字${NC}"; sleep 2; continue
                fi
                size_mb=$(awk "BEGIN {printf \"%d\", $size_gb*1024}")
                if [ "$size_mb" -lt 1 ]; then
                    echo -e "${RED}大小不能小于1MB${NC}"; sleep 2; continue
                fi
                echo "创建 ${size_gb}GB SWAP文件..."
                fallocate -l ${size_mb}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$size_mb
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                echo "/swapfile none swap sw 0 0" >> /etc/fstab
                echo -e "${GREEN}SWAP已添加${NC}"
                read -rp "按回车键继续..." _
                ;;
            2)
                swapoff /swapfile 2>/dev/null
                rm -f /swapfile
                sed -i '/\/swapfile/d' /etc/fstab
                echo -e "${GREEN}SWAP已删除${NC}"
                read -rp "按回车键继续..." _
                ;;
            3)
                swapon --show
                free -h | grep Swap
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# 功能16：网络排查工具安装
install_network_tools() {
    clear
    echo "========== 安装网络排查工具 =========="
    echo "包含：TCPing、tcptraceroute、MTR、NextTrace、Speedtest、iperf3"
    ensure_command tcptraceroute tcptraceroute
    ensure_command bc
    # tcping
    wget -q --show-progress "$(github_raw_url tcping.sh)" -O /usr/bin/tcping && chmod +x /usr/bin/tcping
    # mtr
    ensure_command mtr mtr-tiny
    # nexttrace
    curl -sL nxtrace.org/nt | bash
    # speedtest
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    apt install -y speedtest
    # iperf3
    ensure_command iperf3
    echo -e "${GREEN}所有工具安装完成！${NC}"
    read -rp "按回车键返回主菜单..." _
}

# 功能17：DDNS管理（拉取并执行外部脚本）
ddns_menu() {
    clear
    echo "正在拉取 DDNS 管理脚本..."
    local url=$(github_raw_url ddns.sh)
    curl -fsSL "$url" -o /tmp/ddns-easy
    if [ $? -eq 0 ]; then
        chmod +x /tmp/ddns-easy
        mv /tmp/ddns-easy /usr/local/bin/ddns-easy
        echo -e "${GREEN}DDNS 脚本安装完成，正在启动...${NC}"
        sleep 1
        ddns-easy
    else
        echo -e "${RED}下载失败${NC}"
        read -rp "按回车键返回主菜单..." _
    fi
}

# 功能18：GitHub镜像加速管理
git_proxy_menu() {
    while true; do
        clear
        cat <<EOF
========== GitHub 镜像加速 ==========
当前前缀: ${GITHUB_PROXY:-未设置}

[1] 设置/修改镜像前缀
[2] 删除镜像前缀
[0] 返回主菜单
=====================================
EOF
        read -rp "请选择 [0-2]: " gp_choice
        case $gp_choice in
            1)
                echo "请输入新的加速前缀 (例如 https://ghfast.top/ ，留空则清除):"
                read -r new_proxy
                if [[ -z "$new_proxy" ]]; then
                    GITHUB_PROXY=""
                    rm -f "$GITHUB_PROXY_FILE"
                    echo -e "${GREEN}已清除加速前缀${NC}"
                else
                    mkdir -p "$(dirname "$GITHUB_PROXY_FILE")"
                    echo -n "$new_proxy" > "$GITHUB_PROXY_FILE"
                    GITHUB_PROXY="$new_proxy"
                    echo -e "${GREEN}已设置加速前缀: $GITHUB_PROXY${NC}"
                fi
                read -rp "按回车键继续..." _
                ;;
            2)
                rm -f "$GITHUB_PROXY_FILE"
                GITHUB_PROXY=""
                echo -e "${GREEN}已删除加速前缀${NC}"
                read -rp "按回车键继续..." _
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# 功能19：退出（已在主菜单处理）

# 主菜单
while true; do
    clear
    show_system_info
    echo -e "${WHITE}System-Easy 功能菜单${NC}"
    echo -e "${YELLOW}[1]${NC} 安装常用工具 🛠️          ${YELLOW}[10]${NC} 内存占用最大 💾"
    echo -e "${YELLOW}[2]${NC} 日志清理管理 🗑️          ${YELLOW}[11]${NC} 查看端口占用 🔍"
    echo -e "${YELLOW}[3]${NC} BBR管理 ⚡               ${YELLOW}[12]${NC} CPU占用最大 🖥️"
    echo -e "${YELLOW}[4]${NC} DNS管理 🌐               ${YELLOW}[13]${NC} 系统定时重启 🔄"
    echo -e "${YELLOW}[5]${NC} 修改主机名 🖥️            ${YELLOW}[14]${NC} Cron任务管理 ⏰"
    echo -e "${YELLOW}[6]${NC} SSH综合管理 🔒           ${YELLOW}[15]${NC} SWAP管理 💾"
    echo -e "${YELLOW}[7]${NC} 卸载脚本 🗑️              ${YELLOW}[16]${NC} 网络排查工具 🔧"
    echo -e "${YELLOW}[8]${NC} 设置时区与时间同步 ⏰     ${YELLOW}[17]${NC} DDNS管理 🌐"
    echo -e "${YELLOW}[9]${NC} 更新脚本 📥              ${YELLOW}[18]${NC} GitHub镜像加速 ⚡"
    echo -e "${YELLOW}[0]${NC} 退出 🚪"
    echo ""
    read -rp "请输入您的选择 [0-18]: " main_choice

    case $main_choice in
        1) install_tools ;;
        2) log_cleanup_menu ;;
        3) bbr_menu ;;
        4) dns_menu ;;
        5) change_hostname ;;
        6) ssh_integrated_menu ;;
        7) uninstall_script ;;
        8) set_timezone ;;
        9) update_script ;;
        10) check_memory_usage ;;  # 内存占用最大
        11) check_port_usage ;;
        12) check_cpu_usage ;;
        13) set_system_reboot ;;
        14) cron_task_menu ;;
        15) swap_menu ;;
        16) install_network_tools ;;
        17) ddns_menu ;;
        18) git_proxy_menu ;;
        0) 
            echo -e "${GREEN}👋 已退出，下次使用直接运行: sudo system-easy${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}无效选择，请重试 😕${NC}"
            sleep 1
            ;;
    esac
done