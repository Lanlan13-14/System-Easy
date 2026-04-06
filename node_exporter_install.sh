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

    local service_file="/etc/systemd/system/node_exporter.service"
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

    sudo systemctl daemon-reload
    sudo systemctl enable --now node_exporter.service || error "Failed to start node_exporter"
    info "Node Exporter started on 127.0.0.1:9100"

    # 清理临时文件
    rm -f "$target"
    rm -rf "$extract_dir"
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
    echo "=============================================="
}

# 主函数
main() {
    install_deps
    install_node_exporter
    read -r -p "Enter username for metrics access [admin]: " username
    username=${username:-admin}
    username=$(configure_nginx "$username")
    print_connection_info "$username"
}

main "$@"