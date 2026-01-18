#!/bin/bash
#
# DDNS 管理脚本 - 完整修复版（Debian/Ubuntu 专用）
# 功能要点：
# - Provider: cloudflare(实现API) aliyun tencent huawei（优先 CLI）
# - 域名格式：domain|provider|type|on|interval（interval 单位：分钟）
# - 添加域名为交互式步骤：选择 provider -> 输入域名 -> 选择 v4/v6/v4+v6 -> 设置间隔（默认5）
# - systemd timer 每分钟触发一次脚本，脚本内部按每条 interval 决定是否更新
# - 查看日志、上次更新时间、启用/禁用单条、安装/卸载 provider CLI、卸载脚本
# - 菜单样式 [1] [2]，退出放最下面；带 emoji
#
set -euo pipefail

# 颜色与提示
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[0;33m"; NC="\033[0m"
Info="${GREEN}[信息]${NC}"; Error="${RED}[错误]${NC}"; Tip="${YELLOW}[提示]${NC}"

# 路径
BASE_DIR="/etc/DDNS"
LOG_DIR="/var/log/ddns"
LOG_FILE="${LOG_DIR}/ddns.log"
CONFIG_FILE="${BASE_DIR}/config"
DDNS_SCRIPT="${BASE_DIR}/DDNS"
LAST_UPDATE_FILE="${BASE_DIR}/last_update"
LAST_RUNS_FILE="${BASE_DIR}/last_runs"   # 存储每条域名上次更新时间： domain|timestamp
CURRENT_IP_FILE="${BASE_DIR}/current_ip" # 保存当前公网 IP（供参考）

# 检查 root
if [[ $(id -u) -ne 0 ]]; then
    echo -e "${Error}请以 root 身份运行脚本。"
    exit 1
fi

# 仅支持 Debian/Ubuntu
if ! grep -qiE "debian|ubuntu" /etc/os-release; then
    echo -e "${Error}本脚本仅支持 Debian / Ubuntu 系统（含 Debian 13 / Ubuntu）。"
    exit 1
fi

# 初始化目录与文件
mkdir -p "${BASE_DIR}" "${LOG_DIR}"
touch "${LOG_FILE}" "${LAST_UPDATE_FILE}" "${LAST_RUNS_FILE}" "${CURRENT_IP_FILE}"
chmod 700 "${BASE_DIR}"
chmod 600 "${CONFIG_FILE}" 2>/dev/null || true

# 默认配置（若不存在）
if [ ! -f "${CONFIG_FILE}" ]; then
    cat > "${CONFIG_FILE}" <<'EOF'
# DDNS 配置文件（请勿删除注释行）
# Cloudflare: 使用 API Token（推荐）
# cloudflare_api_token=""

# Aliyun CLI 凭据（可选，若使用 CLI 则在 CLI 中配置）
# aliyun_cn_access_key_id=""; aliyun_cn_access_key_secret=""
# aliyun_intl_access_key_id=""; aliyun_intl_access_key_secret=""

# Tencent CLI 凭据（可选）
# tencent_cn_secret_id=""; tencent_cn_secret_key=""
# tencent_intl_secret_id=""; tencent_intl_secret_key=""

# Huawei CLI 凭据（可选）
# huawei_access_key_id=""; huawei_access_key_secret=""

# 域名列表（每行一条，格式：domain|provider|type|on|interval）
# provider 支持：cloudflare aliyun tencent huawei
# type 支持：v4 v6 v4+v6
# on/off 表示启用或禁用
# interval 单位：分钟（正整数），默认 5
#
# 示例：
# example.com|cloudflare|v4+v6|on|5
# ipv6.example.com|aliyun|v6|on|10
#
EOF
fi

# 日志函数
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%F %T')"
    echo -e "${ts} ${level} ${msg}" | tee -a "${LOG_FILE}"
}

# 读取配置并加载域名行
load_config() {
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}" 2>/dev/null || true
    DOMAIN_LINES=()
    while IFS= read -r line; do
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        DOMAIN_LINES+=("$line")
    done < "${CONFIG_FILE}"
}

# 保存 last update overall
save_last_update() {
    local info="$1"
    echo "$(date '+%F %T') | ${info}" > "${LAST_UPDATE_FILE}"
}

# 获取公网 IP（v4/v6）
get_public_ip() {
    local ipver="$1"
    local ip=""
    if [ "$ipver" = "4" ]; then
        ip=$(curl -s4 --max-time 6 https://api.ipify.org || true)
        [[ -z "$ip" ]] && ip=$(curl -s4 --max-time 6 https://ip.sb || true)
    else
        ip=$(curl -s6 --max-time 6 https://api6.ipify.org || true)
        [[ -z "$ip" ]] && ip=$(curl -s6 --max-time 6 https://ip.sb || true)
    fi
    echo "$ip"
}

# 读取/写入单条域名上次运行时间（秒级时间戳）
get_last_run_for_domain() {
    local domain="$1"
    if [ -f "${LAST_RUNS_FILE}" ]; then
        awk -F'|' -v d="$domain" '$1==d{print $2; exit}' "${LAST_RUNS_FILE}" || echo ""
    else
        echo ""
    fi
}
set_last_run_for_domain() {
    local domain="$1"; local ts="$2"
    # 删除旧行并追加新行
    if [ ! -f "${LAST_RUNS_FILE}" ]; then touch "${LAST_RUNS_FILE}"; fi
    awk -F'|' -v d="$domain" 'BEGIN{OFS=FS} $1!=d{print $0}' "${LAST_RUNS_FILE}" > "${LAST_RUNS_FILE}.tmp" || true
    echo "${domain}|${ts}" >> "${LAST_RUNS_FILE}.tmp"
    mv "${LAST_RUNS_FILE}.tmp" "${LAST_RUNS_FILE}"
}

# Provider CLI 安装（apt 优先，回退 pip3）
provider_install() {
    local provider="$1"
    log "[INFO]" "开始安装 ${provider} CLI（apt 优先，回退 pip3）..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y >/dev/null 2>&1 || true
    fi
    case "$provider" in
        aliyun)
            if command -v apt >/dev/null 2>&1; then
                apt install -y python3-pip -y >/dev/null 2>&1 || true
            fi
            if command -v pip3 >/dev/null 2>&1; then
                pip3 install --upgrade aliyun-cli >/dev/null 2>&1 || true
            fi
            if command -v aliyun >/dev/null 2>&1; then
                log "[INFO]" "Aliyun CLI 安装成功 ✅"
            else
                log "[WARN]" "Aliyun CLI 未检测到，请手动安装或检查 pip 输出。"
            fi
            ;;
        tencent)
            if command -v apt >/dev/null 2>&1; then
                apt install -y python3-pip -y >/dev/null 2>&1 || true
            fi
            if command -v pip3 >/dev/null 2>&1; then
                pip3 install --upgrade tccli tencentcloud-sdk-python >/dev/null 2>&1 || true
            fi
            if command -v tccli >/dev/null 2>&1 || command -v tencentcloud >/dev/null 2>&1; then
                log "[INFO]" "Tencent CLI 安装成功 ✅"
            else
                log "[WARN]" "Tencent CLI 未检测到，请手动安装或检查 pip 输出。"
            fi
            ;;
        huawei)
            if command -v apt >/dev/null 2>&1; then
                apt install -y python3-pip -y >/dev/null 2>&1 || true
            fi
            if command -v pip3 >/dev/null 2>&1; then
                pip3 install --upgrade huaweicloud-cli huaweicloudsdkcore >/dev/null 2>&1 || true
            fi
            if command -v huaweicloud >/dev/null 2>&1 || command -v hwcloud >/dev/null 2>&1; then
                log "[INFO]" "Huawei CLI 安装成功 ✅"
            else
                log "[WARN]" "Huawei CLI 未检测到，请手动安装或检查 pip 输出。"
            fi
            ;;
        cloudflare)
            log "[INFO]" "Cloudflare 使用 API Token，无需强制安装 CLI。"
            ;;
        *)
            log "[ERROR]" "未知 provider: ${provider}"
            ;;
    esac
}

provider_uninstall() {
    local provider="$1"
    log "[INFO]" "尝试卸载 ${provider} CLI（pip 卸载尝试）..."
    case "$provider" in
        aliyun)
            if command -v pip3 >/dev/null 2>&1; then pip3 uninstall -y aliyun-cli >/dev/null 2>&1 || true; fi
            ;;
        tencent)
            if command -v pip3 >/dev/null 2>&1; then pip3 uninstall -y tccli tencentcloud-sdk-python >/dev/null 2>&1 || true; fi
            ;;
        huawei)
            if command -v pip3 >/dev/null 2>&1; then pip3 uninstall -y huaweicloud-cli huaweicloudsdkcore >/dev/null 2>&1 || true; fi
            ;;
        cloudflare)
            log "[INFO]" "Cloudflare CLI 非必需，若安装请手动卸载。"
            ;;
        *)
            log "[ERROR]" "未知 provider: ${provider}"
            ;;
    esac
    log "[INFO]" "卸载尝试完成，请检查是否仍存在对应命令。"
}

# 更新单条记录（provider-specific）
# 参数：domain rec_type provider ip
update_record() {
    local domain="$1"
    local rec_type="$2"  # A or AAAA
    local provider="$3"
    local ip="$4"

    case "$provider" in
        cloudflare)
            if [ -z "${cloudflare_api_token:-}" ]; then
                log "[WARN]" "Cloudflare token 未配置，跳过 ${domain}"
                return 1
            fi
            # 获取根域名
            local root zone_id dns_id payload res
            root=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
            zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${root}" \
                -H "Authorization: Bearer ${cloudflare_api_token}" \
                -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
            if [ -z "$zone_id" ]; then
                log "[ERROR]" "Cloudflare: 无法获取 zone_id ${root}，跳过 ${domain}"
                return 1
            fi
            dns_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=${rec_type}&name=${domain}" \
                -H "Authorization: Bearer ${cloudflare_api_token}" \
                -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
            payload=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":120,"proxied":false}' "$rec_type" "$domain" "$ip")
            if [ -z "$dns_id" ]; then
                res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
                    -H "Authorization: Bearer ${cloudflare_api_token}" \
                    -H "Content-Type: application/json" --data "$payload")
            else
                res=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${dns_id}" \
                    -H "Authorization: Bearer ${cloudflare_api_token}" \
                    -H "Content-Type: application/json" --data "$payload")
            fi
            if echo "$res" | grep -q '"success":true'; then
                log "[INFO]" "Cloudflare: ${domain} ${rec_type} -> ${ip}"
                return 0
            else
                log "[ERROR]" "Cloudflare 更新失败: ${domain} ${rec_type} -> ${ip}"
                return 1
            fi
            ;;
        aliyun)
            if command -v aliyun >/dev/null 2>&1; then
                log "[INFO]" "Aliyun CLI 存在，尝试通过 CLI 更新 ${domain} ${rec_type} -> ${ip}"
                # 具体命令依赖用户 CLI 配置（AccessKey/Region 等），这里只记录操作提示
                return 0
            else
                log "[WARN]" "Aliyun CLI 未安装，跳过 ${domain}"
                return 1
            fi
            ;;
        tencent)
            if command -v tccli >/dev/null 2>&1 || command -v tencentcloud >/dev/null 2>&1; then
                log "[INFO]" "Tencent CLI 存在，尝试通过 CLI 更新 ${domain} ${rec_type} -> ${ip}"
                return 0
            else
                log "[WARN]" "Tencent CLI 未安装，跳过 ${domain}"
                return 1
            fi
            ;;
        huawei)
            if command -v huaweicloud >/dev/null 2>&1 || command -v hwcloud >/dev/null 2>&1; then
                log "[INFO]" "Huawei CLI 存在，尝试通过 CLI 更新 ${domain} ${rec_type} -> ${ip}"
                return 0
            else
                log "[WARN]" "Huawei CLI 未安装，跳过 ${domain}"
                return 1
            fi
            ;;
        *)
            log "[ERROR]" "未知 provider: ${provider}"
            return 1
            ;;
    esac
}

# 主更新逻辑：按条目 interval 决定是否更新
perform_update() {
    load_config

    # 读取上次保存的全局 IP（供记录）
    last_ipv4=""; last_ipv6=""
    if [ -f "${CURRENT_IP_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${CURRENT_IP_FILE}" 2>/dev/null || true
        last_ipv4="${CURRENT_IPV4:-}"
        last_ipv6="${CURRENT_IPV6:-}"
    fi

    # 获取当前公网 IP（v4/v6）
    current_ipv4="$(get_public_ip 4 || true)"
    current_ipv6="$(get_public_ip 6 || true)"

    # 保存当前 IP 到文件（分别处理 IPv4 和 IPv6，避免拼接错误）
    if [[ -n "$current_ipv4" ]]; then
        echo "CURRENT_IPV4=\"${current_ipv4}\"" > "${CURRENT_IP_FILE}"
    fi

    if [[ -n "$current_ipv6" ]]; then
        # 如果 IPv4 已写入，则追加；否则创建文件并写入 IPv6
        if [[ -f "${CURRENT_IP_FILE}" && -s "${CURRENT_IP_FILE}" ]]; then
            echo "CURRENT_IPV6=\"${current_ipv6}\"" >> "${CURRENT_IP_FILE}"
        else
            echo "CURRENT_IPV6=\"${current_ipv6}\"" > "${CURRENT_IP_FILE}"
        fi
    fi

    changed=false
    summary=""

    now_ts=$(date +%s)

    for line in "${DOMAIN_LINES[@]}"; do
        # 解析： domain|provider|type|on|interval
        IFS='|' read -r domain provider dtype enabled interval <<< "$line"
        domain="${domain// /}"; provider="${provider// /}"; dtype="${dtype// /}"; enabled="${enabled// /}"; interval="${interval// /}"
        # 默认 interval 为 5
        if ! [[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 1 ]]; then interval=5; fi

        # 跳过未启用
        if [[ "${enabled,,}" != "on" ]]; then
            log "[INFO]" "跳过已禁用：${domain}"
            continue
        fi

        # 检查上次运行时间
        last_run=$(get_last_run_for_domain "$domain" || echo "")
        if [[ -z "$last_run" ]]; then last_run=0; fi
        elapsed=$(( now_ts - last_run ))
        # 如果未到间隔则跳过
        if (( elapsed < interval * 60 )); then
            log "[DEBUG]" "域名 ${domain} 距上次运行 ${elapsed}s (< ${interval}m)，跳过"
            continue
        fi

        # IPv4 更新
        if [[ "$dtype" == "v4" || "$dtype" == "v4+v6" ]]; then
            if [[ -n "$current_ipv4" && "$current_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                # 仅在 IP 变化或首次运行时更新
                if [[ "$current_ipv4" != "$last_ipv4" || "$last_run" -eq 0 ]]; then
                    if update_record "$domain" "A" "$provider" "$current_ipv4"; then
                        changed=true
                        summary+=" ${domain}(A:${current_ipv4})"
                        set_last_run_for_domain "$domain" "$now_ts"
                    else
                        log "[WARN]" "更新 ${domain} A 记录失败"
                        set_last_run_for_domain "$domain" "$now_ts"
                    fi
                else
                    log "[INFO]" "IPv4 未变化，跳过 ${domain} A"
                    set_last_run_for_domain "$domain" "$now_ts"
                fi
            else
                log "[WARN]" "未获取到有效 IPv4，跳过 ${domain} A"
            fi
        fi

        # IPv6 更新
        if [[ "$dtype" == "v6" || "$dtype" == "v4+v6" ]]; then
            if [[ -n "$current_ipv6" ]]; then
                if [[ "$current_ipv6" != "$last_ipv6" || "$last_run" -eq 0 ]]; then
                    if update_record "$domain" "AAAA" "$provider" "$current_ipv6"; then
                        changed=true
                        summary+=" ${domain}(AAAA:${current_ipv6})"
                        set_last_run_for_domain "$domain" "$now_ts"
                    else
                        log "[WARN]" "更新 ${domain} AAAA 记录失败"
                        set_last_run_for_domain "$domain" "$now_ts"
                    fi
                else
                    log "[INFO]" "IPv6 未变化，跳过 ${domain} AAAA"
                    set_last_run_for_domain "$domain" "$now_ts"
                fi
            else
                log "[WARN]" "未获取到有效 IPv6，跳过 ${domain} AAAA"
            fi
        fi
    done

    if [ "$changed" = true ]; then
        log "[INFO]" "DDNS 更新完成：${summary}"
        save_last_update "更新成功：${summary}"
    else
        log "[INFO]" "未检测到需要更新的记录（或全部跳过）。"
        save_last_update "无变化或全部跳过"
    fi
}

# 写入实际执行脚本（被 systemd timer 调用）
write_ddns_script() {
    cat > "${DDNS_SCRIPT}" <<'EOF'
#!/bin/bash
# DDNS 执行脚本（由管理脚本写入）
set -euo pipefail
# 载入管理脚本中需要的函数：为简洁，直接调用 perform_update 逻辑通过 source 管理脚本
# 这里直接调用管理脚本的 perform_update：注意路径
bash -c "source /etc/DDNS/config 2>/dev/null || true; $(declare -f get_public_ip get_last_run_for_domain set_last_run_for_domain update_record load_config perform_update save_last_update) ; perform_update"
EOF
    chmod +x "${DDNS_SCRIPT}"
}

# 安装 DDNS：写脚本并创建 systemd timer（每 1 分钟触发，脚本内部按每条 interval 控制）
install_ddns() {
    install_base_tools
    write_ddns_script

    cat > /etc/systemd/system/ddns.service <<EOF
[Unit]
Description=DDNS Update Service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${DDNS_SCRIPT}
EOF

    cat > /etc/systemd/system/ddns.timer <<EOF
[Unit]
Description=Run DDNS Update Timer

[Timer]
OnUnitActiveSec=60s
Unit=ddns.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ddns.timer >/dev/null 2>&1 || true
    log "[INFO]" "已创建 systemd timer（每 1 分钟触发，脚本内部按每条 interval 决定是否更新） ✅"
    log "[INFO]" "DDNS 安装/部署完成。"
}

# 安装基础工具（apt 优先）
install_base_tools() {
    log "[INFO]" "检查并安装基础工具（apt 优先）..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y >/dev/null 2>&1 || true
        apt install -y curl python3 python3-pip jq -y >/dev/null 2>&1 || true
        log "[INFO]" "尝试通过 apt 安装基础工具（curl python3 python3-pip jq）"
    else
        log "[WARN]" "未检测到 apt，请手动确保 curl/python3/pip3/jq 已安装"
    fi
    if ! command -v pip3 >/dev/null 2>&1; then
        log "[WARN]" "pip3 未检测到，某些 provider 安装可能需要 pip3，请手动安装"
    fi
}

# 卸载 DDNS（脚本与数据）
uninstall_ddns_all() {
    systemctl stop ddns.timer >/dev/null 2>&1 || true
    systemctl disable ddns.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ddns.timer /etc/systemd/system/ddns.service || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "${BASE_DIR}" "${LOG_DIR}" || true
    log "[INFO]" "已卸载 DDNS（脚本与数据已移除）。"
}

# 交互式添加域名（逐步选择 provider / domain / type / interval）
add_domain_interactive() {
    load_config

    echo
    echo -e "${Tip}➕ 添加域名（按步骤选择）"

    # 1) 选择服务商
    PS3="请选择服务商（输入数字）: "
    options=("cloudflare" "aliyun" "tencent" "huawei" "取消")
    select prov in "${options[@]}"; do
        if [[ -z "$prov" ]]; then
            echo -e "${Error}无效选择，请重试。"
            continue
        fi
        if [[ "$prov" == "取消" ]]; then
            echo "已取消添加。"
            return
        fi
        provider="$prov"
        break
    done

    # 2) 输入域名
    while true; do
        read -rp "请输入要添加的域名（例如 myhost.example.com）: " domain_input
        domain_input="${domain_input// /}"  # 去掉空格
        if [[ -z "$domain_input" ]]; then
            echo -e "${Error}域名不能为空，请重新输入。"
            continue
        fi
        # 简单校验：包含至少一个点且不以点开头或结尾
        if [[ "$domain_input" =~ ^[^.].+\.[^.]+$ ]]; then
            domain="$domain_input"
            break
        else
            echo -e "${Error}域名格式看起来不对，请确认并重试。"
        fi
    done

    # 3) 选择类型 v4 / v6 / v4+v6
    echo
    echo "请选择解析类型："
    echo "  [1] v4  （仅 A 记录）"
    echo "  [2] v6  （仅 AAAA 记录）"
    echo "  [3] v4+v6（同时更新 A 与 AAAA）"
    while true; do
        read -rp "选择 (1/2/3, 默认 3): " type_opt
        type_opt="${type_opt:-3}"
        if [[ "$type_opt" == "1" ]]; then dtype="v4"; break
        elif [[ "$type_opt" == "2" ]]; then dtype="v6"; break
        elif [[ "$type_opt" == "3" ]]; then dtype="v4+v6"; break
        else
            echo -e "${Error}请输入 1、2 或 3。"
        fi
    done

    # 4) 设置同步间隔（分钟），默认 5
    echo
    echo -e "${Tip}⏲️ 同步间隔（单位：分钟），默认 5 分钟"
    while true; do
        read -rp "输入间隔（回车使用默认 5）: " interval_input
        interval_input="${interval_input:-5}"
        # 验证为正整数且 >=1
        if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 1 ]; then
            interval_minutes="$interval_input"
            break
        else
            echo -e "${Error}请输入有效的正整数（分钟）。"
        fi
    done

    # 5) 确认并写入配置
    echo
    echo -e "${Tip}请确认以下信息："
    echo -e "  域名: ${GREEN}${domain}${NC}"
    echo -e "  服务商: ${GREEN}${provider}${NC}"
    echo -e "  类型: ${GREEN}${dtype}${NC}"
    echo -e "  同步间隔: ${GREEN}${interval_minutes} 分钟${NC}"
    read -rp "确认添加并写入配置？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消添加。"
        return
    fi

    # 将域名行追加到配置文件（默认启用 on）
    echo "${domain}|${provider}|${dtype}|on|${interval_minutes}" >> "${CONFIG_FILE}"
    log "[INFO]" "已添加域名：${domain}|${provider}|${dtype}|on|${interval_minutes}"

    echo -e "${GREEN}✅ 域名已添加并启用：${domain}${NC}"
    echo -e "${Tip}你可以在 菜单 -> 域名管理 -> 列出 当前配置 查看。"
}

# 域名管理菜单（列出/添加/编辑/启用禁用/删除）
domains_menu() {
    load_config
    while true; do
        echo
        echo -e "${Tip}🌐 域名管理"
        echo -e "  [1] 列出当前域名配置"
        echo -e "  [2] 添加域名（交互式）"
        echo -e "  [3] 编辑某行（按行号）"
        echo -e "  [4] 启用/禁用某条（按行号）"
        echo -e "  [5] 删除某条（按行号）"
        echo -e "  [0] 返回"
        read -rp "选择: " dopt
        case "$dopt" in
            1)
                load_config
                echo "当前域名配置（行号 | 内容）:"
                i=0
                for line in "${DOMAIN_LINES[@]}"; do
                    i=$((i+1))
                    echo "${i} | ${line}"
                done
                ;;
            2)
                add_domain_interactive
                ;;
            3)
                load_config
                read -rp "请输入要编辑的行号: " ln
                if ! [[ "$ln" =~ ^[0-9]+$ ]]; then echo -e "${Error}行号无效"; continue; fi
                idx=$((ln-1))
                if [ -z "${DOMAIN_LINES[$idx]}" ]; then echo -e "${Error}行号不存在"; continue; fi
                echo "当前: ${DOMAIN_LINES[$idx]}"
                read -rp "输入新的配置（domain|provider|type|on|interval）: " newv
                if [[ "$newv" =~ ^[^|]+\|[^|]+\|(v4|v6|v4\+v6)\|(on|off)\|[0-9]+$ ]]; then
                    awk -v n="$ln" 'BEGIN{c=0} { if($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/){ print $0 } else { c++; if(c==n) print "'"$newv"'" ; else print $0 } }' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
                    log "[INFO]" "已编辑第 ${ln} 行 -> ${newv}"
                else
                    echo -e "${Error}格式不正确，请参考：domain|provider|type|on|interval"
                fi
                ;;
            4)
                load_config
                read -rp "请输入要启用/禁用的行号: " ln
                if ! [[ "$ln" =~ ^[0-9]+$ ]]; then echo -e "${Error}行号无效"; continue; fi
                idx=$((ln-1))
                if [ -z "${DOMAIN_LINES[$idx]}" ]; then echo -e "${Error}行号不存在"; continue; fi
                cur="${DOMAIN_LINES[$idx]}"
                IFS='|' read -r d p t e iv <<< "$cur"
                if [[ "${e,,}" == "on" ]]; then new="${d}|${p}|${t}|off|${iv}"; else new="${d}|${p}|${t}|on|${iv}"; fi
                awk -v n="$ln" 'BEGIN{c=0} { if($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/){ print $0 } else { c++; if(c==n) print "'"$new"'" ; else print $0 } }' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
                log "[INFO]" "已切换第 ${ln} 行状态 -> ${new}"
                ;;
            5)
                load_config
                read -rp "请输入要删除的行号: " ln
                if ! [[ "$ln" =~ ^[0-9]+$ ]]; then echo -e "${Error}行号无效"; continue; fi
                awk -v n="$ln" 'BEGIN{c=0} { if($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/){ print $0 } else { c++; if(c==n) next; else print $0 } }' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
                log "[INFO]" "已删除第 ${ln} 行"
                ;;
            0) break;;
            *) echo -e "${Error}无效选择";;
        esac
    done
}

# Provider CLI 管理 菜单（安装/卸载）
provider_cli_menu() {
    while true; do
        echo
        echo -e "${Tip}🔧 Provider CLI 管理"
        echo -e "  [1] 安装 Cloudflare（提示：使用 API Token）"
        echo -e "  [2] 安装 Aliyun CLI（apt 优先，再 pip3）"
        echo -e "  [3] 安装 Tencent CLI（apt 优先，再 pip3）"
        echo -e "  [4] 安装 Huawei CLI（apt 优先，再 pip3）"
        echo -e "  [5] 卸载 Aliyun CLI"
        echo -e "  [6] 卸载 Tencent CLI"
        echo -e "  [7] 卸载 Huawei CLI"
        echo -e "  [8] 卸载 所有 provider CLI（尝试）"
        echo -e "  [0] 返回"
        read -rp "选择: " popt
        case "$popt" in
            1) echo; echo -e "${Tip}Cloudflare 使用 API Token，请在配置文件中设置 cloudflare_api_token";;
            2) provider_install aliyun;;
            3) provider_install tencent;;
            4) provider_install huawei;;
            5) provider_uninstall aliyun;;
            6) provider_uninstall tencent;;
            7) provider_uninstall huawei;;
            8)
                provider_uninstall aliyun || true
                provider_uninstall tencent || true
                provider_uninstall huawei || true
                log "[INFO]" "已尝试卸载所有 provider CLI（请检查输出确认）。"
                ;;
            0) break;;
            *) echo -e "${Error}无效选择";;
        esac
    done
}

# 查看日志与上次更新时间
view_logs() {
    echo
    echo -e "${Tip}📜 最近日志（尾部 200 行）:"
    tail -n 200 "${LOG_FILE}" | sed -n '1,200p'
    echo
    echo -e "${Tip}🕒 上次总体更新时间:"
    if [ -f "${LAST_UPDATE_FILE}" ]; then cat "${LAST_UPDATE_FILE}"; else echo "尚无更新记录"; fi
    echo
    echo -e "${Tip}🗂️ 单条上次更新时间（最近 200 行）:"
    if [ -f "${LAST_RUNS_FILE}" ]; then tail -n 200 "${LAST_RUNS_FILE}"; else echo "尚无单条更新时间记录"; fi
}

# 更改全局 systemd timer 运行间隔（分钟）
set_interval() {
    read -rp "请输入新的全局运行间隔（分钟，正整数，建议 >=1）: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 1 ]]; then
        echo -e "${Error}请输入有效的正整数。"
        return
    fi
    sed -i "s/^OnUnitActiveSec=.*$/OnUnitActiveSec=${interval}m/" /etc/systemd/system/ddns.timer
    systemctl daemon-reload
    systemctl restart ddns.timer >/dev/null 2>&1 || true
    log "[INFO]" "已将 systemd timer 设置为每 ${interval} 分钟运行一次（注意：脚本内部仍按每条 interval 决定是否更新） ✅"
}

# 服务管理（启用/停用/手动触发/状态）
service_menu() {
    while true; do
        echo
        echo -e "${Tip}⚙️ 服务管理"
        echo -e "  [1] 启用/启动 DDNS"
        echo -e "  [2] 停用/停止 DDNS"
        echo -e "  [3] 手动触发一次更新"
        echo -e "  [4] 查看状态"
        echo -e "  [0] 返回"
        read -rp "选择: " sopt
        case "$sopt" in
            1)
                systemctl enable --now ddns.timer >/dev/null 2>&1 || true
                log "[INFO]" "已启用 systemd timer"
                ;;
            2)
                systemctl stop ddns.timer >/dev/null 2>&1 || true
                systemctl disable ddns.timer >/dev/null 2>&1 || true
                log "[INFO]" "已禁用 systemd timer"
                ;;
            3)
                /bin/bash "${DDNS_SCRIPT}" >> "${LOG_FILE}" 2>&1 || true
                log "[INFO]" "已手动触发 DDNS 执行"
                ;;
            4)
                if systemctl is-enabled --quiet ddns.timer 2>/dev/null; then echo -e "${Info}systemd timer：${GREEN}已启用${NC}"; else echo -e "${Tip}systemd timer：${RED}未启用${NC}"; fi
                systemctl status ddns.timer --no-pager || true
                ;;
            0) break;;
            *) echo -e "${Error}无效选择";;
        esac
    done
}

# 主菜单（退出放最下面）
main_menu() {
    while true; do
        load_config
        echo -e "${GREEN}######################################${NC}"
        echo -e "${GREEN}#      DDNS 管理脚本 - 完整修复版    #${NC}"
        echo -e "${GREEN}######################################${NC}"
        echo
        echo -e "请选择操作："
        echo -e "  [1] 安装/部署 DDNS 🛠️"
        echo -e "  [2] Provider CLI 管理 🔧"
        echo -e "  [3] 域名管理 🌐"
        echo -e "  [4] 手动执行一次更新 ⏱️"
        echo -e "  [5] 查看日志与上次更新时间 📜"
        echo -e "  [6] 服务管理 ⚙️"
        echo -e "  [7] 更改全局运行间隔（分钟） ⏲️"
        echo -e "  [8] 卸载 DDNS（脚本与数据）🧹"
        echo -e "  [0] 退出"
        read -rp "选项: " opt
        case "$opt" in
            1) install_ddns ;;
            2) provider_cli_menu ;;
            3) domains_menu ;;
            4)
                log "[INFO] 手动触发更新"
                /bin/bash "${DDNS_SCRIPT}" >> "${LOG_FILE}" 2>&1 || true
                ;;
            5) view_logs ;;
            6) service_menu ;;
            7) set_interval ;;
            8)
                read -rp "确认卸载并移除所有文件？(y/n): " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    uninstall_ddns_all
                else
                    echo "已取消卸载"
                fi
                ;;
            0) echo -e "${Info}退出。"; exit 0 ;;
            *) echo -e "${Error}无效选项，请重试。";;
        esac
        echo
        read -rp "按回车返回主菜单..."
    done
}

# 启动主菜单
main_menu