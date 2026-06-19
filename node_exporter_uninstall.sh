#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "This script must be run as root (use sudo)"

REMOVE_NGINX=0
for arg in "${@:-}"; do
  case "$arg" in
    --help|-h)
      cat <<USAGE
Usage: sudo bash uninstall_node_exporter_clean.sh

The script always asks interactively whether to remove nginx completely.
USAGE
      exit 0
      ;;
    *) fail "Unknown argument: $arg" ;;
  esac
done

systemctl_exists() { has systemctl && systemctl list-unit-files "$1" >/dev/null 2>&1; }
stop_disable_remove_unit() {
  local unit="$1" file="/etc/systemd/system/$1"
  if has systemctl; then
    info "Stopping/disabling $unit if present..."
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  fi
  if [[ -e "$file" || -L "$file" ]]; then
    info "Removing $file"
    rm -f "$file"
  else
    warn "$file not found"
  fi
}

info "Uninstalling Node Exporter stack installed by the installer..."

# Stop timer first so it cannot trigger the oneshot during cleanup.
stop_disable_remove_unit node-ip.timer
stop_disable_remove_unit node-ip.service
stop_disable_remove_unit node_exporter.service

if has systemctl; then
  info "Reloading systemd daemon..."
  systemctl daemon-reload || true
fi

# Kill remaining node_exporter processes safely. Avoid pkill -f because it may match this script path/arguments.
info "Checking remaining node_exporter processes..."
if has pgrep && pgrep -x node_exporter >/dev/null 2>&1; then
  warn "Killing remaining node_exporter processes by exact process name..."
  pkill -TERM -x node_exporter || true
  sleep 1
  pkill -KILL -x node_exporter >/dev/null 2>&1 || true
else
  info "No node_exporter process found"
fi

# Nginx reverse proxy pieces created by the installer.
NGINX_CONF=/etc/nginx/conf.d/node_exporter.conf
AUTH_FILE=/etc/nginx/.htpasswd

if [[ -f "$NGINX_CONF" ]]; then
  info "Removing nginx node_exporter config: $NGINX_CONF"
  rm -f "$NGINX_CONF"
else
  warn "$NGINX_CONF not found"
fi

# Only remove the generic htpasswd if it is not referenced by any remaining nginx config.
if [[ -f "$AUTH_FILE" ]]; then
  if [[ -d /etc/nginx ]] && grep -Rqs --fixed-strings "$AUTH_FILE" /etc/nginx; then
    warn "$AUTH_FILE is still referenced by another nginx config; keeping it"
  else
    info "Removing auth file: $AUTH_FILE"
    rm -f "$AUTH_FILE"
  fi
else
  warn "$AUTH_FILE not found"
fi

if has nginx; then
  info "Testing nginx configuration after removal..."
  if nginx -t >/dev/null 2>&1; then
    if has systemctl; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || warn "Failed to reload/restart nginx"
    else
      nginx -s reload >/dev/null 2>&1 || warn "Failed to reload nginx"
    fi
  else
    warn "nginx -t failed after removing config; please check nginx manually"
  fi
fi

# Files/directories created by the installer.
for path in \
  /node_exporter \
  /etc/node-exporter-ip \
  /var/lib/node_exporter \
  /tmp/node_exporter.tar.gz; do
  if [[ -e "$path" || -L "$path" ]]; then
    info "Removing $path"
    rm -rf "$path"
  else
    warn "$path not found"
  fi
done
rm -rf /tmp/node_exporter-*.linux-amd64 2>/dev/null || true

echo ""
echo -e "${YELLOW}========================================${NC}"
warn "Nginx may be used by other websites or reverse proxies on this server."
read -r -p "Do you want to completely remove nginx package and /etc/nginx? (y/N): " remove_nginx_answer
remove_nginx_answer=${remove_nginx_answer:-n}
echo -e "${YELLOW}========================================${NC}"
if [[ "$remove_nginx_answer" =~ ^[Yy]$ ]]; then
  REMOVE_NGINX=1
else
  REMOVE_NGINX=0
fi

if [[ "$REMOVE_NGINX" -eq 1 ]]; then
  warn "Removing nginx completely..."
  has systemctl && { systemctl stop nginx >/dev/null 2>&1 || true; systemctl disable nginx >/dev/null 2>&1 || true; }
  if has apt-get; then
    apt-get purge -y nginx nginx-common nginx-core >/dev/null 2>&1 || warn "apt purge nginx failed"
    apt-get autoremove -y >/dev/null 2>&1 || true
  elif has dnf; then
    dnf remove -y nginx >/dev/null 2>&1 || warn "dnf remove nginx failed"
  else
    warn "No supported package manager found; remove nginx manually if needed"
  fi
  rm -rf /etc/nginx
fi

info "Verifying ports/processes..."
if has pgrep && pgrep -x node_exporter >/dev/null 2>&1; then
  warn "node_exporter process still exists:"
  pgrep -ax node_exporter || true
else
  info "node_exporter process: absent"
fi

if has ss; then
  ss -tlnp 2>/dev/null | grep -E ':(9100|9101)\b' || info "Ports 9100/9101: not listening"
else
  warn "ss not found; skipping port check"
fi

cat <<DONE

${GREEN}========== Uninstallation Complete ==========${NC}
Removed:
  - node_exporter systemd unit
  - node-ip service/timer
  - /node_exporter
  - /etc/node-exporter-ip
  - /var/lib/node_exporter
  - nginx node_exporter reverse-proxy config
  - auth file if unused by other nginx configs
Nginx package: $([[ "$REMOVE_NGINX" -eq 1 ]] && echo removed || echo kept)
DONE
