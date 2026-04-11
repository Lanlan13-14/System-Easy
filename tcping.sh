#!/usr/bin/env bash

port=80
count=0
interval=1
timeout=3
quiet=0
rtts=()
ipver=""

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
  -4          force IPv4
  -6          force IPv6
  -h          print help and exit
EOF
exit 0
}

ARGS=$(getopt -o c:i:p:t:q46h --long help -n "tcping" -- "$@")
[ $? -ne 0 ] && exit 1
eval set -- "$ARGS"

while true; do
    case "$1" in
        -c) count="$2"; shift 2 ;;
        -i) interval="$2"; shift 2 ;;
        -p) port="$2"; shift 2 ;;
        -t) timeout="$2"; shift 2 ;;
        -q) quiet=1; shift ;;
        -4) ipver="4"; shift ;;
        -6) ipver="6"; shift ;;
        -h|--help) usage ;;
        --) shift; break ;;
        *) echo "Internal error!"; exit 1 ;;
    esac
done

dest="$1"
[ -z "$dest" ] && usage

command -v tcptraceroute >/dev/null 2>&1 || { echo "Error: tcptraceroute not installed"; exit 1; }
command -v bc >/dev/null 2>&1 || { echo "Error: bc not installed"; exit 1; }

if [[ "$ipver" == "4" ]]; then
    resolved=$(getent ahosts "$dest" | awk '$2=="STREAM" && $1 ~ /\./ {print $1; exit}')
elif [[ "$ipver" == "6" ]]; then
    resolved=$(getent ahosts "$dest" | awk '$2=="STREAM" && $1 ~ /:/ {print $1; exit}')
else
    resolved="$dest"
fi

[ -z "$resolved" ] && { echo "Failed to resolve host for IPv${ipver:-default}"; exit 1; }
dest="$resolved"

fmt2() { printf "%.2f" "$1"; }

update_stats() {
    rtt="$1"
    ((ok++))
    sum=$(echo "$sum + $rtt" | bc)
    rtts+=("$rtt")
    if (( $(echo "$min < 0 || $rtt < $min" | bc) )); then min=$rtt; fi
    if (( $(echo "$rtt > $max" | bc) )); then max=$rtt; fi
}

print_stats() {
    if [ "$ok" -gt 0 ]; then
        avg=$(echo "scale=4; $sum / $ok" | bc)
    else
        avg=0; min=0; max=0
    fi
    fail=$((sent-ok))
    loss=$(echo "scale=2; if ($sent>0) $fail*100/$sent else 0" | bc)
    mdev=0
    if [ "$ok" -gt 0 ]; then
        sum_abs=0
        for val in "${rtts[@]}"; do
            diff=$(echo "scale=4; if ($val>$avg) ($val-$avg) else ($avg-$val)" | bc)
            sum_abs=$(echo "$sum_abs+$diff" | bc)
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

sent=0
ok=0
min=-1
max=0
sum=0
seq=0

while :; do
    out=$(tcptraceroute -n -f 255 -m 255 -q 1 -w "$timeout" "$dest" "$port" 2>&1)
    last_line=$(echo "$out" | tail -n1)
    
    ((sent++))
    
    # 判断成功：看到 [open] 或到达目标 IP
    if echo "$last_line" | grep -q "\[open\]" || echo "$last_line" | grep -q "$dest"; then
        # 取最后一个 RTT（到达目标的完整延迟）
        rtt=$(echo "$last_line" | awk '{for(i=NF;i>=1;i--) if($i ~ /ms/) {print $(i-1); exit}}')
        if [[ -n "$rtt" ]]; then
            rtt_fmt=$(fmt2 "$rtt")
            [ "$quiet" -eq 0 ] && echo "connected to $dest:$port, seq=$seq time=${rtt_fmt} ms"
            update_stats "$rtt"
        else
            [ "$quiet" -eq 0 ] && echo "connected to $dest:$port, seq=$seq (no RTT data)"
        fi
    else
        [ "$quiet" -eq 0 ] && echo "no response from $dest:$port, seq=$seq"
    fi
    
    ((seq++))
    [ "$count" -gt 0 ] && [ "$sent" -ge "$count" ] && break
    sleep "$interval"
done

print_stats