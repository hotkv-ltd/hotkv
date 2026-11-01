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
| Google Cloud `c4d-standard-384` (384 vCPUs) | HotKV, Redis 8.10.3, Valkey 9.1.3, Dragonfly 2.0.2 | [`results/gcp-c4d-standard-384-256B-p30-4server-3run-v0.3.0-20261027/`](results/gcp-c4d-standard-384-256B-p30-4server-3run-v0.3.0-20261027/RESULTS.md) |
| AWS `c8in.48xlarge` (192 vCPUs) | HotKV, Redis 8.10.3, Valkey 9.1.3, Dragonfly 2.0.2 | [`results/aws-c8in-48xlarge-256B-p30-4server-3run-v0.3.0-20261031/`](results/aws-c8in-48xlarge-256B-p30-4server-3run-v0.3.0-20261031/RESULTS.md) |
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

**Check the network before you run.** On some cloud network cards the number of queues is small and fixed, whatever the size of
the machine. Google Cloud's gVNIC (driver `gve`) on a `c4d-standard-384` server and `h4d-standard-192` load generators exposes
16 receive and 16 transmit queues (`ethtool -l <interface>`), with one interrupt per queue on CPUs 0 to 15. With the default
settings all packet processing then runs on those 16 CPUs. If you see CPUs 0 to 15 at 100 percent softirq while the rest of the
machine is idle, throughput on small requests is limited by the network card and not by the server. Check it while a benchmark
runs. It lists the 20 CPUs with the highest softirq share:

```bash
mpstat -P ALL 5 1 | awk '/^Average/ && $2!="all" && $2!="CPU" {print $2, "soft=" $8, "idle=" $NF}' | sort -t= -k2 -n -r | head -20
```

We spread receive processing over all CPUs (receive packet steering and receive flow steering), raised the NIC rings to their
maximum and raised the softirq budget. We applied the same settings, as root, on the server and on every load generator before
the run. They do not survive a reboot. `<interface>` is the interface that carries the private address, and `<N>` is the number
of CPUs of that machine (`nproc`). The mask has `<N>` bits set, written as hex in groups of 32 bits separated by commas (for 192
CPUs, six groups of `ffffffff`).

```bash
sysctl -w net.core.rps_sock_flow_entries=1048576
for q in /sys/class/net/<interface>/queues/rx-*; do
    echo <mask> > $q/rps_cpus
    echo 65536 > $q/rps_flow_cnt        # 1048576 divided by the number of receive queues (16)
done
ethtool -G <interface> rx 4096 tx 4096
sysctl -w net.core.netdev_budget=4800 net.core.netdev_budget_usecs=16000
```

On the gVNIC the 16 transmit-queue interrupts share CPUs 0 to 15 with the 16 receive-queue interrupts. We moved them to CPUs 16
to 31, on the server and on every load generator, which took that work off the busiest CPUs. The transmit interrupts are the last
16 of the interface's `gve-ntfy-blk` entries in `/proc/interrupts`:

```bash
i=0
for irq in $(awk '/gve-ntfy-blk/{gsub(":","",$1);print $1}' /proc/interrupts | sort -n | tail -16); do
    echo $((16 + i)) > /proc/irq/$irq/smp_affinity_list
    i=$((i + 1))
done
```

The settings are host settings and do not depend on which server runs. Every server in a run gets them equally. A run that
used them says so in its `NOTES.md`. The Azure D160 run listed above did not use them.

**Give every server a large listen backlog when the run opens thousands of connections.** The default backlog is small (256 for
Dragonfly, 511 for Redis, Valkey and HotKV). A load generator that opens ten thousand or more connections at once can overflow
a server's accept queue: the kernel drops the connection attempts, the clients retry with growing delays, and the memtier processes
start their tests minutes apart. The harness adds up the rates of all processes, so a sum taken over tests that did not overlap
is larger than what the server delivered at any one moment. Set `TCP_BACKLOG=65535` (the kernel allows that through
`net.core.somaxconn`, which `tune_server.sh` sets) to start every server with it. The check is the wall time per command in
`comparison.json` (`server_resources.wall_ms`): a server that needs minutes to connect did not have all its connections at the
same time. The Azure D160 run did not set it; there every server had its connections open within about 30 seconds per command.

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
- `TCP_BACKLOG=<n>` starts every server with a listen backlog of `<n>`, see above. Leave it unset to keep each server's default.
- `MEMTIER_PROCS=<n>` runs `<n>` memtier_benchmark processes on each load generator instead of one, see the next section.
  Leave it unset to get one process per load generator, which is what the Azure D160 run used.

**A single memtier_benchmark process does not scale to a very large number of threads.** By default the harness starts one
memtier_benchmark process on each load generator with one thread per vCPU. On a load generator with many cores that one process
can run out of throughput long before the load generator runs out of CPU, and then the load generator, not the server, sets the
result. We saw this on 192-core load generators, where all cores were busy in user space while the server was mostly idle, and the
same threads and connections split over several processes gave a much higher result from the same server. The report flags a
result as client-limited when a load generator is above about 85% CPU, but it cannot tell you that more processes would help.
To check on your own hardware, run one memtier_benchmark against a running server with all the load generator's cores as threads,
then run several in parallel that share the same total threads, and compare the totals:

```bash
memtier_benchmark -s <server-ip> -p 6399 -t 192 -c 50 --pipeline 30 --test-time=10 --hide-histogram --command=PING
for i in 1 2 3 4; do memtier_benchmark -s <server-ip> -p 6399 -t 48 -c 50 --pipeline 30 --test-time=10 --hide-histogram --command=PING --randomize --distinct-client-seed & done; wait
```

To run the harness this way set `MEMTIER_PROCS` and give every process its own key sequence. memtier_benchmark seeds its random
numbers from a constant unless it is given `--randomize`, so processes started without it replay the same keys:

```bash
MEMTIER_PROCS=16 SEED_ARGS="--distinct-client-seed --randomize" BENCH_CLIENTS="..." ... bash harness/full_bench.sh 3 256 30
```

The processes on a load generator share its threads, so the total number of threads and connections is the same as with one
process. A run that used `MEMTIER_PROCS` says so in its report and in its `NOTES.md`. The number of processes at which more
splitting stops helping depends on the load generator and the network; on ours it stopped helping at about 16.

**3. Render the report.** The results are written to `/tmp/full_bench_p30/` (set `OUTDIR` to change it):

```bash
python3 harness/render_report.py /tmp/full_bench_p30/comparison.json -o RESULTS.md --title "My run"
python3 harness/render_html.py /tmp/full_bench_p30/comparison.json -o RESULTS.html --title "My run"
```

## What is measured

Twelve commands: `SET`, `GET`, `MGET`, `SETNX`, `APPEND`, `INCR`, `LPUSH`, `RPUSH`, `SADD`, `HSET`, `MSET` and `PING`.

- Each server runs alone, as one instance, with persistence off.
- Before every command the keyspace is emptied and 5,000,000 keys are written, so reads find their keys.
- The load is memtier_benchmark on every load generator at the same time (one process per load generator unless `MEMTIER_PROCS` is set): one thread per vCPU, 50 connections per thread,
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
