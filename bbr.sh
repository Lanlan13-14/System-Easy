#!/bin/bash
set -e
set -o pipefail

#================================================================================
# Linux 网络性能优化脚本（高延迟/大带宽场景）- 优化版
# 特性：
# - 支持动态模式（基于内存自动计算）和固定模式（16M/24M/32M/48M/64M）
# - 同时优化最高速率和最低抖动
# - 使用 fq + bbr（内核版本决定bbr版本）
# - 优化缓冲区管理和TSO/GSO设置
# 适用于 Debian / Ubuntu
#================================================================================

# --- 确保以 Root 权限运行 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误: 此脚本必须以 root 权限运行。"
   exit 1
fi

# --- 颜色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# --- 固定模式预设 (缓冲区大小: 字节) ---
declare -A FIXED_PRESETS
FIXED_PRESETS=(
    ["16M"]="16777216"
    ["24M"]="25165824"
    ["32M"]="33554432"
    ["48M"]="50331648"
    ["64M"]="67108864"
)

# --- 辅助函数 ---
print_step() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_title() {
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

apply_sysctl_value() {
    local key="$1"
    local target_value="$2"
    local proc_path="/proc/sys/${key//./\/}"
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

check_kernel_feature() {
    local feature=$1
    local proc_path="/proc/sys/${feature//./\/}"
    if [ -e "$proc_path" ]; then
        return 0
    else
        return 1
    fi
}

get_kernel_version() {
    local version
    version=$(uname -r | cut -d'-' -f1)
    echo "$version"
}

compare_kernel_version() {
    # 比较内核版本，如果当前版本 >= 目标版本返回0
    local current=$1
    local required=$2
    
    if [[ "$current" == "$(echo -e "$current\n$required" | sort -V | tail -n1)" ]]; then
        return 0
    else
        return 1
    fi
}

# --- 显示菜单 ---
show_menu() {
    clear
    print_title "Linux 网络性能优化脚本"
    echo -e "${BLUE}请选择优化模式:${NC}"
    echo -e "[1] 动态模式 (基于系统内存自动计算最优值)"
    echo -e "[2] 固定模式 (从预设缓冲区大小中选择)"
    echo -e "[3] 退出脚本"
    echo ""
    echo -n "请输入选项 [1-3]: "
}

show_fixed_preset_menu() {
    echo ""
    print_title "固定模式预设选项"
    echo -e "${BLUE}请选择缓冲区大小预设:${NC}"
    echo -e "[1] 16M  - 低内存系统或低延迟要求"
    echo -e "[2] 24M  - 中等内存系统"
    echo -e "[3] 32M  - 标准配置"
    echo -e "[4] 48M  - 大内存系统"
    echo -e "[5] 64M  - 超大内存系统"
    echo -e "[6] 返回主菜单"
    echo ""
    echo -n "请输入选项 [1-6]: "
}

# --- 检测内核和BBR支持 ---
check_bbr_support() {
    local kernel_version
    kernel_version=$(get_kernel_version)
    
    print_step "检测内核版本: $kernel_version"
    
    # BBR 需要内核 4.9+，BBRv2 需要 5.4+
    if compare_kernel_version "$kernel_version" "4.9.0"; then
        if compare_kernel_version "$kernel_version" "5.4.0"; then
            BBR_MSG="内核 $kernel_version 支持 BBRv2（将使用 bbr）"
        else
            BBR_MSG="内核 $kernel_version 支持 BBRv1（将使用 bbr）"
        fi
        BBR_SUPPORTED=true
    else
        BBR_MSG="内核 $kernel_version 不支持 BBR（<4.9），将使用 cubic"
        BBR_SUPPORTED=false
    fi
    
    # 检查当前是否已加载 BBR
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_AVAILABLE=true
    else
        BBR_AVAILABLE=false
    fi
    
    print_step "$BBR_MSG"
}

# --- 危险操作确认（删除旧调优） ---
print_warn "接下来可选择删除已有的调优文件（包括 /etc/sysctl.d 下的内容 与 limits 配置）。"
echo "你可以输入 'yes' 以继续删除，输入其它任意内容以跳过删除步骤。"
read -r -p "确认删除旧调优并清空 sysctl.conf ? (输入 yes 继续) : " confirm_cleanup

if [[ "$confirm_cleanup" == "yes" ]]; then
    print_step "执行清理：删除指定旧配置..."
    rm -f /etc/sysctl.d/network-tuning.conf || true
    rm -f /etc/security/limits.d/99-custom-limits.conf || true

    echo "即将删除 /etc/sysctl.d 目录（包含所有文件）。再次确认输入 'confirm' 以继续删除目录，否则跳过。"
    read -r -p "再次确认删除 /etc/sysctl.d ? (输入 confirm 继续) : " confirm_dir
    if [[ "$confirm_dir" == "confirm" ]]; then
        rm -rf /etc/sysctl.d || true
        print_step "/etc/sysctl.d 已删除。"
    else
        print_warn "跳过删除 /etc/sysctl.d 目录。"
    fi

    echo "" > /etc/sysctl.conf || true
    print_step "/etc/sysctl.conf 已清空。"

    sysctl -p || true
    sysctl --system || true

    print_step "旧调优已清理。"
else
    print_warn "跳过旧调优删除步骤。"
fi

# --- 重新创建 sysctl.d 目录（如果被删除） ---
if [ ! -d "$SYSCTL_DIR" ]; then
    mkdir -p "$SYSCTL_DIR"
fi

# --- 备份现有 sysctl.d（如果存在） ---
mkdir -p "$BACKUP_BASE_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="${BACKUP_BASE_DIR}/sysctl_backup_${TIMESTAMP}.tar.gz"
print_step "正在备份 /etc/sysctl.d 到 $BACKUP_FILE ..."
if [ -d /etc/sysctl.d ]; then
    tar -czf "$BACKUP_FILE" -C /etc sysctl.d 2>/dev/null || true
    print_step "备份完成: $BACKUP_FILE"
else
    print_warn "未检测到 /etc/sysctl.d，跳过备份。"
fi

# --- 检测 BBR 支持 ---
check_bbr_support

# --- 主菜单选择 ---
while true; do
    show_menu
    read -r main_choice
    case $main_choice in
        1)
            mode="dynamic"
            print_step "已选择: 动态模式"
            break
            ;;
        2)
            mode="fixed"
            print_step "已选择: 固定模式"
            break
            ;;
        3)
            print_step "退出脚本"
            rm -f "$TEMP_SYSCTL_FILE"
            exit 0
            ;;
        *)
            print_error "无效选项，请重新选择"
            sleep 2
            ;;
    esac
done

# --- 根据模式获取缓冲区大小 ---
if [ "$mode" = "dynamic" ]; then
    # 动态模式：询问带宽
    read_bandwidth() {
        local prompt="$1"
        local val
        while true; do
            read -r -p "$prompt (输入数字，单位 Mbps，回车跳过) : " val
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

    echo ""
    print_step "动态模式 - 请输入带宽信息（可选）"
    down_mbps=$(read_bandwidth "请输入 下行带宽 (Download) 的数值")
    up_mbps=$(read_bandwidth "请输入 上行带宽 (Upload) 的数值")

    # 根据内存大小确定策略与 base buffer
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

    # 计算基于带宽的上限
    bandwidth_to_bytes_per_sec() {
        local mbps="$1"
        if [[ -z "$mbps" ]]; then
            echo "0"
            return
        fi
        awk "BEGIN{printf \"%d\", $mbps * 125000}"
    }

    down_bps=$(bandwidth_to_bytes_per_sec "$down_mbps")
    up_bps=$(bandwidth_to_bytes_per_sec "$up_mbps")

    calc_final_max_buf() {
        local base_buf="$1"
        local down_bps="$2"
        local up_bps="$3"
        local max_band_bps=$(( down_bps > up_bps ? down_bps : up_bps ))
        
        if (( max_band_bps == 0 )); then
            echo "$base_buf"
            return
        fi
        
        local factor=10
        local band_based_buf
        band_based_buf=$(awk "BEGIN{printf \"%d\", $max_band_bps * $factor}")
        
        local target=$(( base_buf > band_based_buf ? base_buf : band_based_buf ))
        local max_limit=1073741824
        
        if [ "$strategy" = "ultra_10g_plus" ]; then
            max_limit=2147483648
        fi
        
        if (( target > max_limit )); then
            target=$max_limit
        fi
        
        if (( target < 16384 )); then
            target=16384
        fi
        
        echo "$target"
    }

    FINAL_MAX_BUF=$(calc_final_max_buf "$base_tcp_buf" "$down_bps" "$up_bps")
    FINAL_MAX_BUF=$(awk "BEGIN{printf \"%d\", $FINAL_MAX_BUF * 1.1}")
    
    print_step "动态模式计算完成"
    print_step "内存大小: ${mem_total_mb}MB, 策略: $strategy"
    print_step "基础缓冲区: $(human_readable "$base_tcp_buf")"

else
    # 固定模式选择
    while true; do
        show_fixed_preset_menu
        read -r fixed_choice
        case $fixed_choice in
            1)
                FINAL_MAX_BUF="${FIXED_PRESETS['16M']}"
                strategy="fixed_16M"
                ulimit_n=262144
                print_step "已选择固定模式: 16M"
                break
                ;;
            2)
                FINAL_MAX_BUF="${FIXED_PRESETS['24M']}"
                strategy="fixed_24M"
                ulimit_n=524288
                print_step "已选择固定模式: 24M"
                break
                ;;
            3)
                FINAL_MAX_BUF="${FIXED_PRESETS['32M']}"
                strategy="fixed_32M"
                ulimit_n=524288
                print_step "已选择固定模式: 32M"
                break
                ;;
            4)
                FINAL_MAX_BUF="${FIXED_PRESETS['48M']}"
                strategy="fixed_48M"
                ulimit_n=1048576
                print_step "已选择固定模式: 48M"
                break
                ;;
            5)
                FINAL_MAX_BUF="${FIXED_PRESETS['64M']}"
                strategy="fixed_64M"
                ulimit_n=1048576
                print_step "已选择固定模式: 64M"
                break
                ;;
            6)
                # 返回主菜单
                rm -f "$TEMP_SYSCTL_FILE"
                exec "$0"
                ;;
            *)
                print_error "无效选项，请重新选择"
                sleep 2
                ;;
        esac
    done
fi

# --- 抖动优化参数 ---
print_step "配置抖动优化参数..."

# 核心抖动控制参数
JITTER_OPTIMIZATIONS=(
    # 减少调度延迟
    ["kernel.sched_min_granularity_ns"]="10000000"
    ["kernel.sched_wakeup_granularity_ns"]="15000000"
    ["kernel.sched_migration_cost_ns"]="5000000"
    
    # IRQ平衡优化
    ["kernel.numa_balancing"]="0"
    ["kernel.timer_migration"]="0"
    
    # 网络中断控制
    ["net.core.dev_weight"]="64"
    ["net.core.dev_weight_tx"]="32"
    
    # RPS/RFS优化（如果支持）
    ["net.core.rps_sock_flow_entries"]="32768"
)

# --- 核心优化参数 ---
sysctl_values=(
    # 基础队列优化
    ["net.core.somaxconn"]="65535"
    ["net.ipv4.tcp_max_syn_backlog"]="65535"
    ["net.core.netdev_max_backlog"]="65535"
    ["net.core.optmem_max"]="25165824"

    # 缓冲区设置
    ["net.core.rmem_max"]="$FINAL_MAX_BUF"
    ["net.core.wmem_max"]="$FINAL_MAX_BUF"
    ["net.core.rmem_default"]="$((FINAL_MAX_BUF / 4))"
    ["net.core.wmem_default"]="$((FINAL_MAX_BUF / 4))"
    ["net.ipv4.tcp_rmem"]="4096 $((FINAL_MAX_BUF / 2)) $FINAL_MAX_BUF"
    ["net.ipv4.tcp_wmem"]="4096 $((FINAL_MAX_BUF / 2)) $FINAL_MAX_BUF"

    # TCP 快速路径优化
    ["net.ipv4.tcp_fin_timeout"]="15"
    ["net.ipv4.tcp_keepalive_time"]="300"
    ["net.ipv4.tcp_keepalive_intvl"]="30"
    ["net.ipv4.tcp_keepalive_probes"]="3"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_dsack"]="1"
    ["net.ipv4.tcp_slow_start_after_idle"]="0"
    
    # 降低延迟的参数
    ["net.ipv4.tcp_low_latency"]="1"
    ["net.ipv4.tcp_notsent_lowat"]="16384"
    ["net.ipv4.tcp_mtu_probing"]="1"
    ["net.ipv4.tcp_early_retrans"]="3"
    ["net.ipv4.tcp_thin_linear_timeouts"]="1"
    ["net.ipv4.tcp_autocorking"]="0"
    
    # 队列和拥塞控制 - 统一使用bbr（内核决定版本）
    ["net.ipv4.tcp_congestion_control"]="bbr"
    ["net.core.default_qdisc"]="fq"

    # TCP Fast Open
    ["net.ipv4.tcp_fastopen"]="3"

    # RACK (Recent ACKnowledgment) - 减少重传延迟
    ["net.ipv4.tcp_rack_ident_enabled"]="1"
    ["net.ipv4.tcp_recovery"]="1"
    
    # 安全与稳定性
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.all.accept_source_route"]="0"
    ["net.ipv4.tcp_syncookies"]="1"
    
    # 内存与调度
    ["vm.swappiness"]="10"
    ["vm.vfs_cache_pressure"]="50"
    ["vm.dirty_ratio"]="30"
    ["vm.dirty_background_ratio"]="5"
    ["vm.dirty_expire_centisecs"]="3000"
    ["vm.dirty_writeback_centisecs"]="500"
)

# --- 添加抖动优化参数（如果内核支持）---
for key in "${!JITTER_OPTIMIZATIONS[@]}"; do
    if check_kernel_feature "$key"; then
        sysctl_values["$key"]="${JITTER_OPTIMIZATIONS[$key]}"
    fi
done

# --- 文件句柄调整 ---
current_file_max=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
target_file_max=$(( ulimit_n * 10 ))
if (( current_file_max < target_file_max )); then
    sysctl_values["fs.file-max"]="$target_file_max"
fi

# --- 增加 inotify 限制 ---
sysctl_values["fs.inotify.max_user_watches"]="524288"
sysctl_values["fs.inotify.max_user_instances"]="512"

# --- 尝试加载 BBR 模块（如果支持）---
if [ "$BBR_SUPPORTED" = true ] && [ "$BBR_AVAILABLE" = false ]; then
    print_step "尝试加载 BBR 模块..."
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        print_step "BBR 模块加载成功"
        # 确保 BBR 模块开机加载
        mkdir -p /etc/modules-load.d/
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    else
        print_warn "BBR 模块加载失败，将使用默认拥塞算法"
        sysctl_values["net.ipv4.tcp_congestion_control"]="cubic"
    fi
elif [ "$BBR_SUPPORTED" = false ]; then
    print_warn "内核版本过低，BBR 不可用，将使用 cubic"
    sysctl_values["net.ipv4.tcp_congestion_control"]="cubic"
fi

# --- 配置中断平衡建议（非强制）---
print_step "生成中断平衡建议..."
IRQBALANCE_SUGGESTION=""
if command -v irqbalance >/dev/null 2>&1; then
    if systemctl is-active irqbalance >/dev/null 2>&1; then
        IRQBALANCE_SUGGESTION="irqbalance 服务正在运行，有助于减少网络延迟抖动"
    else
        IRQBALANCE_SUGGESTION="建议启动 irqbalance 服务：systemctl start irqbalance && systemctl enable irqbalance"
    fi
else
    IRQBALANCE_SUGGESTION="建议安装 irqbalance：apt-get install irqbalance (Debian/Ubuntu)"
fi

# --- 应用配置到临时文件 ---
: > "$TEMP_SYSCTL_FILE"
for key in "${!sysctl_values[@]}"; do
    apply_sysctl_value "$key" "${sysctl_values[$key]}"
done

# 写入 sysctl 配置文件
SYSCTL_CONF_FILE="$SYSCTL_DIR/network-tuning.conf"
print_step "正在写入内核配置文件: $SYSCTL_CONF_FILE"
{
    echo ""
    echo "$SYSCTL_MARKER_START"
    echo "# 优化模式: $mode, 策略: $strategy, 应用时间: $(date '+%F %T')"
    echo "# 内核版本: $(uname -r)"
    if [ "$mode" = "dynamic" ] && [[ -n "$down_mbps" || -n "$up_mbps" ]]; then
        echo "# 用户输入带宽: down=${down_mbps:-N/A}Mbps up=${up_mbps:-N/A}Mbps"
    fi
    echo "# 最终缓冲区大小: $(human_readable "$FINAL_MAX_BUF") ($FINAL_MAX_BUF bytes)"
    echo "# 抖动优化: 已启用"
    echo "# BBR状态: $BBR_MSG"
    echo "# RACK支持: $(check_kernel_feature net.ipv4.tcp_rack_ident_enabled && echo "是" || echo "否")"
    echo ""
    cat "$TEMP_SYSCTL_FILE"
    echo "$SYSCTL_MARKER_END"
} > "$SYSCTL_CONF_FILE"

rm -f "$TEMP_SYSCTL_FILE"

# --- 应用 sysctl 设置 ---
print_step "应用 sysctl 设置..."
sysctl --system >/dev/null 2>&1 || true
sysctl -p >/dev/null 2>&1 || true

# --- 写入 Ulimit ---
print_step "正在写入 Ulimit 配置文件: $LIMITS_CONF_FILE"
{
    echo ""
    echo "$LIMITS_MARKER_START"
    echo "# 优化模式: $mode, 策略: $strategy"
    echo "* soft nofile $ulimit_n"
    echo "* hard nofile $ulimit_n"
    echo "root soft nofile $ulimit_n"
    echo "root hard nofile $ulimit_n"
    
    # 增加其他限制
    echo "* soft nproc $ulimit_n"
    echo "* hard nproc $ulimit_n"
    echo "root soft nproc $ulimit_n"
    echo "root hard nproc $ulimit_n"
    
    echo "$LIMITS_MARKER_END"
} > "$LIMITS_CONF_FILE"

# --- 最终报告 ---
clear
print_title "✅ 优化完成报告"
echo
echo -e "${CYAN}【基础信息】${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "优化模式      : ${GREEN}$mode${NC}"
echo -e "应用策略      : ${GREEN}$strategy${NC}"
echo -e "内核版本      : ${YELLOW}$(uname -r)${NC}"
echo -e "缓冲区大小    : ${YELLOW}$(human_readable "$FINAL_MAX_BUF") ($FINAL_MAX_BUF bytes)${NC}"
echo -e "文件描述符限制: ${YELLOW}$ulimit_n${NC}"
echo
echo -e "${CYAN}【网络优化状态】${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "拥塞算法      : ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")${NC}"
echo -e "队列算法      : ${GREEN}$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")${NC}"
echo -e "TCP Fast Open : ${GREEN}$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "unknown")${NC}"
echo -e "BBR 状态      : ${GREEN}$BBR_MSG${NC}"
echo -e "RACK 支持     : ${GREEN}$(check_kernel_feature net.ipv4.tcp_rack_ident_enabled && echo "已启用" || echo "不支持")${NC}"
echo
echo -e "${CYAN}【抖动优化措施】${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "✓ TCP 低延迟模式: 已启用"
echo -e "✓ 调度器优化: 已应用"
echo -e "✓ 自动 corking: 已禁用"
echo -e "✓ 精简超时: 已优化"
echo -e "✓ $IRQBALANCE_SUGGESTION"
echo
echo -e "${CYAN}【配置文件】${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "内核配置      : $SYSCTL_CONF_FILE"
echo -e "Ulimit配置    : $LIMITS_CONF_FILE"
echo -e "备份目录      : $BACKUP_BASE_DIR"
echo
echo -e "${YELLOW}【重要提示】${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. 重新登录 SSH 后 ulimit 才会完全生效"
echo "2. 建议监控重传率: netstat -s | grep retrans"
echo "3. 查看队列延迟: tc -s qdisc show"
echo "4. 生产环境建议先在测试环境验证"
echo
print_title "脚本执行完成"