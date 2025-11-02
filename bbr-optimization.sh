#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本 (修正版)
#
# 原作者: yahuisme
# 修改说明: 移除高风险参数，并改为直接修改 /etc/sysctl.conf
# 版本: 1.6.1_MOD (2025-11-01)
# ==============================================================================

# --- 脚本版本号定义 ---
SCRIPT_VERSION="1.6.1_MOD"

set -euo pipefail

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 配置文件路径 (修改为直接修改默认配置文件) ---
CONF_FILE="/etc/sysctl.conf"

# --- 标记和范围 ---
START_MARKER="# === BBR_OPTIMIZATION_START ==="
END_MARKER="# === BBR_OPTIMIZATION_END ==="

# --- 系统信息检测函数 ---
get_system_info() {
    # 使用 tr -d '\r' 清理可能的 DOS 换行符
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    CPU_CORES=$(nproc | tr -d '\r')

    # ... (虚拟化检测部分保持不变) ...
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt)
    elif grep -q -i "hypervisor" /proc/cpuinfo; then
        VIRT_TYPE="KVM/VMware"
    elif command -v dmidecode >/dev/null 2>&1 && dmidecode -s system-product-name | grep -q -i "virtual"; then
        VIRT_TYPE=$(dmidecode -s system-product-name)
    else
        VIRT_TYPE="unknown"
    fi

    echo -e "${CYAN}>>> 系统信息检测：${NC}"
    echo -e "内存大小   : ${YELLOW}${TOTAL_MEM}MB${NC}"
    echo -e "CPU核心数  : ${YELLOW}${CPU_CORES}${NC}"
    echo -e "虚拟化类型 : ${YELLOW}${VIRT_TYPE}${NC}"

    calculate_parameters
}

# --- 动态参数计算函数 (保持不变) ---
calculate_parameters() {
    if [ "$TOTAL_MEM" -le 512 ]; then
        VM_TIER="经典级(≤512MB)"
        RMEM_MAX="8388608"
        WMEM_MAX="8388608"
        TCP_RMEM="4096 65536 8388608"
        TCP_WMEM="4096 65536 8388608"
        SOMAXCONN="32768"
        NETDEV_BACKLOG="16384"
        FILE_MAX="262144"
        CONNTRACK_MAX="131072"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        VM_TIER="轻量级(512MB-1GB)"
        RMEM_MAX="16777216"
        WMEM_MAX="16777216"
        TCP_RMEM="4096 65536 16777216"
        TCP_WMEM="4096 65536 16777216"
        SOMAXCONN="49152"
        NETDEV_BACKLOG="24576"
        FILE_MAX="524288"
        CONNTRACK_MAX="262144"
    elif [ "$TOTAL_MEM" -le 2048 ]; then
        VM_TIER="标准级(1GB-2GB)"
        RMEM_MAX="33554432"
        WMEM_MAX="33554432"
        TCP_RMEM="4096 87380 33554432"
        TCP_WMEM="4096 65536 33554432"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="32768"
        FILE_MAX="1048576"
        CONNTRACK_MAX="524288"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        VM_TIER="高性能级(2GB-4GB)"
        RMEM_MAX="67108864"
        WMEM_MAX="67108864"
        TCP_RMEM="4096 131072 67108864"
        TCP_WMEM="4096 87380 67108864"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="65535"
        FILE_MAX="2097152"
        CONNTRACK_MAX="1048576"
    elif [ "$TOTAL_MEM" -le 8192 ]; then
        VM_TIER="企业级(4GB-8GB)"
        RMEM_MAX="134217728"
        WMEM_MAX="134217728"
        TCP_RMEM="8192 131072 134217728"
        TCP_WMEM="8192 87380 134217728"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="65535"
        FILE_MAX="4194304"
        CONNTRACK_MAX="2097152"
    else
        VM_TIER="旗舰级(>8GB)"
        RMEM_MAX="134217728"
        WMEM_MAX="134217728"
        TCP_RMEM="8192 131072 134217728"
        TCP_WMEM="8192 87380 134217728"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="65535"
        FILE_MAX="8388608"
        CONNTRACK_MAX="2097152"
    fi
}

# --- 预检查函数 (保持不变) ---
pre_flight_checks() {
    echo -e "${BLUE}>>> 执行预检查...${NC}"
    if [[ $(id -u) -ne 0 ]]; then
        echo -e "${RED}❌ 错误: 此脚本必须以root权限运行。${NC}"
        exit 1
    fi
    local KERNEL_VERSION
    KERNEL_VERSION=$(uname -r)
    if [[ $(printf '%s\n' "4.9" "$KERNEL_VERSION" | sort -V | head -n1) != "4.9" ]]; then
        echo -e "${RED}❌ 错误: 内核版本 $KERNEL_VERSION 不支持BBR (需要 4.9+)。${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ 内核版本 $KERNEL_VERSION, 支持BBR。${NC}"
    fi
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
        echo -e "${YELLOW}⚠️  警告: BBR模块未加载，尝试加载...${NC}"
        modprobe tcp_bbr 2>/dev/null || { echo -e "${RED}❌ 无法加载BBR模块, 请检查内核。${NC}"; exit 1; }
    fi
}

# --- 备份管理与清理函数 (修改为适应 /etc/sysctl.conf) ---
manage_backups() {
    if [ -f "$CONF_FILE" ]; then
        local BAK_FILE="$CONF_FILE.bak_$(date +%F_%H-%M-%S)"
        echo -e "${YELLOW}>>> 创建当前配置备份: $BAK_FILE${NC}"
        cp "$CONF_FILE" "$BAK_FILE"
    fi
    # 限制备份数量，只保留最新的两个
    local old_backups
    set +e
    old_backups=$(ls -t "$CONF_FILE.bak_"* 2>/dev/null | tail -n +3) # 只删除第3个及以后的
    set -e
    if [ -n "$old_backups" ]; then
        echo -e "${CYAN}>>> 清理旧的备份文件...${NC}"
        echo "$old_backups" | xargs rm -f
        echo -e "${GREEN}✅ 旧备份清理完成。${NC}"
    fi
}

# --- 主要优化配置 (删除激进参数，并使用标记替换) ---
apply_optimizations() {
    echo -e "${CYAN}>>> 应用核心网络优化配置 (${YELLOW}${VM_TIER}${CYAN})...${NC}"

    # 1. 构造新的优化内容
    local NEW_CONF
    NEW_CONF=$(cat << EOF
${START_MARKER}
# ==========================================================
# TCP/IP & BBR 优化配置 (由脚本自动生成)
# 生成时间: $(date)
# 针对硬件: ${TOTAL_MEM}MB 内存, ${CPU_CORES}核CPU (${VM_TIER})
# ==========================================================
net.core.default_qdisc = fq            # 启用 FQ 队列调度器
net.ipv4.tcp_congestion_control = bbr  # 启用 BBR 拥塞控制算法
net.core.rmem_max = ${RMEM_MAX}        # 最大 socket 读缓冲区
net.core.wmem_max = ${WMEM_MAX}        # 最大 socket 写缓冲区
net.ipv4.tcp_rmem = ${TCP_RMEM}        # TCP 读缓冲区 (min/default/max)
net.ipv4.tcp_wmem = ${TCP_WMEM}        # TCP 写缓冲区 (min/default/max)
net.core.somaxconn = ${SOMAXCONN}      # 最大监听队列长度
net.core.netdev_max_backlog = ${NETDEV_BACKLOG} # 网络设备最大排队数
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN} # SYN 队列最大长度
fs.file-max = ${FILE_MAX}              # 系统级最大文件句柄数
# 以下参数使用内核默认值 (已移除：tcp_tw_reuse, tcp_fin_timeout, tcp_slow_start_after_idle 等激进参数)

EOF
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        NEW_CONF+="\nnet.netfilter.nf_conntrack_max = ${CONNTRACK_MAX} # 连接跟踪表最大条目数\n"
    fi
    NEW_CONF+="${END_MARKER}"
    )

    # 2. 移除旧的优化内容
    if grep -q "${START_MARKER}" "$CONF_FILE"; then
        echo -e "${YELLOW}>>> 发现旧的优化配置，正在移除...${NC}"
        # 使用 sed 移除标记之间的内容
        sed -i "/${START_MARKER}/,/${END_MARKER}/d" "$CONF_FILE"
    fi

    # 3. 追加新的优化内容到文件末尾
    echo -e "$NEW_CONF" >> "$CONF_FILE"
    echo -e "${GREEN}✅ 优化配置已写入 ${CONF_FILE}${NC}"
}

# --- 应用与验证 (保持不变) ---
apply_and_verify() {
    echo -e "${CYAN}>>> 使配置生效...${NC}"
    sysctl --system >/dev/null 2>&1 || { echo -e "${RED}❌ 配置应用失败, 请检查 $CONF_FILE 文件格式。${NC}"; exit 1; }
    echo -e "${GREEN}✅ 配置已动态生效。${NC}"
    echo -e "${CYAN}>>> 验证优化结果...${NC}"
    local CURRENT_CC
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    local CURRENT_QDISC
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc)
    echo -e "当前拥塞控制算法: ${YELLOW}$CURRENT_CC${NC}"
    echo -e "当前网络队列调度器: ${YELLOW}$CURRENT_QDISC${NC}"
    if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
        echo -e "${GREEN}✅ BBR 与 FQ 已成功启用!${NC}"
    else
        echo -e "${RED}❌ 优化未完全生效, 请检查系统日志。${NC}"
    fi
}

# --- 提示信息 (修改为适应 /etc/sysctl.conf) ---
show_tips() {
    echo ""
    echo -e "${YELLOW}-------------------- 操作完成 --------------------${NC}"
    echo -e "配置文件已写入: ${CYAN}$CONF_FILE${NC}"
    local bak_file_hint
    bak_file_hint=$(ls -t "$CONF_FILE.bak_"* 2>/dev/null | head -n 1)
    if [ -n "$bak_file_hint" ]; then
        echo -e "如需恢复备份, 可运行:"
        echo -e "${GREEN}mv \"$bak_file_hint\" \"$CONF_FILE\" && sysctl --system${NC}"
    fi
    echo -e "${YELLOW}--------------------------------------------------${NC}"
}

# --- 冲突配置检查函数 (删除，因为现在直接写入主文件，其他sysctl.d文件优先级更高，冲突风险变小) ---
# check_for_conflicts() { ... }

# --- 幂等性检查函数 (修改为检查 /etc/sysctl.conf 里的标记) ---
check_if_already_applied() {
    if grep -q "${START_MARKER}" "$CONF_FILE" 2>/dev/null; then
        local current_cc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [[ "$current_cc" == "bbr" ]]; then
            echo -e "${GREEN}✅ 系统已被此脚本优化，且BBR已启用，无需重复操作。${NC}"
            exit 0
        fi
    fi
}

# --- 撤销与卸载函数 (修改为适应 /etc/sysctl.conf) ---
revert_optimizations() {
    echo -e "${YELLOW}>>> 正在尝试撤销优化...${NC}"
    local latest_backup
    latest_backup=$(ls -t "$CONF_FILE.bak_"* 2>/dev/null | head -n 1)

    if [[ $(id -u) -ne 0 ]]; then
        echo -e "${RED}❌ 错误: 操作必须以root权限运行。${NC}"
        exit 1
    fi

    if [ -f "$latest_backup" ]; then
        echo -e "找到最新备份文件: ${CYAN}$latest_backup${NC}"
        mv "$latest_backup" "$CONF_FILE"
        echo -e "${GREEN}✅ 已通过备份文件恢复。${NC}"
    elif grep -q "${START_MARKER}" "$CONF_FILE" 2>/dev/null; then
        echo -e "${YELLOW}未找到备份文件，将清除配置文件中的脚本优化部分...${NC}"
        # 使用 sed 移除标记之间的内容
        sed -i "/${START_MARKER}/,/${END_MARKER}/d" "$CONF_FILE"
        echo -e "${GREEN}✅ 配置文件中脚本优化部分已清除。${NC}"
    else
        echo -e "${GREEN}✅ 系统未发现脚本添加的优化配置，无需操作。${NC}"
        return 0
    fi

    echo -e "${CYAN}>>> 使恢复后的配置生效...${NC}"
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}🎉 优化已成功撤销！系统将恢复到内核默认或之前的配置。${NC}"
}

# --- 主函数 ---
main() {
    if [[ "${1:-}" == "uninstall" || "${1:-}" == "--revert" ]]; then
        revert_optimizations
        exit 0
    fi

    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      Linux TCP/IP & BBR 核心优化脚本 v${SCRIPT_VERSION}      ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    pre_flight_checks
    check_if_already_applied
    get_system_info
    manage_backups
    apply_optimizations
    apply_and_verify
    show_tips

    echo -e "\n${GREEN}🎉 所有核心优化已完成并生效！${NC}"

    exit 0
}

# --- 脚本入口 ---
main "$@"
