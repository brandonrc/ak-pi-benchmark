#!/usr/bin/env bash
# Profile the Pi while a cargo client resolves + fetches a fixed crate set through
# the cargo sparse proxy, cold then warm. Uses a throwaway CARGO_HOME each run so
# the client always downloads; "cold"/"warm" refers to the PROXY cache.
cd "$(dirname "$0")/.." || exit 1
source config.env; source lib/common.sh

command -v cargo >/dev/null || die "cargo not found on this client"
TS=$(date +%Y%m%d-%H%M%S)
CSV="$RESULTS_DIR/cargo-$TS.csv"
META="$RESULTS_DIR/cargo-$TS.client.json"
CRATE_DIR="workloads/cargo"

cargo_run() { # <cargo_home>
  # Pass the registry config explicitly: cargo discovers .cargo/config.toml from
  # the CWD, not the --manifest-path dir, so without this cargo silently talks to
  # real crates.io instead of the Pi proxy.
  CARGO_HOME="$1" \
  CARGO_HTTP_CAINFO="$(pwd)/$AK_CERT" \
  CARGO_NET_RETRY=3 \
  cargo fetch --manifest-path "$CRATE_DIR/Cargo.toml" --locked --config "$(pwd)/$CRATE_DIR/.cargo/config.toml"
}
measure() { # <phase> <cargo_home> -> "secs crates bytes"
  local phase="$1" home="$2" t0 t1 crates bytes
  set_phase "$phase"; t0=$(date +%s.%N)
  cargo_run "$home" >/dev/null 2>&1 || warn "cargo phase $phase had errors"
  t1=$(date +%s.%N)
  crates=$(find "$home/registry/cache" -name '*.crate' 2>/dev/null | wc -l | tr -d ' ')
  bytes=$(find "$home/registry" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
  echo "$(echo "$t1 - $t0" | bc) $crates $bytes"
}

# point cargo at the Pi sparse proxy via a local, self-contained config
CFG="$CRATE_DIR/.cargo/config.toml"; mkdir -p "$CRATE_DIR/.cargo"
cat > "$CFG" <<TOML
[source.crates-io]
replace-with = "ak"
[registries.ak]
index = "$CARGO_SPARSE_URL"
[net]
retry = 3
TOML
export CARGO_HOME  # (per-call below)

log "=== cargo benchmark ($TS) ==="
start_sampler "$CSV"
set_phase baseline; sleep 6

log "resetting proxy repo for a COLD cache (restarts backend to clear caches)"
set_phase cargo_reset
reset_repo "$CARGO_REPO" "$(printf '{"key":"%s","name":"crates.io Proxy","format":"cargo","repo_type":"remote","upstream_url":"%s","index_upstream_url":"%s","allow_anonymous_access":true,"is_public":true}' "$CARGO_REPO" "$CARGO_DL_UPSTREAM" "$CARGO_INDEX_UPSTREAM")"
sleep 2

cold_home=$(mktemp -d); warm_home=$(mktemp -d)
log "COLD fetch (proxy pulls index+crates from crates.io)"
read -r cold_s cold_c cold_b <<<"$(measure cargo_cold "$cold_home")"
set_phase idle_between; sleep 6
log "WARM fetch (proxy serves from cache)"
read -r warm_s warm_c warm_b <<<"$(measure cargo_warm "$warm_home")"
set_phase cooldown; sleep 6
stop_sampler "$CSV"

cat > "$META" <<JSON
{"benchmark":"cargo","timestamp":"$TS",
 "cold":{"seconds":$cold_s,"crates":$cold_c,"bytes":$cold_b},
 "warm":{"seconds":$warm_s,"crates":$warm_c,"bytes":$warm_b}}
JSON
log "client: COLD ${cold_s}s ${cold_c} crates ${cold_b}B | WARM ${warm_s}s ${warm_c} crates ${warm_b}B"
rm -rf "$cold_home" "$warm_home"
log "wrote $CSV and $META"
