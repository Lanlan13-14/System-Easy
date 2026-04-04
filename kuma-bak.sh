#!/usr/bin/env bash

# =========================
# Uptime Kuma 多节点监控推送脚本
# 优化版：串行推送 + HTTP状态码检测 + 日志查看 + 日志清理（单备份）
# 保存至：/usr/local/bin/kuma-ping
# 赋权：chmod +x /usr/local/bin/kuma-ping
# =========================

# 配置文件路径
CONFIG_FILE="/usr/local/etc/kuma_tasks.conf"
SERVICE_FILE="/etc/systemd/system/kuma-push.service"
LOG_FILE="/var/log/kuma-push.log"
ERROR_LOG="/var/log/kuma-push.errors.log"
DEBUG_LOG="/var/log/kuma-push.debug.log"
CLEANUP_CONFIG="/usr/local/etc/kuma_cleanup.conf"

# 默认配置
TASKS=()
PUSH_STATS=()  # 推送统计

# 日志清理默认配置
LOG_RETENTION_DAYS=30
LOG_MAX_SIZE_MB=100
AUTO_CLEANUP_ENABLED=true
LAST_CLEANUP_DATE=""

# =========================
# 初始化
# =========================

init_logs() {
    touch "$LOG_FILE" "$ERROR_LOG" "$DEBUG_LOG" 2>/dev/null || true
    load_cleanup_config
}

# =========================
# 加载配置
# =========================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        mapfile -t TASKS < "$CONFIG_FILE"
    else
        # 创建默认配置
        cat > "$CONFIG_FILE" << 'EOF'
# Uptime Kuma Push 监控配置
# 格式：名称|API_URL|目标|模式|端口|间隔(秒)
# 示例：我的服务器|https://uptime.example.com/api/push/abc123|8.8.8.8|icmp|0|60
EOF
    fi
}

# 加载日志清理配置
load_cleanup_config() {
    if [ -f "$CLEANUP_CONFIG" ]; then
        source "$CLEANUP_CONFIG"
    else
        # 创建默认清理配置
        cat > "$CLEANUP_CONFIG" << EOF
# 日志清理配置
LOG_RETENTION_DAYS=30
LOG_MAX_SIZE_MB=100
AUTO_CLEANUP_ENABLED=true
LAST_CLEANUP_DATE=""
EOF
    fi
}

# 保存清理配置
save_cleanup_config() {
    cat > "$CLEANUP_CONFIG" << EOF
# 日志清理配置
LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS
LOG_MAX_SIZE_MB=$LOG_MAX_SIZE_MB
AUTO_CLEANUP_ENABLED=$AUTO_CLEANUP_ENABLED
LAST_CLEANUP_DATE="$LAST_CLEANUP_DATE"
EOF
}

# 保存配置
save_config() {
    printf "%s\n" "${TASKS[@]}" > "$CONFIG_FILE"
}

# =========================
# 统一的日志备份函数（只保留一个最新备份）
# =========================

# 创建日志备份（会覆盖旧备份）
create_single_backup() {
    local log_file="$1"
    local backup_dir="/var/log/kuma-backup"
    local backup_name="$(basename "$log_file").backup.gz"
    local backup_path="$backup_dir/$backup_name"

    mkdir -p "$backup_dir"

    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        # 压缩备份（会覆盖旧的备份文件）
        if gzip -c "$log_file" > "$backup_path" 2>/dev/null; then
            echo "[$(date '+%F %T')] 已更新备份: $backup_path" >> "$DEBUG_LOG"
            return 0
        fi
    fi
    return 1
}

# 轮转日志（保留指定行数，并创建备份）
rotate_log_with_backup() {
    local log_file="$1"
    local keep_lines=${2:-10000}

    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        # 创建备份（会覆盖旧备份）
        create_single_backup "$log_file"

        # 保留最近的行数
        tail -n $keep_lines "$log_file" > "${log_file}.tmp"
        mv "${log_file}.tmp" "$log_file"

        return 0
    fi
    return 1
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
# 日志清理函数（统一单备份策略）
# =========================

cleanup_logs() {
    echo "====================================="
    echo "        日志清理工具"
    echo "====================================="

    local before_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
    local before_error_size=$(du -h "$ERROR_LOG" 2>/dev/null | cut -f1)
    local before_debug_size=$(du -h "$DEBUG_LOG" 2>/dev/null | cut -f1)

    echo "清理前日志大小:"
    echo "  主日志: $before_size"
    echo "  错误日志: $before_error_size"
    echo "  调试日志: $before_debug_size"
    echo ""

    local cleaned=0

    # 按大小清理（超过限制时轮转）
    if [ $LOG_MAX_SIZE_MB -gt 0 ]; then
        local max_size_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))

        for log in "$LOG_FILE" "$ERROR_LOG" "$DEBUG_LOG"; do
            if [ -f "$log" ]; then
                local current_size=$(stat -c%s "$log" 2>/dev/null || stat -f%z "$log" 2>/dev/null)
                if [ "$current_size" -gt "$max_size_bytes" ]; then
                    echo "日志文件 $(basename "$log") 超过 ${LOG_MAX_SIZE_MB}MB，正在轮转..."

                    # 轮转日志（自动创建备份并保留最近10000行）
                    rotate_log_with_backup "$log" 10000

                    echo "  ✓ 已备份并截断日志"
                    cleaned=1
                fi
            fi
        done
    fi

    # 显示备份信息
    local backup_dir="/var/log/kuma-backup"
    if [ -d "$backup_dir" ]; then
        echo ""
        echo "当前备份文件:"
        ls -lh "$backup_dir"/*.backup.gz 2>/dev/null | awk '{print "  " $9 ": " $5}' || echo "  无备份文件"

        local backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
        echo "备份总大小: $backup_size"
    fi

    local after_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
    local after_error_size=$(du -h "$ERROR_LOG" 2>/dev/null | cut -f1)
    local after_debug_size=$(du -h "$DEBUG_LOG" 2>/dev/null | cut -f1)

    echo ""
    echo "清理后日志大小:"
    echo "  主日志: $after_size"
    echo "  错误日志: $after_error_size"
    echo "  调试日志: $after_debug_size"

    LAST_CLEANUP_DATE=$(date '+%Y-%m-%d %H:%M:%S')
    save_cleanup_config

    if [ $cleaned -eq 1 ]; then
        echo "✓ 日志清理完成"
    else
        echo "✓ 无需清理，日志文件大小在限制范围内"
    fi

    read -p "按回车键继续..."
}

configure_cleanup() {
    load_cleanup_config
    echo "====================================="
    echo "      日志清理配置"
    echo "====================================="
    echo "[1] 设置日志最大大小 (当前: ${LOG_MAX_SIZE_MB}MB)"
    echo "[2] 启用/禁用自动清理 (当前: ${AUTO_CLEANUP_ENABLED})"
    echo "[3] 立即执行清理"
    echo "[4] 查看备份文件"
    echo "[5] 恢复备份"
    echo "[0] 返回主菜单"
    echo "====================================="
    echo "注：备份策略为只保留一个最新备份文件"
    echo "====================================="

    read -p "请选择 [0-5]: " cleanup_choice

    case $cleanup_choice in
        1)
            read -p "请输入日志最大大小(MB) (0=不限制): " size
            if [[ "$size" =~ ^[0-9]+$ ]]; then
                LOG_MAX_SIZE_MB=$size
                save_cleanup_config
                echo "已设置日志最大 ${size}MB"
            else
                echo "无效输入！"
            fi
            sleep 1
            configure_cleanup
            ;;
        2)
            if [ "$AUTO_CLEANUP_ENABLED" = true ]; then
                AUTO_CLEANUP_ENABLED=false
                echo "已禁用自动清理"
            else
                AUTO_CLEANUP_ENABLED=true
                echo "已启用自动清理"
            fi
            save_cleanup_config
            sleep 1
            configure_cleanup
            ;;
        3)
            cleanup_logs
            configure_cleanup
            ;;
        4)
            echo "====================================="
            echo "备份文件列表:"
            ls -lh /var/log/kuma-backup/*.backup.gz 2>/dev/null || echo "无备份文件"
            echo "====================================="
            read -p "按回车键继续..."
            configure_cleanup
            ;;
        5)
            echo "====================================="
            echo "恢复备份（会覆盖当前日志）"
            echo "====================================="
            local backup_files=(/var/log/kuma-backup/*.backup.gz)
            if [ ${#backup_files[@]} -eq 0 ] || [ ! -f "${backup_files[0]}" ]; then
                echo "没有找到备份文件！"
            else
                echo "可恢复的备份文件:"
                local i=1
                for backup in "${backup_files[@]}"; do
                    if [ -f "$backup" ]; then
                        local backup_name=$(basename "$backup")
                        local backup_size=$(du -h "$backup" | cut -f1)
                        echo "[$i] $backup_name ($backup_size)"
                        ((i++))
                    fi
                done

                read -p "请选择要恢复的备份 [1-${#backup_files[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ $choice -le ${#backup_files[@]} ]; then
                    local selected_backup="${backup_files[$((choice-1))]}"
                    local log_name=$(basename "$selected_backup" .backup.gz)

                    echo "选择恢复: $log_name"
                    read -p "确认恢复？这将覆盖当前日志 [y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        # 先备份当前日志
                        local current_backup="/var/log/kuma-backup/${log_name}.before_restore.gz"
                        if [ -f "/var/log/$log_name" ]; then
                            gzip -c "/var/log/$log_name" > "$current_backup"
                            echo "已备份当前日志到: $current_backup"
                        fi

                        # 恢复备份
                        gunzip -c "$selected_backup" > "/var/log/$log_name"
                        echo "✓ 日志已恢复"
                    fi
                fi
            fi
            read -p "按回车键继续..."
            configure_cleanup
            ;;
        0)
            return
            ;;
        *)
            echo "无效选择！"
            sleep 1
            configure_cleanup
            ;;
    esac
}

# 自动清理检查（在守护进程中调用）
auto_cleanup_check() {
    if [ "$AUTO_CLEANUP_ENABLED" != true ]; then
        return
    fi

    # 检查上次清理时间，如果超过1天则执行清理
    local last_cleanup_ts=0
    if [ -n "$LAST_CLEANUP_DATE" ]; then
        last_cleanup_ts=$(date -d "$LAST_CLEANUP_DATE" +%s 2>/dev/null || echo 0)
    fi

    local current_ts=$(date +%s)
    local days_since_cleanup=$(( (current_ts - last_cleanup_ts) / 86400 ))

    if [ $days_since_cleanup -ge 1 ]; then
        echo "[$(date '+%F %T')] 执行自动日志清理..." >> "$LOG_FILE"

        # 按大小清理
        if [ $LOG_MAX_SIZE_MB -gt 0 ]; then
            local max_size_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))

            for log in "$LOG_FILE" "$ERROR_LOG" "$DEBUG_LOG"; do
                if [ -f "$log" ]; then
                    local current_size=$(stat -c%s "$log" 2>/dev/null || stat -f%z "$log" 2>/dev/null)
                    if [ "$current_size" -gt "$max_size_bytes" ]; then
                        # 轮转日志（只保留一个最新备份）
                        rotate_log_with_backup "$log" 5000
                        echo "[$(date '+%F %T')] 已轮转日志: $log" >> "$LOG_FILE"
                    fi
                fi
            done
        fi

        LAST_CLEANUP_DATE=$(date '+%Y-%m-%d %H:%M:%S')
        save_cleanup_config
        echo "[$(date '+%F %T')] 自动日志清理完成" >> "$LOG_FILE"
    fi
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
# 推送函数（优化版：HTTP状态码检测 + 指数退避）
# =========================

push_to_kuma() {
    local api="$1"
    local status="$2"
    local msg="$3"
    local ping="$4"
    local name="$5"

    local max_retries=5
    local retry_count=0
    local retry_delay=1
    local success=false
    local http_code=""

    # 构建完整 URL
    local url="${api}?status=${status}&msg=${msg}&ping=${ping}"

    for retry_count in $(seq 1 $max_retries); do
        # 执行 curl 请求，获取 HTTP 状态码
        http_code=$(curl -w "%{http_code}" \
            -o /dev/null \
            -s \
            --connect-timeout 5 \
            --max-time 10 \
            "$url" 2>/dev/null)

        local curl_exit=$?

        # 检查 curl 执行状态和 HTTP 状态码
        if [ $curl_exit -eq 0 ] && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            success=true
            if [ $retry_count -gt 1 ]; then
                echo "[$(date '+%F %T')] [$name] ✓ 推送成功（第${retry_count}次尝试，HTTP:$http_code）" >> "$LOG_FILE"
            fi
            break
        else
            # 推送失败
            if [ $retry_count -lt $max_retries ]; then
                local error_msg=""
                if [ $curl_exit -ne 0 ]; then
                    error_msg="curl错误码:$curl_exit"
                else
                    error_msg="HTTP:$http_code"
                fi
                echo "[$(date '+%F %T')] [$name] ✗ 推送失败 ($error_msg)，${retry_delay}秒后重试（${retry_count}/${max_retries}）" >> "$ERROR_LOG"
                sleep $retry_delay
                # 指数退避：1, 2, 4, 8 秒
                retry_delay=$((retry_delay * 2))
            else
                echo "[$(date '+%F %T')] [$name] ✗ 推送最终失败，已重试${max_retries}次" >> "$ERROR_LOG"
                if [ $curl_exit -ne 0 ]; then
                    echo "[$(date '+%F %T')] [$name] 详情: curl错误码=$curl_exit, URL=$url" >> "$ERROR_LOG"
                else
                    echo "[$(date '+%F %T')] [$name] 详情: HTTP=$http_code, URL=$url" >> "$ERROR_LOG"
                fi
                return 1
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
# 日志查看函数
# =========================

view_logs() {
    while true; do
        clear
        echo "====================================="
        echo "        日志查看工具"
        echo "====================================="
        echo "[1] 实时查看主日志 (tail -f)"
        echo "[2] 实时查看错误日志 (tail -f)"
        echo "[3] 查看最近50行主日志"
        echo "[4] 查看最近50行错误日志"
        echo "[5] 查看推送失败记录"
        echo "[6] 查看推送重试记录"
        echo "[7] 查看特定任务日志"
        echo "[8] 查看推送统计"
        echo "[9] 查看日志大小统计"
        echo "[10] 清空日志"
        echo "[11] 日志清理工具"
        echo "[0] 返回主菜单"
        echo "====================================="

        read -p "请选择 [0-11]: " log_choice

        case $log_choice in
            1)
                echo "实时查看主日志 (按 Ctrl+C 返回)..."
                tail -f "$LOG_FILE"
                ;;
            2)
                echo "实时查看错误日志 (按 Ctrl+C 返回)..."
                tail -f "$ERROR_LOG"
                ;;
            3)
                echo "最近50行主日志："
                tail -50 "$LOG_FILE"
                read -p "按回车键继续..."
                ;;
            4)
                echo "最近50行错误日志："
                tail -50 "$ERROR_LOG"
                read -p "按回车键继续..."
                ;;
            5)
                echo "推送失败记录："
                grep "✗ 推送" "$ERROR_LOG" | tail -20
                read -p "按回车键继续..."
                ;;
            6)
                echo "推送重试记录："
                grep "重试" "$ERROR_LOG" | tail -20
                read -p "按回车键继续..."
                ;;
            7)
                read -p "请输入任务名称: " task_name
                if [ -n "$task_name" ]; then
                    echo "任务 [$task_name] 的日志："
                    grep "\[$task_name\]" "$LOG_FILE" | tail -30
                    echo ""
                    echo "错误日志："
                    grep "\[$task_name\]" "$ERROR_LOG" | tail -10
                fi
                read -p "按回车键继续..."
                ;;
            8)
                echo "推送统计："
                echo "=============================="
                local total_push=$(grep "✓ 推送成功" "$LOG_FILE" | wc -l)
                local failed_push=$(grep "✗ 推送最终失败" "$ERROR_LOG" | wc -l)
                local retry_push=$(grep "重试" "$ERROR_LOG" | wc -l)
                echo "总推送次数: $total_push"
                echo "推送失败次数: $failed_push"
                echo "重试次数: $retry_push"
                if [ $total_push -gt 0 ]; then
                    local success_rate=$(( (total_push - failed_push) * 100 / total_push ))
                    echo "成功率: ${success_rate}%"
                fi
                echo "=============================="
                read -p "按回车键继续..."
                ;;
            9)
                echo "日志文件大小统计："
                echo "=============================="
                ls -lh "$LOG_FILE" "$ERROR_LOG" "$DEBUG_LOG" 2>/dev/null | awk '{print $9 ": " $5}'
                echo ""
                echo "备份文件："
                ls -lh /var/log/kuma-backup/*.backup.gz 2>/dev/null | awk '{print "  " $9 ": " $5}' || echo "  无备份文件"
                echo "=============================="
                read -p "按回车键继续..."
                ;;
            10)
                read -p "确认清空所有日志？[y/N] " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    # 清空前先备份
                    create_single_backup "$LOG_FILE"
                    create_single_backup "$ERROR_LOG"
                    create_single_backup "$DEBUG_LOG"

                    > "$LOG_FILE"
                    > "$ERROR_LOG"
                    > "$DEBUG_LOG"
                    echo "日志已清空，已创建备份"
                fi
                sleep 1
                ;;
            11)
                configure_cleanup
                ;;
            0)
                break
                ;;
            *)
                echo "无效选择！"
                sleep 1
                ;;
        esac
    done
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
StandardOutput=append:$LOG_FILE
StandardError=append:$ERROR_LOG

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
    echo "日志文件: $LOG_FILE"
    echo "错误日志: $ERROR_LOG"

    # 检查依赖
    check_dependencies

    # 初始化日志
    init_logs

    declare -A LAST_RUN

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
            echo "[$(date '+%F %T')] [$NAME] 检测: $TARGET -> $STATUS (${PING:-timeout}ms)" >> "$LOG_FILE"

            # 串行推送：每个任务检测完成后立即推送（带5次重试）
            push_to_kuma "$API" "$STATUS" "$MSG" "$PING" "$NAME"

            # 短暂延迟，避免推送过于密集
            sleep 1
        done

        # 执行自动日志清理检查
        auto_cleanup_check

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
    echo "[12] 查看日志"
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
            read -p "请选择操作 [0-12]: " choice

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
                12) view_logs ;;
                0) echo "再见！下次使用请输入kuma-ping"; exit 0 ;;
                *) echo "无效选择！" && sleep 2 ;;
            esac
        done
        ;;
esac