# HotKV vs Redis vs Valkey vs Dragonfly: AWS c8in.48xlarge (Intel Xeon 6975P-C, Granite Rapids), 256B pipeline=30

> One load generator of the same size as the server (192 vCPUs each) drove this run, with 9,600 connections. The 300 Gbps network was not the limit: the busiest command moved 209 Gbps, and both machines were busy during the tests. The link-used and CPU columns below are averaged over a window longer than the 10-second test; NOTES.md has the figures over the test window. HotKV was built from source with -march=native for this CPU; Redis, Valkey and Dragonfly are their stock release builds. Every server was given all 192 vCPUs (Redis 128 I/O threads, its maximum) and run as a single instance, each with a listen backlog of 65,535. See NOTES.md.

## Rig

| | |
|---|---|
| Platform | AWS c8in.48xlarge (Intel Xeon 6975P-C, Granite Rapids) (virtual machine) |
| CPU | Intel(R) Xeon(R) 6975P-C, 192 cores, x86_64 |
| RAM | 371.8 GB |
| OS | Linux 7.0.0-1014-aws |
| Load generator | 1 dedicated client machine(s): 172.31.44.151 |
| Network | ens130, 300 Gbps link |
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

**Server threads** (the same for every server: all the machine's cores, clamped to each server's maximum): HotKV=192, Redis=128, Valkey=192, Dragonfly=192

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
| Interface | `ens130` |

### Per-server

**HotKV**

```
/opt/hotkv/build/release/src/hotkv --port 6399 --bind 0.0.0.0 --threads 192 --no-snapshot --protected-mode no --maxclients 65000 --tcp-backlog 65535 --loglevel warning
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
/opt/valkey-9.1.3/src/valkey-server --port 6399 --bind 0.0.0.0 --save  --appendonly no --protected-mode no --maxclients 65000 --tcp-backlog 65535 --io-threads 192 --loglevel warning
```

| directive | effective value |
|---|---|
| `maxmemory` | `0` |
| `maxmemory-policy` | `noeviction` |
| `io-threads` | `192` |
| `appendonly` | `no` |
| `protected-mode` | `no` |
| `tcp-backlog` | `65535` |
| `timeout` | `0` |
| `hz` | `10` |
| `databases` | `16` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Dragonfly**

```
/opt/dragonfly/build-opt/dragonfly --port 6399 --bind 0.0.0.0 --proactor_threads=192 --dbfilename= --noversion_check --logtostderr --tcp_backlog=65535 
```

| directive | effective value |
|---|---|
| `maxmemory` | `315278504755` |
| `timeout` | `0` |
| `databases` | `16` |

### Fairness notes

- maxmemory=0 (no memory cap) on HotKV, Redis, Valkey; Dragonfly kept its default cap (maxmemory 315 GB; its largest resident set in the run was 62 GB).
- Persistence off everywhere (Redis/Valkey --save '' --appendonly no; Dragonfly --dbfilename= ). No server pays disk IO the others do not.
- No server-specific tuning beyond thread count and the client-connection ceiling: maxclients 65000 on HotKV, Redis and Valkey (the load generators open 9,600 connections); Dragonfly was left at its default. See tuning.tuned_threads.
- The read range is exactly the range populate filled, so reads hit ~100% and measure the value path rather than the nil path.
- --distinct-client-seed: every client gets its own key sequence. Without it memtier seeds all clients identically and thousands of connections replay one key order, which manufactures cache locality no real workload has. Applied to every server equally.

## Throughput (ops/sec, median of 3 runs)

| command | HotKV | Redis | Valkey | Dragonfly |
|---|---|---|---|---|
| SET | **61,482,683** | 1,184,006 | 892,878 | 25,428,235 |
| GET | **93,116,889** | 1,059,301 | 1,240,243 | 27,453,054 |
| MGET | **11,141,133** | 233,592 | 458,229 | 4,049,004 |
| SETNX | **71,343,058** | 1,361,495 | 1,754,620 | 27,135,916 |
| APPEND | **25,295,131** | 665,510 | 796,396 | 14,340,891 |
| INCR | **85,100,187** | 1,524,883 | 1,891,864 | 32,065,853 |
| LPUSH | **34,166,510** | 624,774 | 765,314 | 19,770,742 |
| RPUSH | **37,103,127** | 713,830 | 760,682 | 21,117,772 |
| SADD | **56,196,701** | 658,603 | 755,402 | 23,916,182 |
| HSET | **45,837,316** | 409,508 | 666,821 | 16,839,279 |
| MSET | **17,978,711** | 328,534 | 415,674 | 2,293,652 |
| PING | **189,050,648** | 3,767,306 | 2,933,705 | 180,161,580 |

## Resource usage

Per command and server, each column is the median of that metric over the runs,
so a row need not come from one single run. `cores` is CPU time over
wall time (8.0 = eight cores fully busy). `ops/CPU-s` is throughput per second
of CPU consumed - the efficiency figure that still means something on a
different machine. Memory is the server process's resident set; `peak` is its
high-water mark including the populate phase.

| command | server | ops/sec | cores | ops/CPU-s | RSS MB | peak MB | Gbps | link % | hit % |
|---|---|---|---|---|---|---|---|---|---|
| SET | HotKV | 61,482,683 | 115.0 | 34,829 | 2,909 | 2,909 | 100.06 | 33 | - |
| SET | Redis | 1,184,006 | 62.8 | 1,201 | 1,973 | 1,973 | 1.98 | 1 | - |
| SET | Valkey | 892,878 | 8.4 | 7,084 | 2,435 | 2,435 | 1.52 | 1 | - |
| SET | Dragonfly | 25,428,235 | 118.2 | 14,062 | 2,032 | 3,203 | 41.29 | 14 | - |
| GET | HotKV | 93,116,889 | 114.7 | 53,182 | 2,861 | 2,861 | 148.87 | 50 | 100.0 |
| GET | Redis | 1,059,301 | 83.1 | 824 | 2,027 | 2,027 | 1.79 | 1 | 100.0 |
| GET | Valkey | 1,240,243 | 5.9 | 13,721 | 1,897 | 2,503 | 2.07 | 1 | 100.0 |
| GET | Dragonfly | 27,453,054 | 121.7 | 14,704 | 2,126 | 3,203 | 43.96 | 15 | 100.0 |
| MGET | HotKV | 11,141,133 | 106.1 | 6,847 | 3,454 | 3,454 | 135.67 | 45 | - |
| MGET | Redis | 233,592 | 78.2 | 195 | 2,110 | 2,110 | 3.45 | 1 | - |
| MGET | Valkey | 458,229 | 5.9 | 4,980 | 1,929 | 2,503 | 6.14 | 2 | - |
| MGET | Dragonfly | 4,049,004 | 124.4 | 2,108 | 2,988 | 3,940 | 49.66 | 17 | - |
| SETNX | HotKV | 71,343,058 | 115.5 | 39,720 | 2,925 | 3,379 | 115.48 | 38 | - |
| SETNX | Redis | 1,361,495 | 55.3 | 1,571 | 2,081 | 2,081 | 2.26 | 1 | - |
| SETNX | Valkey | 1,754,620 | 7.8 | 14,591 | 1,921 | 2,503 | 2.89 | 1 | - |
| SETNX | Dragonfly | 27,135,916 | 116.9 | 14,919 | 2,483 | 3,940 | 43.80 | 15 | - |
| APPEND | HotKV | 25,295,131 | 70.7 | 22,664 | 104,480 | 104,870 | 41.41 | 14 | - |
| APPEND | Redis | 665,510 | 49.0 | 888 | 7,117 | 7,117 | 1.13 | 0 | - |
| APPEND | Valkey | 796,396 | 4.9 | 10,627 | 7,634 | 7,670 | 1.36 | 0 | - |
| APPEND | Dragonfly | 14,340,891 | 123.7 | 7,568 | 45,390 | 46,359 | 23.79 | 8 | - |
| INCR | HotKV | 85,100,187 | 120.6 | 45,706 | 2,271 | 104,870 | 19.89 | 7 | - |
| INCR | Redis | 1,524,883 | 3.0 | 33,684 | 572 | 6,993 | 0.37 | 0 | - |
| INCR | Valkey | 1,891,864 | 4.0 | 29,543 | 446 | 7,669 | 0.46 | 0 | - |
| INCR | Dragonfly | 32,065,853 | 119.2 | 17,548 | 1,486 | 46,359 | 7.47 | 2 | - |
| LPUSH | HotKV | 34,166,510 | 116.1 | 18,958 | 118,065 | 118,065 | 55.55 | 19 | - |
| LPUSH | Redis | 624,774 | 49.4 | 730 | 5,137 | 6,993 | 1.07 | 0 | - |
| LPUSH | Valkey | 765,314 | 4.2 | 11,514 | 5,630 | 7,669 | 1.30 | 0 | - |
| LPUSH | Dragonfly | 19,770,742 | 123.8 | 10,411 | 57,179 | 58,137 | 32.39 | 11 | - |
| RPUSH | HotKV | 37,103,127 | 114.9 | 20,650 | 128,633 | 128,633 | 59.56 | 20 | - |
| RPUSH | Redis | 713,830 | 53.4 | 861 | 5,568 | 6,993 | 1.21 | 0 | - |
| RPUSH | Valkey | 760,682 | 7.8 | 6,700 | 5,619 | 7,669 | 1.29 | 0 | - |
| RPUSH | Dragonfly | 21,117,772 | 121.1 | 11,198 | 61,040 | 61,966 | 34.10 | 11 | - |
| SADD | HotKV | 56,196,701 | 115.4 | 31,464 | 9,275 | 128,479 | 91.02 | 30 | - |
| SADD | Redis | 658,603 | 54.6 | 803 | 2,537 | 6,993 | 1.12 | 0 | - |
| SADD | Valkey | 755,402 | 3.4 | 14,679 | 2,685 | 7,669 | 1.27 | 0 | - |
| SADD | Dragonfly | 23,916,182 | 119.6 | 13,017 | 3,500 | 61,966 | 38.87 | 13 | - |
| HSET | HotKV | 45,837,316 | 110.9 | 26,752 | 17,502 | 128,479 | 138.22 | 46 | - |
| HSET | Redis | 409,508 | 82.2 | 326 | 4,415 | 6,993 | 1.33 | 0 | - |
| HSET | Valkey | 666,821 | 3.4 | 13,010 | 5,167 | 7,669 | 2.12 | 1 | - |
| HSET | Dragonfly | 16,839,279 | 117.4 | 9,411 | 6,759 | 61,966 | 50.83 | 17 | - |
| MSET | HotKV | 17,978,711 | 99.1 | 11,739 | 4,237 | 128,479 | 109.74 | 37 | - |
| MSET | Redis | 328,534 | 83.7 | 258 | 3,097 | 6,993 | 2.24 | 1 | - |
| MSET | Valkey | 415,674 | 5.0 | 5,118 | 2,775 | 7,669 | 2.83 | 1 | - |
| MSET | Dragonfly | 2,293,652 | 114.8 | 1,313 | 2,893 | 61,966 | 14.20 | 5 | - |
| PING | HotKV | 189,050,648 | 67.4 | 181,352 | 3,863 | 128,479 | 24.24 | 8 | - |
| PING | Redis | 3,767,306 | 3.5 | 69,830 | 2,179 | 6,993 | 0.52 | 0 | - |
| PING | Valkey | 2,933,705 | 5.9 | 35,268 | 1,967 | 7,669 | 0.42 | 0 | - |
| PING | Dragonfly | 180,161,580 | 116.1 | 99,878 | 2,711 | 61,966 | 23.16 | 8 | - |

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
| PING | HotKV | 90% |
| PING | Dragonfly | 85% |


## HotKV vs each server

HotKV's throughput divided by the other server's, on the same command. Where a
figure was flagged above (wire-bound or client-bound), the true figure may be
higher, and the ratio is given as a bound: `>=` where HotKV's was flagged, `<=`
where the other server's was, and no ratio where both were.

| command | vs Redis | vs Valkey | vs Dragonfly |
|---|---|---|---|
| SET | 51.93x | 68.86x | 2.42x |
| GET | 87.90x | 75.08x | 3.39x |
| MGET | 47.69x | 24.31x | 2.75x |
| SETNX | 52.40x | 40.66x | 2.63x |
| APPEND | 38.01x | 31.76x | 1.76x |
| INCR | 55.81x | 44.98x | 2.65x |
| LPUSH | 54.69x | 44.64x | 1.73x |
| RPUSH | 51.98x | 48.78x | 1.76x |
| SADD | 85.33x | 74.39x | 2.35x |
| HSET | 111.93x | 68.74x | 2.72x |
| MSET | 54.72x | 43.25x | 7.84x |
| PING | >= 50.18x | >= 64.44x | n/a (both limited by the rig) |

Median ratio over the commands above: >= 53.54x vs Redis (12 commands), >= 46.88x vs Valkey (12 commands), 2.63x vs Dragonfly (11 commands).

---

Data: `comparison.json`. It carries every individual run, not just the medians shown here.

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named only to identify the software that was measured; this implies no sponsorship, endorsement or affiliation.
