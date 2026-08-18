#!/usr/bin/env bash
# Runs ON the Pi. Samples resource usage once per interval and appends CSV rows,
# tagging each row with the label found in /tmp/ak-bench/phase. Stop with SIGTERM.
#   usage: sampler.sh <out.csv> <interval_sec> <iface>
OUT="${1:?out csv}"; INTERVAL="${2:-1.0}"; IFACE="${3:-wlan0}"
PHASE_FILE=/tmp/ak-bench/phase
mkdir -p /tmp/ak-bench; [ -f "$PHASE_FILE" ] || echo baseline > "$PHASE_FILE"

sum_stat_cpu() { # args: pids -> prints summed utime+stime ticks (fields 14+15 of /proc/PID/stat)
  local t=0 p u s
  for p in "$@"; do
    [ -r "/proc/$p/stat" ] || continue
    # comm may contain spaces/parens; take fields after the last ')'
    read -r u s < <(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $12, $13}')
    t=$(( t + ${u:-0} + ${s:-0} ))
  done
  echo "$t"
}
proc_field() { awk -v k="$1" '$1==k":"{print $2; exit}' "/proc/$2/status" 2>/dev/null; }
sum_rss() { local t=0 p v; for p in "$@"; do v=$(proc_field VmRSS "$p"); t=$((t+${v:-0})); done; echo "$t"; }

echo "epoch,phase,be_rss_kb,be_pss_kb,be_swap_kb,be_cpu_ticks,be_threads,pg_rss_kb,pg_cpu_ticks,nginx_rss_kb,mem_total_kb,mem_avail_kb,swap_used_kb,load1,temp_c,net_rx,net_tx" > "$OUT"

BE=$(pgrep -x artifact-keeper | head -1)
trap 'exit 0' TERM INT
while :; do
  ep=$(date +%s.%N)
  phase=$(cat "$PHASE_FILE" 2>/dev/null || echo unknown)
  [ -d "/proc/$BE" ] || BE=$(pgrep -x artifact-keeper | head -1)
  NG=$(pgrep -x nginx | head -1)
  PGPIDS=$(pgrep -x postgres)

  be_rss=$(proc_field VmRSS "$BE"); be_swap=$(proc_field VmSwap "$BE")
  be_pss=$(awk '/^Pss:/{s+=$2} END{print s+0}' "/proc/$BE/smaps_rollup" 2>/dev/null)
  be_thr=$(awk '/^Threads:/{print $2}' "/proc/$BE/status" 2>/dev/null)
  be_cpu=$(sum_stat_cpu "$BE")
  pg_rss=$(sum_rss $PGPIDS); pg_cpu=$(sum_stat_cpu $PGPIDS)
  ng_rss=$(proc_field VmRSS "$NG")

  read -r mt ma su < <(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2} END{print t, a, st-sf}' /proc/meminfo)
  load1=$(awk '{print $1}' /proc/loadavg)
  temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  # /proc/net/dev can merge the iface label with rx bytes ("wlan0:12345") when
  # the counter is large, so split on the colon rather than by column.
  netline=$(grep -E "^[[:space:]]*$IFACE:" /proc/net/dev 2>/dev/null)
  netvals=${netline#*:}
  read -r rx _ _ _ _ _ _ _ tx _ <<<"$netvals"

  echo "$ep,$phase,${be_rss:-0},${be_pss:-0},${be_swap:-0},${be_cpu:-0},${be_thr:-0},${pg_rss:-0},${pg_cpu:-0},${ng_rss:-0},${mt:-0},${ma:-0},${su:-0},${load1:-0},${temp:-0},${rx:-0},${tx:-0}" >> "$OUT"
  sleep "$INTERVAL"
done
