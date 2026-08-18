#!/usr/bin/env python3
"""Merge a load sweep's client results (.load.json) with the server sampler CSV
into one JSON dataset keyed by concurrency, for plotting.

  analyze_load.py <clk_tck> <cores> <out.json> <load-TS.csv>
(the sibling <load-TS.load.json> is read automatically)
"""
import csv, json, sys

CLK = float(sys.argv[1]); CORES = float(sys.argv[2]); OUT = sys.argv[3]; CSVP = sys.argv[4]
LOADJ = CSVP.rsplit(".csv", 1)[0] + ".load.json"

rows = list(csv.DictReader(open(CSVP)))
client = {c["concurrency"]: c for c in json.load(open(LOADJ))}

def num(r, k):
    try: return float(r[k])
    except Exception: return 0.0

def phase_rows(name):
    return [r for r in rows if r["phase"] == name]

def span(vals):
    vals = [v for v in vals if v is not None]
    return (max(vals) - min(vals)) if vals else 0.0

out = []
for conc in sorted(client, key=int):
    rws = phase_rows(f"conc_{conc}")
    if not rws: continue
    ep = [num(r, "epoch") for r in rws]
    wall = (max(ep) - min(ep)) or 1.0
    be_cpu_s = span([num(r, "be_cpu_ticks") for r in rws]) / CLK
    pg_cpu_s = span([num(r, "pg_cpu_ticks") for r in rws]) / CLK
    tx = span([num(r, "net_tx") for r in rws]) * 8 / 1e6 / wall
    c = client[conc]
    out.append({
        "concurrency": int(conc),
        "rps": c["rps"], "p50_ms": c["p50_ms"], "p95_ms": c["p95_ms"],
        "p99_ms": c["p99_ms"], "error_rate": c["error_rate"], "client_mbps": c["mbps"],
        "be_cpu_pct": round(be_cpu_s / wall * 100, 1),
        "be_cpu_pct_of_box": round(be_cpu_s / wall * 100 / CORES, 1),
        "pg_cpu_pct": round(pg_cpu_s / wall * 100, 1),
        "load_max": max((num(r, "load1") for r in rws), default=0),
        "temp_max": max((num(r, "temp_c") for r in rws), default=0),
        "mem_used_peak_mb": round(max(((num(r,"mem_total_kb")-num(r,"mem_avail_kb"))/1024 for r in rws), default=0)),
        "swap_used_peak_mb": round(max((num(r,"swap_used_kb")/1024 for r in rws), default=0)),
        "be_rss_peak_mb": round(max((num(r,"be_rss_kb")/1024 for r in rws), default=0)),
        "net_tx_mbps": round(tx, 1),
    })

json.dump(out, open(OUT, "w"), indent=2)
print(f"wrote {OUT} ({len(out)} levels)")
for d in out:
    print(f"  c={d['concurrency']:>3}  {d['rps']:>6.0f} rps  "
          f"p95={d['p95_ms']:>6.0f}ms  err={d['error_rate']*100:>4.1f}%  "
          f"beCPU={d['be_cpu_pct']:>4.0f}%  load={d['load_max']:>5.1f}  "
          f"{d['temp_max']:>4.0f}C  {d['net_tx_mbps']:>4.0f}Mbps")
