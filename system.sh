#!/bin/bash

# 检查是否以root身份运行 🚨
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root身份运行 🚨" 1>&2
   exit 1
fi

# 脚本URL
SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/system.sh"

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

# 功能3：BBR管理子菜单 ⚡
bbr_menu() {
    while true; do
        echo "BBR管理菜单 ⚡："
        echo "1. 安装BBR v3 🚀"
        echo "2. BBR调优 ⚙️"
        echo "3. 卸载BBR 🗑️"
        echo "4. 返回主菜单 🔙"
        read -p "请输入您的选择： " choice
        case $choice in
            1)
                echo "正在安装BBR v3内核 ⏳..."
                echo "注意：安装完成后，请手动输入 'system-easy' 返回面板以继续操作 ❗"
                bash <(curl -L -s https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh)
                if lsmod | grep -q tcp_bbr; then
                    echo "BBR v3内核安装成功 🎉 请运行 'system-easy' 返回面板以调优或管理BBR。"
                else
                    echo "BBR v3安装失败，请检查网络或日志 😔"
                fi
                return
                ;;
            2)
                echo "正在应用BBR优化配置 ⚙️..."
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
                if sysctl -p && sysctl --system; then
                    echo "BBR优化配置已应用 🎉"
                    echo "当前TCP拥塞控制算法：$(sysctl -n net.ipv4.tcp_congestion_control)"
                else
                    echo "BBR优化配置应用失败，请检查 /etc/sysctl.conf 😔"
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            3)
                echo "正在卸载BBR 🗑️..."
                if lsmod | grep -q tcp_bbr; then
                    rmmod tcp_bbr 2>/dev/null
                    if ! lsmod | grep -q tcp_bbr; then
                        echo "BBR模块已移除 ✅"
                    else
                        echo "无法移除BBR模块，可能被内核占用 😔"
                    fi
                else
                    echo "未检测到BBR模块，无需移除 ✅"
                fi
                # 恢复默认TCP拥塞控制
                sed -i '/net\.core\.default_qdisc/d' /etc/sysctl.conf
                sed -i '/net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
                echo "net.ipv4.tcp_congestion_control=cubic" >> /etc/sysctl.conf
                if sysctl -p && sysctl --system; then
                    echo "已恢复默认TCP拥塞控制（cubic） 🎉"
                    echo "当前TCP拥塞控制算法：$(sysctl -n net.ipv4.tcp_congestion_control)"
                else
                    echo "恢复默认配置失败，请检查 /etc/sysctl.conf 😔"
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
                        echo "  systemctl status ssh.service"
                        echo "  journalctl -xeu ssh.service"
                        mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                        continue
                    fi
                else
                    echo "SSH配置文件测试失败 😔 请检查："
                    echo "  sshd -t"
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
    new_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c 20)
    # 确保密码包含至少1个大写字母、1个小写字母、1个数字、1个特殊字符
    while true; do
        has_upper=$(echo "$new_pass" | grep -q '[A-Z]' && echo "yes" || echo "no")
        has_lower=$(echo "$new_pass" | grep -q '[a-z]' && echo "yes" || echo "no")
        has_digit=$(echo "$new_pass" | grep -q '[0-9]' && echo "yes" || echo "no")
        has_special=$(echo "$new_pass" | grep -q '[!@#$%^&*()_+]' && echo "yes" || echo "no")
        if [ "$has_upper" = "yes" ] && [ "$has_lower" = "yes" ] && [ "$has_digit" = "yes" ] && [ "$has_special" = "yes" ]; then
            break
        fi
        new_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c 20)
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
        echo "  journalctl -xeu ssh.service"
    else
        echo "密码修改失败 😔 请检查："
        echo "  journalctl -xeu ssh.service"
        echo "您可以尝试手动修改密码：sudo passwd root"
    fi
}

# 功能8：卸载脚本 🗑️
uninstall_script() {
    echo "正在卸载脚本（仅删除脚本本身） 🗑️..."
    rm -f "$0"
    echo "脚本已删除，即将退出 🚪"
    exit 0
}

# 功能9：设置系统时区与时间同步 ⏰
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
                echo "当前系统时区：$(timedatectl show --property=Timezone --value) 🕒"
                echo "NTP服务状态：$(timedatectl show --property=NTPSynchronized --value | grep -q 'yes' && echo '已同步' || echo '未同步')"
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
                        timedatectl set-timezone UTC
                        echo "时区已设置为UTC 🎉"
                        ;;
                    2)
                        timedatectl set-timezone Asia/Shanghai
                        echo "时区已设置为Asia/Shanghai 🎉"
                        ;;
                    3)
                        timedatectl set-timezone America/New_York
                        echo "时区已设置为America/New_York 🎉"
                        ;;
                    4)
                        echo "请输入时区（格式示例：Asia/Shanghai 或 Europe/London） 📝"
                        echo "可使用 'timedatectl list-timezones' 查看可用时区 🔍"
                        read -p "请输入时区： " custom_tz
                        if timedatectl set-timezone "$custom_tz"; then
                            echo "时区已设置为$custom_tz 🎉"
                        else
                            echo "时区设置失败，请检查输入格式（例如Asia/Shanghai） 😔"
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
                read -p "请输入您的选择 [1-9]（直接回车默认选4）： " ntp_choice
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
                    # 启用系统NTP
                    timedatectl set-ntp true
                    echo "等待时间同步（可能需要几秒钟） ⏳..."
                    sleep 5
                    if timedatectl show --property=NTPSynchronized --value | grep -q 'yes'; then
                        echo "时间同步成功，当前时间：$(date) ✅"
                    else
                        echo "时间同步尚未完成，请稍后检查（timedatectl status） 😔"
                    fi
                else
                    echo "NTP服务启动失败，请检查：journalctl -xeu chronyd 😔"
                fi
                echo "按回车键返回菜单 🔙"
                read
                ;;
            4)
                echo "正在禁用NTP时间同步 🚫..."
                timedatectl set-ntp false
                if systemctl is-active --quiet chronyd; then
                    systemctl stop chronyd >/dev/null 2>&1
                    systemctl disable chronyd >/dev/null 2>&1
                    echo "NTP服务已禁用 🎉"
                else
                    echo "NTP服务未运行，无需禁用 ✅"
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
                    sleep 3
                    if timedatectl show --property=NTPSynchronized --value | grep -q 'yes'; then
                        echo "时间同步成功，当前时间：$(date) 🎉"
                    else
                        echo "时间同步失败，请检查NTP服务状态（systemctl status chronyd） 😔"
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

# 功能10：更新脚本 📥
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

# 功能11：查看端口占用 🔍
check_port_usage() {
    read -p "请输入要检查的端口号： " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "无效端口号，请输入1-65535之间的数字 😕"
        return
    fi

    echo "端口 $port 的占用情况 🔍："
    echo "PID    Process Name    Address"
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
                    echo "$pid    $process_name    $address"
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
                    echo "$pid    $process_name    $address"
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

# 功能12：查看内存占用最大程序 💾
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

# 功能13：查看CPU占用最大程序 🖥️
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

# 功能14：设置系统定时重启 🔄
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

# 功能15：Cron任务管理 ⏰
cron_task_menu() {
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

# 主菜单 📋
while true; do
    echo "系统维护脚本菜单 📋："
    echo "1. 安装常用工具和依赖 🛠️"
    echo "2. 日志清理管理 🗑️"
    echo "3. BBR管理 ⚡"
    echo "4. DNS管理 🌐"
    echo "5. 修改主机名 🖥️"
    echo "6. SSH端口管理 🔒"
    echo "7. 修改SSH密码 🔑"
    echo "8. 卸载脚本 🗑️"
    echo "9. 设置系统时区与时间同步 ⏰"
    echo "10. 更新脚本 📥"
    echo "11. 查看端口占用 🔍"
    echo "12. 查看内存占用最大程序 💾"
    echo "13. 查看CPU占用最大程序 🖥️"
    echo "14. 设置系统定时重启 🔄"
    echo "15. Cron任务管理 ⏰"
    echo "16. 退出 🚪"
    read -p "请输入您的选择： " main_choice
    case $main_choice in
        1) install_tools ;;
        2) log_cleanup_menu ;;
        3) bbr_menu ;;
        4) dns_menu ;;
        5) change_hostname ;;
        6) ssh_port_menu ;;
        7) change_ssh_password ;;
        8) uninstall_script ;;
        9) set_timezone ;;
        10) update_script ;;
        11) check_port_usage ;;
        12) check_memory_usage ;;
        13) check_cpu_usage ;;
        14) set_system_reboot ;;
        15) cron_task_menu ;;
        16) 
            echo "👋 已退出，⚡ 下次使用直接运行: sudo system-easy"
            exit 0 
            ;;
        *) echo "无效选择，请重试 😕" ;;
    esac
done