# HotKV vs Redis vs Valkey vs Dragonfly: Azure D160alds_v7 (AMD EPYC 9V45, Turin), 256B pipeline=30

> Azure meters outbound traffic. On this rig iperf3 measured 78.4 Gbps outbound and at least 131.7 Gbps inbound (three client machines). GET and MGET send the values out and come close to the outbound cap. Writes are inbound: a link-used figure above 100 percent compares their inbound bytes with the outbound cap and does not mean the link was full. Ratios over flagged figures are shown as bounds. HotKV was built from source with -march=native for this CPU; Redis, Valkey and Dragonfly are their stock release builds. Every server was given all 160 vCPUs (Redis 128 I/O threads, its maximum) and run as a single instance. See NOTES.md.

## Rig

| | |
|---|---|
| Platform | Azure D160alds_v7 (AMD EPYC 9V45, Turin) (virtual machine) |
| CPU | AMD EPYC 9V45 96-Core Processor, 160 cores, x86_64 |
| RAM | 314.8 GB |
| OS | Linux 6.17.0-1022-azure |
| Load generator | 3 dedicated client machine(s): 10.0.0.5, 10.0.0.6, 10.0.0.7 |
| Network | eth0, 78 Gbps link |
| Benchmark tool | memtier_benchmark memtier_benchmark v=255.255.255 sha=272eeb64:0 bits=64 libevent=2.1.12-stable openssl=OpenSSL 3.0.13 30 Jan 2024 prometheus=yes |

### Versions

| server | version |
|---|---|
| HotKV | 0.3.0 |
| Redis | 8.10.2 |
| Valkey | 9.1.2 |
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
| memtier threads per client box | 64 |
| Connections per thread | 50 |
| Total connections per client box | 3,200 |
| Test duration per command | 10 s |
| Runs per command | 3 |
| Reported statistic | median of runs |
| Key pattern | R (uniform random) over the populated range |
| Keyspace size (keys) | 5,000,000 |
| Populate | P (parallel sequential), --requests=allkeys |
| Distinct seed per client | yes |

**Server threads** (the same for every server: all the machine's cores, clamped to each server's maximum): HotKV=160, Redis=128, Valkey=160, Dragonfly=160

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
| Interface | `eth0` |

### Per-server

**HotKV**

```
/opt/hotkv/build/release/src/hotkv --port 6399 --bind 0.0.0.0 --threads 160 --no-snapshot --protected-mode no --loglevel warning
```

| directive | effective value |
|---|---|
| `maxmemory` | `0` |
| `maxmemory-policy` | `noeviction` |
| `io-threads` | `1` |
| `appendonly` | `no` |
| `protected-mode` | `no` |
| `tcp-backlog` | `511` |
| `timeout` | `0` |
| `hz` | `10` |
| `databases` | `16` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Redis**

```
/opt/redis-8.10.2/src/redis-server --port 6399 --bind 0.0.0.0 --save  --appendonly no --protected-mode no --io-threads 128 --io-threads-do-reads yes --loglevel warning
```

| directive | effective value |
|---|---|
| `maxmemory` | `0` |
| `maxmemory-policy` | `noeviction` |
| `io-threads` | `128` |
| `appendonly` | `no` |
| `protected-mode` | `no` |
| `tcp-backlog` | `511` |
| `timeout` | `0` |
| `hz` | `10` |
| `databases` | `16` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Valkey**

```
/opt/valkey-9.1.2/src/valkey-server --port 6399 --bind 0.0.0.0 --save  --appendonly no --protected-mode no --io-threads 160 --loglevel warning
```

| directive | effective value |
|---|---|
| `maxmemory` | `0` |
| `maxmemory-policy` | `noeviction` |
| `io-threads` | `160` |
| `appendonly` | `no` |
| `protected-mode` | `no` |
| `tcp-backlog` | `511` |
| `timeout` | `0` |
| `hz` | `10` |
| `databases` | `16` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Dragonfly**

```
/opt/dragonfly/build-opt/dragonfly --port 6399 --bind 0.0.0.0 --proactor_threads=160 --dbfilename= --noversion_check --logtostderr 
```

| directive | effective value |
|---|---|
| `maxmemory` | `265588057702` |
| `timeout` | `0` |
| `databases` | `16` |

### Fairness notes

- maxmemory=0 (no memory cap) on HotKV, Redis, Valkey; Dragonfly kept its default cap (maxmemory 266 GB; its largest resident set in the run was 43 GB).
- Persistence off everywhere (Redis/Valkey --save '' --appendonly no; Dragonfly --dbfilename= ). No server pays disk IO the others do not.
- No server-specific tuning beyond thread count; see tuning.tuned_threads.
- The read range is exactly the range populate filled, so reads hit ~100% and measure the value path rather than the nil path.
- --distinct-client-seed: every client gets its own key sequence. Without it memtier seeds all clients identically and thousands of connections replay one key order, which manufactures cache locality no real workload has. Applied to every server equally.

## Throughput (ops/sec, median of 3 runs)

| command | HotKV | Redis | Valkey | Dragonfly |
|---|---|---|---|---|
| SET | **50,480,621** | 3,409,794 | 2,882,486 | 15,042,258 |
| GET | **36,643,656** | 1,132,934 | 1,631,573 | 13,446,228 |
| MGET | **4,617,382** | 277,956 | 536,872 | 2,348,137 |
| SETNX | **55,333,360** | 1,397,967 | 1,860,919 | 14,442,422 |
| APPEND | **25,050,648** | 1,530,680 | 1,290,421 | 8,858,165 |
| INCR | **90,783,545** | 2,104,069 | 1,918,073 | 20,603,259 |
| LPUSH | **31,617,779** | 1,247,914 | 842,106 | 10,579,641 |
| RPUSH | **43,776,706** | 628,324 | 878,476 | 11,014,977 |
| SADD | **50,626,647** | 2,053,737 | 894,438 | 12,044,417 |
| HSET | **28,997,514** | 536,527 | 781,768 | 9,797,534 |
| MSET | **11,275,369** | 378,641 | 464,801 | 2,941,342 |
| PING | 125,232,520 | 3,235,600 | 3,480,446 | **126,033,542** |

## Resource usage

Per command and server, each column is the median of that metric over the runs,
so a row need not come from one single run. `cores` is CPU time over
wall time (8.0 = eight cores fully busy). `ops/CPU-s` is throughput per second
of CPU consumed - the efficiency figure that still means something on a
different machine. Memory is the server process's resident set; `peak` is its
high-water mark including the populate phase.

| command | server | ops/sec | cores | ops/CPU-s | RSS MB | peak MB | Gbps | link % | hit % |
|---|---|---|---|---|---|---|---|---|---|
| SET | HotKV | 50,480,621 | 97.0 | 37,767 | 2,826 | 2,863 | 89.42 | 115 | - |
| SET | Redis | 3,409,794 | 62.2 | 1,689 | 2,004 | 2,106 | 2.63 | 3 | - |
| SET | Valkey | 2,882,486 | 13.1 | 6,813 | 2,650 | 2,650 | 2.23 | 3 | - |
| SET | Dragonfly | 15,042,258 | 99.1 | 10,509 | 1,990 | 3,221 | 26.00 | 33 | - |
| GET | HotKV | 36,643,656 | 62.2 | 45,058 | 2,809 | 2,863 | 68.88 | 88 | 100.0 |
| GET | Redis | 1,132,934 | 64.7 | 1,325 | 2,178 | 2,179 | 2.13 | 3 | 100.0 |
| GET | Valkey | 1,631,573 | 16.6 | 7,400 | 1,939 | 2,663 | 3.11 | 4 | 100.0 |
| GET | Dragonfly | 13,446,228 | 98.0 | 10,518 | 2,140 | 3,221 | 25.30 | 32 | 100.0 |
| MGET | HotKV | 4,617,382 | 86.0 | 3,866 | 3,377 | 3,409 | 64.57 | 83 | - |
| MGET | Redis | 277,956 | 90.8 | 223 | 2,288 | 2,288 | 4.35 | 6 | - |
| MGET | Valkey | 536,872 | 17.6 | 2,335 | 2,041 | 2,663 | 8.30 | 11 | - |
| MGET | Dragonfly | 2,348,137 | 111.1 | 1,621 | 2,994 | 3,908 | 34.12 | 44 | - |
| SETNX | HotKV | 55,333,360 | 78.7 | 53,703 | 2,906 | 3,409 | 105.69 | 136 | - |
| SETNX | Redis | 1,397,967 | 21.9 | 4,870 | 2,221 | 2,254 | 2.60 | 3 | - |
| SETNX | Valkey | 1,860,919 | 13.7 | 10,969 | 2,011 | 2,663 | 3.59 | 5 | - |
| SETNX | Dragonfly | 14,442,422 | 93.3 | 11,838 | 2,470 | 3,908 | 27.54 | 35 | - |
| APPEND | HotKV | 25,050,648 | 62.3 | 30,303 | 104,185 | 104,822 | 48.53 | 62 | - |
| APPEND | Redis | 1,530,680 | 36.8 | 1,736 | 10,674 | 10,674 | 1.64 | 2 | - |
| APPEND | Valkey | 1,290,421 | 13.7 | 5,020 | 8,840 | 8,855 | 1.75 | 2 | - |
| APPEND | Dragonfly | 8,858,165 | 103.9 | 6,344 | 30,299 | 31,356 | 16.60 | 21 | - |
| INCR | HotKV | 90,783,545 | 86.7 | 77,928 | 2,235 | 104,822 | 24.40 | 31 | - |
| INCR | Redis | 2,104,069 | 3.4 | 36,425 | 576 | 10,652 | 0.46 | 1 | - |
| INCR | Valkey | 1,918,073 | 9.6 | 15,240 | 576 | 8,855 | 0.55 | 1 | - |
| INCR | Dragonfly | 20,603,259 | 109.7 | 14,346 | 1,476 | 31,356 | 5.63 | 7 | - |
| LPUSH | HotKV | 31,617,779 | 113.0 | 21,370 | 113,998 | 113,998 | 60.30 | 77 | - |
| LPUSH | Redis | 1,247,914 | 46.1 | 1,099 | 8,025 | 10,652 | 1.42 | 2 | - |
| LPUSH | Valkey | 842,106 | 7.6 | 8,351 | 5,327 | 8,855 | 1.64 | 2 | - |
| LPUSH | Dragonfly | 10,579,641 | 102.4 | 7,854 | 40,578 | 41,611 | 20.20 | 26 | - |
| RPUSH | HotKV | 43,776,706 | 106.9 | 30,620 | 152,065 | 152,065 | 81.73 | 105 | - |
| RPUSH | Redis | 628,324 | 57.4 | 831 | 4,776 | 10,652 | 1.25 | 2 | - |
| RPUSH | Valkey | 878,476 | 8.7 | 6,897 | 5,415 | 8,855 | 1.62 | 2 | - |
| RPUSH | Dragonfly | 11,014,977 | 100.9 | 8,367 | 41,987 | 43,016 | 21.06 | 27 | - |
| SADD | HotKV | 50,626,647 | 103.2 | 36,456 | 9,509 | 151,958 | 93.22 | 120 | - |
| SADD | Redis | 2,053,737 | 54.2 | 851 | 2,533 | 10,652 | 1.22 | 2 | - |
| SADD | Valkey | 894,438 | 6.1 | 10,442 | 2,795 | 8,855 | 1.63 | 2 | - |
| SADD | Dragonfly | 12,044,417 | 96.4 | 9,380 | 3,459 | 43,016 | 22.44 | 29 | - |
| HSET | HotKV | 28,997,514 | 84.6 | 25,851 | 17,901 | 151,958 | 101.92 | 131 | - |
| HSET | Redis | 536,527 | 87.9 | 436 | 3,929 | 10,652 | 1.86 | 2 | - |
| HSET | Valkey | 781,768 | 7.7 | 7,779 | 4,225 | 8,855 | 2.72 | 3 | - |
| HSET | Dragonfly | 9,797,534 | 97.6 | 7,533 | 6,676 | 43,016 | 33.94 | 44 | - |
| MSET | HotKV | 11,275,369 | 87.6 | 9,280 | 4,422 | 151,958 | 76.05 | 98 | - |
| MSET | Redis | 378,641 | 99.3 | 288 | 3,213 | 10,652 | 2.90 | 4 | - |
| MSET | Valkey | 464,801 | 8.2 | 4,362 | 2,736 | 8,855 | 3.47 | 4 | - |
| MSET | Dragonfly | 2,941,342 | 105.5 | 2,130 | 2,849 | 43,016 | 21.15 | 27 | - |
| PING | HotKV | 125,232,520 | 60.6 | 158,866 | 4,076 | 151,958 | 19.16 | 25 | - |
| PING | Redis | 3,235,600 | 4.2 | 59,675 | 2,378 | 10,652 | 0.54 | 1 | - |
| PING | Valkey | 3,480,446 | 10.6 | 23,393 | 2,020 | 8,855 | 0.58 | 1 | - |
| PING | Dragonfly | 126,033,542 | 105.7 | 91,474 | 2,639 | 43,016 | 19.31 | 25 | - |

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

### Wire-bound (7)

These used at or above 85% of the network link, so the link set the
number, not the server. Treat them as lower bounds, and see the caveat above
if this instance meters send and receive bandwidth differently.

> Correction, 22 October 2026: the `link used` column below adds inbound and
> outbound bytes and divides by the harness wall clock (about 13 s, including
> server launch), not the 10-second test. Per-direction figures over the test
> window are in NOTES.md under "Reading the flagged figures": GET and MGET sat
> on the outbound ceiling, and SETNX, HSET, SET and SADD on the inbound one.

| command | server | link used |
|---|---|---|
| SET | HotKV | 115% |
| GET | HotKV | 88% |
| SETNX | HotKV | 136% |
| RPUSH | HotKV | 105% |
| SADD | HotKV | 120% |
| HSET | HotKV | 131% |
| MSET | HotKV | 98% |

### Client-bound (1)

The load generators sat above 85% CPU, so these figures may be
the load generators' ceiling rather than the server's. Treat them as lower bounds.

| command | server | client CPU |
|---|---|---|
| PING | HotKV | 86% |


## HotKV vs each server

HotKV's throughput divided by the other server's, on the same command. Where a
figure was flagged above (wire-bound or client-bound), the true figure may be
higher, and the ratio is given as a bound: `>=` where HotKV's was flagged, `<=`
where the other server's was, and no ratio where both were.

| command | vs Redis | vs Valkey | vs Dragonfly |
|---|---|---|---|
| SET | >= 14.80x | >= 17.51x | >= 3.36x |
| GET | >= 32.34x | >= 22.46x | >= 2.73x |
| MGET | 16.61x | 8.60x | 1.97x |
| SETNX | >= 39.58x | >= 29.73x | >= 3.83x |
| APPEND | 16.37x | 19.41x | 2.83x |
| INCR | 43.15x | 47.33x | 4.41x |
| LPUSH | 25.34x | 37.55x | 2.99x |
| RPUSH | >= 69.67x | >= 49.83x | >= 3.97x |
| SADD | >= 24.65x | >= 56.60x | >= 4.20x |
| HSET | >= 54.05x | >= 37.09x | >= 2.96x |
| MSET | >= 29.78x | >= 24.26x | >= 3.83x |
| PING | >= 38.70x | >= 35.98x | >= 0.99x |

Median ratio over the commands above: >= 31.06x vs Redis (12 commands), >= 32.86x vs Valkey (12 commands), >= 3.17x vs Dragonfly (12 commands).

### Where HotKV is slower

Commands on which another server measured higher throughput than HotKV.

| command | server | theirs | ours | gap |
|---|---|---|---|---|
| PING | Dragonfly | 126,033,542 | 125,232,520 | 0.6% faster |

---

Data: `comparison.json`. It carries every individual run, not just the medians shown here.

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named only to identify the software that was measured; this implies no sponsorship, endorsement or affiliation.
