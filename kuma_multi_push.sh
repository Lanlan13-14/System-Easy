#!/usr/bin/env bash

# =========================
# Uptime Kuma 多节点监控推送脚本
# 保存至：/usr/local/bin/kuma-ping
# 赋权：chmod +x /usr/local/bin/kuma-ping
# =========================

# 配置文件路径
CONFIG_FILE="/usr/local/etc/kuma_tasks.conf"
SERVICE_FILE="/etc/systemd/system/kuma-push.service"

# 默认配置
TASKS=()

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        mapfile -t TASKS < "$CONFIG_FILE"
    else
        # 创建默认配置
        cat > "$CONFIG_FILE" << EOF
# 格式：名称|API_URL|目标|模式|端口|间隔(秒)
# 示例：我的服务器|https://uptime.example.com/api/push/abc123|8.8.8.8|icmp|0|60
EOF
    fi
}

# 保存配置
save_config() {
    printf "%s\n" "${TASKS[@]}" > "$CONFIG_FILE"
}

# =========================
# 依赖检查与安装
# =========================

check_dependencies() {
    local missing=()

    # 检查 bc
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
    fi

    # 检查 tcptraceroute
    if ! command -v tcptraceroute &> /dev/null; then
        missing+=("tcptraceroute")
    fi

    # 检查 tcping
    if ! command -v tcping &> /dev/null; then
        missing+=("tcping")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "检测到缺少依赖: ${missing[*]}"
        install_dependencies
    else
        echo "所有依赖已安装。"
    fi
}

install_dependencies() {
    echo "开始安装依赖..."

    # 检测系统包管理器
    if command -v apt &> /dev/null; then
        sudo apt update
        sudo apt install -y bc tcptraceroute
    elif command -v yum &> /dev/null; then
        sudo yum install -y bc tcptraceroute
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y bc tcptraceroute
    else
        echo "无法自动安装依赖，请手动安装：bc 和 tcptraceroute"
    fi

    # 安装 tcping 脚本
    if [ ! -f "/usr/bin/tcping" ]; then
        echo "安装 tcping 脚本..."
        sudo wget -O /usr/bin/tcping https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/tcping.sh
        sudo chmod +x /usr/bin/tcping
    fi

    echo "依赖安装完成！"
}

# =========================
# 函数区
# =========================

get_icmp_ping() {
    ping -c 1 -W 1 "$1" 2>/dev/null | \
    grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}'
}

get_tcp_ping() {
    if ! command -v tcping &> /dev/null; then
        echo "tcping 未安装" >&2
        return 1
    fi

    RESULT=$(tcping -p "$2" "$1" -c 3 2>/dev/null)

    echo "$RESULT" | grep -q "round-trip" || return 1

    echo "$RESULT" | \
    grep "round-trip" | \
    awk -F'=' '{print $2}' | \
    awk -F'/' '{print $2}' | \
    awk '{print $1}'
}

# =========================
# 推送函数（串行推送，失败立即重试最多5次）
# =========================

push_to_kuma() {
    local api="$1"
    local status="$2"
    local msg="$3"
    local ping="$4"
    local name="$5"

    local max_retries=5
    local timeout=10
    local retry_count=0
    local success=false

    for retry_count in $(seq 1 $max_retries); do
        # 使用 curl 推送，设置超时时间
        if curl -s -f -o /dev/null \
            --connect-timeout 5 \
            --max-time $timeout \
            "${api}?status=${status}&msg=${msg}&ping=${ping}" 2>/dev/null; then
            
            success=true
            if [ $retry_count -gt 1 ]; then
                echo "[$(date '+%F %T')] [$name] 推送成功（第${retry_count}次尝试）"
            fi
            break
        else
            # 推送失败，立即重试（不等待）
            if [ $retry_count -lt $max_retries ]; then
                echo "[$(date '+%F %T')] [$name] 推送失败，立即重试（${retry_count}/${max_retries}）" >&2
                # 不等待，立即继续下一次重试
            else
                echo "[$(date '+%F %T')] [$name] 推送失败，已重试${max_retries}次" >&2
                # 记录到失败日志文件
                echo "[$(date '+%F %T')] [$name] 推送失败 API:${api} STATUS:${status} MSG:${msg} PING:${ping}" >> /var/log/kuma-push.errors.log 2>/dev/null
            fi
        fi
    done

    if $success; then
        return 0
    else
        return 1
    fi
}

# =========================
# 系统服务管理
# =========================

setup_service() {
    # 获取当前脚本路径
    local script_path=$(readlink -f "$0")

    # 创建 systemd 服务文件
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Uptime Kuma Multi Push Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$script_path --daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    echo "服务文件已创建：$SERVICE_FILE"
}

enable_service() {
    setup_service
    sudo systemctl enable kuma-push.service
    sudo systemctl start kuma-push.service
    echo "开机自启已启用，服务已启动。"
}

disable_service() {
    sudo systemctl stop kuma-push.service
    sudo systemctl disable kuma-push.service
    echo "开机自启已禁用，服务已停止。"
}

start_service() {
    if [ -f "$SERVICE_FILE" ]; then
        sudo systemctl start kuma-push.service
        echo "服务已启动。"
    else
        echo "服务未安装，请先设置开机自启动（选项6）。"
    fi
}

stop_service() {
    if [ -f "$SERVICE_FILE" ]; then
        sudo systemctl stop kuma-push.service
        echo "服务已停止。"
    else
        echo "服务未安装。"
    fi
}

restart_service() {
    if [ -f "$SERVICE_FILE" ]; then
        sudo systemctl restart kuma-push.service
        echo "服务已重启。"
    else
        echo "服务未安装，请先设置开机自启动（选项6）。"
    fi
}

service_status() {
    if [ -f "$SERVICE_FILE" ]; then
        echo "服务状态："
        sudo systemctl status kuma-push.service --no-pager
    else
        echo "服务未安装。"
    fi
}

# =========================
# 任务管理函数
# =========================

list_tasks() {
    load_config
    echo "=============================="
    echo "当前监控任务列表："
    echo "=============================="
    if [ ${#TASKS[@]} -eq 0 ] || [ ${#TASKS[@]} -eq 1 ] && [ -z "${TASKS[0]}" ]; then
        echo "暂无监控任务。"
    else
        local i=1
        for task in "${TASKS[@]}"; do
            if [ -n "$task" ] && [[ ! "$task" =~ ^# ]]; then
                IFS='|' read -r name api target mode port interval <<< "$task"
                echo "[$i] 名称：$name"
                echo "    目标：$target"
                echo "    模式：$mode"
                [ "$mode" = "tcping" ] && echo "    端口：$port"
                echo "    间隔：${interval}秒"
                echo "    API：${api:0:50}..."
                echo "------------------------------"
                ((i++))
            fi
        done
    fi
}

add_task() {
    load_config
    echo "添加新监控任务："
    echo "=============================="

    read -p "监控名称: " name
    read -p "Kuma API地址: " api
    read -p "目标IP/域名: " target
    read -p "模式 [1]icmp [2]tcping (默认: 1): " mode_choice
    case $mode_choice in
        2) mode="tcping" ;;
        *) mode="icmp" ;;
    esac

    port="0"
    if [ "$mode" = "tcping" ]; then
        read -p "TCP端口: " port
    fi

    read -p "监控间隔(秒, 默认60): " interval
    interval=${interval:-60}

    # 验证输入
    if [ -z "$name" ] || [ -z "$api" ] || [ -z "$target" ]; then
        echo "错误：名称、API地址和目标不能为空！"
        return 1
    fi

    # 添加到配置
    local new_task="$name|$api|$target|$mode|$port|$interval"
    TASKS+=("$new_task")
    save_config

    echo "任务添加成功！"
}

edit_task() {
    load_config
    list_tasks

    read -p "请选择要编辑的任务编号: " choice

    local i=1
    local valid_tasks=()
    for task in "${TASKS[@]}"; do
        if [ -n "$task" ] && [[ ! "$task" =~ ^# ]]; then
            valid_tasks[$i]="$task"
            ((i++))
        fi
    done

    if [ -z "${valid_tasks[$choice]}" ]; then
        echo "无效的选择！"
        return 1
    fi

    local old_task="${valid_tasks[$choice]}"
    IFS='|' read -r name api target mode port interval <<< "$old_task"

    echo "编辑任务 (直接回车保持不变):"
    echo "原名称: $name"
    read -p "新名称: " new_name
    name=${new_name:-$name}

    echo "原API: $api"
    read -p "新API: " new_api
    api=${new_api:-$api}

    echo "原目标: $target"
    read -p "新目标: " new_target
    target=${new_target:-$target}

    echo "原模式: $mode"
    read -p "新模式 [1]icmp [2]tcping: " mode_choice
    if [ -n "$mode_choice" ]; then
        case $mode_choice in
            2) mode="tcping" ;;
            1) mode="icmp" ;;
        esac
    fi

    if [ "$mode" = "tcping" ]; then
        echo "原端口: $port"
        read -p "新端口: " new_port
        port=${new_port:-$port}
    else
        port="0"
    fi

    echo "原间隔: ${interval}秒"
    read -p "新间隔: " new_interval
    interval=${new_interval:-$interval}

    # 替换旧任务
    local new_task="$name|$api|$target|$mode|$port|$interval"
    for idx in "${!TASKS[@]}"; do
        if [ "${TASKS[$idx]}" = "$old_task" ]; then
            TASKS[$idx]="$new_task"
            break
        fi
    done

    save_config
    echo "任务编辑成功！"
}

delete_task() {
    load_config
    list_tasks

    read -p "请选择要删除的任务编号: " choice

    local i=1
    local valid_indices=()
    for idx in "${!TASKS[@]}"; do
        if [ -n "${TASKS[$idx]}" ] && [[ ! "${TASKS[$idx]}" =~ ^# ]]; then
            valid_indices[$i]=$idx
            ((i++))
        fi
    done

    if [ -z "${valid_indices[$choice]}" ]; then
        echo "无效的选择！"
        return 1
    fi

    local idx=${valid_indices[$choice]}
    echo "确认删除任务: ${TASKS[$idx]%%|*}"
    read -p "确定删除？[y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        unset 'TASKS[$idx]'
        save_config
        echo "任务已删除。"
    fi
}

# =========================
# 主逻辑（串行推送）
# =========================

run_daemon() {
    echo "启动 Kuma 推送守护进程..."
    echo "日志文件: /var/log/kuma-push.log"
    echo "错误日志: /var/log/kuma-push.errors.log"

    # 检查依赖
    check_dependencies

    declare -A LAST_RUN
    local log_file="/var/log/kuma-push.log"
    local error_log="/var/log/kuma-push.errors.log"
    local push_queue=()  # 推送队列

    # 创建日志文件（如果不存在）
    touch "$log_file" "$error_log" 2>/dev/null || true

    while true; do
        NOW=$(date +%s)
        load_config

        # 第一步：收集所有需要检测的任务
        local tasks_to_check=()
        for TASK in "${TASKS[@]}"; do
            # 跳过注释和空行
            [[ "$TASK" =~ ^# ]] && continue
            [ -z "$TASK" ] && continue

            IFS='|' read -r NAME API TARGET MODE PORT INTERVAL <<< "$TASK"

            # 参数验证
            [ -z "$NAME" ] || [ -z "$API" ] || [ -z "$TARGET" ] && continue

            LAST=${LAST_RUN["$NAME"]}
            [ -z "$LAST" ] && LAST=0

            # 时间没到就跳过
            if (( NOW - LAST >= INTERVAL )); then
                tasks_to_check+=("$TASK")
                LAST_RUN["$NAME"]=$NOW
            fi
        done

        # 第二步：串行执行检测和推送（避免并发推送）
        for TASK in "${tasks_to_check[@]}"; do
            IFS='|' read -r NAME API TARGET MODE PORT INTERVAL <<< "$TASK"

            # 执行检测
            if [ "$MODE" = "icmp" ]; then
                PING=$(get_icmp_ping "$TARGET")
            else
                PING=$(get_tcp_ping "$TARGET" "$PORT")
            fi

            # 状态判断
            if [ -n "$PING" ]; then
                STATUS="up"
                MSG="OK"
            else
                STATUS="down"
                MSG="timeout"
                PING=""
            fi

            # 输出检测结果到日志
            echo "[$(date '+%F %T')] [$NAME] 检测结果: $TARGET $STATUS ${PING}ms" >> "$log_file"

            # 串行推送：每个任务检测完成后立即推送（带5次重试）
            push_to_kuma "$API" "$STATUS" "$MSG" "$PING" "$NAME"
            
            # 短暂延迟，避免推送过于密集
            sleep 1
        done

        # 如果没有任务需要执行，短暂休眠
        if [ ${#tasks_to_check[@]} -eq 0 ]; then
            sleep 5
        fi
    done
}

# =========================
# 菜单
# =========================

show_menu() {
    clear
    echo "====================================="
    echo "      Uptime Kuma 监控管理工具"
    echo "====================================="
    echo "[1] 列出所有监控任务"
    echo "[2] 添加监控任务"
    echo "[3] 编辑监控任务"
    echo "[4] 删除监控任务"
    echo "[5] 检查/安装依赖"
    echo "[6] 设置开机自启动"
    echo "[7] 禁用开机自启动"
    echo "[8] 启动服务"
    echo "[9] 停止服务"
    echo "[10] 重启服务"
    echo "[11] 查看服务状态"
    echo "[0] 退出"
    echo "====================================="
}

# =========================
# 主程序入口
# =========================

case "$1" in
    --daemon)
        run_daemon
        ;;
    *)
        # 交互式菜单
        while true; do
            show_menu
            read -p "请选择操作 [0-11]: " choice

            case $choice in
                1) list_tasks && read -p "按回车键继续..." ;;
                2) add_task && read -p "按回车键继续..." ;;
                3) edit_task && read -p "按回车键继续..." ;;
                4) delete_task && read -p "按回车键继续..." ;;
                5) check_dependencies && read -p "按回车键继续..." ;;
                6) enable_service && read -p "按回车键继续..." ;;
                7) disable_service && read -p "按回车键继续..." ;;
                8) start_service && read -p "按回车键继续..." ;;
                9) stop_service && read -p "按回车键继续..." ;;
                10) restart_service && read -p "按回车键继续..." ;;
                11) service_status && read -p "按回车键继续..." ;;
                0) echo "再见！下次使用请输入kuma-ping"; exit 0 ;;
                *) echo "无效选择！" && sleep 2 ;;
            esac
        done
        ;;
esac