#!/usr/bin/env python3
"""Turn sampler CSVs (+ sibling .client.json) into a markdown report.

Usage: analyze.py <clk_tck> <out.md> <bench1.csv> [bench2.csv ...]
Each CSV row is tagged with a phase label; we reduce per phase.
"""
import csv, json, os, sys, statistics as st

CLK = float(sys.argv[1]); OUT = sys.argv[2]; CSVS = sys.argv[3:]
MB = 1024.0  # kB -> MB

def load(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows

def num(r, k):
    try: return float(r[k])
    except Exception: return 0.0

def phases(rows):
    order, buckets = [], {}
    for r in rows:
        p = r["phase"]
        if p not in buckets: buckets[p] = []; order.append(p)
        buckets[p].append(r)
    return [(p, buckets[p]) for p in order]

def span(vals):  # robust delta for monotonic counters (ignore resets)
    vals = [v for v in vals if v is not None]
    return (max(vals) - min(vals)) if vals else 0.0

def reduce_phase(rows):
    ep = [num(r,"epoch") for r in rows]
    dur = (max(ep)-min(ep)) if len(ep) > 1 else 0.0
    be_rss = [num(r,"be_rss_kb")/MB for r in rows]
    be_pss = [num(r,"be_pss_kb")/MB for r in rows]
    be_swp = [num(r,"be_swap_kb")/MB for r in rows]
    pg_rss = [num(r,"pg_rss_kb")/MB for r in rows]
    mem_used = [(num(r,"mem_total_kb")-num(r,"mem_avail_kb"))/MB for r in rows]
    swap_used = [num(r,"swap_used_kb")/MB for r in rows]
    load = [num(r,"load1") for r in rows]
    temp = [num(r,"temp_c") for r in rows]
    return {
        "samples": len(rows), "dur": dur,
        "be_rss_peak": max(be_rss or [0]), "be_rss_mean": st.mean(be_rss or [0]),
        "be_pss_peak": max(be_pss or [0]),
        "be_swap_peak": max(be_swp or [0]),
        "be_cpu_s": span([num(r,"be_cpu_ticks") for r in rows])/CLK,
        "be_thr": max((num(r,"be_threads") for r in rows), default=0),
        "pg_rss_peak": max(pg_rss or [0]),
        "pg_cpu_s": span([num(r,"pg_cpu_ticks") for r in rows])/CLK,
        "mem_used_peak": max(mem_used or [0]),
        "swap_used_peak": max(swap_used or [0]),
        "swap_delta": (swap_used[-1]-swap_used[0]) if swap_used else 0.0,
        "load_max": max(load or [0]), "temp_max": max(temp or [0]),
        "net_rx_mb": span([num(r,"net_rx") for r in rows])/(MB*MB),
        "net_tx_mb": span([num(r,"net_tx") for r in rows])/(MB*MB),
    }

def client_meta(csv_path):
    j = csv_path.rsplit(".csv",1)[0] + ".client.json"
    if os.path.exists(j):
        with open(j) as f: return json.load(f)
    return {}

out = []
out.append("## Per-phase resource profile\n")
for csvp in CSVS:
    rows = load(csvp)
    if not rows: continue
    meta = client_meta(csvp)
    name = meta.get("benchmark") or os.path.basename(csvp)
    out.append(f"### {name}  \n`{os.path.basename(csvp)}`\n")
    # client summary
    if meta:
        for phase in ("cold","warm"):
            m = meta.get(phase, {})
            if m:
                b = m.get("bytes",0); s = m.get("seconds",0) or 0
                extra = m.get("files", m.get("crates",""))
                thru = (b/MB/MB/s) if s else 0
                out.append(f"- **client {phase}**: {s:.1f}s, {b/MB/MB:.1f} MB, "
                           f"{extra} artifacts, {thru:.2f} MB/s")
        out.append("")
    # server per-phase table
    hdr = ("| phase | s | be RSS peak | be PSS peak | be swap peak | be CPU-s | "
           "pg RSS peak | pg CPU-s | sys mem peak | swap peak | Δswap | load | °C | net↓ | net↑ |")
    sep = "|"+"---|"*15
    out.append(hdr); out.append(sep)
    for p, rws in phases(rows):
        d = reduce_phase(rws)
        out.append("| {p} | {dur:.0f} | {a:.0f} MB | {pss:.0f} MB | {sw:.0f} MB | {cpu:.1f} | "
                   "{pg:.0f} MB | {pgc:.1f} | {mu:.0f} MB | {su:.0f} MB | {sd:+.0f} | "
                   "{ld:.2f} | {t:.0f} | {rx:.1f} | {tx:.1f} |".format(
            p=p, dur=d["dur"], a=d["be_rss_peak"], pss=d["be_pss_peak"], sw=d["be_swap_peak"],
            cpu=d["be_cpu_s"], pg=d["pg_rss_peak"], pgc=d["pg_cpu_s"], mu=d["mem_used_peak"],
            su=d["swap_used_peak"], sd=d["swap_delta"], ld=d["load_max"], t=d["temp_max"],
            rx=d["net_rx_mb"], tx=d["net_tx_mb"]))
    out.append("")

with open(OUT,"w") as f: f.write("\n".join(out)+"\n")
print(f"wrote {OUT}")
