#!/bin/bash
set -e
set -o pipefail

#================================================================================
# Linux 网络性能优化脚本（高延迟/大带宽场景）
# - 在应用前可选择清除已有调优（包含 /etc/sysctl.d 与 limits 文件）
# - 使用 fq + bbr（若内核支持）
# - 缓冲区设为上限（不基于 RTT）
# 适用于 Debian / Ubuntu
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

# --- 辅助函数 ---
apply_sysctl_value() {
    local key="$1"
    local target_value="$2"
    local proc_path="/proc/sys/${key//./\/}"
    # 仅在内核支持该项时写入临时文件，避免报错
    if [ -e "$proc_path" ] || [ -d "$(dirname "$proc_path")" ]; then
        echo "$key = $target_value" >> "$TEMP_SYSCTL_FILE"
    fi
}

human_readable() {
    local bytes=$1
    if [ "$bytes" -ge $((1024**3)) ]; then
        printf "%.1fG" "$(awk "BEGIN{printf %f, $bytes/1024/1024/1024}")"
    elif [ "$bytes" -ge $((1024**2)) ]; then
        printf "%.1fM" "$(awk "BEGIN{printf %f, $bytes/1024/1024}")"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%.1fK" "$(awk "BEGIN{printf %f, $bytes/1024}")"
    else
        printf "%dB" "$bytes"
    fi
}

# --- 危险操作确认（删除旧调优） ---
echo "警告：接下来可选择删除已有的调优文件（包括 /etc/sysctl.d 下的内容 与 limits 配置）。"
echo "你可以输入 'yes' 以继续删除，输入其它任意内容以跳过删除步骤。"
read -rp "确认删除旧调优并清空 sysctl.conf ? (输入 yes 继续) : " confirm_cleanup

if [[ "$confirm_cleanup" == "yes" ]]; then
    echo "执行清理：删除指定旧配置..."
    # 删除指定文件（按用户要求）
    rm -f /etc/sysctl.d/network-tuning.conf || true
    rm -f /etc/security/limits.d/99-custom-limits.conf || true

    # 可选：删除整个目录（危险），仅在确认时执行
    echo "即将删除 /etc/sysctl.d 目录（包含所有文件）。再次确认输入 'confirm' 以继续删除目录，否则跳过。"
    read -rp "再次确认删除 /etc/sysctl.d ? (输入 confirm 继续) : " confirm_dir
    if [[ "$confirm_dir" == "confirm" ]]; then
        rm -rf /etc/sysctl.d || true
        echo "/etc/sysctl.d 已删除。"
    else
        echo "跳过删除 /etc/sysctl.d 目录。"
    fi

    # 清空 /etc/sysctl.conf（按用户要求）
    echo "" > /etc/sysctl.conf || true
    echo "/etc/sysctl.conf 已清空。"

    # 立即应用（使系统回到更干净的状态）
    sysctl -p || true
    sysctl --system || true

    echo "旧调优已清理（按确认）。"
else
    echo "跳过旧调优删除步骤。"
fi

# --- 重新创建 sysctl.d 目录（如果被删除） ---
if [ ! -d "$SYSCTL_DIR" ]; then
    mkdir -p "$SYSCTL_DIR"
fi

# --- 备份现有 sysctl.d（如果存在） ---
mkdir -p "$BACKUP_BASE_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="${BACKUP_BASE_DIR}/sysctl_backup_${TIMESTAMP}.tar.gz"
echo "正在备份 /etc/sysctl.d 到 $BACKUP_FILE ..."
if [ -d /etc/sysctl.d ]; then
    tar -czf "$BACKUP_FILE" -C /etc sysctl.d || true
    echo "备份完成: $BACKUP_FILE"
else
    echo "未检测到 /etc/sysctl.d，跳过备份。"
fi

# --- 交互：询问上下行带宽（Mbps，可选） ---
read_bandwidth() {
    local prompt="$1"
    local val
    while true; do
        read -rp "$prompt (输入数字，单位 Mbps，回车跳过) : " val
        val=$(echo "$val" | tr -d '[:space:]')
        if [[ -z "$val" ]]; then
            echo ""
            return 0
        fi
        if [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "$val"
            return 0
        fi
        echo "输入无效，请输入正数（可带小数）或回车跳过。"
    done
}

echo "=== 带宽信息（可选） ==="
down_mbps=$(read_bandwidth "请输入 下行带宽 (Download) 的数值")
up_mbps=$(read_bandwidth "请输入 上行带宽 (Upload) 的数值")

# --- 根据内存大小确定策略与 base buffer ---
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
declare base_tcp_buf

case "$strategy" in
    tiny_lt_512m)
        ulimit_n=65535; base_tcp_buf=16777216 ;;         # 16MB
    small_512_768m)
        ulimit_n=131072; base_tcp_buf=33554432 ;;        # 32MB
    small_768_1g)
        ulimit_n=262144; base_tcp_buf=67108864 ;;        # 64MB
    medium_1g_1_5g|medium_1_5g_2g)
        ulimit_n=524288; base_tcp_buf=134217728 ;;       # 128MB
    large_2g_3g|large_3g_4g|xlarge_4g_5g)
        ulimit_n=1048576; base_tcp_buf=268435456 ;;      # 256MB
    xlarge_5g_6g|xlarge_6g_7g|xlarge_7g_8g|xlarge_8g_9g|xlarge_9g_10g)
        ulimit_n=1048576; base_tcp_buf=402653184 ;;      # 384MB
    ultra_10g_plus)
        ulimit_n=4194304; base_tcp_buf=536870912 ;;      # 512MB
esac

# --- 计算基于带宽的上限（不使用 RTT） ---
# 将 Mbps 转为 bytes/s: 1 Mbps = 125000 bytes/s
bandwidth_to_bytes_per_sec() {
    local mbps="$1"
    if [[ -z "$mbps" ]]; then
        echo "0"
        return
    fi
    # 保留整数
    awk "BEGIN{printf \"%d\", $mbps * 125000}"
}

down_bps=$(bandwidth_to_bytes_per_sec "$down_mbps")
up_bps=$(bandwidth_to_bytes_per_sec "$up_mbps")

# 目标：缓冲区直接给上限。取 base_tcp_buf 与 (bandwidth_bps * factor) 的较大值
# factor 取 10（经验值），表示为带宽乘以若干秒的缓冲能力；然后对最终值做上限限制
calc_final_max_buf() {
    local base_buf="$1"
    local down_bps="$2"
    local up_bps="$3"
    local max_band_bps=$(( down_bps > up_bps ? down_bps : up_bps ))
    # 如果没有带宽输入，直接使用 base_buf
    if (( max_band_bps == 0 )); then
        echo "$base_buf"
        return
    fi
    # factor 秒的缓冲（不基于 RTT），取 10 秒的缓冲作为上限参考
    local factor=10
    local band_based_buf
    band_based_buf=$(awk "BEGIN{printf \"%d\", $max_band_bps * $factor}")
    # 取较大值
    local target=$(( base_buf > band_based_buf ? base_buf : band_based_buf ))
    # 限制最大值：默认 1GB，ultra 档放宽到 2GB
    local max_limit=1073741824
    if [ "$strategy" = "ultra_10g_plus" ]; then
        max_limit=2147483648
    fi
    if (( target > max_limit )); then
        target=$max_limit
    fi
    # 最小限制
    if (( target < 16384 )); then
        target=16384
    fi
    echo "$target"
}

FINAL_MAX_BUF=$(calc_final_max_buf "$base_tcp_buf" "$down_bps" "$up_bps")
# 给一点 headroom（乘以 1.1），并取整数
FINAL_MAX_BUF=$(awk "BEGIN{printf \"%d\", $FINAL_MAX_BUF * 1.1}")

# --- 核心优化参数（BBR + fq，缓冲上限） ---
sysctl_values=(
    ["net.core.somaxconn"]="65535"
    ["net.ipv4.tcp_max_syn_backlog"]="65535"
    ["net.core.netdev_max_backlog"]="65535"

    ["net.core.rmem_max"]="$FINAL_MAX_BUF"
    ["net.core.wmem_max"]="$FINAL_MAX_BUF"
    ["net.core.rmem_default"]="16777216"
    ["net.core.wmem_default"]="16777216"
    ["net.ipv4.tcp_rmem"]="4096 87380 $FINAL_MAX_BUF"
    ["net.ipv4.tcp_wmem"]="4096 87380 $FINAL_MAX_BUF"

    # TCP 行为优化（稳定性）
    ["net.ipv4.tcp_fin_timeout"]="30"
    ["net.ipv4.tcp_keepalive_time"]="300"
    ["net.ipv4.tcp_keepalive_intvl"]="60"
    ["net.ipv4.tcp_keepalive_probes"]="5"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_mtu_probing"]="1"
    ["net.ipv4.tcp_slow_start_after_idle"]="0"
    ["net.ipv4.tcp_notsent_lowat"]="16384"

    # 启用 FQ + BBR（BBRv1），不基于 RTT
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"

    # TCP Fast Open（客户端+服务端）
    ["net.ipv4.tcp_fastopen"]="3"

    # 额外稳定性设置
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_dsack"]="1"
    ["net.ipv4.tcp_retries2"]="8"
    ["net.ipv4.tcp_syn_retries"]="2"
    ["net.ipv4.tcp_no_metrics_save"]="1"

    # 通用
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["vm.swappiness"]="10"
)

# --- 文件句柄调整 ---
current_file_max=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
target_file_max=$(( ulimit_n * 10 ))
if (( current_file_max < target_file_max )); then
    sysctl_values["fs.file-max"]="$target_file_max"
fi

# --- BBR 检测与启用 ---
bbr_status_message="BBR: 内核不支持或模块加载失败。"
modprobe tcp_bbr >/dev/null 2>&1 || true
if [[ $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) == *"bbr"* ]]; then
    mkdir -p /etc/modules-load.d/
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    bbr_status_message="BBR: 已成功加载模块并配置启用。"
fi

# --- 应用配置到临时文件 ---
# 清空临时文件
: > "$TEMP_SYSCTL_FILE"
for key in "${!sysctl_values[@]}"; do
    apply_sysctl_value "$key" "${sysctl_values[$key]}"
done

# 写入 sysctl 配置文件
SYSCTL_CONF_FILE="$SYSCTL_DIR/network-tuning.conf"
echo "正在写入内核配置文件: $SYSCTL_CONF_FILE"
{
    echo ""
    echo "$SYSCTL_MARKER_START"
    echo "# Strategy: $strategy, Applied: $(date '+%F %T')"
    if [[ -n "$down_mbps" || -n "$up_mbps" ]]; then
        echo "# User inputs: down=${down_mbps:-N/A}Mbps up=${up_mbps:-N/A}Mbps"
    else
        echo "# User inputs: bandwidth not provided"
    fi
    echo "# Final buffer limit (bytes): $FINAL_MAX_BUF"
    echo "# Final buffer limit (human): $(human_readable $FINAL_MAX_BUF)"
    cat "$TEMP_SYSCTL_FILE"
    echo "$SYSCTL_MARKER_END"
} > "$SYSCTL_CONF_FILE"

rm -f "$TEMP_SYSCTL_FILE"

# --- 应用 sysctl 设置 ---
echo "应用 sysctl 设置..."
sysctl --system || true
# 也执行 sysctl -p 以确保 /etc/sysctl.conf 的内容被加载（脚本可能已清空）
sysctl -p || true

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
echo "- 已备份目录: $BACKUP_BASE_DIR"
echo "- 内核配置: $SYSCTL_CONF_FILE"
echo "- Ulimit 配置: $LIMITS_CONF_FILE"
echo "- $bbr_status_message"
echo
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
echo "- 当前拥塞算法: $current_cc"
echo "- TCP Fast Open 状态: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "unknown")"
if [[ -n "$down_mbps" || -n "$up_mbps" ]]; then
    echo "- 用户带宽输入: down=${down_mbps:-N/A}Mbps up=${up_mbps:-N/A}Mbps"
fi
echo "- 应用缓冲上限: $(human_readable $FINAL_MAX_BUF) ($FINAL_MAX_BUF bytes)"
echo "- 注意: 重新登录 SSH 后 ulimit 才会完全生效。"
echo
echo "建议：若要在生产环境做更激进的测试，请先在测试环境验证并监控重传率、延迟与队列长度。"
echo "======================================================================"