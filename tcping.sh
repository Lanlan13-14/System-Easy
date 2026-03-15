#!/usr/bin/env bash

port=80
count=0
interval=1
timeout=3
quiet=0
rtts=()

usage() {
cat <<EOF
Usage:
tcping [options] <host>

Options:
  -c count    how many times to probe
  -i interval seconds between probes (default 1)
  -p port     port number (default 80)
  -q quiet    (only statistics)
  -t timeout  seconds per probe (default 3)
  -h          print help and exit
EOF
exit 0
}

# 使用 getopt 重新解析参数，支持选项和参数任意顺序
ARGS=$(getopt -o c:i:p:t:qh --long help -n "tcping" -- "$@")
if [ $? -ne 0 ]; then
    exit 1
fi
eval set -- "$ARGS"

while true; do
    case "$1" in
        -c) count="$2"; shift 2 ;;
        -i) interval="$2"; shift 2 ;;
        -p) port="$2"; shift 2 ;;
        -t) timeout="$2"; shift 2 ;;
        -q) quiet=1; shift ;;
        -h|--help) usage ;;
        --) shift; break ;;
        *) echo "Internal error!"; exit 1 ;;
    esac
done

# 剩余的第一个参数是目标地址
dest="$1"
[ -z "$dest" ] && usage

# 检查 tcptraceroute 是否安装
command -v tcptraceroute >/dev/null 2>&1 || {
    echo "Error: tcptraceroute not installed"
    exit 1
}

fmt2() {
    printf "%.2f" "$1"
}

update_stats() {
    rtt="$1"
    ((ok++))
    sum=$(echo "$sum + $rtt" | bc)
    rtts+=("$rtt")

    if (( $(echo "$min < 0 || $rtt < $min" | bc) )); then
        min=$rtt
    fi
    if (( $(echo "$rtt > $max" | bc) )); then
        max=$rtt
    fi
}

print_stats() {
    if [ "$ok" -gt 0 ]; then
        avg=$(echo "scale=4; $sum / $ok" | bc)
    else
        avg=0
        min=0
        max=0
    fi

    fail=$((sent-ok))
    if [ "$sent" -gt 0 ]; then
        loss=$(echo "scale=2; $fail*100/$sent" | bc)
    else
        loss=0
    fi

    # 计算平均偏差 mdev
    mdev=0
    if [ "$ok" -gt 0 ]; then
        sum_abs=0
        for val in "${rtts[@]}"; do
            # 使用 bc 条件表达式计算绝对值
            diff=$(echo "scale=4; if ($val > $avg) ($val - $avg) else ($avg - $val)" | bc)
            sum_abs=$(echo "$sum_abs + $diff" | bc)
        done
        mdev=$(echo "scale=4; $sum_abs / $ok" | bc)
    fi

    printf -- "--- %s:%s tcping statistics ---\n" "$dest" "$port"
    printf "%d probes, %d success, %d failed (%.2f%% loss)\n" "$sent" "$ok" "$fail" "$loss"
    printf "round-trip min/avg/max/mdev = %s/%s/%s/%s ms\n" "$(fmt2 "$min")" "$(fmt2 "$avg")" "$(fmt2 "$max")" "$(fmt2 "$mdev")"
    exit 0
}

trap print_stats INT TERM

[ "$quiet" -eq 0 ] && echo "tcping $dest:$port"

# 初始化统计变量
sent=0
ok=0
min=-1
max=0
sum=0
seq=0

while :; do
    # 执行 tcptraceroute 并提取 RTT
    out=$(tcptraceroute -n -f 255 -m 255 -q 1 -w "$timeout" "$dest" "$port" 2>/dev/null)
    rtt=$(echo "$out" | sed 's/.*] //' | awk '{print $1}')

    ((sent++))

    if [[ "$rtt" =~ ^[0-9.]+$ ]]; then
        rtt_fmt=$(fmt2 "$rtt")
        [ "$quiet" -eq 0 ] && echo "connected to $dest:$port, seq=$seq time=${rtt_fmt} ms"
        update_stats "$rtt"
    else
        [ "$quiet" -eq 0 ] && echo "no response from $dest:$port, seq=$seq"
    fi

    ((seq++))
    # 使用 sent 判断是否达到指定次数，修复 -c 不生效问题
    [ "$count" -gt 0 ] && [ "$sent" -ge "$count" ] && break
    sleep "$interval"
done

print_stats