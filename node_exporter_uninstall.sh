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

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi

info "Starting uninstallation of Node Exporter and Nginx proxy..."

# 1. 停止并禁用 Node Exporter 服务
if systemctl list-units --full -all | grep -q "node_exporter.service"; then
    info "Stopping node_exporter service..."
    systemctl stop node_exporter.service 2>/dev/null || true
    systemctl disable node_exporter.service 2>/dev/null || true
    info "Removing node_exporter service file..."
    rm -f /etc/systemd/system/node_exporter.service
    systemctl daemon-reload
else
    warn "node_exporter service not found"
fi

# 2. 删除 Node Exporter 安装目录
if [[ -d "/node_exporter" ]]; then
    info "Removing /node_exporter directory..."
    rm -rf /node_exporter
else
    warn "/node_exporter directory not found"
fi

# 3. 删除 Nginx 配置文件
if [[ -f "/etc/nginx/conf.d/node_exporter.conf" ]]; then
    info "Removing Nginx configuration..."
    rm -f /etc/nginx/conf.d/node_exporter.conf
    info "Testing and reloading Nginx..."
    nginx -t 2>/dev/null && systemctl reload nginx || warn "Nginx config test failed, please check manually"
else
    warn "Nginx configuration not found"
fi

# 4. 删除密码文件
if [[ -f "/etc/nginx/.htpasswd" ]]; then
    info "Removing htpasswd file..."
    rm -f /etc/nginx/.htpasswd
else
    warn "htpasswd file not found"
fi

# 5. 可选：删除下载的临时文件
if [[ -f "/tmp/node_exporter.tar.gz" ]]; then
    info "Cleaning up temporary files..."
    rm -f /tmp/node_exporter.tar.gz
fi

# 清理解压目录（如果存在）
if [[ -d "/tmp/node_exporter-1.10.2.linux-amd64" ]]; then
    rm -rf /tmp/node_exporter-1.10.2.linux-amd64
fi

# 6. 询问是否卸载 Nginx（可选）
echo ""
read -p "Do you want to completely remove Nginx as well? (y/n): " remove_nginx
if [[ "$remove_nginx" =~ ^[Yy]$ ]]; then
    info "Removing Nginx..."
    if command -v apt &>/dev/null; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        apt remove --purge -y nginx nginx-common nginx-core 2>/dev/null || warn "Failed to remove nginx via apt"
        apt autoremove -y 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        dnf remove -y nginx 2>/dev/null || warn "Failed to remove nginx via dnf"
    else
        warn "Unsupported package manager, please remove nginx manually"
    fi
    rm -rf /etc/nginx 2>/dev/null || true
    info "Nginx has been removed"
else
    info "Nginx kept intact (only Node Exporter config removed)"
fi

# 7. 清理端口占用提醒
echo ""
info "Checking if ports are still listening..."
if ss -tlnp | grep -q ":9100 "; then
    warn "Port 9100 is still in use by another process"
else
    info "Port 9100 is free"
fi

if ss -tlnp | grep -q ":9101 "; then
    warn "Port 9101 is still in use by another process"
else
    info "Port 9101 is free"
fi

# 完成信息
echo ""
echo -e "${GREEN}========== Uninstallation Complete ==========${NC}"
echo "The following items have been removed:"
echo "  ✓ Node Exporter binary (/node_exporter)"
echo "  ✓ Node Exporter systemd service"
echo "  ✓ Nginx configuration for Node Exporter"
echo "  ✓ Basic authentication file"
echo "  ✓ Temporary download files"
if [[ "$remove_nginx" =~ ^[Yy]$ ]]; then
    echo "  ✓ Nginx (complete removal)"
else
    echo "  ✗ Nginx (kept intact)"
fi
echo ""
echo "To verify:"
echo "  systemctl status node_exporter (should show 'not found')"
echo "  ss -tlnp | grep -E '9100|9101' (should show nothing if no other services use these ports)"
echo "=============================================="