#!/bin/bash
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印信息函数
info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# 检查命令是否存在
check_cmd() { command -v "$1" &>/dev/null; }

# 安装基础依赖
install_deps() {
    if check_cmd apt; then
        info "Detected apt-based system"
        sudo apt update || error "apt update failed"
        sudo apt install -y wget curl tar nginx apache2-utils || error "apt install failed"
    elif check_cmd dnf; then
        info "Detected dnf-based system"
        sudo dnf install -y wget curl tar nginx httpd-tools || error "dnf install failed"
    else
        error "Unsupported package manager. Only apt/dnf are supported."
    fi
}

# 获取下载链接
get_download_url() {
    local version="1.10.2"
    local file="node_exporter-${version}.linux-amd64.tar.gz"
    local github_url="https://github.com/prometheus/node_exporter/releases/download/v${version}/${file}"

    info "Detecting geographic location..."
    local country
    country=$(curl -s --max-time 3 https://ipapi.co/country/ 2>/dev/null || true)

    if [[ "$country" == "CN" ]]; then
        warn "Detected China mainland. GitHub downloads may be slow."
        read -r -p "Do you want to use a GitHub acceleration proxy? (y/n) [n]: " use_proxy
        use_proxy=${use_proxy:-n}
        if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
            read -r -p "Enter acceleration proxy prefix (e.g., https://ghproxy.com/ ): " proxy_prefix
            proxy_prefix="${proxy_prefix%/}"
            echo "${proxy_prefix}/${github_url}"
            return
        fi
    fi
    echo "$github_url"
}

# 安装 Node Exporter
install_node_exporter() {
    local enable_ip_collect="$1"
    local download_url
    download_url=$(get_download_url)
    local target="/tmp/node_exporter.tar.gz"

    info "Downloading Node Exporter from: $download_url"
    curl -fL -o "$target" "$download_url" || error "Download failed"

    info "Extracting Node Exporter..."
    tar -zxf "$target" -C /tmp || error "Extraction failed"

    local extract_dir="/tmp/node_exporter-1.10.2.linux-amd64"
    local install_dir="/node_exporter"

    if [[ -d "$install_dir" ]]; then
        warn "Removing existing $install_dir"
        sudo rm -rf "$install_dir"
    fi
    sudo cp -r "$extract_dir" "$install_dir"

    # 构建 systemd service 文件
    local service_file="/etc/systemd/system/node_exporter.service"
    
    if [[ "$enable_ip_collect" == "yes" ]]; then
        info "Configuring node_exporter with textfile collector for IP metrics"
        sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=root
ExecStart=${install_dir}/node_exporter \\
    --web.listen-address="127.0.0.1:9100" \\
    --collector.textfile.directory="/var/lib/node_exporter/textfile"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    else
        info "Configuring node_exporter without textfile collector"
        sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=root
ExecStart=${install_dir}/node_exporter --web.listen-address="127.0.0.1:9100"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable --now node_exporter.service || error "Failed to start node_exporter"
    info "Node Exporter started on 127.0.0.1:9100"

    # 清理临时文件
    rm -f "$target"
    rm -rf "$extract_dir"
}

# 配置 IP 采集
setup_ip_collection() {
    info "Setting up IP collection system..."
    
    # 创建 textfile 目录
    sudo mkdir -p /var/lib/node_exporter/textfile
    sudo chmod 755 /var/lib/node_exporter/textfile
    
    # 创建脚本目录
    sudo mkdir -p /etc/node-exporter-ip
    
    # 创建 IP 采集脚本
    sudo tee /etc/node-exporter-ip/update-ip.sh > /dev/null <<'EOF'
#!/bin/bash

# 获取 IPv4 出站 IP
IPV4=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
# 获取 IPv6 出站 IP
IPV6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

# 写入 prometheus 格式文件
cat > /var/lib/node_exporter/textfile/node_ip.prom <<PROM
# HELP node_ip_info Egress IP address of the node
# TYPE node_ip_info gauge
PROM

# 添加 IPv4 指标（如果不为空）
if [[ -n "$IPV4" ]]; then
    echo "node_ip_info{ip=\"$IPV4\",family=\"ipv4\"} 1" >> /var/lib/node_exporter/textfile/node_ip.prom
fi

# 添加 IPv6 指标（如果不为空）
if [[ -n "$IPV6" ]]; then
    echo "node_ip_info{ip=\"$IPV6\",family=\"ipv6\"} 1" >> /var/lib/node_exporter/textfile/node_ip.prom
fi
EOF

    sudo chmod +x /etc/node-exporter-ip/update-ip.sh
    
    # 创建 systemd service
    sudo tee /etc/systemd/system/node-ip.service > /dev/null <<EOF
[Unit]
Description=Update Node Exporter IP metrics
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/node-exporter-ip/update-ip.sh
EOF

    # 创建 systemd timer（每60秒执行一次）
    sudo tee /etc/systemd/system/node-ip.timer > /dev/null <<EOF
[Unit]
Description=Timer for Node Exporter IP metrics update

[Timer]
OnBootSec=20s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
EOF

    # 启用 timer
    sudo systemctl daemon-reload
    sudo systemctl enable node-ip.timer
    sudo systemctl start node-ip.timer
    
    # 立即执行一次生成指标
    sudo /etc/node-exporter-ip/update-ip.sh
    
    info "IP collection system configured and started"
}

# 配置 Nginx 反向代理
configure_nginx() {
    local username="$1"
    local auth_file="/etc/nginx/.htpasswd"
    local nginx_conf="/etc/nginx/conf.d/node_exporter.conf"

    info "Setting up HTTP basic authentication for Nginx"
    while true; do
        read -s -p "Enter password: " password
        echo
        read -s -p "Confirm password: " password_confirm
        echo
        if [[ "$password" == "$password_confirm" && -n "$password" ]]; then
            break
        else
            warn "Passwords do not match or empty. Please try again."
        fi
    done

    if check_cmd htpasswd; then
        echo "$password" | sudo htpasswd -i -c "$auth_file" "$username"
    elif check_cmd openssl; then
        local hashed
        hashed=$(openssl passwd -6 "$password")
        echo "$username:$hashed" | sudo tee "$auth_file" > /dev/null
    else
        error "Neither htpasswd nor openssl found. Please install apache2-utils or httpd-tools."
    fi

    sudo tee "$nginx_conf" > /dev/null <<EOF
server {
    listen 9101;
    server_name _;

    auth_basic "Restricted Metrics";
    auth_basic_user_file $auth_file;

    location / {
        proxy_pass http://127.0.0.1:9100;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

    sudo nginx -t || error "Nginx configuration test failed"
    sudo systemctl enable --now nginx
    sudo systemctl restart nginx || error "Failed to restart Nginx"
    info "Nginx reverse proxy configured on port 9101 with basic auth"

    echo "$username"
}

# 打印最终访问信息
print_connection_info() {
    local username="$1"
    local enable_ip_collect="$2"
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}')
    if [[ -z "$ip_addr" ]]; then
        ip_addr="<server_ip>"
    fi

    echo ""
    echo -e "${GREEN}========== Installation Complete ==========${NC}"
    echo "Node Exporter is running locally on 127.0.0.1:9100"
    echo "Nginx proxy with basic auth listening on port 9101"
    echo ""
    echo -e "Access metrics URL: ${YELLOW}http://${ip_addr}:9101/metrics${NC}"
    echo "Username: $username"
    echo "Password: (the one you entered)"
    echo ""
    echo "Test with: curl -u '$username' http://${ip_addr}:9101/metrics"
    
    # 打印 IP 采集相关信息
    if [[ "$enable_ip_collect" == "yes" ]]; then
        echo ""
        echo -e "${GREEN}--- IP Collection Status ---${NC}"
        
        # 显示当前采集的 IP 指标文件
        if [[ -f /var/lib/node_exporter/textfile/node_ip.prom ]]; then
            echo -e "${GREEN}IP metrics file created:${NC}"
            cat /var/lib/node_exporter/textfile/node_ip.prom | sed 's/^/  /'
        else
            echo -e "${YELLOW}IP metrics file not yet created (will be generated shortly)${NC}"
        fi
        
        # 显示 systemd timer 状态
        echo ""
        echo -e "${GREEN}Systemd timer status:${NC}"
        systemctl status node-ip.timer --no-pager -l 2>/dev/null | grep -E "Active:|Loaded:" | sed 's/^/  /' || echo "  Timer not active"
        
        echo ""
        echo -e "${GREEN}Prometheus query examples:${NC}"
        echo "  node_ip_info"
        echo "  node_ip_info{family=\"ipv4\"}"
        echo "  node_ip_info{family=\"ipv6\"}"
        
        echo ""
        echo -e "${GREEN}IP Collection Components:${NC}"
        echo "  Script: /etc/node-exporter-ip/update-ip.sh"
        echo "  Metrics: /var/lib/node_exporter/textfile/node_ip.prom"
        echo "  Service: node-ip.service"
        echo "  Timer:   node-ip.timer (runs every 60s)"
    fi
    
    echo ""
    echo "=============================================="
}

# 主函数
main() {
    install_deps
    
    # 询问是否启用 IP 采集功能
    echo ""
    echo -e "${YELLOW}Do you want to enable automatic IP collection?${NC}"
    echo "This will add node_ip_info metrics showing your egress IP addresses."
    read -r -p "Enable IP collection? (y/n) [y]: " enable_ip
    enable_ip=${enable_ip:-y}
    
    local enable_ip_collect="no"
    if [[ "$enable_ip" =~ ^[Yy]$ ]]; then
        enable_ip_collect="yes"
        info "IP collection will be enabled"
    else
        info "IP collection will NOT be enabled"
    fi
    
    # 安装 node_exporter（传入是否启用 IP 采集）
    install_node_exporter "$enable_ip_collect"
    
    # 如果需要，配置 IP 采集
    if [[ "$enable_ip_collect" == "yes" ]]; then
        setup_ip_collection
    fi
    
    # 配置 Nginx
    read -r -p "Enter username for metrics access [admin]: " username
    username=${username:-admin}
    username=$(configure_nginx "$username")
    
    # 打印最终信息
    print_connection_info "$username" "$enable_ip_collect"
}

main "$@"