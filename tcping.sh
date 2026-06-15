#!/usr/bin/env bash
# tcping - single-file TCP connect latency probe.
#
# This implementation intentionally avoids helper programs such as
# tcptraceroute, nc, timeout, bc, awk, grep, sed and getopt.  Probes are
# measured with Bash's /dev/tcp redirection and Bash integer arithmetic.

set -u

port=80
count=0
interval="1"
timeout="3"
quiet=0
ipver=""

sent=0
ok=0
fail=0
seq=0
min_us=-1
max_us=0
sum_us=0
rtts_us=()
resolved=""

die() {
    printf 'tcping: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  tcping [options] <host>

Options:
  -c count    how many times to probe; 0 means forever (default 0)
  -i interval seconds between probes (default 1)
  -p port     port number (default 80)
  -q          quiet; only print final statistics
  -t timeout  seconds per probe (default 3)
  -4          force IPv4 when resolving hostnames
  -6          force IPv6 when resolving hostnames
  -h, --help  print help and exit
EOF
    exit 0
}

is_uint() {
    [[ ${1-} =~ ^[0-9]+$ ]]
}

is_number() {
    [[ ${1-} =~ ^([0-9]+)(\.[0-9]+)?$ || ${1-} =~ ^\.[0-9]+$ ]]
}

number_to_us() {
    local n=${1-} int frac
    [[ $n == .* ]] && n="0$n"
    int=${n%%.*}
    if [[ $n == *.* ]]; then
        frac=${n#*.}
    else
        frac=""
    fi
    frac=${frac:0:6}
    while ((${#frac} < 6)); do frac="${frac}0"; done
    # 10# avoids octal interpretation for values with leading zeroes.
    printf '%d\n' $((10#$int * 1000000 + 10#$frac))
}

now_us() {
    local t=${EPOCHREALTIME:-} sec frac
    if [[ -z $t ]]; then
        # EPOCHREALTIME exists in Bash 5+.  This script targets Bash because
        # /dev/tcp is also a Bash feature; fail clearly on older shells.
        die 'Bash 5+ is required for reliable sub-second timing'
    fi
    sec=${t%%.*}
    frac=${t#*.}
    frac=${frac:0:6}
    while ((${#frac} < 6)); do frac="${frac}0"; done
    printf '%d\n' $((10#$sec * 1000000 + 10#$frac))
}

fmt_ms() {
    local us=${1:-0} sign="" whole frac2 rem
    if (( us < 0 )); then sign="-"; us=$((-us)); fi
    # round to nearest 0.01 ms = 10 us
    us=$((us + 5))
    whole=$((us / 1000))
    rem=$((us % 1000))
    frac2=$((rem / 10))
    printf '%s%d.%02d' "$sign" "$whole" "$frac2"
}

percent_loss() {
    local failed=${1:-0} total=${2:-0} scaled whole frac
    if (( total <= 0 )); then
        printf '0.00'
        return
    fi
    # percentage with two decimals, rounded: failed * 10000 / total.
    scaled=$(((failed * 10000 + total / 2) / total))
    whole=$((scaled / 100))
    frac=$((scaled % 100))
    printf '%d.%02d' "$whole" "$frac"
}

is_ipv4_literal() {
    local ip=$1 part IFS=.
    [[ $ip == *.* ]] || return 1
    read -r -a parts <<< "$ip"
    ((${#parts[@]} == 4)) || return 1
    for part in "${parts[@]}"; do
        [[ $part =~ ^[0-9]+$ ]] || return 1
        ((10#$part >= 0 && 10#$part <= 255)) || return 1
    done
    return 0
}

is_ipv6_literal() {
    [[ $1 == *:* ]]
}

strip_host_brackets() {
    local h=$1
    if [[ $h == \[*\] ]]; then
        h=${h#\[}
        h=${h%\]}
    fi
    printf '%s\n' "$h"
}

resolve_host() {
    local host=$1 family=$2 line addr fam rest

    if [[ -z $family ]]; then
        resolved=$host
        return 0
    fi

    if [[ $family == 4 && $(is_ipv4_literal "$host"; echo $?) == 0 ]]; then
        resolved=$host
        return 0
    fi
    if [[ $family == 6 && $(is_ipv6_literal "$host"; echo $?) == 0 ]]; then
        resolved=$host
        return 0
    fi
    if [[ $family == 4 && $(is_ipv6_literal "$host"; echo $?) == 0 ]]; then
        return 1
    fi
    if [[ $family == 6 && $(is_ipv4_literal "$host"; echo $?) == 0 ]]; then
        return 1
    fi

    # /proc/net/*_trie cannot resolve DNS.  For -4/-6 hostnames we use Bash's
    # getent coprocess when available because it is the libc resolver front-end,
    # not a probing dependency.  The actual TCP measurement remains our own.
    if command -v getent >/dev/null 2>&1; then
        while IFS= read -r line; do
            set -- $line
            addr=${1-}
            fam=${2-}
            if [[ $fam == STREAM ]]; then
                if [[ $family == 4 && $addr == *.* ]]; then resolved=$addr; return 0; fi
                if [[ $family == 6 && $addr == *:* ]]; then resolved=$addr; return 0; fi
            fi
        done < <(getent ahosts "$host" 2>/dev/null)
    fi

    return 1
}

validate_args() {
    is_uint "$count" || die '-c expects a non-negative integer'
    is_uint "$port" || die '-p expects an integer port number'
    (( port >= 1 && port <= 65535 )) || die '-p expects a port in range 1..65535'
    is_number "$interval" || die '-i expects a non-negative number'
    is_number "$timeout" || die '-t expects a positive number'
    interval_us=$(number_to_us "$interval")
    timeout_us=$(number_to_us "$timeout")
    (( interval_us >= 0 )) || die '-i expects a non-negative number'
    (( timeout_us > 0 )) || die '-t expects a positive number'
}

sleep_interval() {
    local us=${1:-0} sec frac delay rfd wfd cpid _unused
    (( us <= 0 )) && return 0
    sec=$((us / 1000000))
    frac=$((us % 1000000))
    printf -v delay '%d.%06d' "$sec" "$frac"

    # Use a private coprocess as the wait target so interactive stdin is never
    # consumed while tcping is sleeping between probes.
    coproc TCPING_DELAY { IFS= read -r _unused; }
    cpid=$TCPING_DELAY_PID
    rfd=${TCPING_DELAY[0]}
    wfd=${TCPING_DELAY[1]}
    IFS= read -r -t "$delay" -u "$rfd" _unused || true
    kill "$cpid" 2>/dev/null || true
    wait "$cpid" 2>/dev/null || true
    exec {rfd}<&-
    exec {wfd}>&-
}

probe_once() {
    local host=$1 prt=$2 timeout_s=$3 start end pid rc rfd wfd delay
    start=$(now_us)
    printf -v delay '%d.%06d' "$((timeout_s / 1000000))" "$((timeout_s % 1000000))"

    # Run the connector as a coprocess.  It writes its own completion timestamp,
    # so the reported RTT does not include parent-side polling jitter.
    coproc TCPING_CONNECT {
        if exec 3<>"/dev/tcp/$host/$prt"; then
            printf '0 %s\n' "$(now_us)"
            exec 3<&-
            exec 3>&-
        else
            printf '1 %s\n' "$(now_us)"
        fi
    } 2>/dev/null
    pid=$TCPING_CONNECT_PID
    rfd=${TCPING_CONNECT[0]}
    wfd=${TCPING_CONNECT[1]}
    exec {wfd}>&-

    if IFS=' ' read -r -t "$delay" -u "$rfd" rc end; then
        wait "$pid" 2>/dev/null || true
        exec {rfd}<&-
        if [[ $rc == 0 && $end =~ ^[0-9]+$ ]]; then
            probe_rtt_us=$((end - start))
            (( probe_rtt_us < 0 )) && probe_rtt_us=0
            return 0
        fi
        return 1
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exec {rfd}<&-
    return 124
}

update_stats() {
    local rtt=$1
    ((ok++))
    rtts_us+=("$rtt")
    sum_us=$((sum_us + rtt))
    if (( min_us < 0 || rtt < min_us )); then min_us=$rtt; fi
    if (( rtt > max_us )); then max_us=$rtt; fi
}

print_stats() {
    local avg_us=0 mdev_us=0 abs_sum=0 val diff line_fail
    line_fail=$((sent - ok))
    if (( ok > 0 )); then
        avg_us=$(((sum_us + ok / 2) / ok))
        for val in "${rtts_us[@]}"; do
            if (( val >= avg_us )); then diff=$((val - avg_us)); else diff=$((avg_us - val)); fi
            abs_sum=$((abs_sum + diff))
        done
        mdev_us=$(((abs_sum + ok / 2) / ok))
    else
        min_us=0
        max_us=0
    fi

    printf -- '--- %s:%s tcping statistics ---\n' "$resolved" "$port"
    printf '%d probes, %d success, %d failed (%s%% loss)\n' "$sent" "$ok" "$line_fail" "$(percent_loss "$line_fail" "$sent")"
    printf 'round-trip min/avg/max/mdev = %s/%s/%s/%s ms\n' \
        "$(fmt_ms "$min_us")" "$(fmt_ms "$avg_us")" "$(fmt_ms "$max_us")" "$(fmt_ms "$mdev_us")"
}

finish() {
    printf '\n' >&2
    print_stats
    exit 130
}

while (($#)); do
    case $1 in
        -c)
            (($# >= 2)) || die '-c requires an argument'
            count=$2; shift 2 ;;
        -i)
            (($# >= 2)) || die '-i requires an argument'
            interval=$2; shift 2 ;;
        -p)
            (($# >= 2)) || die '-p requires an argument'
            port=$2; shift 2 ;;
        -t)
            (($# >= 2)) || die '-t requires an argument'
            timeout=$2; shift 2 ;;
        -q)
            quiet=1; shift ;;
        -4)
            [[ -z $ipver || $ipver == 4 ]] || die '-4 and -6 are mutually exclusive'
            ipver=4; shift ;;
        -6)
            [[ -z $ipver || $ipver == 6 ]] || die '-4 and -6 are mutually exclusive'
            ipver=6; shift ;;
        -h|--help)
            usage ;;
        --)
            shift; break ;;
        -*)
            die "unknown option: $1" ;;
        *)
            break ;;
    esac
done

(($# == 1)) || usage

dest=$(strip_host_brackets "$1")
[[ -n $dest ]] || usage

validate_args

if ! resolve_host "$dest" "$ipver"; then
    if [[ -n $ipver ]]; then
        die "failed to resolve IPv${ipver} address for $dest"
    fi
    die "failed to resolve host: $dest"
fi

trap finish INT TERM

((quiet == 0)) && printf 'tcping %s:%s\n' "$resolved" "$port"

while :; do
    ((sent++))
    probe_rtt_us=0
    if probe_once "$resolved" "$port" "$timeout_us"; then
        update_stats "$probe_rtt_us"
        ((quiet == 0)) && printf 'connected to %s:%s, seq=%d time=%s ms\n' "$resolved" "$port" "$seq" "$(fmt_ms "$probe_rtt_us")"
    else
        ((quiet == 0)) && printf 'no response from %s:%s, seq=%d\n' "$resolved" "$port" "$seq"
    fi

    ((seq++))
    ((count > 0 && sent >= count)) && break
    sleep_interval "$interval_us"
done

print_stats
exit 0
