# HotKV vs Redis vs Valkey vs Dragonfly: AWS 3 x c8in.12xlarge cluster (Intel Xeon 6975P-C, Granite Rapids), 256B pipeline=100

> Three servers formed one cluster, driven by two load generators started together. HotKV and Dragonfly ran one process per server, Redis and Valkey 40 single-thread processes per server. On several commands the load generators ran above 85% CPU, so those figures are lower bounds; NOTES.md explains how to read them.

## Rig

| | |
|---|---|
| Platform | AWS 3 x c8in.12xlarge cluster (Intel Xeon 6975P-C, Granite Rapids) (virtual machine) |
| CPU | Intel(R) Xeon(R) 6975P-C (3 servers, 48 vCPUs each), 144 cores, x86_64 |
| RAM | 92 GiB per server |
| OS | Linux 7.0.0-1014-aws |
| Load generator | 2 dedicated client machine(s): 172.31.32.45 (c8in.48xlarge), 172.31.47.233 (c8in.12xlarge) |
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
| Pipeline depth | 100 |
| memtier threads per client box | 192 |
| memtier processes per client box | 16 |
| Connections per thread | 16 |
| Total connections per client box | 9,216 |
| Test duration per command | 15 s |
| Runs per command | 2 |
| Reported statistic | median of runs |
| Key pattern | R (uniform random) over the populated range |
| Keyspace size (keys) | 5,000,000 |
| Populate | P (parallel sequential), --requests=allkeys |
| Distinct seed per client | yes |

**Server threads** (the same for every server: all the machine's cores, clamped to each server's maximum): HotKV=40, Redis=1, Valkey=1, Dragonfly=40

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

### Per-server

**HotKV**

```
taskset -c 0-39 hotkv node.conf   (one process per server host, port 7400)
```

| directive | effective value |
|---|---|
| `protected-mode` | `no` |
| `appendonly` | `no` |
| `save` | `(off)` |
| `tcp-backlog` | `65535` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Redis**

```
taskset -c 0-39 redis-server node.conf   (40 processes per server host, ports 7400 to 7439)
```

| directive | effective value |
|---|---|
| `protected-mode` | `no` |
| `appendonly` | `no` |
| `save` | `(off)` |
| `tcp-backlog` | `65535` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Valkey**

```
taskset -c 0-39 valkey-server node.conf   (40 processes per server host, ports 7400 to 7439)
```

| directive | effective value |
|---|---|
| `protected-mode` | `no` |
| `appendonly` | `no` |
| `save` | `(off)` |
| `tcp-backlog` | `65535` |

No memory cap (`maxmemory=0`): nothing was evicted during the run.

**Dragonfly**

```
taskset -c 0-39 dragonfly --port=7400 --proactor_threads=40 --dbfilename= --cluster_mode=yes --maxclients=65000 --tcp_backlog=65535   (one process per server host)
```

### Fairness notes

- Three-node cluster: HotKV and Dragonfly run one process per server host with 40 threads. Redis and Valkey run 40 single-thread processes per server host (120 primaries). All 16,384 slots are spread evenly. Persistence is off everywhere and every server process is pinned to CPUs 0 to 39.
- HotKV ran with pipeline-prefetch set to yes (off by default). Redis and Valkey ran with their own batch prefetching at its default.
- The load comes from two machines started together: a c8in.48xlarge running 16 memtier_benchmark processes of 12 threads, and a c8in.12xlarge running 4 processes of 12 threads. memtier runs in cluster mode, so each client connects to every node. The figure of a run is the sum of all processes. The connections row counts 16 connections per thread and node on the large machine.
- Before every run the keyspace is emptied and written completely with that command's own data type, and DBSIZE over all primaries is checked against it.
- The Load generator CPU column is the CPU of the large load generator. At or above 85 percent a figure is a lower bound, because the load generator and not the server may have set the limit. Redis and Valkey need 120 processes, which costs the load generators more per operation.
- MGET, MSET and PING are not run: in a cluster MGET and MSET with random keys fail with CROSSSLOT, and PING has no key to route by.
- Throughput only. The sweep does not record latency, memory or network use per command.

## Throughput (ops/sec, median of 2 runs)

| command | HotKV | Redis | Valkey | Dragonfly |
|---|---|---|---|---|
| GET | **92,250,494** | 57,310,939 | 52,879,754 | 22,535,920 |
| SET | **76,093,800** | 55,005,330 | 48,518,580 | 25,207,728 |
| SETNX | **86,134,695** | 60,700,958 | 56,963,270 | 27,507,054 |
| INCR | **119,203,736** | 118,415,379 | 104,582,158 | 30,764,594 |
| SADD | **51,686,378** | 40,420,523 | 33,808,564 | 22,703,871 |
| RPUSH | **47,118,672** | 29,333,684 | 29,029,248 | 18,704,970 |
| HSET | **38,423,932** | 28,823,716 | 27,201,056 | 18,443,362 |
| LPUSH | **31,146,670** | 23,744,623 | 24,045,672 | 16,854,033 |
| APPEND | 34,971,148 | **41,726,221** | 40,866,387 | 10,365,166 |

## Resource usage

Per command and server, each column is the median of that metric over the runs,
so a row need not come from one single run. `cores` is CPU time over
wall time (8.0 = eight cores fully busy). `ops/CPU-s` is throughput per second
of CPU consumed - the efficiency figure that still means something on a
different machine. Memory is the server process's resident set; `peak` is its
high-water mark including the populate phase.

| command | server | ops/sec | cores | ops/CPU-s | RSS MB | peak MB | Gbps | hit % |
|---|---|---|---|---|---|---|---|---|
| GET | HotKV | 92,250,494 | 112.8 | 817,824 | - | - | - | 100.0 |
| GET | Redis | 57,310,939 | 116.9 | 490,340 | - | - | - | 100.0 |
| GET | Valkey | 52,879,754 | 118.1 | 447,830 | - | - | - | 100.0 |
| GET | Dragonfly | 22,535,920 | 119.5 | 188,554 | - | - | - | 100.0 |
| SET | HotKV | 76,093,800 | 115.2 | 660,536 | - | - | - | - |
| SET | Redis | 55,005,330 | 117.6 | 467,732 | - | - | - | - |
| SET | Valkey | 48,518,580 | 119.0 | 407,582 | - | - | - | - |
| SET | Dragonfly | 25,207,728 | 119.5 | 210,908 | - | - | - | - |
| SETNX | HotKV | 86,134,695 | 115.9 | 743,053 | - | - | - | - |
| SETNX | Redis | 60,700,958 | 116.9 | 519,344 | - | - | - | - |
| SETNX | Valkey | 56,963,270 | 117.8 | 483,395 | - | - | - | - |
| SETNX | Dragonfly | 27,507,054 | 119.5 | 230,146 | - | - | - | - |
| INCR | HotKV | 119,203,736 | 115.9 | 1,028,328 | - | - | - | - |
| INCR | Redis | 118,415,379 | 98.6 | 1,200,480 | - | - | - | - |
| INCR | Valkey | 104,582,158 | 112.1 | 933,103 | - | - | - | - |
| INCR | Dragonfly | 30,764,594 | 119.3 | 257,919 | - | - | - | - |
| SADD | HotKV | 51,686,378 | 111.6 | 463,140 | - | - | - | - |
| SADD | Redis | 40,420,523 | 119.8 | 337,513 | - | - | - | - |
| SADD | Valkey | 33,808,564 | 120.2 | 281,176 | - | - | - | - |
| SADD | Dragonfly | 22,703,871 | 119.5 | 189,959 | - | - | - | - |
| RPUSH | HotKV | 47,118,672 | 112.6 | 418,609 | - | - | - | - |
| RPUSH | Redis | 29,333,684 | 120.0 | 244,447 | - | - | - | - |
| RPUSH | Valkey | 29,029,248 | 120.0 | 241,910 | - | - | - | - |
| RPUSH | Dragonfly | 18,704,970 | 119.5 | 156,501 | - | - | - | - |
| HSET | HotKV | 38,423,932 | 111.6 | 344,300 | - | - | - | - |
| HSET | Redis | 28,823,716 | 119.3 | 241,648 | - | - | - | - |
| HSET | Valkey | 27,201,056 | 119.3 | 228,044 | - | - | - | - |
| HSET | Dragonfly | 18,443,362 | 119.5 | 154,312 | - | - | - | - |
| LPUSH | HotKV | 31,146,670 | 111.6 | 279,092 | - | - | - | - |
| LPUSH | Redis | 23,744,623 | 119.3 | 199,066 | - | - | - | - |
| LPUSH | Valkey | 24,045,672 | 120.5 | 199,582 | - | - | - | - |
| LPUSH | Dragonfly | 16,854,033 | 119.5 | 141,014 | - | - | - | - |
| APPEND | HotKV | 34,971,148 | 68.9 | 507,711 | - | - | - | - |
| APPEND | Redis | 41,726,221 | 119.8 | 348,415 | - | - | - | - |
| APPEND | Valkey | 40,866,387 | 119.5 | 341,921 | - | - | - | - |
| APPEND | Dragonfly | 10,365,166 | 104.9 | 98,829 | - | - | - | - |

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

### Client-bound (17)

The load generators sat above 85% CPU, so these figures may be
the load generators' ceiling rather than the server's. Treat them as lower bounds.

| command | server | client CPU |
|---|---|---|
| GET | HotKV | 100% |
| GET | Redis | 100% |
| GET | Valkey | 100% |
| SET | Redis | 100% |
| SET | Valkey | 99% |
| SETNX | HotKV | 88% |
| SETNX | Redis | 100% |
| SETNX | Valkey | 100% |
| INCR | HotKV | 93% |
| INCR | Redis | 100% |
| INCR | Valkey | 100% |
| SADD | Redis | 96% |
| SADD | Valkey | 91% |
| HSET | Redis | 88% |
| HSET | Valkey | 86% |
| APPEND | Redis | 96% |
| APPEND | Valkey | 95% |


## HotKV vs each server

HotKV's throughput divided by the other server's, on the same command. Where a
figure was flagged above (wire-bound or client-bound), the true figure may be
higher, and the ratio is given as a bound: `>=` where HotKV's was flagged, `<=`
where the other server's was, and no ratio where both were.

| command | vs Redis | vs Valkey | vs Dragonfly |
|---|---|---|---|
| GET | n/a (both limited by the rig) | n/a (both limited by the rig) | >= 4.09x |
| SET | <= 1.38x | <= 1.57x | 3.02x |
| SETNX | n/a (both limited by the rig) | n/a (both limited by the rig) | >= 3.13x |
| INCR | n/a (both limited by the rig) | n/a (both limited by the rig) | >= 3.87x |
| SADD | <= 1.28x | <= 1.53x | 2.28x |
| RPUSH | 1.61x | 1.62x | 2.52x |
| HSET | <= 1.33x | <= 1.41x | 2.08x |
| LPUSH | 1.31x | 1.30x | 1.85x |
| APPEND | <= 0.84x | <= 0.86x | 3.37x |

Median ratio over the commands above: 1.46x vs Redis (2 commands), 1.46x vs Valkey (2 commands), >= 3.02x vs Dragonfly (9 commands).

### Where HotKV is slower

Commands on which another server measured higher throughput than HotKV.

| command | server | theirs | ours | gap |
|---|---|---|---|---|
| APPEND | Redis | 41,726,221 | 34,971,148 | 19.3% faster |
| APPEND | Valkey | 40,866,387 | 34,971,148 | 16.9% faster |

---

Data: `comparison.json`. It carries every individual run, not just the medians shown here.

Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named only to identify the software that was measured; this implies no sponsorship, endorsement or affiliation.
