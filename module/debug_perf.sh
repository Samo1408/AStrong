#!/system/bin/sh
# AlwaysStrong DEBUG profiler
# Low-overhead sampler for diagnosing battery drain / thermal load.
# Logs only process accounting, restart state and thermal/battery telemetry.

MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
CFG=/data/adb/tricky_store
OUT="$CFG/debug_perf.log"
PIDFILE="$CFG/.debug_perf.pid"
LOCK="$CFG/.debug_perf.lock"
INTERVAL=15
DURATION=3600

mkdir -p "$CFG" 2>/dev/null

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

cpu_total() {
    awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat 2>/dev/null
}

proc_stat() {
    # pid|comm|utime|stime|state
    p="$1"
    [ -r "/proc/$p/stat" ] || return 1
    awk '{name=$2; sub(/^\\(/,"",name); sub(/\\)$/,"",name); print name"|"$14"|"$15"|"$3}' "/proc/$p/stat" 2>/dev/null
}

snapshot_named() {
    for name in TEESimulator supervisor daemon aswatcher asfetch; do
        for p in $(pidof "$name" 2>/dev/null); do
            s=$(proc_stat "$p")
            [ -n "$s" ] || continue
            IFS='|' read -r comm ut st state <<EOF
$s
EOF
            echo "PROC|$p|$name|$ut|$st|$state"
        done
    done
}

battery_line() {
    cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    cur=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
    volt=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
    temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    stat=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    echo "BAT|cap=${cap:-?}|current_uA=${cur:-?}|voltage_uV=${volt:-?}|temp_raw=${temp:-?}|status=${stat:-?}"
}

thermal_line() {
    # Record thermal-zone temperatures; zone names are omitted because some
    # vendor names can be noisy. Values are enough to correlate heat changes.
    out=""
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        v=$(cat "$z" 2>/dev/null)
        [ -n "$v" ] && out="$out $(basename "$(dirname "$z")")=$v"
    done
    echo "THERM|$out"
}

log_top() {
    # Best-effort snapshot. Different Android toybox versions expose different
    # top flags, so failure is harmless.
    echo "TOP_BEGIN"
    top -n 1 -m 12 2>/dev/null | head -80
    echo "TOP_END"
}

start() {
    if is_running; then
        echo "debug profiler already running: $(cat "$PIDFILE")"
        return 0
    fi
    rm -f "$LOCK" 2>/dev/null
    (
        echo $$ > "$PIDFILE"
        trap 'rm -f "$PIDFILE" "$LOCK" 2>/dev/null; exit 0' INT TERM EXIT
        : > "$OUT"
        echo "AlwaysStrong DEBUG profiler start $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        echo "interval=${INTERVAL}s duration=${DURATION}s"
        prev_total=$(cpu_total)
        # Per-process previous counters: pid|ut+st
        start_ts=$(date +%s 2>/dev/null)
        last_top=0
        while :; do
            now=$(date +%s 2>/dev/null)
            [ -n "$now" ] || now=0
            elapsed=$((now-start_ts))
            [ "$elapsed" -ge "$DURATION" ] && break

            total=$(cpu_total)
            delta_total=$((total-prev_total))
            [ "$delta_total" -le 0 ] && delta_total=1
            prev_total=$total

            echo "SAMPLE|$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)|elapsed=${elapsed}s|cpu_total_delta=${delta_total}"
            battery_line
            thermal_line

            # For each module process calculate CPU share since last sample by
            # storing counters in a tiny per-pid file. This does not require
            # root beyond what the module already has.
            for name in TEESimulator supervisor daemon aswatcher asfetch; do
                for p in $(pidof "$name" 2>/dev/null); do
                    s=$(proc_stat "$p")
                    [ -n "$s" ] || continue
                    IFS='|' read -r comm ut st state <<EOF
$s
EOF
                    cur=$((ut+st))
                    prevfile="$CFG/.debug_cpu_$p"
                    prev=$(cat "$prevfile" 2>/dev/null)
                    if echo "$prev" | grep -qE '^[0-9]+$'; then
                        d=$((cur-prev))
                        # Approximate % of one CPU over the sample interval.
                        pct=$(awk -v d="$d" -v t="$delta_total" 'BEGIN { if(t<=0) printf "0.0"; else printf "%.1f", (d/t)*100 }')
                    else
                        d=0; pct="0.0"
                    fi
                    echo "$cur" > "$prevfile"
                    echo "PCPU|pid=$p|name=$name|jiffies_delta=$d|cpu_pct_total=${pct}%|state=$state"
                done
            done

            # A system-wide top snapshot once per minute helps catch a culprit
            # outside AlwaysStrong without making the profiler itself busy.
            if [ $((elapsed-last_top)) -ge 60 ]; then
                log_top
                last_top=$elapsed
            fi
            echo "---"
            sleep "$INTERVAL"
        done >> "$OUT" 2>&1
        echo "AlwaysStrong DEBUG profiler stop $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >> "$OUT" 2>&1
        rm -f "$PIDFILE" "$LOCK" 2>/dev/null
    ) >> "$OUT" 2>&1 &
    echo $! > "$PIDFILE"
    chmod 600 "$OUT" "$PIDFILE" 2>/dev/null
    echo "debug profiler started: $(cat "$PIDFILE")"
}

stop() {
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        sleep 1
    fi
    rm -f "$PIDFILE" "$LOCK" 2>/dev/null
    echo "debug profiler stopped"
}

status() {
    if is_running; then echo "running pid=$(cat "$PIDFILE") log=$OUT"; else echo "stopped log=$OUT"; fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    *) echo "usage: $0 {start|stop|status}"; exit 2 ;;
esac
