#!/usr/bin/env bash
# "Max out" test: sweep client concurrency against a WARM-cached artifact and
# record where the Pi saturates (throughput knee, latency blow-up, CPU/thermal
# ceiling, error onset). Server resources are sampled on the Pi per phase.
cd "$(dirname "$0")/.." || exit 1
source config.env; source lib/common.sh

TS=$(date +%Y%m%d-%H%M%S)
CSV="$RESULTS_DIR/load-$TS.csv"
META="$RESULTS_DIR/load-$TS.load.json"
DURATION=${LOAD_DURATION:-10}
LEVELS=${LOAD_LEVELS:-"1 2 4 8 16 32 64 96 128"}
# Small cached wheel: keeps per-request bytes low so request-handling/CPU (not
# just wifi bandwidth) is what we push. Warm it first so we test the Pi serving
# from cache, not upstream.
TARGET="$BASE_URL/pypi/$PYPI_REPO/simple/idna/idna-3.10-py3-none-any.whl"

log "=== max-out load sweep ($TS) — target: idna wheel (cached) ==="
log "warming cache"; akcurl -o /dev/null "$TARGET"; akcurl -o /dev/null -w 'warm fetch -> %{http_code}, %{size_download} bytes\n' "$TARGET"

start_sampler "$CSV"
set_phase idle; sleep 6
echo "[" > "$META"; first=1
for c in $LEVELS; do
  log "concurrency=$c for ${DURATION}s"
  set_phase "conc_$c"
  out=$(python3 scripts/loadgen.py "$TARGET" "$c" "$DURATION" "$(pwd)/$AK_CERT")
  echo "  -> $out" >&2
  [ $first -eq 1 ] && first=0 || echo "," >> "$META"
  printf '%s' "$out" >> "$META"
  set_phase "cool_$c"; sleep 3
done
echo "]" >> "$META"
set_phase cooldown; sleep 6
stop_sampler "$CSV"
log "wrote $CSV and $META"
