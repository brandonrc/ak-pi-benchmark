#!/usr/bin/env python3
"""Dependency-free HTTPS load generator. Persistent connection per worker.

  loadgen.py <url> <concurrency> <duration_s> <ca_cert>

Emits one JSON line: throughput, latency percentiles, error rate, bytes.
Each worker keeps one keep-alive connection and loops GETs until the deadline,
so this measures sustained server request-handling, not TLS-handshake churn.
"""
import http.client, json, ssl, sys, threading, time
from urllib.parse import urlparse

URL, CONC, DUR, CA = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
u = urlparse(URL)
ctx = ssl.create_default_context(cafile=CA)

lats, oks, errs, nbytes = [], [0]*CONC, [0]*CONC, [0]*CONC
buckets = [[] for _ in range(CONC)]

def worker(i, deadline):
    conn = None
    while time.monotonic() < deadline:
        try:
            if conn is None:
                conn = http.client.HTTPSConnection(u.hostname, u.port or 443,
                                                   context=ctx, timeout=30)
            t0 = time.monotonic()
            conn.request("GET", u.path or "/", headers={"Connection": "keep-alive"})
            r = conn.getresponse()
            body = r.read()
            dt = (time.monotonic() - t0) * 1000.0
            if r.status < 400:
                oks[i] += 1; nbytes[i] += len(body); buckets[i].append(dt)
            else:
                errs[i] += 1
        except Exception:
            errs[i] += 1
            try:
                if conn: conn.close()
            except Exception:
                pass
            conn = None

deadline = time.monotonic() + DUR
ts = [threading.Thread(target=worker, args=(i, deadline)) for i in range(CONC)]
t0 = time.monotonic()
for t in ts: t.start()
for t in ts: t.join()
elapsed = time.monotonic() - t0

for b in buckets: lats += b
lats.sort()
def pct(p):
    if not lats: return 0.0
    return lats[min(len(lats)-1, int(p/100.0*len(lats)))]
total_ok, total_err = sum(oks), sum(errs)
print(json.dumps({
    "concurrency": CONC, "duration_s": round(elapsed, 2),
    "requests": total_ok, "errors": total_err,
    "rps": round(total_ok/elapsed, 1) if elapsed else 0,
    "error_rate": round(total_err/max(1, total_ok+total_err), 4),
    "bytes": sum(nbytes),
    "mbps": round(sum(nbytes)*8/1e6/elapsed, 1) if elapsed else 0,
    "p50_ms": round(pct(50), 1), "p95_ms": round(pct(95), 1),
    "p99_ms": round(pct(99), 1), "max_ms": round(lats[-1], 1) if lats else 0,
}))
