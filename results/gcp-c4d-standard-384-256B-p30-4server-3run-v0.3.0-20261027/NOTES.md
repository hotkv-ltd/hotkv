# Notes: Google Cloud c4d-standard-384 (AMD EPYC 9B45, Turin), 27 October 2026

What was measured, how, and how to read the flagged figures in `RESULTS.md`. Every
throughput figure in `RESULTS.md` is a measured value; nothing here changes one.

This benchmark was run by HotKV Ltd, the maker of HotKV.

## Rig

| | |
|---|---|
| Server | Google Cloud `c4d-standard-384`: 384 vCPUs (AMD EPYC 9B45, 2 sockets, 96 cores each, 2 threads per core), 1,464 GB RAM |
| Load generators | 2 x Google Cloud `h4d-standard-192`, 192 vCPUs each, running memtier_benchmark only |
| Placement | `us-central1-a`, one VPC network; all benchmark traffic over private addresses |
| OS | Ubuntu 24.04.5 LTS, kernel 7.0.0-1014-gcp, on every machine |
| Network interface | gVNIC (driver `gve`), MTU 1460, 16 receive and 16 transmit queues on every machine |
| Compiler | GCC 13.3.0 (Ubuntu 24.04) for every server built from source |

## Versions

The latest stable release of each competitor on the day of the run.

| server | version | how it was built |
|---|---|---|
| HotKV | 0.3.0 (commit `38a0d11d`) | from source, CMake release build with `-DHOTKV_NATIVE=ON` (`-march=native`, tuned to this CPU), jemalloc |
| Redis | 8.10.3 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc 5.3.0) |
| Valkey | 9.1.3 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc 5.3.0) |
| Dragonfly | v2.0.2 (commit `8ce4bbb1`) | git tag `v2.0.2`, upstream's release build |
| memtier_benchmark | commit `272eeb64` | the same build on every load generator, for every server |

HotKV is built for the exact CPU it runs on (`-march=native`); the others are their
stock release builds. The HotKV commit is `38a0d11d`, which is newer than the 0.3.0 release
tag (32 commits). It adds a fix to the RESP parser (empty lines between commands are skipped, as
Redis does) and the other fixes made after the tag; the binary itself reports `HotKV v0.3.0`.

## Configuration

- **Threads.** Every server was given all 384 vCPUs: HotKV `--threads 384`, Dragonfly
  `--proactor_threads=384`, Valkey `io-threads 256` (its maximum), Redis `io-threads 128`
  (Redis 8.10.3 accepts 1 to 128 and refuses to start above that). Redis and Valkey execute
  commands on a single thread; their I/O threads parallelise reading and writing the network
  only. They can reach higher throughput with fewer I/O threads than they were given here, so
  their figures may be below their best on this machine.
- **Single instance.** Each server ran as one process. Redis and Valkey are designed to
  scale beyond one command thread by running several instances as a cluster; a cluster
  was not measured here.
- **Persistence off** for every server: Redis and Valkey `--save "" --appendonly no`,
  Dragonfly `--dbfilename=`, HotKV `--no-snapshot`.
- **Connections.** Every server accepted up to 65,000 clients (`--maxclients 65000` for HotKV,
  Redis and Valkey; Dragonfly's default is 64,000). The run opens 19,200 connections.
- **Listen backlog.** Every server was started with a listen backlog of 65,535 (HotKV, Redis
  and Valkey `--tcp-backlog 65535`, Dragonfly `--tcp_backlog=65535`; the harness setting
  `TCP_BACKLOG`). See "Connection setup" below.
- **Network exposure.** Every server listened on the private network with protected
  mode off; nothing else differed from its defaults. The exact launch line and the
  effective configuration read back from each running server are in `RESULTS.md`.
- **Load.** On each load generator 16 memtier_benchmark processes ran at the same time, each with
  12 threads x 50 connections (192 threads and 9,600 connections per load generator, 19,200 in
  total), pipeline 30, 256-byte values, 10 seconds per command. Every process used its own random
  seed (`--distinct-client-seed --randomize`). Before each command the keyspace was emptied and
  5,000,000 keys were written, so reads find their keys. Three runs per command; `RESULTS.md`
  reports the median. The reason for several processes per load generator is in the README
  (a single memtier_benchmark process does not scale to 192 threads).
- **Host network settings.** The settings in the README section "Check the network before you run"
  were applied before the run on the server and on both load generators: receive steering
  (RPS and RFS) over all CPUs, rings of 4096, a larger softirq budget, and the 16 transmit-queue
  interrupts of the gVNIC moved from CPUs 0 to 15 (where the receive interrupts are) to CPUs 16 to 31.
  The settings do not depend on which server runs; every server got them equally.
- **Exclusive legs skipped.** The harness's optional legs that start an extra HotKV instance with
  value compression were not run (`SKIP_EXCLUSIVE=1`). Nothing from them is reported.

## Network ceilings

iperf3 over the private network immediately before the run, 8 streams per pair:

| direction | measured |
|---|---|
| server to both load generators at once (outbound) | 172.4 Gbps (72.6 + 99.9) |
| both load generators to the server at once (inbound) | 175.7 Gbps (53.8 + 121.9) |
| server to one load generator | 165.9 Gbps (8 streams), 53.7 Gbps (one flow) |

`RESULTS.md` was rendered with a 172 Gbps link (`NET_LINK_GBPS=172`). The ceilings are measured with
iperf3 and are floors: the run itself moved more than that inbound (see below).

## Reading the flagged figures

The harness reads the server's network counters and its CPU time over the whole time it measures a
command: starting the server, writing the 5,000,000 keys, the 10-second test and stopping the server.
That is about 19 seconds per command here, against 10 seconds of test. So the `Gbps`, `link used`,
`cores` and `ops/CPU-s` columns in `RESULTS.md` are averages over a window about twice as long as the
test and read low. The throughput and latency figures are not affected. The figures below divide the
per-direction NIC byte counts in `raw/p30_4srv_raw.tgz` (`server_resources.rx_bytes` and `tx_bytes`) by
the 10-second test duration (medians of three runs). They agree with the bytes per request: HotKV's GET
sent 269 bytes per reply and its SET received 315 bytes per request.

| HotKV command | ops/sec | inbound Gbps | outbound Gbps |
|---|---|---|---|
| SET | 62.5 M | 157.3 | 7.9 |
| SETNX | 65.2 M | 165.3 | 7.1 |
| RPUSH | 64.4 M | 163.3 | 5.9 |
| SADD | 66.0 M | 166.6 | 8.1 |
| HSET | 39.2 M | 185.7 | 7.7 |
| MSET | 18.5 M | 180.2 | 4.4 |
| LPUSH | 43.0 M | 109.0 | 3.7 |
| APPEND | 29.4 M | 75.9 | 3.1 |
| GET | 80.5 M | 25.5 | 173.0 |
| MGET | 10.1 M | 17.7 | 173.5 |
| INCR | 237.1 M | 72.1 | 15.1 |
| PING | 275.6 M | 35.7 | 20.3 |

- **Reads send the values out**, so the outbound cap applies. HotKV's GET and MGET moved 173.0 and
  173.5 Gbps outbound, which is the measured outbound ceiling of 172.4 Gbps. Both are floors set by
  the network; HotKV's true read throughput on this CPU is higher.
- **Writes receive the values.** HSET and MSET moved 185.7 and 180.2 Gbps inbound, above the 175.7
  Gbps that iperf3 measured, so the real inbound ceiling is at least 186 Gbps. SET, SETNX, RPUSH and
  SADD moved 157 to 167 Gbps, and they cluster at 62 to 66 million operations per second, which is what
  a shared ceiling looks like. They are floors set by the network too. LPUSH (109 Gbps) and APPEND
  (76 Gbps) were below it.
- **Network-bound figures do not scale with the machine.** The extra cores of this server over the
  Azure D160 run lift HotKV's reads and its small commands (INCR, PING) by 2.2 to 2.6 times, but its
  larger writes by only 1.2 to 1.6 times, because the inbound ceiling grew less than the core count.
- **PING and INCR move little data** and are limited by the load generators. On PING the load
  generators' CPU, averaged over memtier's whole run, was 89% with HotKV and 89% with Dragonfly,
  and `RESULTS.md` flags both. On the test window alone it was higher. The 3% difference
  between the two servers (275.6 M and 266.3 M, with runs from 270 to 286 M and from 261 to 278 M that
  overlap) is within that limit, so PING is a tie between HotKV and Dragonfly, and both figures are
  floors.
- **Redis and Valkey** moved at most 5 Gbps in and 8 Gbps out on any command, and Dragonfly at most
  40 Gbps in (HSET) and 25 Gbps out (MGET). None of them were limited by the network.
- **CPU figures.** I/O threads (Redis, Valkey) and proactor threads (Dragonfly) can keep
  cores busy without executing commands, so the CPU and ops-per-CPU-second columns are
  not a comparison of efficiency between servers.

## Connection setup

The run opens 19,200 connections at once. With a server's default listen backlog (256 for Dragonfly,
511 for Redis, Valkey and HotKV) that burst can overflow the accept queue of a server that accepts
slowly. The kernel then drops the connection attempts, the clients retry with growing delays, and the
memtier processes start their 10-second tests minutes apart. The harness adds up the rates of all
processes, so a sum taken over tests that did not overlap is larger than what the server delivered at
any one moment. We therefore gave every server the same large backlog (65,535, which the kernel allows
through `net.core.somaxconn`). All connections are then open within seconds, the tests overlap, and
the sum is a rate the server actually sustained. If you reproduce this run without `TCP_BACKLOG`,
check the wall time per command in `comparison.json` (`server_resources.wall_ms`): a server that needs
minutes for it did not have all of its connections at the same time.

## Reproducing

On the server, after `harness/setup_server.sh` (build tools, Redis, Valkey, memtier and Dragonfly at the
versions above) and `harness/tune_server.sh`, with HotKV built with `-DHOTKV_NATIVE=ON`, memtier on each
load generator, the host network settings from the README on all three machines, and an SSH key the
server can use to reach the load generators:

```bash
BENCH_CLIENTS="<client1-ip> <client2-ip>" SSH_USER=<user> SSH_KEY=~/.ssh/<key> \
SERVER_ADDR=<server-ip> MEMTIER_PROCS=16 SEED_ARGS="--distinct-client-seed --randomize" \
MAXCLIENTS=65000 TCP_BACKLOG=65535 SKIP_EXCLUSIVE=1 SWEEP=0 FIXED_THREADS=384 NET_LINK_GBPS=172 \
bash harness/full_bench.sh 3 256 30
python3 harness/render_report.py /tmp/full_bench_p30/comparison.json -o RESULTS.md --title "..." --banner "..."
python3 harness/render_html.py /tmp/full_bench_p30/comparison.json -o RESULTS.html --title "..." --banner "..."
```

`raw/run.log` is the harness's own output for this run, and `raw/p30_4srv_raw.tgz` holds memtier's output
for every run of every command.

Three things in `raw/run.log` need a word. The warning that the load generators (192 vCPUs each) are
smaller than the server (384) is true, and the report's client-bound check covers its consequence: only
PING is flagged. The twelve `Killed` lines are the shell reporting that the harness stopped a server
between runs. And the harness prints a HotKV commit hash taken from `HOTKV_SHA_OVERRIDE`, because the
build on the server came from a source archive without a git tree.

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
