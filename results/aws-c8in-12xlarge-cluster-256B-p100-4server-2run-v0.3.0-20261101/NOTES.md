# Notes: AWS 3 x c8in.12xlarge cluster (Intel Xeon 6975P-C, Granite Rapids), 1 November 2026

What was measured, how, and how to read the figures in `RESULTS.md`. Every
throughput figure in `RESULTS.md` is a measured value; nothing here changes one.

This benchmark was run by HotKV Ltd, the maker of HotKV.

Unlike the other result sets in this repository, which run each server as a single instance, this one runs all four
servers as a three-node cluster. Redis and Valkey run commands on one thread per process and are commonly scaled across
cores by running many processes, so a cluster is the layout in which each product uses a large server the way it is
usually deployed.

## Rig

| | |
|---|---|
| Servers | 3 x AWS `c8in.12xlarge`: 48 vCPUs each (Intel Xeon 6975P-C, 24 cores with 2 threads each, one socket), 92 GiB RAM, one ENA interface, 75 Gbps advertised |
| Load generators | 1 x AWS `c8in.48xlarge` (192 vCPUs) and 1 x AWS `c8in.12xlarge` (48 vCPUs), running memtier_benchmark only, started together |
| Placement | `eu-south-2a`, one VPC subnet, one cluster placement group; all benchmark traffic over private addresses |
| OS | Ubuntu 24.04 LTS, kernel 7.0.0-1014-aws, on all five machines |

## Versions

The latest stable release of each competitor on the day of the run.

| server | version | how it was built |
|---|---|---|
| HotKV | 0.3.0 plus the `pipeline-prefetch` setting (commit `126d1a6a`) | from source, CMake release build with `-DHOTKV_NATIVE=ON` (`-march=native`, tuned to this CPU), jemalloc |
| Redis | 8.10.3 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc) |
| Valkey | 9.1.3 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc) |
| Dragonfly | v2.0.2 | git tag `v2.0.2`, upstream's release build |
| memtier_benchmark | commit `272eeb64` | the same build on every load generator, for every server |

HotKV is built for the exact CPU it runs on (`-march=native`); the others are their stock release builds. The HotKV
build adds the `pipeline-prefetch` setting, which is off by default. It looks ahead in a client's pipeline and asks the
CPU for the memory the next commands will read. This run used `pipeline-prefetch yes`. Redis and Valkey ran with their
own batch prefetching at its default.

## Configuration

| | |
|---|---|
| Cluster | 3 servers, all 16,384 slots spread evenly across the primaries, no replicas |
| HotKV | one process per server, 40 threads (3 primaries) |
| Redis, Valkey | 40 single-thread processes per server (120 primaries), ports 7400 to 7439 |
| Dragonfly | one process per server, 40 proactor threads (3 primaries) |
| CPU pinning | every server process is pinned to CPUs 0 to 39 of its host (`taskset`), leaving the other 8 vCPUs free |
| Persistence | off on every server |
| Workload | 5,000,000 keys, 256-byte values, pipeline depth 100, `memtier_benchmark` in cluster mode with `--distinct-client-seed` and `--randomize` |
| Load | 16 memtier processes of 12 threads on the large load generator and 4 processes of 12 threads on the small one, 16 connections per thread and node |
| Procedure | 15 seconds per run, 2 runs per command, the median is reported; before every run the keyspace is emptied and written completely with that command's own data type, and `DBSIZE` over all primaries is checked against it |
| Commands | GET, SET, SETNX, INCR, SADD, RPUSH, HSET, LPUSH, APPEND. MGET and MSET with random keys fail with `CROSSSLOT` in a cluster, and PING has no key to route by, so they are not run |

Host tuning, applied the same way to all five machines: `harness/tune_server.sh` (open files, listen backlog,
overcommit, transparent huge pages off), receive packet steering and receive flow steering over all CPUs
(`rps_cpus` set to every CPU, `rps_sock_flow_entries` 1,048,576), the network card's receive ring at its maximum (8192),
`net.core.netdev_budget` 4800 and `netdev_budget_usecs` 16000, and a listen backlog of 65,535. The scripts are in the
raw archive.

## Reading the figures

- **Client-bound figures.** The main load generator ran above 85 percent CPU on GET, SETNX and INCR with HotKV, and on
  GET, SET, SETNX, INCR, SADD, HSET and APPEND with Redis and Valkey. Those figures are lower bounds, because the load
  generators and not the servers may have set the limit. `RESULTS.md` lists them and gives the ratios between them as
  bounds. Redis and Valkey need 120 processes, which costs the load generators more per operation.
- **INCR is a tie.** The load generators set the limit for all three of HotKV, Redis and Valkey.
- **HotKV was slower on APPEND.** 35.0 million operations per second against 41.7 million for Redis and 40.9 million for
  Valkey. We have not found the cause. APPEND adds data on every call, so the datasets grow by about 10 GB per second
  across the cluster and the run is also a test of memory allocation. A 30-second APPEND run ran the servers out of
  memory. A profile of HotKV on APPEND showed page faults, TLB shootdowns and lock contention, but we have not shown
  which of them accounts for the gap. The load generators were at about 30 percent CPU with HotKV on APPEND, so its
  figure is not a lower bound.
- **The cores column.** It is the busy share of all the vCPUs of the three server hosts over the middle of each run,
  added up, so it includes the work of the network stack as well as the server processes.
- **What was not measured.** Latency, memory and network use per command, persistence, replication, failover and other
  cluster sizes. The sweep script records throughput, the hit ratio and CPU only.

## Reproducing

On the main load generator, with `harness/setup_server.sh` run on every machine (build tools, Redis, Valkey, memtier and
Dragonfly at the versions above), `harness/tune_server.sh` and the network tuning above applied, a HotKV binary built with
`-DHOTKV_NATIVE=ON`, and an SSH key that reaches the three server hosts and the second load generator:

```bash
export NODES="<server-1> <server-2> <server-3>" HOTKV_BIN=<path to hotkv> DRAGONFLY_BIN=<path to dragonfly>
export RUNS=2 TEST_TIME=15 PIPELINES=100 COMMANDS="GET SET SETNX INCR SADD RPUSH HSET LPUSH APPEND"
export SERVER_CPUS=0-39 EXTRA_CLIENTS="<second-load-generator>:4"
OUT=results/hotkv EXTRA_NODE_CONF_HOTKV="pipeline-prefetch yes" SERVERS=hotkv KS=1 THREADS_PER_NODE=40 bash harness/cluster_bench_sweep.sh
OUT=results/redis SERVERS=redis KS=40 THREADS_PER_NODE=1 bash harness/cluster_bench_sweep.sh
OUT=results/valkey SERVERS=valkey KS=40 THREADS_PER_NODE=1 bash harness/cluster_bench_sweep.sh
OUT=results/dragonfly SERVERS=dragonfly KS=1 THREADS_PER_NODE=40 bash harness/cluster_bench_sweep.sh
python3 harness/cluster_to_comparison.py results -o comparison.json   # needs results/meta.json, see the raw archive
python3 harness/render_report.py comparison.json -o RESULTS.md
python3 harness/render_html.py comparison.json -o RESULTS.html
```

`raw/cluster_p100_raw.tgz` holds, for each server, the sweep's `results.csv` and `run.log`, memtier's output and the CPU
samples of every run, plus `meta.json` (the description of the run that `cluster_to_comparison.py` reads) and the
two scripts the run used (`run.sh`, `tune_network.sh`). `raw/run.log` is the output of the whole sequence.

Before this run, other layouts and pipeline depths were tried on the same machines while the rig was being set up, and
they were used to choose the layouts above. They are not part of this result set. The run reported here is a complete
fresh run of all four servers.

The scripts in `harness/` are the ones this run used. `cluster_bench_sweep.sh` and `cluster_to_comparison.py` are new, and
the settings they add are off unless set. Nothing in the existing benchmark scripts changed.

## Notices

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named
here only to identify the software that was measured; their use does not imply any
sponsorship, endorsement or affiliation. The results describe this configuration, on
this hardware, on this date; other workloads, value sizes, pipeline depths or
configurations will give different results. If you find an error, or a setting that is
unfair to any server, contact HotKV Ltd through hotkv.com and we will re-measure and
correct the results.
