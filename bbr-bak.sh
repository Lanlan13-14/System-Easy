#!/bin/bash
set -e
set -o pipefail

#================================================================================
#
#           Linux 网络性能优化脚本（高延迟优化版，适用于 Debian / Ubuntu）
#
#================================================================================

# --- 确保以 Root 权限运行 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误: 此脚本必须以 root 权限运行。" 
   exit 1
fi

# --- 全局变量与配置 ---
SYSCTL_DIR="/etc/sysctl.d"
LIMITS_CONF_FILE="/etc/security/limits.d/99-custom-limits.conf"
TEMP_SYSCTL_FILE=$(mktemp)
BACKUP_BASE_DIR="/etc/sysctl_backup"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="${BACKUP_BASE_DIR}/sysctl_backup_${TIMESTAMP}.tar.gz"

# 定义用于管理配置块的标记
SYSCTL_MARKER_START="# --- BEGIN Kernel Tuning by Script ---"
SYSCTL_MARKER_END="# --- END Kernel Tuning by Script ---"
LIMITS_MARKER_START="# --- BEGIN Ulimit Settings by Script ---"
LIMITS_MARKER_END="# --- END Ulimit Settings by Script ---"

# --- 辅助函数 ---
apply_sysctl_value() {
    local key="$1"
    local target_value="$2"
    local proc_path="/proc/sys/${key//./\/}"
    if [ -f "$proc_path" ]; then
        echo "$key = $target_value" >> "$TEMP_SYSCTL_FILE"
    fi
}

# --- 目录与备份逻辑 ---
if [ ! -d "$SYSCTL_DIR" ]; then
    echo "未检测到 $SYSCTL_DIR，正在创建..."
    mkdir -p "$SYSCTL_DIR"
fi

mkdir -p "$BACKUP_BASE_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="${BACKUP_BASE_DIR}/sysctl_backup_${TIMESTAMP}.tar.gz"

echo "正在备份 $SYSCTL_DIR 到压缩文件 $BACKUP_FILE ..."
tar -czf "$BACKUP_FILE" -C /etc sysctl.d
echo "✅ 备份完成: $BACKUP_FILE"

# --- 清理旧配置 ---
echo "正在清理旧的 BBR 优化配置文件..."
find "$SYSCTL_DIR" -type f -name "*bbr*.conf" -exec rm -f {} \; >/dev/null 2>&1
find "$SYSCTL_DIR" -type f -name "*network*.conf" -exec rm -f {} \; >/dev/null 2>&1

SYSCTL_CONF_FILE="$SYSCTL_DIR/network-tuning.conf"

# --- 根据内存大小确定策略 ---
mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_total_mb=$((mem_total_kb / 1024))

if [ "$mem_total_mb" -lt 512 ]; then
    strategy="tiny_lt_512m"
elif [ "$mem_total_mb" -le 768 ]; then
    strategy="small_512_768m"
elif [ "$mem_total_mb" -le 1024 ]; then
    strategy="small_768_1g"
elif [ "$mem_total_mb" -le 1536 ]; then
    strategy="medium_1g_1_5g"
elif [ "$mem_total_mb" -le 2048 ]; then
    strategy="medium_1_5g_2g"
elif [ "$mem_total_mb" -le 3072 ]; then
    strategy="large_2g_3g"
elif [ "$mem_total_mb" -le 4096 ]; then
    strategy="large_3g_4g"
elif [ "$mem_total_mb" -le 5120 ]; then
    strategy="xlarge_4g_5g"
elif [ "$mem_total_mb" -le 6144 ]; then
    strategy="xlarge_5g_6g"
elif [ "$mem_total_mb" -le 7168 ]; then
    strategy="xlarge_6g_7g"
elif [ "$mem_total_mb" -le 8192 ]; then
    strategy="xlarge_7g_8g"
elif [ "$mem_total_mb" -le 9216 ]; then
    strategy="xlarge_8g_9g"
elif [ "$mem_total_mb" -le 10240 ]; then
    strategy="xlarge_9g_10g"
else
    strategy="ultra_10g_plus"
fi

# --- 参数模板 ---
declare -A sysctl_values
declare ulimit_n

# 🚀 BBR 高延迟优化版缓冲区分档
case "$strategy" in
    tiny_lt_512m)
        ulimit_n=65535; tcp_buf=16777216 ;;         # 16MB
    small_512_768m)
        ulimit_n=131072; tcp_buf=33554432 ;;        # 32MB
    small_768_1g)
        ulimit_n=262144; tcp_buf=67108864 ;;        # 64MB
    medium_1g_1_5g|medium_1_5g_2g)
        ulimit_n=524288; tcp_buf=134217728 ;;       # 128MB
    large_2g_3g|large_3g_4g|xlarge_4g_5g)
        ulimit_n=1048576; tcp_buf=268435456 ;;      # 256MB
    xlarge_5g_6g|xlarge_6g_7g|xlarge_7g_8g|xlarge_8g_9g|xlarge_9g_10g)
        ulimit_n=1048576; tcp_buf=402653184 ;;      # 384MB
    ultra_10g_plus)
        ulimit_n=4194304; tcp_buf=536870912 ;;      # 512MB
esac

# --- 核心优化参数（BBR高延迟 & 稳定调优） ---
sysctl_values=(
    ["net.core.somaxconn"]="65535"
    ["net.ipv4.tcp_max_syn_backlog"]="65535"
    ["net.core.netdev_max_backlog"]="65535"

    # 高延迟适配缓冲区
    ["net.core.rmem_max"]="$tcp_buf"
    ["net.core.wmem_max"]="$tcp_buf"
    ["net.core.rmem_default"]="16777216"
    ["net.core.wmem_default"]="16777216"
    # ✅ 修改上下行默认值对称
    ["net.ipv4.tcp_rmem"]="4096 87380 $tcp_buf"
    ["net.ipv4.tcp_wmem"]="4096 87380 $tcp_buf"

    # TCP 行为优化（控制抖动、提高稳定性）
    ["net.ipv4.tcp_fin_timeout"]="30"
    ["net.ipv4.tcp_keepalive_time"]="300"
    ["net.ipv4.tcp_keepalive_intvl"]="60"
    ["net.ipv4.tcp_keepalive_probes"]="5"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_mtu_probing"]="1"
    ["net.ipv4.tcp_slow_start_after_idle"]="0"
    ["net.ipv4.tcp_notsent_lowat"]="16384"

    # 启用 FQ + BBR（BBRv1）
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"

    # 启用 TCP Fast Open（客户端+服务端）
    ["net.ipv4.tcp_fastopen"]="3"

    # 通用优化
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["vm.swappiness"]="10"
)

# --- 文件句柄调整 ---
current_file_max=$(sysctl -n fs.file-max)
target_file_max=$(( ulimit_n * 10 ))
if (( current_file_max < target_file_max )); then
    sysctl_values["fs.file-max"]="$target_file_max"
fi

# --- BBR 检测与启用 ---
bbr_status_message="BBR: 内核不支持或模块加载失败。"
modprobe tcp_bbr >/dev/null 2>&1
if [[ $(sysctl -n net.ipv4.tcp_available_congestion_control) == *"bbr"* ]]; then
    mkdir -p /etc/modules-load.d/
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    bbr_status_message="BBR: 已成功加载模块并配置启用。"
fi

# --- 应用配置 ---
for key in "${!sysctl_values[@]}"; do
    apply_sysctl_value "$key" "${sysctl_values[$key]}"
done

echo "正在写入内核配置文件: $SYSCTL_CONF_FILE"
{
    echo ""
    echo "$SYSCTL_MARKER_START"
    echo "# Strategy: $strategy, Applied: $(date '+%F %T')"
    cat "$TEMP_SYSCTL_FILE"
    echo "$SYSCTL_MARKER_END"
} > "$SYSCTL_CONF_FILE"
rm "$TEMP_SYSCTL_FILE"

sysctl_apply_output=$(sysctl --system 2>&1)

# --- 写入 Ulimit ---
echo "正在写入 Ulimit 配置文件: $LIMITS_CONF_FILE"
{
    echo ""
    echo "$LIMITS_MARKER_START"
    echo "# Strategy: $strategy"
    echo "* soft nofile $ulimit_n"
    echo "* hard nofile $ulimit_n"
    echo "root soft nofile $ulimit_n"
    echo "root hard nofile $ulimit_n"
    echo "$LIMITS_MARKER_END"
} > "$LIMITS_CONF_FILE"

# --- 报告 ---
echo "======================================================================"
echo "          优化完成 - '${strategy}' 策略已应用"
echo "======================================================================"
echo
echo "- 已备份: $BACKUP_BASE_DIR"
echo "- 内核配置: $SYSCTL_CONF_FILE"
echo "- Ulimit 配置: $LIMITS_CONF_FILE"
echo "- $bbr_status_message"
echo
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
echo "- 当前拥塞算法: $current_cc"
echo "- TCP Fast Open 状态: $(sysctl -n net.ipv4.tcp_fastopen)"
echo "- 注意: 重新登录 SSH 后 ulimit 才会完全生效。"
echo
echo "--- sysctl --system 输出: ---"
echo "$sysctl_apply_output"
echo "--------------------------------------------------"
echo
echo "✅ 优化已完成，建议重启服务器以确保所有配置完全生效。"
echo "======================================================================"