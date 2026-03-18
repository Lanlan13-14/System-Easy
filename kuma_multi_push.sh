#!/usr/bin/env bash

# =========================
# 配置区（按格式一条一条加）
# 格式：
# 名称|API_URL|目标|模式|端口|间隔(秒)
# =========================
# Tips
# 保存至/usr/local/bin/kuma_multi_push.sh
# 赋权 chmod +x /usr/local/bin/kuma_multi_push.sh
# 运行 nohup /usr/local/bin/kuma_multi_push.sh > /dev/null 2>&1 &
# 也可自行写systemd
# tcping模式需要依赖主页有

TASKS=(
"<name>|https://example.com/api/push/<token>|<ip>|<icmp|tcping>|<port>|<time>"
)

# =========================
# 函数区
# =========================

get_icmp_ping() {
    ping -c 1 -W 1 "$1" 2>/dev/null | \
    grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}'
}

get_tcp_ping() {
    RESULT=$(tcping -p "$2" "$1" -c 3 2>/dev/null)

    echo "$RESULT" | grep -q "round-trip" || return

    echo "$RESULT" | \
    grep "round-trip" | \
    awk -F'=' '{print $2}' | \
    awk -F'/' '{print $2}' | \
    awk '{print $1}'
}

# =========================
# 主逻辑（多任务调度）
# =========================

declare -A LAST_RUN

while true; do
    NOW=$(date +%s)

    for TASK in "${TASKS[@]}"; do
        IFS='|' read -r NAME API TARGET MODE PORT INTERVAL <<< "$TASK"

        LAST=${LAST_RUN["$NAME"]}
        [ -z "$LAST" ] && LAST=0

        # 时间没到就跳过
        if (( NOW - LAST < INTERVAL )); then
            continue
        fi

        LAST_RUN["$NAME"]=$NOW

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

        # 上报到 Kuma（注意这里自动拼接参数）
        curl -s "${API}?status=${STATUS}&msg=${MSG}&ping=${PING}" >/dev/null

        echo "[$(date '+%F %T')] [$NAME] $TARGET $STATUS ${PING}ms"
    done

    sleep 1
done