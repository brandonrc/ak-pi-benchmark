#!/usr/bin/env bash
# Profile the Pi while a pip client pulls a fixed wheel set through the pypi proxy,
# cold (empty proxy cache) then warm (served from cache). Client-side metrics +
# a server-side resource CSV land in results/.
cd "$(dirname "$0")/.." || exit 1
source config.env; source lib/common.sh

TS=$(date +%Y%m%d-%H%M%S)
CSV="$RESULTS_DIR/pypi-$TS.csv"
META="$RESULTS_DIR/pypi-$TS.client.json"
# Deterministic wheel set: fixed interpreter/platform so the byte volume is
# identical on any client OS (we fetch linux wheels regardless of host).
PYARGS=(--only-binary=:all: --python-version 3.11 --implementation cp --abi cp311 --platform manylinux2014_x86_64)

pip_run() { # <dest>
  python3 -m pip download "${PYARGS[@]}" --no-cache-dir --disable-pip-version-check \
    --index-url "$PYPI_INDEX_URL" --cert "$(pwd)/$AK_CERT" \
    -r workloads/pypi/requirements.txt -d "$1"
}
measure() { # <phase> <dest> -> echoes "secs bytes files"
  local phase="$1" dest="$2" t0 t1 bytes files
  set_phase "$phase"; t0=$(date +%s.%N)
  pip_run "$dest" >/dev/null 2>&1 || warn "pip phase $phase had errors (see below)"
  t1=$(date +%s.%N)
  bytes=$(find "$dest" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
  files=$(find "$dest" -type f | wc -l | tr -d ' ')
  echo "$(echo "$t1 - $t0" | bc) $bytes $files"
}

log "=== pypi benchmark ($TS) ==="
start_sampler "$CSV"
set_phase baseline; sleep 6

log "resetting proxy repo for a COLD cache (restarts backend to clear caches)"
set_phase pypi_reset
reset_repo "$PYPI_REPO" "$(printf '{"key":"%s","name":"PyPI Proxy","format":"pypi","repo_type":"remote","upstream_url":"%s","allow_anonymous_access":true,"is_public":true}' "$PYPI_REPO" "$PYPI_UPSTREAM")"
sleep 2

cold_dest=$(mktemp -d); warm_dest=$(mktemp -d)
log "COLD pull (proxy fetches from pypi.org, caches, streams to client)"
read -r cold_s cold_b cold_f <<<"$(measure pypi_cold "$cold_dest")"
set_phase idle_between; sleep 6
log "WARM pull (proxy serves from its own cache)"
read -r warm_s warm_b warm_f <<<"$(measure pypi_warm "$warm_dest")"
set_phase cooldown; sleep 6
stop_sampler "$CSV"

cat > "$META" <<JSON
{"benchmark":"pypi","timestamp":"$TS",
 "cold":{"seconds":$cold_s,"bytes":$cold_b,"files":$cold_f},
 "warm":{"seconds":$warm_s,"bytes":$warm_b,"files":$warm_f}}
JSON
log "client: COLD ${cold_s}s ${cold_b}B ${cold_f} files | WARM ${warm_s}s ${warm_b}B ${warm_f} files"
rm -rf "$cold_dest" "$warm_dest"
log "wrote $CSV and $META"
