#!/bin/bash

# 检查是否以root身份运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root身份运行" 1>&2
   exit 1
fi

# 用于存储原SSH端口的临时文件
SSH_PORT_FILE="/tmp/original_ssh_port"

# 功能1：安装常用工具和依赖
install_tools() {
    echo "正在更新软件包列表..."
    apt update -y
    echo "正在安装常用工具：curl、vim、git及依赖..."
    apt install -y curl vim git python3-systemd systemd-journal-remote cron
    echo "安装完成。"
}

# 功能2：日志清理子菜单
log_cleanup_menu() {
    while true; do
        echo "日志清理菜单："
        echo "1. 开启自动日志清理（每天凌晨02:00）"
        echo "2. 关闭自动日志清理"
        echo "3. 返回主菜单"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "正在启用自动日志清理..."
                cron_job="0 2 * * * journalctl --vacuum-time=2weeks && find /var/log -type f -name '*.log.*' -exec rm {} \; && find /var/log -type f -name '*.gz' -exec rm {} \;"
                (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
                echo "自动日志清理已启用（每天凌晨02:00）。"
                ;;
            2)
                echo "正在关闭自动日志清理..."
                crontab -l | grep -v "journalctl --vacuum-time=2weeks" | crontab -
                echo "自动日志清理已关闭。"
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择，请重试。"
                ;;
        esac
    done
}

# 功能3：启用BBR
enable_bbr() {
    # 检查是否为Debian 13
    if grep -q "Debian GNU/Linux 13" /etc/os-release; then
        echo "检测到Debian 13，正在创建/etc/sysctl.conf（如果不存在）..."
        touch /etc/sysctl.conf
    fi

    # 检查是否支持BBR
    if ! lsmod | grep -q tcp_bbr; then
        echo "未检测到BBR模块，正在通过外部脚本安装..."
        bash <(curl -L -s https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh)
        echo "BBR安装脚本已执行，请等待完成。"
    else
        echo "BBR模块已可用。"
    fi

    # 应用BBR优化配置
    echo "正在应用BBR优化配置..."
    cat > /etc/sysctl.conf << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
    sysctl -p && sysctl --system
    echo "BBR已启用并优化，按回车键返回菜单。"
    read
}

# 功能4：DNS管理子菜单
dns_menu() {
    while true; do
        echo "DNS管理菜单："
        echo "1. 查看当前系统DNS"
        echo "2. 修改系统DNS（永久更改）"
        echo "3. 返回主菜单"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "当前DNS设置："
                cat /etc/resolv.conf
                ;;
            2)
                echo "警告：此操作将永久修改系统DNS。"
                read -p "请输入新的DNS服务器（例如8.8.8.8）： " dns1
                read -p "请输入备用DNS服务器（可选，例如8.8.4.4）： " dns2
                echo "nameserver $dns1" > /etc/resolv.conf
                if [ ! -z "$dns2" ]; then
                    echo "nameserver $dns2" >> /etc/resolv.conf
                fi
                # 防止系统覆盖resolv.conf
                chattr +i /etc/resolv.conf
                echo "DNS已永久修改。"
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择，请重试。"
                ;;
        esac
    done
}

# 功能5：修改主机名
change_hostname() {
    current_hostname=$(hostname)
    echo "当前主机名：$current_hostname"
    read -p "请输入新主机名： " new_hostname
    echo "警告：此操作将永久更改主机名。"
    hostnamectl set-hostname "$new_hostname"
    sed -i "s/$current_hostname/$new_hostname/g" /etc/hosts
    echo "主机名已更改为$new_hostname。"
}

# 功能6：SSH端口管理子菜单
ssh_port_menu() {
    # 获取当前SSH端口
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1 || echo "22")
    echo "当前SSH端口：$current_port"

    while true; do
        echo "SSH端口管理菜单："
        echo "1. 修改SSH端口（原端口$current_port将保持有效直到手动禁用）"
        echo "2. 禁用原登录端口"
        echo "3. 返回主菜单"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                read -p "请输入新的SSH端口： " new_port
                # 记录原端口到临时文件
                echo "$current_port" > "$SSH_PORT_FILE"
                # 添加新端口但保留旧端口
                sed -i "/^Port /d" /etc/ssh/sshd_config
                echo "Port $current_port" >> /etc/ssh/sshd_config
                echo "Port $new_port" >> /etc/ssh/sshd_config
                # 检查UFW是否启用并添加新端口规则
                if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
                    echo "检测到UFW防火墙已启用，正在为新端口 $new_port 添加放行规则..."
                    ufw allow "$new_port"/tcp
                    ufw reload
                    echo "UFW规则已更新，新端口 $new_port 已放行。"
                fi
                systemctl restart ssh
                echo "SSH端口已修改，$current_port和$new_port均可使用。"
                current_port="$new_port"  # 更新用于下次显示
                ;;
            2)
                # 读取记录的原端口
                if [ -f "$SSH_PORT_FILE" ]; then
                    old_port=$(cat "$SSH_PORT_FILE")
                    echo "记录的原SSH端口：$old_port"
                    read -p "是否禁用端口 $old_port？（y/n）： " confirm
                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                        sed -i "/^Port $old_port/d" /etc/ssh/sshd_config
                        systemctl restart ssh
                        # 删除临时文件
                        rm -f "$SSH_PORT_FILE"
                        echo "原端口$old_port已禁用，临时文件已删除。"
                        # 如果UFW启用，移除旧端口规则
                        if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
                            ufw delete allow "$old_port"/tcp
                            ufw reload
                            echo "UFW规则已更新，端口 $old_port 已移除。"
                        fi
                    else
                        read -p "请输入要禁用的端口： " manual_port
                        sed -i "/^Port $manual_port/d" /etc/ssh/sshd_config
                        systemctl restart ssh
                        echo "端口$manual_port已禁用。"
                        if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
                            ufw delete allow "$manual_port"/tcp
                            ufw reload
                            echo "UFW规则已更新，端口 $manual_port 已移除。"
                        fi
                    fi
                else
                    read -p "未找到记录的原端口，请输入要禁用的端口： " manual_port
                    sed -i "/^Port $manual_port/d" /etc/ssh/sshd_config
                    systemctl restart ssh
                    echo "端口$manual_port已禁用。"
                    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
                        ufw delete allow "$manual_port"/tcp
                        ufw reload
                        echo "UFW规则已更新，端口 $manual_port 已移除。"
                    fi
                fi
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择，请重试。"
                ;;
        esac
    done
}

# 功能7：修改SSH密码
change_ssh_password() {
    echo "生成一个20位复杂密码..."
    new_pass=$(openssl rand -base64 15 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c 20)
    echo "生成的密码：$new_pass"
    echo "警告：修改后，下次登录必须使用新密码。"

    read -p "请输入新密码（可见）： " pass1
    read -p "请再次确认新密码（可见）： " pass2

    if [ "$pass1" != "$pass2" ]; then
        echo "两次输入的密码不匹配，操作取消。"
        return
    fi

    echo "root:$pass1" | chpasswd
    echo "SSH密码已更改，新密码为：$pass1"
    echo "请记住：下次登录需使用此新密码。"
}

# 功能8：卸载脚本
uninstall_script() {
    echo "正在卸载脚本（仅删除脚本本身）..."
    rm -f "$0"
    echo "脚本已删除，即将退出。"
    exit 0
}

# 功能9：设置系统时区
set_timezone() {
    echo "当前系统时区：$(timedatectl show --property=Timezone --value)"
    echo "请选择时区："
    echo "[1] UTC"
    echo "[2] Asia/Shanghai（中国标准时间）"
    echo "[3] America/New_York（纽约时间）"
    echo "[4] 手动输入时区"
    read -p "请输入您的选择 [1-4]： " tz_choice
    case $tz_choice in
        1)
            timedatectl set-timezone UTC
            echo "时区已设置为UTC。"
            ;;
        2)
            timedatectl set-timezone Asia/Shanghai
            echo "时区已设置为Asia/Shanghai。"
            ;;
        3)
            timedatectl set-timezone America/New_York
            echo "时区已设置为America/New_York。"
            ;;
        4)
            echo "请输入时区（格式示例：Asia/Shanghai 或 Europe/London）"
            echo "可使用 'timedatectl list-timezones' 查看可用时区"
            read -p "请输入时区： " custom_tz
            if timedatectl set-timezone "$custom_tz"; then
                echo "时区已设置为$custom_tz。"
            else
                echo "时区设置失败，请检查输入格式（例如Asia/Shanghai）。"
            fi
            ;;
        *)
            echo "无效选择，时区未更改。"
            ;;
    esac
    echo "按回车键返回菜单。"
    read
}

# 主菜单
while true; do
    echo "系统维护脚本菜单："
    echo "1. 安装常用工具和依赖"
    echo "2. 日志清理管理"
    echo "3. 启用BBR"
    echo "4. DNS管理"
    echo "5. 修改主机名"
    echo "6. SSH端口管理"
    echo "7. 修改SSH密码"
    echo "8. 卸载脚本"
    echo "9. 设置系统时区"
    echo "10. 退出"
    read -p "请输入您的选择： " main_choice
    case $main_choice in
        1) install_tools ;;
        2) log_cleanup_menu ;;
        3) enable_bbr ;;
        4) dns_menu ;;
        5) change_hostname ;;
        6) ssh_port_menu ;;
        7) change_ssh_password ;;
        8) uninstall_script ;;
        9) set_timezone ;;
        10) exit 0 ;;
        *) echo "无效选择，请重试。" ;;
    esac
done