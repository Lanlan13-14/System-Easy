#!/usr/bin/env bash

port=80
count=0
interval=1
timeout=3
seq=0
sent=0
ok=0
min=-1
max=0
sum=0
quiet=0
rtts=()  # 用于存储所有成功 RTT 值的数组

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

while getopts "c:i:p:qt:h" opt; do
case $opt in
c) count=$OPTARG ;;
i) interval=$OPTARG ;;
p) port=$OPTARG ;;
t) timeout=$OPTARG ;;
q) quiet=1 ;;
h) usage ;;
*) usage ;;
esac
done
shift $((OPTIND-1))

dest="$1"
[ -z "$dest" ] && usage

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
rtts+=("$rtt")  # 保存 RTT 值用于计算 mdev

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
if (( $(echo "$val < $avg" | bc) )); then
diff=$(echo "$avg - $val" | bc)
else
diff=$(echo "$val - $avg" | bc)
fi
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

while :; do
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
# 修复 -c 不生效：改用 sent 判断已发送次数
[ "$count" -gt 0 ] && [ "$sent" -ge "$count" ] && break
sleep "$interval"
done

print_stats