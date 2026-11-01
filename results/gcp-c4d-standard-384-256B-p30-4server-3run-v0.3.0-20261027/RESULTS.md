# HotKV vs Redis vs Valkey vs Dragonfly: GCP c4d-standard-384 (AMD EPYC 9B45, Turin), 256B pipeline=30

> Google Cloud's network limited this rig. iperf3 measured 172 Gbps outbound and 176 Gbps inbound (two client machines). The NIC counters of the run show HotKV's GET and MGET at 173 Gbps outbound, so those two are floors set by the link, and its inbound-heavy writes (SET, SETNX, RPUSH, SADD, HSET, MSET) at 157 to 186 Gbps, close to or at the inbound ceiling. The link-used column below is averaged over a window longer than the 10-second test and understates these; NOTES.md has the figures over the test window. HotKV was built from source with -march=native for this CPU; Redis, Valkey and Dragonfly are their stock release builds. Every server was given all 384 vCPUs (Redis 128 I/O threads, its maximum; Valkey 256) and run as a single instance, each with a listen backlog of 65,535. See NOTES.md.

## Rig

| | |
|---|---|
| Platform | GCP c4d-standard-384 (AMD EPYC 9B45, Turin) (virtual machine) |
| CPU | AMD EPYC 9B45, 384 cores, x86_64 |
| RAM | 1464.4 GB |
| OS | Linux 7.0.0-1014-gcp |
| Load generator | 2 dedicated client machine(s): 10.128.0.44, 10.128.0.46 |
| Network | ens3, 172 Gbps link |
| Benchmark tool | memtier_benchmark memtier_benchmark v=255.255.255 sha=272eeb64:0 bits=64 libevent=2.1.12-stable openssl=OpenSSL 3.0.13 30 Jan 2024 prometheus=yes |

### Versions

| server | version |
|---|---|
| HotKV | 0.3.0 |
| Redis | 8.10.3 |
| Valkey | 9.1.3 |
| Dragonfly | v2.0.2 |

## Benchmark configuration

Everything needed to reproduce this run, and to check that no server was
handicapped. The launch lines and effective configs below are read back from
each live server, not copied from the script.

### Load

| | |
|---|---|
| Value size | 256 bytes |
| Pipeline depth | 30 |
| memtier threads per client box | 192 |
| memtier processes per client box | 16 |
| Connections per thread | 50 |
| Total connections per client box | 9,600 |
| Test duration per command | 10 s |
| Runs per command | 3 |
| Reported statistic | median of runs |
| Key pattern | R (uniform random) over the populated range |
| Keyspace size (keys) | 5,000,000 |
| Populate | P (parallel sequential), --requests=allkeys |
| Distinct seed per client | yes |

**Server threads** (the same for every server: all the machine's cores, clamped to each server's maximum): HotKV=384, Redis=128, Valkey=256, Dragonfly=384

> Redis and Valkey execute commands on a single thread; the threads they
> were given here are I/O threads. They can reach higher throughput with
> fewer I/O threads than this, so their figures may be below their best
> on this machine. Each was run as a single instance, not as a cluster.

### Host

| setting | value |
|---|---|
| Transparent hugepages | `always madvise [never]` |
| vm.overcommit_memory | `1` |
| net.core.somaxconn | `65535` |
| Open file limit | `1048576` |
| Interface | `ens3` |

### Per-server

**HotKV**

```
/opt/hotkv/build/release/src/hotkv --port 6399 --bind 0.0.0.0 --threads 384 --no-snapshot --protected-mode no --maxclients 65000 --tcp-backlog 65535 --loglevel warning
```

| directive | effective value |
|---|---|
| `maxmemory` | `0` |
| `maxmemory-policy` | `noeviction` |
| `io-threads` | `1` |
| `appendonly` | `no` |
| `protected-mode` | `no` |
| `tcp-backlog` | `65535` |
| `timeout` | `0` |
| `hz` | `10` |
| `databases` | `16` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Redis**

```
/opt/redis-8.10.3/src/redis-server --port 6399 --bind 0.0.0.0 --save  --appendonly no --protected-mode no --maxclients 65000 --tcp-backlog 65535 --io-threads 128 --io-threads-do-reads yes --loglevel warning
```

| directive | effective value |
|---|---|
| `maxmemory` | `0` |
| `maxmemory-policy` | `noeviction` |
| `io-threads` | `128` |
| `appendonly` | `no` |
| `protected-mode` | `no` |
| `tcp-backlog` | `65535` |
| `timeout` | `0` |
| `hz` | `10` |
| `databases` | `16` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Valkey**

```
/opt/valkey-9.1.3/src/valkey-server --port 6399 --bind 0.0.0.0 --save  --appendonly no --protected-mode no --maxclients 65000 --tcp-backlog 65535 --io-threads 256 --loglevel warning
```

| directive | effective value |
|---|---|
| `maxmemory` | `0` |
| `maxmemory-policy` | `noeviction` |
| `io-threads` | `256` |
| `appendonly` | `no` |
| `protected-mode` | `no` |
| `tcp-backlog` | `65535` |
| `timeout` | `0` |
| `hz` | `10` |
| `databases` | `16` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Dragonfly**

```
/opt/dragonfly/build-opt/dragonfly --port 6399 --bind 0.0.0.0 --proactor_threads=384 --dbfilename= --noversion_check --logtostderr --tcp_backlog=65535 
```

| directive | effective value |
|---|---|
| `maxmemory` | `1247239051673` |
| `timeout` | `0` |
| `databases` | `16` |

### Fairness notes

- maxmemory=0 (no memory cap) on HotKV, Redis, Valkey; Dragonfly kept its default cap (maxmemory 1247 GB; its largest resident set in the run was 41 GB).
- Persistence off everywhere (Redis/Valkey --save '' --appendonly no; Dragonfly --dbfilename= ). No server pays disk IO the others do not.
- No server-specific tuning beyond thread count and the client-connection ceiling: maxclients 65000 on HotKV, Redis and Valkey (the load generators open 19,200 connections, above the 10,000 default); Dragonfly was left at its default. See tuning.tuned_threads.
- The read range is exactly the range populate filled, so reads hit ~100% and measure the value path rather than the nil path.
- --distinct-client-seed: every client gets its own key sequence. Without it memtier seeds all clients identically and thousands of connections replay one key order, which manufactures cache locality no real workload has. Applied to every server equally.

## Throughput (ops/sec, median of 3 runs)

| command | HotKV | Redis | Valkey | Dragonfly |
|---|---|---|---|---|
| SET | **62,474,174** | 1,306,196 | 826,739 | 10,053,518 |
| GET | **80,483,397** | 1,096,393 | 1,289,269 | 9,024,100 |
| MGET | **10,079,478** | 207,617 | 402,570 | 1,364,508 |
| SETNX | **65,156,448** | 1,044,184 | 1,442,953 | 10,985,281 |
| APPEND | **29,424,542** | 709,594 | 649,004 | 8,329,877 |
| INCR | **237,126,786** | 1,205,406 | 1,577,061 | 11,029,118 |
| LPUSH | **42,960,161** | 648,946 | 710,282 | 8,953,869 |
| RPUSH | **64,392,579** | 632,306 | 732,005 | 10,048,631 |
| SADD | **65,953,939** | 667,492 | 736,637 | 10,218,602 |
| HSET | **39,150,266** | 536,681 | 650,213 | 8,300,457 |
| MSET | **18,497,269** | 396,164 | 333,744 | 1,827,592 |
| PING | **275,649,341** | 2,392,032 | 2,890,875 | 266,318,780 |

## Resource usage

Per command and server, each column is the median of that metric over the runs,
so a row need not come from one single run. `cores` is CPU time over
wall time (8.0 = eight cores fully busy). `ops/CPU-s` is throughput per second
of CPU consumed - the efficiency figure that still means something on a
different machine. Memory is the server process's resident set; `peak` is its
high-water mark including the populate phase.

| command | server | ops/sec | cores | ops/CPU-s | RSS MB | peak MB | Gbps | link % | hit % |
|---|---|---|---|---|---|---|---|---|---|
| SET | HotKV | 62,474,174 | 121.6 | 26,816 | 3,662 | 3,662 | 86.17 | 50 | - |
| SET | Redis | 1,306,196 | 58.7 | 1,173 | 1,962 | 1,962 | 1.87 | 1 | - |
| SET | Valkey | 826,739 | 9.2 | 4,834 | 2,279 | 2,279 | 1.23 | 1 | - |
| SET | Dragonfly | 10,053,518 | 115.3 | 4,249 | 2,615 | 4,662 | 13.35 | 8 | - |
| GET | HotKV | 80,483,397 | 100.2 | 43,074 | 3,437 | 3,549 | 106.43 | 62 | 100.0 |
| GET | Redis | 1,096,393 | 62.2 | 934 | 2,009 | 2,009 | 1.58 | 1 | 100.0 |
| GET | Valkey | 1,289,269 | 9.8 | 6,332 | 1,896 | 2,309 | 1.86 | 1 | 100.0 |
| GET | Dragonfly | 9,024,100 | 127.9 | 3,665 | 2,936 | 4,662 | 12.00 | 7 | 100.0 |
| MGET | HotKV | 10,079,478 | 99.4 | 5,409 | 4,679 | 4,679 | 102.23 | 59 | - |
| MGET | Redis | 207,617 | 60.9 | 162 | 1,981 | 1,981 | 2.71 | 2 | - |
| MGET | Valkey | 402,570 | 6.3 | 3,218 | 1,901 | 2,309 | 4.63 | 3 | - |
| MGET | Dragonfly | 1,364,508 | 120.6 | 581 | 4,621 | 6,896 | 13.83 | 8 | - |
| SETNX | HotKV | 65,156,448 | 94.9 | 36,870 | 3,719 | 4,272 | 91.76 | 53 | - |
| SETNX | Redis | 1,044,184 | 31.3 | 1,731 | 1,991 | 1,991 | 1.48 | 1 | - |
| SETNX | Valkey | 1,442,953 | 6.8 | 11,234 | 1,899 | 2,309 | 2.06 | 1 | - |
| SETNX | Dragonfly | 10,985,281 | 119.5 | 4,690 | 3,528 | 6,896 | 14.62 | 9 | - |
| APPEND | HotKV | 29,424,542 | 78.9 | 19,820 | 120,829 | 120,957 | 42.24 | 25 | - |
| APPEND | Redis | 709,594 | 28.1 | 1,294 | 7,451 | 7,451 | 1.03 | 1 | - |
| APPEND | Valkey | 649,004 | 8.3 | 4,285 | 7,049 | 7,049 | 0.95 | 1 | - |
| APPEND | Dragonfly | 8,329,877 | 124.1 | 3,356 | 30,188 | 30,974 | 11.16 | 6 | - |
| INCR | HotKV | 237,126,786 | 185.0 | 67,234 | 2,787 | 120,957 | 45.63 | 27 | - |
| INCR | Redis | 1,205,406 | 2.1 | 31,188 | 497 | 6,950 | 0.25 | 0 | - |
| INCR | Valkey | 1,577,061 | 2.9 | 26,848 | 422 | 7,023 | 0.33 | 0 | - |
| INCR | Dragonfly | 11,029,118 | 117.2 | 5,001 | 2,684 | 30,974 | 2.17 | 1 | - |
| LPUSH | HotKV | 42,960,161 | 170.8 | 13,497 | 152,179 | 152,179 | 60.46 | 35 | - |
| LPUSH | Redis | 648,946 | 22.9 | 1,438 | 5,250 | 6,950 | 0.91 | 1 | - |
| LPUSH | Valkey | 710,282 | 8.7 | 4,284 | 5,426 | 7,023 | 1.03 | 1 | - |
| LPUSH | Dragonfly | 8,953,869 | 121.1 | 3,767 | 37,528 | 37,554 | 11.82 | 7 | - |
| RPUSH | HotKV | 64,392,579 | 162.8 | 20,888 | 217,493 | 217,493 | 89.30 | 52 | - |
| RPUSH | Redis | 632,306 | 41.6 | 801 | 5,280 | 6,950 | 0.92 | 1 | - |
| RPUSH | Valkey | 732,005 | 6.5 | 5,909 | 5,505 | 7,023 | 1.03 | 1 | - |
| RPUSH | Dragonfly | 10,048,631 | 126.4 | 4,045 | 40,827 | 40,827 | 13.27 | 8 | - |
| SADD | HotKV | 65,953,939 | 136.1 | 25,627 | 10,817 | 216,894 | 92.44 | 54 | - |
| SADD | Redis | 667,492 | 32.1 | 1,034 | 2,488 | 6,950 | 0.94 | 1 | - |
| SADD | Valkey | 736,637 | 5.6 | 6,678 | 2,634 | 7,023 | 1.03 | 1 | - |
| SADD | Dragonfly | 10,218,602 | 116.7 | 4,427 | 4,619 | 40,456 | 13.46 | 8 | - |
| HSET | HotKV | 39,150,266 | 112.8 | 17,093 | 18,947 | 216,894 | 93.97 | 55 | - |
| HSET | Redis | 536,681 | 65.4 | 416 | 4,714 | 6,950 | 1.44 | 1 | - |
| HSET | Valkey | 650,213 | 7.6 | 3,837 | 5,133 | 7,023 | 1.70 | 1 | - |
| HSET | Dragonfly | 8,300,457 | 118.6 | 3,564 | 8,053 | 40,456 | 20.58 | 12 | - |
| MSET | HotKV | 18,497,269 | 121.5 | 7,564 | 5,861 | 216,894 | 91.69 | 53 | - |
| MSET | Redis | 396,164 | 65.5 | 305 | 3,181 | 6,950 | 2.37 | 1 | - |
| MSET | Valkey | 333,744 | 13.0 | 1,301 | 2,941 | 7,023 | 1.86 | 1 | - |
| MSET | Dragonfly | 1,827,592 | 92.3 | 1,021 | 4,697 | 40,456 | 9.20 | 5 | - |
| PING | HotKV | 275,649,341 | 82.9 | 178,783 | 5,298 | 216,894 | 30.12 | 18 | - |
| PING | Redis | 2,392,032 | 2.1 | 61,619 | 2,162 | 6,950 | 0.29 | 0 | - |
| PING | Valkey | 2,890,875 | 12.5 | 12,439 | 1,962 | 7,023 | 0.35 | 0 | - |
| PING | Dragonfly | 266,318,780 | 123.9 | 114,425 | 4,212 | 40,456 | 28.84 | 17 | - |

## Validity checks

These decide which numbers mean anything. A result produced against a full
cable or a maxed-out load generator is a measurement of the rig, not the
server.

**What "wire-bound" means, in plain terms:** every request and reply travels
over the machine's network connection, which has a fixed top speed (its
bandwidth). When a command moves enough data to fill that connection, the
network, not the server, becomes the bottleneck: the server could go faster but
the wire cannot carry any more. The ops/sec figure then measures the cable
rather than the software. Read a wire-bound number as a floor (the true server
number is higher, and shows up on a faster link or with a smaller value size,
which puts fewer bytes on the wire per operation). Any ratio between two servers
that are both wire-bound is meaningless. The "link used" column is the share of
the link a command consumed; the threshold for the flag is 85%.

> Caveat for cloud NICs: the "link used" figure assumes one link speed for both
> directions. Some cloud instances cap outbound (send) and inbound (receive)
> differently, so an inbound-heavy command (writes) can show a high figure
> without actually being limited. Where that applies it is called out in a
> NOTES.md next to this report.

### Client-bound (2)

The load generators sat above 85% CPU, so these figures may be
the load generators' ceiling rather than the server's. Treat them as lower bounds.

| command | server | client CPU |
|---|---|---|
| PING | HotKV | 89% |
| PING | Dragonfly | 89% |


## HotKV vs each server

HotKV's throughput divided by the other server's, on the same command. Where a
figure was flagged above (wire-bound or client-bound), the true figure may be
higher, and the ratio is given as a bound: `>=` where HotKV's was flagged, `<=`
where the other server's was, and no ratio where both were.

| command | vs Redis | vs Valkey | vs Dragonfly |
|---|---|---|---|
| SET | 47.83x | 75.57x | 6.21x |
| GET | 73.41x | 62.43x | 8.92x |
| MGET | 48.55x | 25.04x | 7.39x |
| SETNX | 62.40x | 45.15x | 5.93x |
| APPEND | 41.47x | 45.34x | 3.53x |
| INCR | 196.72x | 150.36x | 21.50x |
| LPUSH | 66.20x | 60.48x | 4.80x |
| RPUSH | 101.84x | 87.97x | 6.41x |
| SADD | 98.81x | 89.53x | 6.45x |
| HSET | 72.95x | 60.21x | 4.72x |
| MSET | 46.69x | 55.42x | 10.12x |
| PING | >= 115.24x | >= 95.35x | n/a (both limited by the rig) |

Median ratio over the commands above: >= 69.57x vs Redis (12 commands), >= 61.45x vs Valkey (12 commands), 6.41x vs Dragonfly (11 commands).

---

Data: `comparison.json`. It carries every individual run, not just the medians shown here.

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named only to identify the software that was measured; this implies no sponsorship, endorsement or affiliation.
