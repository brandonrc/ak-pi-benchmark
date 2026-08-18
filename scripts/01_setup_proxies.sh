#!/usr/bin/env bash
# Idempotently: unlock the admin account, then create the pypi + cargo pull-through
# proxy repositories on the Pi. Safe to re-run. Leaves a valid token in results/.token.
cd "$(dirname "$0")/.." || exit 1
source config.env; source lib/common.sh

# --- 1. obtain an unlocked token (deterministic: DB-reset the admin pw if needed) ---
get_token() {
  local out
  if ! out=$(ak_login "$AK_ADMIN_PW" 2>/dev/null); then
    log "admin login failed; setting a known admin credential via DB"
    reset_admin_via_db "$AK_ADMIN_PW"
    sleep 1
    out=$(ak_login "$AK_ADMIN_PW") || die "login still failing after DB reset"
  fi
  printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

TOKEN=$(get_token); [ -n "$TOKEN" ] || die "no token"
echo "$TOKEN" > "$RESULTS_DIR/.token"; log "API unlocked; token cached"

auth=(-H "Authorization: Bearer $TOKEN")

# --- 2. create a repo if absent (idempotent), then force anonymous read ---
ensure_repo() {
  local key="$1" body="$2"
  if akcurl "${auth[@]}" -o /dev/null -w '%{http_code}' "$BASE_URL/api/v1/repositories/$key" | grep -q '^200$'; then
    log "repo '$key' already exists"
  else
    log "creating repo '$key'"
    akcurl "${auth[@]}" -H 'Content-Type: application/json' -X POST \
      "$BASE_URL/api/v1/repositories" -d "$body" \
      -w '\n-> HTTP %{http_code}\n' | tail -3
  fi
  # ensure anonymous read is on regardless of how it was created
  akcurl "${auth[@]}" -H 'Content-Type: application/json' -X PATCH \
    "$BASE_URL/api/v1/repositories/$key" -d '{"allow_anonymous_access":true,"is_public":true}' >/dev/null || true
}

ensure_repo "$PYPI_REPO" "$(printf '{"key":"%s","name":"PyPI Proxy","format":"pypi","repo_type":"remote","upstream_url":"%s","allow_anonymous_access":true,"is_public":true}' "$PYPI_REPO" "$PYPI_UPSTREAM")"
ensure_repo "$CARGO_REPO" "$(printf '{"key":"%s","name":"crates.io Proxy","format":"cargo","repo_type":"remote","upstream_url":"%s","index_upstream_url":"%s","allow_anonymous_access":true,"is_public":true}' "$CARGO_REPO" "$CARGO_DL_UPSTREAM" "$CARGO_INDEX_UPSTREAM")"

# --- 3. verify anonymous pulls actually work (no token) ---
log "verifying anonymous access to the proxy endpoints"
pc=$(akcurl -o /dev/null -w '%{http_code}' "$PYPI_INDEX_URL")
cc=$(akcurl -o /dev/null -w '%{http_code}' "$BASE_URL/cargo/$CARGO_REPO/config.json")
log "  pypi simple index (anon): HTTP $pc"
log "  cargo config.json (anon): HTTP $cc"
{ [ "$pc" = "200" ] || [ "$pc" = "301" ] || [ "$pc" = "302" ]; } || warn "pypi anon read not 200 — server-wide guest access may be disabled"
[ "$cc" = "200" ] || warn "cargo anon read not 200 — check guest access / upstream config.json fetch"
log "setup complete"
