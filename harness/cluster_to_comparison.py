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
#
# File:        harness/cluster_to_comparison.py
# Description: Turn the output of cluster_bench_sweep.sh into a comparison.json
# Author:      HotKV Ltd
# =============================================================================
"""Turn the results of cluster_bench_sweep.sh into a comparison.json that render_report.py and
render_html.py can render, the same report format as full_bench.sh.

    python3 cluster_to_comparison.py DATA_DIR -o comparison.json

DATA_DIR holds one folder per server (hotkv, redis, valkey, dragonfly), each with the results.csv the sweep wrote,
and a meta.json that describes the run (see the one in the raw archive of a published cluster run for the keys).
What the sweep records is throughput, the hit ratio and the CPU of the load generators and of the server hosts, so
that is what the report shows (the cores column is the busy share of all the vCPUs of the server hosts, added up); it has
no per-command memory, network or latency figures.
"""
import argparse
import csv
import json
import statistics
from pathlib import Path

SERVER_NAMES = {"hotkv": "HotKV", "redis": "Redis", "valkey": "Valkey", "dragonfly": "Dragonfly"}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("data_dir")
    ap.add_argument("-o", "--output", default="comparison.json")
    args = ap.parse_args()
    root = Path(args.data_dir)
    meta = json.load(open(root / "meta.json", encoding="utf-8"))

    rows = {}  # server -> command -> [row]
    for key, name in SERVER_NAMES.items():
        path = root / key / "results.csv"
        if not path.exists():
            continue
        for row in csv.DictReader(open(path, encoding="utf-8")):
            rows.setdefault(name, {}).setdefault(row["command"], []).append(row)
    servers = list(rows)
    commands = list(rows[servers[0]])
    runs = max(len(v) for s in rows.values() for v in s.values())

    def med(name, cmd, field):
        return statistics.median(float(r[field]) for r in rows[name][cmd])

    results = {s: {c: med(s, c, "ops_per_sec") for c in commands} for s in servers}
    host_vcpus = meta["system_info"].get("host_vcpus", meta["system_info"]["cpu_cores"])
    detail = {}
    for s in servers:
        detail[s] = {}
        for c in commands:
            d = {"ops": results[s][c], "client_cpu_saturation_pct": med(s, c, "driver_cpu_pct")}
            # node_cpu_pct is the busy share of each whole server host (all its vCPUs) over the middle of the run, "a/b/c"
            cores = statistics.median(sum(float(x) for x in r["node_cpu_pct"].split("/")) / 100 * host_vcpus for r in rows[s][c])
            d.update({"server_cpu_pct": cores * 100, "cores_busy": cores, "ops_per_cpu_sec": results[s][c] / cores})
            hits = [float(r["hit_ratio"]) for r in rows[s][c] if r["hit_ratio"] not in ("", "-")]
            if hits:
                d["hit_rate_pct"] = statistics.median(hits) * 100
            detail[s][c] = d
    all_runs = []
    all_runs_detail = []
    for i in range(runs):
        all_runs.append({s: {c: float(rows[s][c][i]["ops_per_sec"]) for c in commands if i < len(rows[s][c])} for s in servers})
        all_runs_detail.append({s: {c: {"ops": float(rows[s][c][i]["ops_per_sec"]), "client_cpu_saturation_pct": float(rows[s][c][i]["driver_cpu_pct"])}
                                    for c in commands if i < len(rows[s][c])} for s in servers})

    out = {
        "timestamp": meta["timestamp"],
        "tool": "memtier",
        "clients": meta["memtier"]["connections_per_thread"],
        "requests": 0,
        "pipeline": meta["memtier"]["pipeline"],
        "datasize": meta["memtier"]["data_size_bytes"],
        "threads": meta["memtier"]["threads_per_client_machine"],
        "runs": runs,
        "results": results,
        "results_detail": detail,
        "all_runs": all_runs,
        "all_runs_detail": all_runs_detail,
        "server_versions": meta["server_versions"],
        "server_revisions": meta.get("server_revisions", {}),
        "system_info": meta["system_info"],
        "load_generation": meta["load_generation"],
        "tuning": meta["tuning"],
        "benchmark_config": {"servers": meta["servers"], "memtier": meta["memtier"], "host": meta["host"], "notes": meta["notes"]},
        "exclusive_results": [],
        "compressed_results": [],
    }
    json.dump(out, open(args.output, "w", encoding="utf-8"), indent=2)
    print("wrote", args.output)


if __name__ == "__main__":
    main()
