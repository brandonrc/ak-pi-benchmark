# Shared helpers. `source lib/common.sh` after `source config.env`.
set -euo pipefail

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Run a command on the Pi over a shared (multiplexed) SSH connection.
pssh() { ssh $PI_SSH_OPTS "$PI_HOST" "$@"; }

# Copy a file to/from the Pi.
pscp_to()   { scp $PI_SSH_OPTS -q "$1" "$PI_HOST:$2"; }
pscp_from() { scp $PI_SSH_OPTS -q "$PI_HOST:$1" "$2"; }

# curl against the AK API through nginx TLS, verifying with the committed cert.
akcurl() { curl -sS --cacert "$AK_CERT" "$@"; }

# Set the current benchmark phase label the Pi sampler tags rows with.
set_phase() { pssh "echo '$1' > /tmp/ak-bench/phase"; }

# --- resource sampler lifecycle (runs sampler.sh on the Pi) ---
# start_sampler <local_out_csv>  ; stop_sampler <local_out_csv>
start_sampler() {
  local out="$1"
  pssh 'mkdir -p /tmp/ak-bench'
  pscp_to scripts/sampler.sh /tmp/ak-bench/sampler.sh
  pssh 'chmod +x /tmp/ak-bench/sampler.sh; echo baseline > /tmp/ak-bench/phase; rm -f /tmp/ak-bench/run.csv;
        nohup /tmp/ak-bench/sampler.sh /tmp/ak-bench/run.csv '"$SAMPLE_INTERVAL"' '"$PI_IFACE"' >/tmp/ak-bench/sampler.log 2>&1 &
        echo $! > /tmp/ak-bench/sampler.pid'
  SAMPLER_OUT="$out"; log "sampler started (interval ${SAMPLE_INTERVAL}s)"
}
stop_sampler() {
  local out="${1:-$SAMPLER_OUT}"
  pssh 'kill "$(cat /tmp/ak-bench/sampler.pid 2>/dev/null)" 2>/dev/null; sleep 1'
  pscp_from /tmp/ak-bench/run.csv "$out"
  log "sampler stopped; $(wc -l < "$out") rows -> $out"
}

# reset_repo <key> <create_json> — force a genuinely COLD proxy. A plain repo
# DELETE leaves the on-disk cache; and even wiping disk leaves crate/wheel bytes
# in the backend's in-memory (moka) cache — only a restart clears that. So we:
# delete repo -> wipe disk cache -> restart backend (clears moka) -> recreate.
reset_repo() {
  local key="$1" body="$2" tok; tok=$(cat "$RESULTS_DIR/.token")
  akcurl -H "Authorization: Bearer $tok" -X DELETE "$BASE_URL/api/v1/repositories/$key" -o /dev/null -w '' || true
  pssh "rm -rf '$PI_STORAGE/proxy-cache/$key' '$PI_STORAGE/proxy-cache-staging/$key'" || true
  pssh 'sudo systemctl restart artifact-keeper' || true
  for _ in $(seq 1 25); do sleep 2; [ "$(pssh 'curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8080/health' 2>/dev/null)" = 200 ] && break; done
  akcurl -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -X POST \
    "$BASE_URL/api/v1/repositories" -d "$body" -o /dev/null -w '' || true
  akcurl -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -X PATCH \
    "$BASE_URL/api/v1/repositories/$key" -d '{"allow_anonymous_access":true,"is_public":true}' -o /dev/null -w '' || true
  # Wait until the recreated repo is actually serving anonymously (avoids a
  # post-restart race where the repo reads back private and a client 401s).
  local pub
  for _ in $(seq 1 20); do
    pub=$(akcurl -H "Authorization: Bearer $tok" "$BASE_URL/api/v1/repositories/$key" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("allow_anonymous_access"))' 2>/dev/null || echo "")
    [ "$pub" = "True" ] && break
    akcurl -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -X PATCH \
      "$BASE_URL/api/v1/repositories/$key" -d '{"allow_anonymous_access":true,"is_public":true}' -o /dev/null -w '' || true
    sleep 1
  done
}

# Deterministically set the admin password + clear any lockout, straight in the
# DB on the Pi. The file-based first-boot bootstrap is fragile (the plaintext
# file can vanish across restarts); this guarantees a known credential for
# reproducible runs. Idempotent.
reset_admin_via_db() {
  local pw="$1"
  cat <<REMOTE | pssh 'bash -s'
set -e
python3 -c 'import bcrypt' 2>/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-bcrypt
HASH=\$(python3 -c "import bcrypt;print(bcrypt.hashpw(b'$pw', bcrypt.gensalt(12)).decode())")
set -a; . \$HOME/artifact-keeper/artifact-keeper.env; set +a
cat > /tmp/ak-pw.sql <<SQL
UPDATE users SET password_hash='\$HASH', must_change_password=false,
       failed_login_attempts=0, locked_until=NULL, last_failed_login_at=NULL
 WHERE username='admin' AND auth_provider='local';
SQL
psql "\$DATABASE_URL" -f /tmp/ak-pw.sql >/dev/null && rm -f /tmp/ak-pw.sql
REMOTE
}

# --- API auth: return a bearer token in $AK_TOKEN, unlocking on first use ---
ak_login() {
  local pw="$1" body resp code
  body=$(printf '{"username":"%s","password":"%s"}' "$AK_ADMIN_USER" "$pw")
  resp=$(akcurl -X POST "$BASE_URL/api/v1/auth/login" \
           -H 'Content-Type: application/json' -d "$body" -w '\n%{http_code}')
  code=$(printf '%s' "$resp" | tail -1)
  printf '%s' "$resp" | sed '$d'
  [ "$code" = "200" ]
}
