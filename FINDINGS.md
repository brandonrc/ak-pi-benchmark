# Findings — Artifact Keeper on a Raspberry Pi Zero 2 W

Run `20260817-211049` (backend v1.7.6, UI disabled). Numbers are server-side,
sampled on the Pi at 0.25 s. See `results/report-*.md` for the full per-phase
tables and `README.md` for methodology.

## Headline

**The backend is genuinely light — a full multi-format registry proxy idles at a
~20–55 MB resident footprint and serves real `pip`/`cargo` pulls on a 415 MB,
4×1 GHz ARM board.** The pressure on this box is RAM (Postgres + swap), not the
backend binary, and the proxy's *cold* path (fetch-from-upstream) costs several
times the CPU of the *warm* path (serve-from-cache).

## Cold vs warm (client-observed)

| workload | cold | warm | speedup | backend CPU-s cold→warm | upstream pulled (cold) |
|---|---|---|---|---|---|
| pypi (13 wheels, 18.5 MB) | 19.7 s | 7.8 s | **2.5×** | 7.1 → 1.3 (**5.5×**) | 34 MB down / 25 MB up |
| cargo (77 crates, 62.3 MB) | 16.5 s | 7.5 s | **2.2×** | 10.7 → 3.9 (**2.7×**) | 13 MB down / 14 MB up |

- **Warm serving is cheap.** Once cached on the Pi, a pull skips the upstream
  fetch, TLS to the origin, and checksum/caching work — 2–5× less backend CPU
  and ~2× faster end-to-end, with near-zero upstream network.
- **Cold pypi is bandwidth-bound**, cold cargo is **request-bound**: 77 crates =
  hundreds of small sparse-index + crate-file round trips. That fan-out drove
  **system load to ~11 and the SoC to 57 °C** during `cargo_cold`, versus load
  ~3 / 53 °C for `pypi_cold` moving similar bytes. Many small proxied requests
  cost this little box more than a few big ones.

## Memory

- **Backend working set:** ~**66–89 MB RSS** while actively proxying; it idles
  lower (20–55 MB) because the kernel pages the idle backend out to swap under
  memory pressure. Committed ≈ RSS + swap.
- **A backend restart costs ~10–24 CPU-seconds** on this board (re-init of the
  WASM host, 37 format handlers, schedulers, pools) and takes it ~7–9 s to go
  healthy again — the benchmark uses a restart to force a truly cold cache.
- **Postgres is the real memory tenant.** (The `pg RSS peak` column sums RSS
  across ~12 processes and double-counts shared buffers, so it overstates —
  treat it as an upper bound — but Postgres is unambiguously the heavier half.)
- The box runs the whole stack (backend + Postgres) within 415 MB only by
  leaning on **~175–285 MB of swap**. It works, but it is over-committed; the
  earlier decision to disable the Next.js UI (which alone committed ~158 MB) is
  what makes this comfortable enough to serve.

## Practical takeaways

- **Artifact Keeper's backend fits a Pi Zero 2 W with headroom** for light,
  personal/edge proxy use. The binary is not the bottleneck.
- **For lighter still:** run API-only (UI off, done here), and consider moving
  Postgres off-box — it, not the backend, is what forces swap on 415 MB.
- **Warm-cache hit rate matters most** for a constrained proxy: cold pulls cost
  multiples of the CPU and heat. Pre-warming frequently used packages, or a
  high cache hit rate, keeps this board cool and responsive.
- **Cargo-style many-small-file registries stress the box more than byte volume
  suggests** — request fan-out, not MB, is what spikes load here.

---

## Max-out load sweep (concurrency 1 → 128)

A separate stress test: ramp parallel keep-alive clients hammering **one warm-cached
70 KB wheel**, to find the ceiling. Shareable dashboard:
**https://claude.ai/code/artifact/9a54eced-da44-4fcc-8769-1283d53e2391**

| clients | req/s | p95 latency | errors | net Mbps | backend CPU (%/core) | load | °C |
|--------:|------:|------------:|-------:|---------:|---------------------:|-----:|---:|
| 1 | 17 | 150 ms | 0% | 10 | 21 | 0.6 | 45 |
| 4 | **52** | 114 ms | 0% | 29 | 77 | 2.1 | 52 |
| 8 | **52** | 247 ms | 0% | **31** | 82 | 3.8 | 54 |
| 16 | 34 | 670 ms | 1.4% | 17 | 62 | 5.6 | 56 |
| 32 | 25 | 1.4 s | 4.3% | 12 | 61 | 8.6 | 58 |
| 64 | 17 | 5.6 s | 9.6% | 10 | 57 | 11.5 | 60 |
| 128 | 23 | 7.0 s | 7.7% | 13 | 59 | 14.4 | 63 |

**What maxes it out:** throughput peaks at **~52 req/s (~30 Mbps) at concurrency 4–8**,
then *collapses* — more clients make it slower and start erroring. The bottleneck is
the **2.4 GHz Wi-Fi (~30 Mbps)**, not compute: the backend never burns even one of
the four cores (peaks ~82% of a single core), and net-Mbps plateaus in lockstep with
req/s. Load climbs to ~14 and the SoC to 63 °C purely from queued connections.

**To go faster:** wired Ethernet / a better radio (Pi 4/5 or CM4) is the #1 win — the
proxy has CPU headroom. Cap concurrency ~8 (`limit_conn`) so a stampede degrades
gracefully instead of collapsing. Keep cache hit-rate high (cold pulls cost 2–5× CPU
*and* ride that same thin radio to upstream).
