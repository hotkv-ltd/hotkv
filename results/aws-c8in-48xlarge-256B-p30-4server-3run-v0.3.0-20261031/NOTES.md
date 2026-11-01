# Notes: AWS c8in.48xlarge (Intel Xeon 6975P-C, Granite Rapids), 31 October 2026

What was measured, how, and how to read the figures in `RESULTS.md`. Every
throughput figure in `RESULTS.md` is a measured value; nothing here changes one.

This benchmark was run by HotKV Ltd, the maker of HotKV.

## Rig

| | |
|---|---|
| Server | AWS `c8in.48xlarge`: 192 vCPUs (Intel Xeon 6975P-C, 96 cores with 2 threads each, one socket), 384 GiB RAM, one ENA interface |
| Load generator | 1 x AWS `c8in.48xlarge`, running memtier_benchmark only |
| Placement | `eu-south-2a`, one VPC subnet, one cluster placement group; all benchmark traffic over private addresses |
| OS | Ubuntu 24.04 LTS, kernel 7.0.0-1014-aws, on both machines |
| Network interface | ENA (driver `ena`), MTU 9001, 32 receive and transmit queues on each machine, 300 Gbps advertised |
| Compiler | GCC 13.3.0 (Ubuntu 24.04) for every server built from source |

This rig has one load generator, not two, so the run opens 9,600 connections
(16 memtier processes x 12 threads x 50 connections), half of what the other
result sets in this repository open. The server and the load generator have the
same size.

## Versions

The latest stable release of each competitor on the day of the run.

| server | version | how it was built |
|---|---|---|
| HotKV | 0.3.0 (commit `38a0d11d`) | from source, CMake release build with `-DHOTKV_NATIVE=ON` (`-march=native`, tuned to this CPU), jemalloc |
| Redis | 8.10.3 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc 5.3.0) |
| Valkey | 9.1.3 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc 5.3.0) |
| Dragonfly | v2.0.2 (commit `8ce4bbb1`) | git tag `v2.0.2`, upstream's release build |
| memtier_benchmark | commit `272eeb64` | the same build on both machines, for every server |

HotKV is built for the exact CPU it runs on (`-march=native`); the others are their
stock release builds. The HotKV commit is `38a0d11d`, which is newer than the 0.3.0 release
tag (32 commits). It adds a fix to the RESP parser (empty lines between commands are skipped, as
Redis does) and the other fixes made after the tag; the binary itself reports `HotKV v0.3.0`.

## Configuration

- **Threads.** Every server was given all 192 vCPUs: HotKV `--threads 192`, Dragonfly
  `--proactor_threads=192`, Valkey `io-threads 192`, Redis `io-threads 128` (Redis 8.10.3
  accepts 1 to 128 and refuses to start above that). Redis and Valkey execute commands on a
  single thread; their I/O threads parallelise reading and writing the network only. They can
  reach higher throughput with fewer I/O threads than they were given here, so their figures
  may be below their best on this machine.
- **Single instance.** Each server ran as one process. Redis and Valkey are designed to
  scale beyond one command thread by running several instances as a cluster; a cluster
  was not measured here.
- **Persistence off** for every server: Redis and Valkey `--save "" --appendonly no`,
  Dragonfly `--dbfilename=`, HotKV `--no-snapshot`.
- **Connections.** Every server accepted up to 65,000 clients (`--maxclients 65000` for HotKV,
  Redis and Valkey; Dragonfly's default is 64,000). The run opens 9,600 connections.
- **Listen backlog.** Every server was started with a listen backlog of 65,535 (HotKV, Redis
  and Valkey `--tcp-backlog 65535`, Dragonfly `--tcp_backlog=65535`; the harness setting
  `TCP_BACKLOG`).
- **Network exposure.** Every server listened on the private network with protected
  mode off; nothing else differed from its defaults. The exact launch line and the
  effective configuration read back from each running server are in `RESULTS.md`.
- **Load.** On the load generator 16 memtier_benchmark processes ran at the same time, each with
  12 threads x 50 connections (192 threads and 9,600 connections in total), pipeline 30,
  256-byte values, 10 seconds per command. Every process used its own random seed
  (`--distinct-client-seed --randomize`). Before each command the keyspace was emptied and
  5,000,000 keys were written, so reads find their keys. Three runs per command; `RESULTS.md`
  reports the median.
- **Host network settings.** On both machines: receive steering (RPS and RFS) over all CPUs,
  the receive ring raised to its maximum of 8192 (the transmit ring is fixed at 1024), and a
  larger softirq budget. The NIC interrupts were spread over the CPUs by the operating
  system's irqbalance. The settings do not depend on which server runs; every server got them
  equally.
- **Exclusive legs skipped.** The harness's optional legs that start an extra HotKV instance with
  value compression were not run (`SKIP_EXCLUSIVE=1`). Nothing from them is reported.

## Network ceiling

iperf3 between the two machines over the private network, 16 and 32 processes of 8 streams
each, 20 seconds:

| direction | measured |
|---|---|
| server to load generator | 301.2 Gbps |
| load generator to server | 301.2 Gbps |
| one flow | 9.5 Gbps |

`RESULTS.md` was rendered with a 300 Gbps link. During the benchmark's tests the AWS
allowance counters of the network interface (`bw_in_allowance_exceeded`,
`bw_out_allowance_exceeded`, `pps_allowance_exceeded`, `conntrack_allowance_exceeded`) did not
change, so the network was not throttled by AWS during them.

## Reading the figures

The harness reads the server's network counters and its CPU time over the whole time it measures a
command: starting the server, writing the 5,000,000 keys, the 10-second test and stopping the server.
That is about 15 seconds per command here, against 10 seconds of test. So the `Gbps`, `link used`,
`cores` and `ops/CPU-s` columns in `RESULTS.md` are averages over a window longer than the
test and read low. The throughput and latency figures are not affected. The table below divides the
per-direction NIC byte counts in `raw/p30_4srv_raw.tgz` (`server_resources.rx_bytes` and `tx_bytes`) by
the 10-second test duration (medians of three runs). They agree with the bytes per request: HotKV's GET
sent 269 bytes per reply.

| HotKV command | ops/sec | inbound Gbps | outbound Gbps |
|---|---|---|---|
| SET | 61.5 M | 148.8 | 4.6 |
| SETNX | 71.3 M | 173.8 | 4.8 |
| RPUSH | 37.1 M | 90.4 | 2.8 |
| SADD | 56.2 M | 136.5 | 3.8 |
| HSET | 45.8 M | 209.2 | 3.2 |
| MSET | 18.0 M | 167.9 | 1.7 |
| LPUSH | 34.2 M | 83.3 | 2.5 |
| APPEND | 25.3 M | 61.9 | 2.4 |
| GET | 93.1 M | 28.5 | 200.1 |
| MGET | 11.1 M | 17.2 | 190.9 |
| INCR | 85.1 M | 25.6 | 5.2 |
| PING | 189.1 M | 23.8 | 13.9 |

- **The network was not the limit.** The busiest command, HSET, moved 209 Gbps inbound, and GET
  moved 200 Gbps outbound, against 301 Gbps measured in each direction.
- **CPU during the test.** In a separate set of tests on the same two machines, with HotKV alone
  and GET only (12-second tests, CPU sampled during the test, not averaged over the run), the
  server was 91% busy and the load generator 91% to 99% busy:

  | load shape | HotKV GET | server CPU | load generator CPU |
  |---|---|---|---|
  | as in this run (9,600 connections, pipeline 30) | 94.4 M | 91% | 91% |
  | 19,200 connections | 92.2 M | 91% | 97% |
  | half the memtier threads | 76.7 M | 79% | 56% |
  | half the memtier processes | 73.8 M | 76% | 54% |
  | pipeline 60 | 96.8 M | 87% | 99% |
  | load generator kept off the interrupt CPUs | 93.9 M | 89% | 90% |

  More connections, a deeper pipeline or moving the load generator off the interrupt CPUs did not
  raise the result, and halving the load generator's threads or processes lowered it. The 192 vCPUs
  of each machine are 96 physical cores with hyperthreading.
- **Client-bound figures.** The harness flags the commands where the load generator's CPU averaged
  above 85% over the run (see `RESULTS.md`): PING for HotKV (90%) and for Dragonfly (85%). Both
  figures are floors, and no ratio between them is claimed.
- **Run-to-run spread.** HotKV's SET and SETNX were higher in their first run than in the next two
  (SET 74.9, 61.5 and 61.5 M; SETNX 94.3, 71.3 and 70.5 M), so their medians are well below the first
  run. All three runs of every command are in `comparison.json`.
- **Redis and Valkey** moved at most 5 Gbps in and 9 Gbps out in any single run, and Dragonfly at most
  78 Gbps in (HSET) and 70 Gbps out (MGET). None of them were limited by the network.
- **CPU figures.** I/O threads (Redis, Valkey) and proactor threads (Dragonfly) can keep
  cores busy without executing commands, so the CPU and ops-per-CPU-second columns are
  not a comparison of efficiency between servers.

## Connection setup

The run opens 9,600 connections at once, and every server was given a listen backlog of 65,535, so
all connections are open within seconds and the tests of the 16 processes overlap. The wall time of
every command run in `comparison.json` (`server_resources.wall_ms`) was between 15.3 and 16.3 seconds
for every server, so no server needed extra time to accept its connections.

## Reproducing

On the server, after `harness/setup_server.sh` (build tools, Redis, Valkey, memtier and Dragonfly at the
versions above) and `harness/tune_server.sh`, with HotKV built with `-DHOTKV_NATIVE=ON`, memtier on the
load generator, the host network settings above on both machines, and an SSH key the server can use to
reach the load generator:

```bash
BENCH_CLIENTS="<client-ip>" SSH_USER=<user> SSH_KEY=~/.ssh/<key> \
SERVER_ADDR=<server-ip> MEMTIER_PROCS=16 SEED_ARGS="--distinct-client-seed --randomize" \
MAXCLIENTS=65000 TCP_BACKLOG=65535 SKIP_EXCLUSIVE=1 SWEEP=0 FIXED_THREADS=192 NET_LINK_GBPS=300 \
bash harness/full_bench.sh 3 256 30
python3 harness/render_report.py /tmp/full_bench_p30/comparison.json -o RESULTS.md --title "..." --banner "..."
python3 harness/render_html.py /tmp/full_bench_p30/comparison.json -o RESULTS.html --title "..." --banner "..."
```

`raw/run.log` is the harness's own output for this run, and `raw/p30_4srv_raw.tgz` holds memtier's output
for every run of every command.

Two things in `raw/run.log` need a word. The twelve `Killed` lines (three runs of four servers) are the
shell reporting that the harness stopped a server between runs. And the harness prints a HotKV commit
hash taken from `HOTKV_SHA_OVERRIDE`, because the build on the server came from a source archive
without a git tree.

A first launch of this run was stopped part-way, to investigate the CPU figures in the separate tests
above, and its output was set aside. The run reported here is a complete fresh run of all four servers,
started afterwards on the same machines. The first launch's HotKV figures were in the same range.

The scripts in `harness/` are the ones this run used. Compared with the Azure D160 run they add three
settings that are off unless set (`MEMTIER_PROCS`, `TCP_BACKLOG`, and the extra row in the report that
shows the number of memtier processes). Nothing that changes how a server is built, started or measured
changes when they are not set.

## Notices

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named
here only to identify the software that was measured; their use does not imply any
sponsorship, endorsement or affiliation. The results describe this configuration, on
this hardware, on this date; other workloads, value sizes, pipeline depths or
configurations will give different results. If you find an error, or a setting that is
unfair to any server, contact HotKV Ltd through hotkv.com and we will re-measure and
correct the results.
