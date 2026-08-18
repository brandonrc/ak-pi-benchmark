# ak-pi-zero-benchmarks

A small, reproducible framework for **profiling [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper) running baremetal on a Raspberry Pi Zero 2 W** (4× Cortex-A53, **415 MB RAM**, no containers) while real package managers pull artifacts through its pull-through proxies.

It answers: *how much CPU / memory / swap does the backend actually use when a `pip` or `cargo` client installs through it, cold (fetch from upstream) vs warm (served from the Pi's cache)?*

## What it measures

- A **client** on your dev machine drives `pip download` and `cargo fetch` against the Pi's nginx TLS endpoint — the realistic "external developer pulls through the proxy" path.
- A **sampler** runs on the Pi and records, every `SAMPLE_INTERVAL` seconds, per-process and system resource use: backend RSS/PSS/swap/CPU-seconds/threads, Postgres RSS/CPU, nginx RSS, system memory + swap, load, SoC temperature, and network bytes.
- Each row is tagged with a **phase** label (`baseline`, `pypi_cold`, `pypi_warm`, `idle_between`, `cargo_cold`, `cargo_warm`, `cooldown`) so the analyzer can reduce per phase. Alignment is by label, not clock — no cross-host time sync needed.

## Layout

```
config.env              all knobs (host, repo names, cert, sampling, pins)
lib/common.sh           ssh/curl helpers, sampler lifecycle, repo reset, admin unlock
scripts/
  00_preflight.sh       verify client tools + Pi + backend health
  01_setup_proxies.sh   unlock admin (deterministic DB reset), create pypi+cargo proxy repos
  sampler.sh            runs ON the Pi; samples resources -> CSV until SIGTERM
  bench_pypi.sh         pip download a pinned wheel set, cold then warm, with sampling
  bench_cargo.sh        cargo fetch a pinned crate set, cold then warm, with sampling
  analyze.py            CSV (+ client.json) -> per-phase markdown tables
run_all.sh              preflight -> setup -> pypi -> cargo -> report
workloads/
  pypi/requirements.txt pinned wheels (fetched as linux cp311 manylinux2014_x86_64)
  cargo/{Cargo.toml,Cargo.lock,src}  pinned crate tree (~77 crates), --locked
certs/ak-ca.crt         the Pi's local CA (trust anchor for pip/cargo over TLS)
results/                committed CSVs, client JSON, and reports
```

## Run it

Prereqs on the client: `python3` (pip), `cargo`, `curl`, `ssh`, and key-based SSH to the Pi.

```bash
./run_all.sh
```

That produces `results/report-<timestamp>.md` plus the raw `results/*.csv` and `results/*.client.json`. Individual stages are runnable on their own (`bash scripts/bench_pypi.sh`, etc.).

Everything is config-driven — point `config.env` at a different box, change `SAMPLE_INTERVAL`, or edit the pinned workloads and re-run. Results are meant to be committed so runs can be compared over time.

## Reproducibility choices

- **Pinned workloads.** Exact wheel versions and a committed `Cargo.lock` (`--locked`) mean the proxy serves the same bytes every run. pip fetches a fixed `linux cp311 manylinux2014_x86_64` wheel set regardless of the client OS, so byte volume is client-independent.
- **True cold cache.** Before each cold phase the repo is deleted **and** its on-disk `proxy-cache/<key>` is wiped (a plain repo DELETE leaves the cache on disk), so cold really does fetch from upstream. (Caveat: the small in-memory index cache is not flushed without a backend restart; its effect on timing is negligible next to the artifact bytes.)
- **Deterministic admin.** The backend's file-based first-boot admin bootstrap is fragile (the plaintext file can vanish across restarts) and it *re-locks the API on every boot if `ADMIN_PASSWORD` is a well-known default*. The framework instead sets a known admin credential directly in Postgres (bcrypt) and clears the login lockout. The Pi's backend env must therefore **not** set `ADMIN_PASSWORD` to a default.
- **Honest TLS.** A local CA signs a short-lived (397-day), `serverAuth`-EKU, IP-SAN leaf so macOS/pip accept it; clients trust `certs/ak-ca.crt`.

## Reading the numbers

- **Backend memory:** report both RSS and swap — under memory pressure the idle backend is largely paged out, so RSS alone understates the working set. Committed ≈ RSS + swap.
- **Postgres `pg RSS peak`** sums RSS across ~12 processes and therefore **double-counts shared buffers** — treat it as an upper bound, not real unique memory.
- **CPU-seconds** are the backend's `utime+stime` delta across the phase (from `/proc/PID/stat`, `CLK_TCK`=100), i.e. actual work done, independent of wall-clock.

See `results/` for the latest report.
