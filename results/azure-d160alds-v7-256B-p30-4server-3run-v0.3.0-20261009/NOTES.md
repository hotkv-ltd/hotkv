# Notes: Azure D160alds_v7 (AMD EPYC 9V45, Turin), 9 October 2026

What was measured, how, and how to read the flagged figures in `RESULTS.md`. Every
throughput figure in `RESULTS.md` is a measured value; nothing here changes one.

This benchmark was run by HotKV Ltd, the maker of HotKV.

## Rig

| | |
|---|---|
| Server | Azure `Standard_D160alds_v7`: 160 vCPUs (AMD EPYC 9V45, 5th generation EPYC, Turin), 314 GB RAM |
| Load generators | 3 x Azure `Standard_D64alds_v7`, 64 vCPUs each, running memtier_benchmark only |
| Placement | Azure Sweden Central, one availability zone, one virtual network; all benchmark traffic over private addresses |
| OS | Ubuntu 24.04.4 LTS, kernel 6.17.0-1022-azure, on every machine |
| Compiler | GCC 13.3.0 (Ubuntu 24.04) for every server built from source |

## Versions

The latest stable release of each competitor on the day of the run, taken from the
projects' GitHub release tags.

| server | version | how it was built |
|---|---|---|
| HotKV | 0.3.0 | from source, CMake release build with `-DHOTKV_NATIVE=ON` (`-march=native`, tuned to this CPU), jemalloc |
| Redis | 8.10.2 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc 5.3.0) |
| Valkey | 9.1.2 | release tarball, `make BUILD_TLS=no` (upstream's default optimisation flags and bundled jemalloc 5.3.0) |
| Dragonfly | v2.0.2 | git tag `v2.0.2`, upstream's release build (`helio/blaze.sh -release`, `ninja dragonfly`) |
| memtier_benchmark | built from its GitHub source (its build string is in `RESULTS.md`) | the same build on every load generator, for every server |

HotKV is built for the exact CPU it runs on (`-march=native`); the others are their
stock release builds.

The HotKV binary was built from the main branch of HotKV's source on the day of the run.
It reports version 0.3.0 and is newer than the 0.3.0 release tag (it carries bug fixes made
after that tag). The harness recorded no commit hash for it; the version line in `raw/run.log`
is what the binary itself reported.

## Configuration

- **Threads.** Every server was given all 160 vCPUs: HotKV `--threads 160`, Dragonfly
  `--proactor_threads=160`, Valkey `io-threads 160`, Redis `io-threads 128` (Redis
  8.10.2 accepts 1 to 128 and refuses to start above that). The harness also passed
  Redis `io-threads-do-reads yes`, which Redis 8.10.2 lists as deprecated and ignores. Redis and Valkey execute commands on a single thread; their
  I/O threads parallelise reading and writing the network only. They can reach higher
  throughput with fewer I/O threads than they were given here, so their figures may be
  below their best on this machine.
- **Single instance.** Each server ran as one process. Redis and Valkey are designed to
  scale beyond one command thread by running several instances as a cluster; a cluster
  was not measured here.
- **Persistence off** for every server: Redis and Valkey `--save "" --appendonly no`,
  Dragonfly `--dbfilename=`, HotKV `--no-snapshot`.
- **Network exposure.** Every server listened on the private network with protected
  mode off; nothing else differed from its defaults. The exact launch line and the
  effective configuration read back from each running server are in `RESULTS.md`.
- **Load.** On each load generator: 64 memtier threads x 50 connections, pipeline 30,
  256-byte values, 10 seconds per command. Before each command the keyspace was emptied
  and 5,000,000 keys were written, so reads find their keys. Every client used its own
  random seed over the whole keyspace. Three runs per command; `RESULTS.md` reports the
  median.

## Network ceilings

iperf3 over the private network immediately before the run, 8 streams per pair:

| direction | measured |
|---|---|
| server to all three load generators at once (outbound) | 78.4 Gbps (27.3 + 26.5 + 24.6) |
| all three load generators to the server at once (inbound) | 131.7 Gbps (44.1 + 43.8 + 43.8) |
| server to one load generator | 77.7 Gbps |

Azure lists 80 Gbps of network bandwidth for this size and 45 Gbps for a
`D64alds_v7`. The inbound figure is what three load generators could send between
them, so the server's inbound ceiling is at least 131.7 Gbps. `RESULTS.md` was rendered with a
78 Gbps link (`NET_LINK_GBPS=78`).

## Reading the flagged figures

`RESULTS.md` flags a figure when its traffic reaches 85% of the 78 Gbps link, or when
the load generators' CPU reaches 85%. A flagged figure may be below what the server
could do, and ratios built on one are given as bounds.

- **Reads send the values out**, so the outbound cap applies. Over the 10-second test
  window the server's NIC counters show HotKV's GET at 78.8 Gbps and MGET at 82.0 Gbps
  outbound (medians of three runs), which is the measured outbound ceiling. Both are
  floors set by the instance; HotKV's true read throughput on this CPU is higher.
- **Writes receive the values.** Inbound, HotKV's SETNX moved 134.5 Gbps, HSET 132.0,
  SADD 122.3 and SET 122.0 against an inbound ceiling of at least 131.7 Gbps, so those
  four are floors set by the network as well. RPUSH (106.1) and MSET (105.6) used about
  80%, LPUSH 58%, APPEND 46%.
- **Correction, 22 October 2026.** The `link used` column in `RESULTS.md` and the
  figures first quoted here (GET 88%, SETNX 105.7 Gbps) came from the harness adding
  inbound and outbound bytes and dividing by its wall clock, which includes server
  launch and teardown (about 13 s), not the 10-second test. The figures above divide
  the per-direction NIC byte counts in `raw/p30_4srv_raw.tgz` (`server_resources.rx_bytes`
  and `tx_bytes`) by the 10-second test duration. The understatement was in HotKV's
  disfavour: more of its figures were network-bound than the table marks.
- **PING and INCR move little data** and are limited by the load generators. On PING
  the load generators' CPU reached 86% with HotKV and 82% with Dragonfly; the 0.6%
  difference between them is within that limit, so PING is a tie between the two.
- **Redis and Valkey** reached neither limit on any command (at most 11% of the link
  and 2% load-generator CPU); Dragonfly reached at most 52% of the outbound ceiling
  (MGET, 40.6 Gbps) and 34% of the inbound one (HSET, 44.5 Gbps), and 13%
  load-generator CPU, apart from PING.
- **CPU figures.** I/O threads (Redis, Valkey) and proactor threads (Dragonfly) can keep
  cores busy without executing commands, so the CPU and ops-per-CPU-second columns are
  not a comparison of efficiency between servers.

## Reproducing

On the server, after `harness/setup_server.sh` (build tools, Redis, Valkey,
memtier and Dragonfly at the versions above) and `harness/tune_server.sh`, with
HotKV built with `-DHOTKV_NATIVE=ON`, memtier on each load generator, and an SSH key
the server can use to reach them:

```bash
BENCH_CLIENTS="<client1-ip> <client2-ip> <client3-ip>" SSH_USER=<user> SSH_KEY=~/.ssh/bench_id \
SERVER_ADDR=<server-ip> SWEEP=0 FIXED_THREADS=160 NET_LINK_GBPS=78 \
bash harness/full_bench.sh 3 256 30
python3 harness/render_report.py /tmp/full_bench_p30/comparison.json -o RESULTS.md --title "..." --banner "..."
python3 harness/render_html.py /tmp/full_bench_p30/comparison.json -o RESULTS.html --title "..." --banner "..."
```

`raw/run.log` is the harness's own output for this run, and `raw/p30_4srv_raw.tgz`
holds memtier's output for every run of every command.

Two things in `raw/run.log` need a word. Six `SET (4KB+comp)` rows show 0 ops/sec: the
extra HotKV instance started with value compression for that leg did not come up, so the
leg produced no data and nothing from it is reported. The log's warning to add client
machines before publishing concerns `PING`, where the load generators ran at 86 to 89
percent CPU; `RESULTS.md` marks that figure as limited by the clients and shows the ratios
over it as lower bounds.

The scripts in `harness/` are the ones this run used, with three changes made since: the
harness now records the memtier thread count per load generator directly instead of
deriving it from the server's core count (the mistake described below), the report
renderers add the trademark notice and print the footer shown in `RESULTS.md`, and the
wording of the summary line that lists commands on which another server measured higher
was tidied. Nothing that changes how a server is built, started or measured was touched.

Two pieces of metadata the harness wrote were wrong and were corrected after the run:
the memtier threads per load generator (it wrote 156; memtier's own output shows 64)
and a note that no server had a memory cap (Dragonfly kept its default cap, which the
run never came near). Both corrections, with the evidence, are listed in
`comparison.json` under `corrections`.

## Notices

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named
here only to identify the software that was measured; their use does not imply any
sponsorship, endorsement or affiliation. The results describe this configuration, on
this hardware, on this date; other workloads, value sizes, pipeline depths or
configurations will give different results. If you find an error, or a setting that is
unfair to any server, contact HotKV Ltd through hotkv.com and we will re-measure and
correct the results.
