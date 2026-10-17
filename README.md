# HotKV benchmarks

The benchmark harness, the results and the raw data behind the performance figures published by HotKV Ltd, so that you can check
them or run the same tests on your own hardware.

## Read this first

These tests were done by HotKV Ltd, the maker of HotKV, on a best effort basis. We tried to be fair to every server. We used the
same machine and the same settings for all of them, the latest stable release of each, and we published everything we measured,
including the raw output. But no benchmark is perfect, and ours is not either. We may have missed a setting that would help one
of the servers, made a mistake in the harness, or measured something that does not match your workload. The results are one
snapshot, on one rig, on one day. Hardware, cloud, kernel, versions, value sizes, pipeline depth and configuration all change the
numbers. Please treat them as one data point and not as a verdict, and run the benchmark on your own setup before you decide
anything.

**We welcome your benchmarks, findings and bug reports**, whoever you are and whichever server you work on or prefer.

- **Your own results.** Different hardware, cloud, versions or workloads. Please include the hardware, the versions, the exact
  commands and the raw output, so that others can check them.
- **Findings.** A setting that is unfair to any server, a configuration that would give a server its best result, or a mistake in
  how we measured or described something.
- **Bugs** in the scripts, the reports or the documentation.
- **Fixes and improvements** as pull requests.

Open an issue or a pull request in this repository. We read every report. When a published result turns out to be wrong or
unfair, we re-measure it and correct it, and we say what changed.

| Folder | What |
|---|---|
| `harness/` | the scripts that set up the servers, run the benchmark and render the report |
| `results/` | the benchmark results: `RESULTS.md` and `RESULTS.html` (the report), `comparison.json` (all measured values, versions, server command lines), `NOTES.md`, the harness output (`raw/run.log`) and memtier's raw output |
| `vector-search/` | a separate benchmark of vector search (HotKV and Redis 8.10.2), with its own README |

## Results

| Run | Servers | Report |
|---|---|---|
| Azure `Standard_D160alds_v7` (160 vCPUs) | HotKV, Redis 8.10.2, Valkey 9.1.2, Dragonfly 2.0.2 | [`results/azure-d160alds-v7-256B-p30-4server-3run-v0.3.0-20261009/`](results/azure-d160alds-v7-256B-p30-4server-3run-v0.3.0-20261009/RESULTS.md) |
| Vector search, Azure `Standard_D160alds_v7` | HotKV, Redis 8.10.2 | [`vector-search/`](vector-search/README.md) |

## Run the benchmark yourself

You need:

- Ubuntu 24.04 on a server machine and on one or more load generator machines, all on the same private network.
- An SSH key that lets the server log in to the load generators.
- A HotKV binary. HotKV is commercial software: get one from HotKV Ltd (see hotkv.com) and point `HOTKV_BIN` at it.
- About 30 GB of free disk on the server (12 GB with `BUILD_DRAGONFLY=0`).

The published run used one 160-vCPU server and three 64-vCPU load generators. Use load generators with enough CPU: if a load
generator is above about 85% CPU, the report marks the figure as limited by the client and not by the server.

**1. Set up the server.** This installs the build tools, memtier_benchmark and Redis, Valkey and Dragonfly at fixed versions
(override with `REDIS_VERSION`, `VALKEY_VERSION`, `DRAGONFLY_VERSION`), then applies the host settings:

```bash
bash harness/setup_server.sh
bash harness/tune_server.sh
```

Install the same memtier_benchmark build on each load generator.

**2. Run.** The three arguments are the number of runs per command, the value size in bytes and the pipeline depth:

```bash
BENCH_CLIENTS="<client1-ip> <client2-ip> <client3-ip>" SSH_USER=<user> SSH_KEY=~/.ssh/<key> \
SERVER_ADDR=<server-ip> HOTKV_BIN=/path/to/hotkv \
SWEEP=0 FIXED_THREADS=<number of server vCPUs> NET_LINK_GBPS=<link speed in Gbps> \
bash harness/full_bench.sh 3 256 30
```

- `SWEEP=0` gives every server the same thread count (`FIXED_THREADS`). Leave `SWEEP` unset to let the harness search for each
  server's best thread count instead.
- `NET_LINK_GBPS` is the network speed of the server, which the report uses to show how much of the link each result used.
  If you leave it out, the report omits that column.
- `SERVERS="hotkv redis"` limits the run to some servers, and `COMMANDS="SET GET"` to some commands.

**3. Render the report.** The results are written to `/tmp/full_bench_p30/` (set `OUTDIR` to change it):

```bash
python3 harness/render_report.py /tmp/full_bench_p30/comparison.json -o RESULTS.md --title "My run"
python3 harness/render_html.py /tmp/full_bench_p30/comparison.json -o RESULTS.html --title "My run"
```

## What is measured

Twelve commands: `SET`, `GET`, `MGET`, `SETNX`, `APPEND`, `INCR`, `LPUSH`, `RPUSH`, `SADD`, `HSET`, `MSET` and `PING`.

- Each server runs alone, as one instance, with persistence off.
- Before every command the keyspace is emptied and 5,000,000 keys are written, so reads find their keys.
- The load is memtier_benchmark on every load generator at the same time: one thread per vCPU, 50 connections per thread,
  pipeline depth 30, 256-byte values, 10 seconds per command. Each client uses its own random seed.
- Throughput is the sum over all load generators. Each command is run three times and the report shows the median.
- `GET` and `MGET` send values out and writes receive them, so the report also shows how much of the network link each result
  used, and flags results that are close to the link or to the load generators' CPU.

## Check the files

Every file is listed with its SHA-256 checksum:

```bash
sha256sum -c SHA256SUMS
(cd vector-search && sha256sum -c SHA256SUMS)
```

## License and notices

The scripts (`harness/`, `vector-search/scripts/`) are licensed under the Apache License 2.0 (`LICENSE`). The results, raw
data, reports and documentation are licensed under the Creative Commons Attribution 4.0 International License
(`LICENSE-DATA`): reuse and quote them freely, credit HotKV Ltd, link here, and say whether you changed anything. Anyone,
including makers of competing products, may run the scripts and publish what they measure. Neither licence grants any right to
the HotKV name or logo. See `NOTICE`.

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named only to identify the software that was
measured; their use does not imply any sponsorship, endorsement or affiliation. The results describe the tested configuration
and hardware; other workloads, value sizes, pipeline depths or configurations will give different results. If you find an
error, or a setting that is unfair to any server, please open an issue in this repository (or contact HotKV Ltd through
hotkv.com) and we will re-measure and correct the results.
