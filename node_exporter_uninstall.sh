#!/bin/bash
set -euo pipefail

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

info "Starting uninstallation of Node Exporter, IP collector, and Nginx proxy..."

# 1. 停止并禁用 Node Exporter 服务
if systemctl list-units --type=service --all 2>/dev/null | grep -q "node_exporter.service"; then
    info "Stopping node_exporter service..."
    systemctl stop node_exporter.service || true
    systemctl disable node_exporter.service || true
    info "Removing node_exporter service file..."
    rm -f /etc/systemd/system/node_exporter.service || true
    systemctl daemon-reload || true
else
    warn "node_exporter service not found"
fi

# 2. 停止并删除 IP 采集相关服务（如果存在）
if systemctl list-units --type=service --all 2>/dev/null | grep -q "node-ip.service"; then
    info "Stopping node-ip service..."
    systemctl stop node-ip.service || true
    systemctl disable node-ip.service || true
    info "Removing node-ip service file..."
    rm -f /etc/systemd/system/node-ip.service || true
else
    warn "node-ip service not found"
fi

if systemctl list-units --type=timer --all 2>/dev/null | grep -q "node-ip.timer"; then
    info "Stopping node-ip timer..."
    systemctl stop node-ip.timer || true
    systemctl disable node-ip.timer || true
    info "Removing node-ip timer file..."
    rm -f /etc/systemd/system/node-ip.timer || true
else
    warn "node-ip timer not found"
fi

# 重新加载 systemd
if [[ -f /etc/systemd/system/node-ip.service ]] || [[ -f /etc/systemd/system/node-ip.timer ]]; then
    systemctl daemon-reload || true
fi

# 3. 删除 IP 采集脚本和目录
if [[ -d "/etc/node-exporter-ip" ]]; then
    info "Removing IP collection script directory..."
    rm -rf /etc/node-exporter-ip || true
else
    warn "/etc/node-exporter-ip directory not found"
fi

# 4. 删除 textfile 目录和指标文件
if [[ -d "/var/lib/node_exporter/textfile" ]]; then
    info "Removing textfile directory with IP metrics..."
    rm -rf /var/lib/node_exporter/textfile || true
else
    warn "/var/lib/node_exporter/textfile directory not found"
fi

# 5. 删除 Node Exporter 安装目录
if [[ -d "/node_exporter" ]]; then
    info "Removing /node_exporter directory..."
    rm -rf /node_exporter || true
else
    warn "/node_exporter directory not found"
fi

# 6. 删除 Nginx 配置文件
if [[ -f "/etc/nginx/conf.d/node_exporter.conf" ]]; then
    info "Removing Nginx configuration..."
    rm -f /etc/nginx/conf.d/node_exporter.conf || true
    if command -v nginx &>/dev/null; then
        info "Testing and reloading Nginx..."
        if nginx -t 2>/dev/null; then
            systemctl reload nginx 2>/dev/null || warn "Failed to reload Nginx"
        else
            warn "Nginx config test failed, please check manually"
        fi
    fi
else
    warn "Nginx configuration not found"
fi

# 7. 删除密码文件
if [[ -f "/etc/nginx/.htpasswd" ]]; then
    info "Removing htpasswd file..."
    rm -f /etc/nginx/.htpasswd || true
else
    warn "htpasswd file not found"
fi

# 8. 清理临时文件
rm -f /tmp/node_exporter.tar.gz || true
rm -rf /tmp/node_exporter-1.10.2.linux-amd64 || true

# 9. 询问是否卸载 Nginx
echo ""
echo -e "${YELLOW}========================================${NC}"
read -r -p "Do you want to completely remove Nginx as well? (y/n): " remove_nginx
remove_nginx=${remove_nginx:-n}
echo -e "${YELLOW}========================================${NC}"

if [[ "$remove_nginx" =~ ^[Yy]$ ]]; then
    info "Removing Nginx..."
    if command -v apt &>/dev/null; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        apt-get remove --purge -y nginx nginx-common nginx-core 2>/dev/null || warn "Failed to remove nginx via apt"
        apt-get autoremove -y 2>/dev/null || true
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

# 10. 端口检查
echo ""
info "Checking if ports are still listening..."
if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ":9100 "; then
        warn "Port 9100 is still in use by another process"
    else
        info "Port 9100 is free"
    fi

    if ss -tlnp 2>/dev/null | grep -q ":9101 "; then
        warn "Port 9101 is still in use by another process"
    else
        info "Port 9101 is free"
    fi
else
    warn "ss command not found, skipping port check"
fi

# 11. 检查是否还有残留进程
echo ""
info "Checking for remaining processes..."
if pgrep -f "node_exporter" > /dev/null 2>&1; then
    warn "node_exporter process still running, killing it..."
    pkill -f "node_exporter" || true
else
    info "No node_exporter process found"
fi

# 完成信息
echo ""
echo -e "${GREEN}========== Uninstallation Complete ==========${NC}"
echo "The following items have been removed:"
echo "  ✓ Node Exporter binary (/node_exporter)"
echo "  ✓ Node Exporter systemd service"
echo "  ✓ IP collection script (/etc/node-exporter-ip/)"
echo "  ✓ IP collection systemd service and timer"
echo "  ✓ IP metrics file (/var/lib/node_exporter/textfile/)"
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
echo "  systemctl status node_exporter node-ip (should show 'not found')"
echo "  ls -la /etc/node-exporter-ip (should show 'No such file')"
echo "  ls -la /var/lib/node_exporter/textfile (should show 'No such file')"
echo "  ss -tlnp | grep -E '9100|9101' (should show nothing)"
echo "=============================================="