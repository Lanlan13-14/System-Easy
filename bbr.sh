#!/bin/bash
set -e
set -o pipefail

#================================================================================
#
#           Linux 网络性能优化脚本（高延迟优化版，减少抖动）
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

SYSCTL_MARKER_START="# --- BEGIN Kernel Tuning by Script ---"
SYSCTL_MARKER_END="# --- END Kernel Tuning by Script ---"
LIMITS_MARKER_START="# --- BEGIN Ulimit Settings by Script ---"
LIMITS_MARKER_END="# --- END Ulimit Settings by Script ---"

apply_sysctl_value() {
    local key="$1"
    local target_value="$2"
    local proc_path="/proc/sys/${key//./\/}"
    if [ -f "$proc_path" ]; then
        echo "$key = $target_value" >> "$TEMP_SYSCTL_FILE"
    fi
}

# --- 目录与备份逻辑 ---
mkdir -p "$SYSCTL_DIR"
mkdir -p "$BACKUP_BASE_DIR"

echo "正在备份 $SYSCTL_DIR 到 $BACKUP_FILE ..."
tar -czf "$BACKUP_FILE" -C /etc sysctl.d
echo "备份完成"

# --- 清理旧配置 ---
find "$SYSCTL_DIR" -type f -name "*bbr*.conf" -exec rm -f {} \;
find "$SYSCTL_DIR" -type f -name "*network*.conf" -exec rm -f {} \;

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

declare -A sysctl_values
declare ulimit_n

# --- BBR 高延迟优化缓冲区 ---
case "$strategy" in
    tiny_lt_512m)                     ulimit_n=65535;   tcp_buf=16777216 ;; 
    small_512_768m)                   ulimit_n=131072;  tcp_buf=33554432 ;;
    small_768_1g)                     ulimit_n=262144;  tcp_buf=67108864 ;;
    medium_1g_1_5g|medium_1_5g_2g)    ulimit_n=524288;  tcp_buf=134217728 ;;
    large_2g_3g|large_3g_4g|xlarge_4g_5g)
                                      ulimit_n=1048576; tcp_buf=268435456 ;;
    xlarge_5g_6g|xlarge_6g_7g|xlarge_7g_8g|xlarge_8g_9g|xlarge_9g_10g)
                                      ulimit_n=1048576; tcp_buf=402653184 ;;
    ultra_10g_plus)                   ulimit_n=4194304; tcp_buf=536870912 ;;
esac

# --- 核心优化参数（只修改问题项） ---
sysctl_values=(
    ["net.core.somaxconn"]="65535"
    ["net.ipv4.tcp_max_syn_backlog"]="65535"
    ["net.core.netdev_max_backlog"]="65535"

    # 高延迟缓冲区
    ["net.core.rmem_max"]="$tcp_buf"
    ["net.core.wmem_max"]="$tcp_buf"
    # ---- 改：降低 default 缓冲区（显著减少抖动） ----
    ["net.core.rmem_default"]="2097152"
    ["net.core.wmem_default"]="2097152"

    ["net.ipv4.tcp_rmem"]="4096 87380 $tcp_buf"
    ["net.ipv4.tcp_wmem"]="4096 65536 $tcp_buf"

    # TCP 优化
    ["net.ipv4.tcp_fin_timeout"]="30"
    ["net.ipv4.tcp_keepalive_time"]="300"
    ["net.ipv4.tcp_keepalive_intvl"]="60"
    ["net.ipv4.tcp_keepalive_probes"]="5"

    # ---- 改：不再开启 tcp_tw_reuse ----
    ["net.ipv4.tcp_tw_reuse"]="0"

    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_mtu_probing"]="1"
    ["net.ipv4.tcp_slow_start_after_idle"]="0"

    # ---- 改：去掉 notsent_lowat（避免小包 jitter） ----
    # ["net.ipv4.tcp_notsent_lowat"]="16384"   # 已删除

    # FQ + BBR
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"

    # ---- 新增：取消 BBR aggressive pacing ----
    ["net.ipv4.tcp_pacing_ss_ratio"]="100"
    ["net.ipv4.tcp_pacing_ca_ratio"]="100"

    ["net.ipv4.tcp_fastopen"]="3"

    # 其他优化
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["vm.swappiness"]="10"
)

# --- 文件句柄 ---
current_file_max=$(sysctl -n fs.file-max)
target_file_max=$(( ulimit_n * 10 ))
if (( current_file_max < target_file_max )); then
    sysctl_values["fs.file-max"]="$target_file_max"
fi

# --- BBR ---
modprobe tcp_bbr >/dev/null 2>&1
bbr_status="BBR: 内核不支持"
if [[ $(sysctl -n net.ipv4.tcp_available_congestion_control) == *"bbr"* ]]; then
    mkdir -p /etc/modules-load.d/
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    bbr_status="BBR: 已启用"
fi

# --- 应用配置 ---
for key in "${!sysctl_values[@]}"; do
    apply_sysctl_value "$key" "${sysctl_values[$key]}"
done

{
    echo ""
    echo "$SYSCTL_MARKER_START"
    echo "# Strategy: $strategy $(date '+%F %T')"
    cat "$TEMP_SYSCTL_FILE"
    echo "$SYSCTL_MARKER_END"
} > "$SYSCTL_CONF_FILE"

rm "$TEMP_SYSCTL_FILE"

sysctl_output=$(sysctl --system 2>&1)

# --- 写入 Ulimit ---
{
    echo ""
    echo "$LIMITS_MARKER_START"
    echo "* soft nofile $ulimit_n"
    echo "* hard nofile $ulimit_n"
    echo "root soft nofile $ulimit_n"
    echo "root hard nofile $ulimit_n"
    echo "$LIMITS_MARKER_END"
} > "$LIMITS_CONF_FILE"

# --- 报告 ---
echo "======================================================================"
echo "高延迟抖动优化完成"
echo "策略: $strategy"
echo "$bbr_status"
echo "配置已写入: $SYSCTL_CONF_FILE"
echo "ulimit 配置: $LIMITS_CONF_FILE"
echo "======================================================================"
echo "$sysctl_output"
echo "======================================================================"
echo "建议重启服务器以确保所有优化生效。"
