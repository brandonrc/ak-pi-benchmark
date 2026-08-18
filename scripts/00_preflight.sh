#!/usr/bin/env bash
# Verify the client + Pi are ready to benchmark. Non-destructive.
cd "$(dirname "$0")/.." || exit 1
source config.env; source lib/common.sh

ok=1
need() { command -v "$1" >/dev/null && log "client has $1: $($1 --version 2>&1 | head -1)" || { warn "MISSING client tool: $1"; ok=0; }; }
need python3; need cargo; need curl; need ssh

[ -f "$AK_CERT" ] || { warn "missing $AK_CERT (run: scp $PI_HOST:/etc/ssl/ak/ak.crt $AK_CERT)"; ok=0; }

log "ssh to $PI_HOST ..."
if pssh 'echo ok' >/dev/null 2>&1; then
  log "Pi reachable: $(pssh 'cat /proc/device-tree/model 2>/dev/null; echo; nproc; free -m | awk "/Mem/{print \$2\"MB RAM\"}"' | tr '\n' ' ')"
else
  die "cannot ssh to $PI_HOST"
fi

code=$(akcurl -o /dev/null -w '%{http_code}' "$BASE_URL/health") || true
log "backend /health via TLS: HTTP $code"
[ "$code" = "200" ] || { warn "backend not healthy"; ok=0; }

log "services: $(pssh 'systemctl is-active artifact-keeper postgresql nginx' | paste -sd' ' -)"
[ "$(pssh 'systemctl is-active artifact-keeper-web' 2>/dev/null || true)" = "active" ] && warn "UI (artifact-keeper-web) is running — resource numbers will include it" || log "UI is disabled (good — isolates the backend)"

[ "$ok" = 1 ] && log "preflight PASSED" || die "preflight FAILED"
