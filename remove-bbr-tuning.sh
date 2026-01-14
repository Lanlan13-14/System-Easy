#!/usr/bin/env bash
set -e

echo "🔄 开始删除 BBR 调优配置..."

# 0️⃣ 明确删除两个文件
rm -f /etc/sysctl.d/network-tuning.conf
rm -f /etc/security/limits.d/99-custom-limits.conf

# 1️⃣ 清理 /etc/sysctl.d 中的 BBR 相关配置
if [ -d /etc/sysctl.d ]; then
    for f in /etc/sysctl.d/*.conf; do
        [ -f "$f" ] || continue
        if grep -qE \
            'tcp_bbr|bbr|fq(_pie)?|net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc' \
            "$f" 2>/dev/null; then
            echo "🗑️ 删除: $f"
            rm -f "$f"
        fi
    done
fi

# 2️⃣ 清理 /etc/sysctl.conf 中的 TCP 调优项
if [ -f /etc/sysctl.conf ]; then
    sed -i \
        -e '/net\.ipv4\.tcp_congestion_control/d' \
        -e '/net\.core\.default_qdisc/d' \
        /etc/sysctl.conf
fi

# 3️⃣ 卸载 tcp_bbr 模块（如果存在）
if lsmod | grep -q '^tcp_bbr'; then
    echo "🧹 卸载 tcp_bbr 模块"
    rmmod tcp_bbr 2>/dev/null || true
fi

# 4️⃣ 明确恢复为 cubic（避免空状态）
if sysctl net.ipv4.tcp_congestion_control >/dev/null 2>&1; then
    echo "net.ipv4.tcp_congestion_control=cubic" >> /etc/sysctl.conf
fi

# 5️⃣ 重新加载 sysctl
sysctl --system >/dev/null 2>&1 || true

echo "✅ BBR 调优已完全删除"
echo "📌 当前 TCP 拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"