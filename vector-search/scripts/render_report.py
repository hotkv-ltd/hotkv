#!/usr/bin/env python3
# =============================================================================
# Copyright 2026 HotKV Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use
# this file except in compliance with the License. You may obtain a copy of the
# License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by
# applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the specific language
# governing permissions and limitations under the License.
#
# Website:     https://hotkv.com
# =============================================================================
"""Turn the results.json files written by vsbench.py into RESULTS.md.

    python3 render_report.py --title "..." --out RESULTS.md run_999000/results.json run_100000/results.json

Every number in the report is computed here from the raw trials in results.json. Nothing is
typed in by hand. Throughput cells are the median of the trials, with the lowest and highest
trial next to it.
"""
from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict

ENGINES = ("hotkv", "redis")
NAMES = {"hotkv": "HotKV", "redis": "Redis"}
TARGETS = (0.90, 0.95, 0.99)


def f0(x):
    return f"{x:,.0f}"


def f2(x):
    return f"{x:,.2f}"


def pct(x):
    return f"{x * 100:+.0f}%"


class Run:
    def __init__(self, paths):
        """`paths`: one results.json, or several for the same index size (a supplementary run for more
        search depths); their qps and recall records are combined, and the first file supplies the rest."""
        self.paths = paths
        docs = []
        for path in paths:
            with open(path) as fh:
                docs.append(json.load(fh))
        self.d = docs[0]
        for extra in docs[1:]:
            self.d["qps"] = self.d["qps"] + extra["qps"]
            # A supplementary run builds its own HotKV index (Redis is loaded from the same saved file), so for
            # the search depths it measured, its own recall replaces the first run's: a depth's recall and its
            # throughput always come from the same index.
            keys = {(r["size"], r["engine"], r["build"], r["ef"]) for r in extra["recall"]}
            self.d["recall"] = [r for r in self.d["recall"] if (r["size"], r["engine"], r["build"], r["ef"]) not in keys] + extra["recall"]
        self.meta = self.d["meta"]
        self.sizes = sorted({r["size"] for r in self.d["qps"]} | {r["size"] for r in self.d["ingest"]})
        self.recall = defaultdict(dict)          # (size, engine, ef) -> {build: recall}
        for r in self.d["recall"]:
            self.recall[(r["size"], r["engine"], r["ef"])][r["build"]] = r["recall_at_10"]
        self.cells = defaultdict(list)           # (size, engine, ef, clients) -> [trial dicts]
        for r in self.d["qps"]:
            self.cells[(r["size"], r["engine"], r["ef"], r["clients"])].append(r)
        self.ingest = defaultdict(list)          # (size, engine) -> [records]
        for r in self.d["ingest"]:
            self.ingest[(r["size"], r["engine"])].append(r)

    def efs(self, size):
        return sorted({k[2] for k in self.cells if k[0] == size})

    def clients(self, size):
        return sorted({k[3] for k in self.cells if k[0] == size})

    def recall_build1(self, size, engine, ef):
        return self.recall.get((size, engine, ef), {}).get(1)

    def qps(self, size, engine, ef, clients):
        t = self.cells.get((size, engine, ef, clients))
        if not t:
            return None
        v = [x["qps"] for x in t]
        return {"med": statistics.median(v), "lo": min(v), "hi": max(v), "n": len(v),
                "p50": statistics.median(x["p50_ms"] for x in t), "p99": statistics.median(x["p99_ms"] for x in t),
                "cores": statistics.median(x["server_cores_used"] for x in t),
                "client_busy": max(x["client_busy_max"] for x in t)}


def matched(run, size, engine, target, clients):
    """Highest median QPS among the measured ef values whose build-1 recall reaches target."""
    best = None
    for ef in run.efs(size):
        rc = run.recall_build1(size, engine, ef)
        q = run.qps(size, engine, ef, clients)
        if rc is None or q is None or rc < target:
            continue
        if best is None or q["med"] > best[0]["med"]:
            best = (q, ef, rc)
    return best


def table(rows, header, align=None):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join(("---:" if (align and align[i] == "r") else "---") for i in range(len(header))) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", nargs="+", help="results.json of one run; join several for the same size with commas")
    ap.add_argument("--title", required=True)
    ap.add_argument("--out", required=True)
    # Optional: what the report says about the machine and the builds. The defaults are the published
    # Azure D160 run's, so rendering that run again gives the same report.
    ap.add_argument("--machine", default="Azure Standard_D160alds_v7")
    ap.add_argument("--redis-version", default="8.10.2")
    ap.add_argument("--hotkv-commit", default=None, help="overrides the commit recorded in the results")
    ap.add_argument("--limit-note", action="append", default=[], help="an extra line for the limits section (repeatable)")
    args = ap.parse_args()
    runs = [Run(p.split(",")) for p in args.results]
    m0 = runs[0].meta
    a0 = m0["args"]
    L = [f"# {args.title}", ""]
    L += ["Plain vector search on both servers: build an HNSW index, then run top-10 nearest-neighbour queries. "
          "No filters, no attributes, no quantization, none of HotKV's AI engines. Every figure below is computed by "
          "`scripts/render_report.py` from the raw trials in `raw/`.", ""]

    # ---- setup
    lscpu = {}
    for line in m0["lscpu"].splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            lscpu[k.strip()] = v.strip()
    n_server = 0
    for part in a0["server_cpus"].split(","):
        lo, _, hi = part.partition("-")
        n_server += (int(hi) - int(lo) + 1) if hi else 1
    L += ["## Setup", ""]
    L += [table([
        ["Machine", f"{args.machine}: {lscpu.get('Model name', '?')}, {n_server + m0['client_cpus']} vCPUs, one VM"],
        ["Kernel / OS", m0["platform"]],
        ["HotKV", f"commit `{args.hotkv_commit or m0.get('hotkv_commit')}`, binary SHA-256 `{m0['binaries']['hotkv']['sha256'][:16]}...`, release build, portable flags (no -march=native)"],
        ["Redis", f"{args.redis_version} from the GitHub release tag, stock `make`, binary SHA-256 `{m0['binaries']['redis']['sha256'][:16]}...`"],
        ["CPU placement", f"servers pinned to vCPUs {a0['server_cpus']}; load generators on {m0['client_cpus']} other vCPUs; same CPU set for both servers; loopback"],
        ["HotKV launch", f"`hotkv --threads {a0['hotkv_threads']} --no-snapshot --protected-mode no`"],
        ["Redis launch", f"`redis-server --save \"\" --appendonly no --protected-mode no`" + (f" `--io-threads {a0['redis_io_threads']}`" if a0["redis_io_threads"] > 1 else " (default I/O threads)")],
        ["Index", f"HNSW, cosine, M={a0['m']}, ef_construction={a0['ef_construction']}, float32 on both (Redis: `NOQUANT`)"],
        ["Dataset", "dbpedia-entities-openai-1M (OpenAI ada-002, 1,536 dimensions, MIT). Base set = first N rows; queries = the last 1,000 rows; no overlap"],
        ["Ground truth", "exact top-10 by cosine similarity, brute force in float64, independent of either server"],
        ["Trials", f"{a0['trials']} per cell; {a0['warm']:g} s warm-up then {a0['dur']:g} s measured; engines alternate within each cell"],
    ], ["", ""]), ""]

    for run in runs:
        for size in run.sizes:
            a = run.meta["args"]
            L += [f"## {size:,} vectors", ""]

            # ---- loading
            rows = []
            for e in ENGINES:
                recs = run.ingest.get((size, e), [])
                if not recs:
                    continue
                for r in recs:
                    how = f"{r['connections']} connections" + (", `CAS`" if r.get("cas") else "")
                    rows.append([NAMES[e], f"build {r['build']}", how, f"{r['seconds']:.0f} s", f0(r["vectors_per_sec"]),
                                 f"{r['server_cores_used']:.1f}", f"{r.get('server_rss_bytes', 0) / 1e9:.2f} GB"])
            L += ["### Loading", "",
                  "Time and vectors per second are for the whole load, including the load generator's own formatting of each vector. "
                  "RSS is the size of the server process after that load; the server holds every build made so far, so with several builds it grows. "
                  "The Redis indexes were built in an earlier run (`raw/redis_build/`) and saved with `SAVE`; the measurements started Redis from the saved "
                  "file, and the Redis figures here are from the run that built the index.", "",
                  table(rows, ["Engine", "Build", "Loaded over", "Time", "Vectors/s", "Server cores busy", "Process RSS after load"]), ""]

            # ---- recall
            efs_r = sorted({k[2] for k in run.recall if k[0] == size})
            rows = []
            for ef in efs_r:
                row = [ef]
                for e in ENGINES:
                    v = run.recall.get((size, e, ef), {})
                    if v:
                        vals = [v[b] for b in sorted(v)]
                        row.append(f"{vals[0]:.4f}" + (f" ({min(vals):.4f} to {max(vals):.4f} over {len(vals)} builds)" if len(vals) > 1 else ""))
                    else:
                        row.append("")
                rows.append(row)
            L += ["### Recall@10 against exact ground truth", "",
                  "Build 1 is the index the throughput numbers were measured on. With several builds the range over all independent builds is shown.", "",
                  table(rows, ["ef", "HotKV", "Redis"]), ""]

            # ---- matched recall
            cl = run.clients(size)
            L += ["### Queries per second at matched recall", "",
                  "For each recall target, each engine's fastest measured `ef` whose build-1 recall reaches the target. "
                  "The `ef` values and recalls reached are shown, because the two engines do not reach a target at the same `ef`. "
                  "Cells are the median of the trials.", ""]
            for t in TARGETS:
                rows = []
                for c in cl:
                    h, r_ = matched(run, size, "hotkv", t, c), matched(run, size, "redis", t, c)
                    if not h or not r_:
                        rows.append([c, "target not reached by both", "", "", ""])
                        continue
                    rows.append([c, f"{f0(h[0]['med'])} (ef {h[1]}, recall {h[2]:.3f})", f"{f0(r_[0]['med'])} (ef {r_[1]}, recall {r_[2]:.3f})",
                                 f"{h[0]['med'] / r_[0]['med']:.2f}x", f"{f2(h[0]['p50'])} / {f2(r_[0]['p50'])} ms"])
                L += [f"**Recall@10 of {t:.2f} or better**", "", table(rows, ["Clients", "HotKV q/s", "Redis q/s", "HotKV / Redis", "Median latency HotKV / Redis"]), ""]

            # ---- by ef
            L += ["### Throughput and latency at every search depth", "",
                  "Median queries per second (lowest to highest trial), median and 99th-percentile latency, and the CPU cores each server kept busy "
                  "(CPU seconds per wall second, from /proc). `ef` is the search-time beam width.", ""]
            for ef in run.efs(size):
                rh, rr = run.recall_build1(size, "hotkv", ef), run.recall_build1(size, "redis", ef)
                rows = []
                for c in cl:
                    h, r_ = run.qps(size, "hotkv", ef, c), run.qps(size, "redis", ef, c)
                    if not h or not r_:
                        continue
                    rows.append([c, f"{f0(h['med'])} ({f0(h['lo'])} to {f0(h['hi'])})", f"{f0(r_['med'])} ({f0(r_['lo'])} to {f0(r_['hi'])})",
                                 f"{h['med'] / r_['med']:.2f}x", f"{f2(h['p50'])} / {f2(h['p99'])}", f"{f2(r_['p50'])} / {f2(r_['p99'])}",
                                 f"{h['cores']:.1f} / {r_['cores']:.1f}"])
                L += [f"**ef {ef}** (recall@10: HotKV {rh:.4f}, Redis {rr:.4f})", "",
                      table(rows, ["Clients", "HotKV q/s", "Redis q/s", "HotKV / Redis", "HotKV p50 / p99 ms", "Redis p50 / p99 ms", "Cores busy HotKV / Redis"]), ""]

    # ---- checks
    busy = max((c["client_busy"] for run in runs for k in run.cells for c in [run.qps(*k)] if c), default=0)
    short = sum(x["short_replies"] for run in runs for v in run.cells.values() for x in v)
    late = sum(x["late_starts"] for run in runs for v in run.cells.values() for x in v)
    L += ["## Checks", "",
          f"- Busiest load-generator process in any cell: {busy * 100:.0f}% of one CPU. A value near 100% would mean the client, not the server, set the limit.",
          f"- Query replies with fewer than 10 results: {short}. Load-generator processes that started late: {late}.",
          "- Every load was followed by a check that the server holds exactly the number of vectors sent.", ""]
    L += ["## Limits of this measurement", "",
          "- One machine, one dataset (1,536-dimension OpenAI embeddings), top 10 only, float32 vectors, cosine similarity.",
          "- The load generators run on the same machine as the servers, on separate vCPUs, over loopback. The two engines share the CPU set, the memory system and the last-level cache with their load generators.",
          "- vCPUs are hyperthreads: a pinned set of N vCPUs is N/2 physical cores.",
          "- Redis is a stock build. Its vector sets run at most 32 searches at once (a compile-time limit, `HNSW_MAX_THREADS`) and add vectors on the main thread, so it uses a small part of this machine; that is how it behaves, not something this benchmark configured.",
          "- Recall is measured once per index build and `ef`. Independent builds of the same engine differ in recall; the range is shown where several builds were made.",
          "- The HotKV build is an unreleased commit (see Setup). Redis was loaded with `VADD ... CAS` and run with its default I/O threads; the tuning runs that led to those choices are in `raw/tuning/`."] + ["- " + n for n in args.limit_note] + [""]
    with open(args.out, "w") as fh:
        fh.write("\n".join(L))
    print("wrote", args.out)


if __name__ == "__main__":
    main()
