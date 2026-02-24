#!/usr/bin/env bash

port=80
count=0
interval=1
timeout=3
seq=0
sent=0
ok=0
min=0
max=0
sum=0

usage() {
cat <<EOF
Usage
tcping [options] <destination>

Options:
  <destination>      dns name or ip address
  -c <count>         count how many times to connect
  -f                 flood connect (no delays)
  -h                 print help and exit
  -i <interval>      interval delay between each connect (e.g. 1)
  -p <port>          portnr portnumber (e.g. 80)
  -q                 quiet, only returncode
  -t <timeout>       time to wait for response (e.g. 3)
EOF
exit 0
}

while getopts "c:fi:p:qt:h" opt; do
  case $opt in
    c) count=$OPTARG ;;
    i) interval=$OPTARG ;;
    p) port=$OPTARG ;;
    t) timeout=$OPTARG ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

dest="$1"
[ -z "$dest" ] && usage

echo "tcping $dest:$port"

update_stats() {
  rtt="$1"
  ((ok++))
  sum=$(echo "$sum + $rtt" | bc)

  if [ "$min" = "0" ] || (( $(echo "$rtt < $min" | bc) )); then
    min=$rtt
  fi
  if (( $(echo "$rtt > $max" | bc) )); then
    max=$rtt
  fi
}

print_stats() {
  if [ "$ok" -gt 0 ]; then
    avg=$(echo "scale=1; $sum / $ok" | bc)
  else
    avg=0
    min=0
    max=0
  fi
  fail=$((sent-ok))
  loss=$(echo "scale=2; $fail*100/$sent" | bc 2>/dev/null)
  echo "--- $dest:$port ping statistics ---"
  echo "$sent connects, $ok ok, $loss% failed"
  echo "round-trip min/avg/max = $min/$avg/$max ms"
  exit 0
}

trap print_stats INT

while :; do
  start=$(date +%s%3N)

  timeout "$timeout" bash -c "echo > /dev/tcp/$dest/$port" 2>/dev/null
  ret=$?

  end=$(date +%s%3N)
  rtt=$((end-start))
  sent=$((sent+1))

  if [ $ret -eq 0 ]; then
    ms=$(echo "scale=2; $rtt/1" | bc)
    echo "connected to $dest:$port, seq=$seq time=${ms} ms"
    update_stats "$ms"
  else
    echo "no response from $dest:$port, seq=$seq"
  fi

  ((seq++))
  [ "$count" -gt 0 ] && [ "$seq" -ge "$count" ] && break
  sleep "$interval"
done

print_stats