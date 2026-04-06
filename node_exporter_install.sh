#!/bin/bash
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印信息函数
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检查命令是否存在
check_cmd() { command -v "$1" &>/dev/null; }

# 安装基础依赖
install_deps() {
    if check_cmd apt; then
        info "Detected apt-based system"
        sudo apt update
        sudo apt install -y wget curl tar nginx apache2-utils
    elif check_cmd dnf; then
        info "Detected dnf-based system"
        sudo dnf install -y wget curl tar nginx httpd-tools
    else
        error "Unsupported package manager. Only apt/dnf are supported."
    fi
}

# 获取下载链接（仅 GitHub，CN 可选加速）
get_download_url() {
    local version="1.10.2"
    local file="node_exporter-${version}.linux-amd64.tar.gz"
    local github_url="https://github.com/prometheus/node_exporter/releases/download/v${version}/${file}"

    # 检测地理位置 - 使用 ipapi.co 替代原有 API
    info "Detecting geographic location..."
    local country
    # 尝试获取国家代码（超时 3 秒，失败则返回空）
    country=$(curl -s --max-time 3 https://ipapi.co/country/ 2>/dev/null || true)

    if [[ "$country" == "CN" ]]; then
        warn "Detected China mainland. GitHub downloads may be slow."
        read -p "Do you want to use a GitHub acceleration proxy? (y/n): " use_proxy
        if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
            read -p "Enter acceleration proxy prefix (e.g., https://ghproxy.com/ ): " proxy_prefix
            proxy_prefix="${proxy_prefix%/}"
            echo "${proxy_prefix}/${github_url}"
        else
            echo "$github_url"
        fi
    else
        echo "$github_url"
    fi
}

# 安装 Node Exporter
install_node_exporter() {
    local download_url
    download_url=$(get_download_url)
    local target="/tmp/node_exporter.tar.gz"

    info "Downloading Node Exporter from: $download_url"
    curl -fL -o "$target" "$download_url"

    info "Extracting Node Exporter..."
    tar -zxf "$target" -C /tmp

    local extract_dir="/tmp/node_exporter-1.10.2.linux-amd64"
    local install_dir="/node_exporter"

    if [[ -d "$install_dir" ]]; then
        warn "Removing existing $install_dir"
        sudo rm -rf "$install_dir"
    fi
    sudo cp -r "$extract_dir" "$install_dir"

    # 创建 systemd 服务（监听本地 9100）
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
    sudo systemctl enable --now node_exporter.service
    info "Node Exporter started on 127.0.0.1:9100"
}

# 配置 Nginx 反向代理（端口 9101，密码认证）
configure_nginx() {
    local auth_file="/etc/nginx/.htpasswd"
    local nginx_conf="/etc/nginx/conf.d/node_exporter.conf"

    # 创建密码文件
    info "Setting up HTTP basic authentication for Nginx"
    read -p "Enter username for metrics access: " username
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

    # 生成密码（使用 htpasswd 或 openssl）
    if check_cmd htpasswd; then
        printf "$password\n$password\n" | sudo htpasswd -c "$auth_file" "$username" 2>/dev/null
    elif check_cmd openssl; then
        local hashed
        hashed=$(openssl passwd -6 "$password")
        echo "$username:$hashed" | sudo tee "$auth_file" > /dev/null
    else
        error "Neither htpasswd nor openssl found. Please install apache2-utils or httpd-tools."
    fi

    # 写入 Nginx 配置
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

    # 测试并重载 Nginx
    sudo nginx -t || error "Nginx configuration test failed"
    sudo systemctl enable --now nginx
    sudo systemctl restart nginx
    info "Nginx reverse proxy configured on port 9101 with basic auth"
}

# 打印最终访问信息
print_connection_info() {
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
    configure_nginx
    print_connection_info
}

main "$@"