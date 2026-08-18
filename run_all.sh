#!/usr/bin/env bash
# One-shot: preflight -> setup proxies -> pypi bench -> cargo bench -> report.
# Reproducible entrypoint. Results land in results/ and are meant to be committed.
cd "$(dirname "$0")" || exit 1
source config.env; source lib/common.sh

TS=$(date +%Y%m%d-%H%M%S)
log "################ ak-pi-zero benchmark run $TS ################"
bash scripts/00_preflight.sh
bash scripts/01_setup_proxies.sh
bash scripts/bench_pypi.sh
bash scripts/bench_cargo.sh

REPORT="$RESULTS_DIR/report-$TS.md"
LATEST_CSVS=$(ls -t "$RESULTS_DIR"/pypi-*.csv "$RESULTS_DIR"/cargo-*.csv 2>/dev/null | head -2)
{
  echo "# ak-pi-zero benchmark report — $TS"
  echo
  echo "**Target:** \`$PI_HOST\` — $(pssh 'cat /proc/device-tree/model 2>/dev/null' | tr -d '\0'), "
  echo "$(pssh 'nproc') cores, $(pssh 'free -m | awk "/Mem/{print \$2}"') MB RAM, "
  echo "kernel $(pssh 'uname -r'), backend $(akcurl -s "$BASE_URL/health" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)."
  echo
  echo "UI (\`artifact-keeper-web\`) disabled for these numbers. Client drives pip/cargo"
  echo "from a dev machine against the Pi's nginx TLS proxy; the sampler records"
  echo "server-side resource use on the Pi at ${SAMPLE_INTERVAL}s resolution."
  echo
} > "$REPORT"
python3 scripts/analyze.py "$PI_CLK_TCK" "$RESULTS_DIR/_body-$TS.md" $LATEST_CSVS
cat "$RESULTS_DIR/_body-$TS.md" >> "$REPORT"; rm -f "$RESULTS_DIR/_body-$TS.md"
log "################ report: $REPORT ################"
cat "$REPORT"
