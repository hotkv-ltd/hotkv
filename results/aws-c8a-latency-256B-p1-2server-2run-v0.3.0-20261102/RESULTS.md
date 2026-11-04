# HotKV latency and pub/sub benchmark, AWS c8a, 2026-11-02

Every number below comes from the raw files in this folder. Latency cells are p50 / p99 in milliseconds, mean of 2 runs. A cell reads "not sustained" when the product achieved less than 97% of the offered rate.

## Setup

- AWS c8a.12xlarge instances (AMD EPYC 9R45 Zen 5, 48 cores, no SMT, 96 GiB, 22.5 Gbit), eu-south-2a, one cluster placement group, Ubuntu 24.04.
- One load generator and one server. Every product ran alone on the same server, one product at a time, so nothing overlapped and nothing shared the network.
- Servers pinned with taskset to CPUs 0 to 39, persistence off, protected mode off, same port.
- The versions were Redis 8.10.3, Valkey 9.1.3, Dragonfly v2.0.2 and HotKV 0.3.0, with memtier_benchmark commit 272eeb64.
- Launch lines and the live CONFIG GET output are in each result folder (cmdline_*.txt, config_*.txt).
- The data set was 1,000,000 keys with 256 byte values, at pipeline depth 1.

## Method

- For latency we used memtier_benchmark with per-connection --rate-limiting (fixed offered load), HDR output, 20 s per point, 2 repeats, GET only and a 1:10 write:read mix.
- A point counts as sustained only if the achieved rate is at least 97% of the offered rate. memtier is closed loop, so latency at an overloaded point looks better than it is. The sweep for a product stops at the first point that is not sustained.
- Two connection counts. 816 connections (24 threads x 34) and 48 connections (4 threads x 12). memtier rate limiting makes all connections fire together, so a single-threaded server has to work through a burst of 816 requests. That inflates the median of single-threaded products and is a property of the tool, not a steady-state latency.
- For pub/sub we used redis-performance/pubsub-sub-bench (BSD-2), patched to microsecond timestamps (pubsub-sub-bench-microsecond.patch). The unpatched tool compares a millisecond publish time with a microsecond receive time. 64 publishers, 100 subscribers, 128 byte payload, 20 s, 2 repeats.

## Latency, 816 connections

### GET

| Offered req/s | HotKV 0.3.0, 40 threads | Dragonfly v2.0.2, 40 threads | Redis 8.10.3, single thread | Redis 8.10.3, io-threads 8 | Valkey 9.1.3, single thread | Valkey 9.1.3, io-threads 8 |
|---|---|---|---|---|---|---|
| 19,584 | 0.38 / 1.81 | 0.48 / 1.90 | 1.63 / 5.29 | 0.68 / 2.07 | 1.59 / 5.13 | 0.76 / 2.63 |
| 49,776 | 0.25 / 1.34 | 0.27 / 1.60 | 2.24 / 4.40 | 0.35 / 1.50 | 2.32 / 4.50 | 1.96 / 4.62 |
| 99,552 | 0.24 / 0.76 | 0.27 / 1.76 | 2.60 / 5.12 | 0.40 / 0.98 | 2.65 / 5.13 | 1.71 / 3.19 |
| 199,920 | 0.25 / 0.59 | 0.25 / 1.34 | 2.91 / 5.60 | 0.55 / 1.11 | 3.02 / 5.81 | 1.11 / 2.15 |
| 399,840 | 0.27 / 0.63 | 0.27 / 1.48 | not sustained (258k) | 0.62 / 1.23 | not sustained (259k) | 1.24 / 1.49 |
| 799,680 | 0.28 / 0.75 | 0.28 / 1.26 | n/a | 0.68 / 1.18 | n/a | not sustained (670k) |
| 1,199,520 | 0.28 / 0.67 | 0.28 / 1.05 | n/a | not sustained (1078k) | n/a | n/a |
| 1,599,360 | 0.28 / 0.64 | 0.28 / 0.71 | n/a | n/a | n/a | n/a |
| 2,399,856 | not sustained (2284k) | not sustained (2281k) | n/a | n/a | n/a | n/a |

### Mixed 1:10 write:read

| Offered req/s | HotKV 0.3.0, 40 threads | Dragonfly v2.0.2, 40 threads | Redis 8.10.3, single thread | Redis 8.10.3, io-threads 8 | Valkey 9.1.3, single thread | Valkey 9.1.3, io-threads 8 |
|---|---|---|---|---|---|---|
| 19,584 | 0.49 / 1.48 | 0.47 / 1.61 | 1.70 / 5.31 | 0.66 / 1.78 | 1.67 / 5.12 | 0.94 / 2.82 |
| 49,776 | 0.25 / 0.92 | 0.28 / 1.52 | 2.33 / 4.53 | 0.29 / 0.97 | 2.26 / 4.51 | 1.65 / 4.21 |
| 99,552 | 0.24 / 0.60 | 0.27 / 1.69 | 2.77 / 5.26 | 0.35 / 0.82 | 2.79 / 5.31 | 1.33 / 3.12 |
| 199,920 | 0.24 / 0.54 | 0.26 / 1.44 | 3.02 / 5.74 | 0.53 / 1.09 | 3.04 / 5.84 | 1.11 / 1.75 |
| 399,840 | 0.26 / 0.63 | 0.27 / 1.29 | not sustained (256k) | 0.63 / 1.21 | not sustained (253k) | 1.19 / 1.48 |
| 799,680 | 0.28 / 0.75 | 0.28 / 1.23 | n/a | 0.69 / 1.18 | n/a | not sustained (673k) |
| 1,199,520 | 0.28 / 0.66 | 0.28 / 0.97 | n/a | not sustained (1091k) | n/a | n/a |
| 1,599,360 | 0.28 / 0.64 | 0.28 / 0.71 | n/a | n/a | n/a | n/a |
| 2,399,856 | not sustained (2290k) | not sustained (2308k) | n/a | n/a | n/a | n/a |

## Latency, 48 connections

The 48 connection runs stop at 300,000 req/s. Above that the connection count itself limits the rate (48 connections at about 0.13 ms each).

### GET

| Offered req/s | HotKV 0.3.0, 40 threads | Dragonfly v2.0.2, 40 threads | Redis 8.10.3, single thread | Redis 8.10.3, io-threads 8 | Valkey 9.1.3, single thread | Valkey 9.1.3, io-threads 8 |
|---|---|---|---|---|---|---|
| 9,984 | 0.14 / 0.54 | 0.14 / 0.37 | 0.21 / 0.89 | 0.17 / 0.92 | 0.21 / 0.91 | 0.20 / 0.81 |
| 24,960 | 0.12 / 0.29 | 0.12 / 0.29 | 0.19 / 0.41 | 0.13 / 0.30 | 0.20 / 0.42 | 0.20 / 0.43 |
| 49,968 | 0.10 / 0.28 | 0.11 / 0.28 | 0.21 / 0.41 | 0.13 / 0.28 | 0.21 / 0.43 | 0.21 / 0.44 |
| 99,984 | 0.09 / 0.28 | 0.10 / 0.28 | 0.20 / 0.40 | 0.13 / 0.28 | 0.20 / 0.38 | 0.19 / 0.35 |
| 199,968 | 0.08 / 0.27 | 0.08 / 0.27 | 0.20 / 0.35 | 0.10 / 0.27 | 0.21 / 0.36 | 0.11 / 0.28 |
| 300,000 | 0.08 / 0.27 | 0.08 / 0.27 | not sustained (231k) | 0.09 / 0.26 | not sustained (233k) | 0.09 / 0.26 |

### Mixed 1:10 write:read

| Offered req/s | HotKV 0.3.0, 40 threads | Dragonfly v2.0.2, 40 threads | Redis 8.10.3, single thread | Redis 8.10.3, io-threads 8 | Valkey 9.1.3, single thread | Valkey 9.1.3, io-threads 8 |
|---|---|---|---|---|---|---|
| 9,984 | 0.15 / 0.66 | 0.14 / 0.35 | 0.21 / 0.94 | 0.15 / 0.61 | 0.18 / 0.72 | 0.20 / 0.92 |
| 24,960 | 0.12 / 0.29 | 0.12 / 0.31 | 0.20 / 0.41 | 0.14 / 0.31 | 0.20 / 0.42 | 0.20 / 0.43 |
| 49,968 | 0.10 / 0.27 | 0.10 / 0.28 | 0.20 / 0.42 | 0.13 / 0.28 | 0.21 / 0.41 | 0.21 / 0.44 |
| 99,984 | 0.09 / 0.28 | 0.09 / 0.28 | 0.20 / 0.37 | 0.13 / 0.28 | 0.20 / 0.38 | 0.19 / 0.36 |
| 199,968 | 0.08 / 0.28 | 0.08 / 0.25 | 0.21 / 0.36 | 0.10 / 0.28 | 0.21 / 0.36 | 0.11 / 0.26 |
| 300,000 | 0.08 / 0.27 | 0.08 / 0.26 | not sustained (231k) | 0.09 / 0.27 | not sustained (234k) | 0.09 / 0.26 |

## Pub/sub delivery latency, point to point

| Scenario | HotKV 0.3.0, 40 threads | Dragonfly v2.0.2, 40 threads | Redis 8.10.3, single thread | Redis 8.10.3, io-threads 8 | Valkey 9.1.3, single thread | Valkey 9.1.3, io-threads 8 |
|---|---|---|---|---|---|---|
| p2p_10k (about 21k deliveries/s) | 0.10 / 0.71 | 0.10 / 0.65 | 0.11 / 0.74 | 0.11 / 0.62 | 0.11 / 0.76 | 0.12 / 0.78 |
| p2p_50k (about 107k deliveries/s) | 0.10 / 1.02 | 0.12 / 0.92 | 0.10 / 0.80 | 0.11 / 0.63 | 0.10 / 0.82 | 0.10 / 0.86 |
| p2p_100k (about 215k deliveries/s) | 0.11 / 1.20 | 0.13 / 1.13 | 0.51 / 1.03 | 0.20 / 0.73 | 0.57 / 1.07 | 0.12 / 1.22 |

## Findings

1. Throughput headroom with a low tail is where HotKV leads. In the 816 connection run HotKV and Dragonfly both sustain about 1.6M req/s, Redis with io-threads 8 about 800k, Valkey with io-threads 8 about 400k, and single-threaded Redis and Valkey about 200k. From 200k to 1.6M req/s HotKV's p99 is 0.54 to 0.76 ms, and Dragonfly's is 0.71 to 1.48 ms.
2. At light load (48 connections, up to 200k req/s) the multi-threaded products tie on p99 (about 0.27 ms). HotKV has the lowest p50 (0.08 to 0.10 ms at 100k to 200k), then Dragonfly, Redis io-threads 8, Valkey io-threads 8, and single-threaded Redis and Valkey (about 0.2 ms).
3. Pub/sub delivery latency is a tie at the loads tested.

## Scope

- One server and one load generator, one run date, two repeats per point. No claim here covers other hardware, other value sizes, TLS, persistence or clusters.
- We did not test larger or skewed key sets, persistence on, memory per key, cluster mode, sharded pub/sub, one message to many subscribers.

## Files

- raw holds one archive per test (latency-816conn_raw.tgz, latency-48conn_raw.tgz and pubsub_raw.tgz) with the memtier JSON, HDR files, CPU use and pub/sub output of every run, and the sweep logs.
- latency-816conn, latency-48conn and pubsub hold the launch line, live config and version of each product.
- harness holds the sweep and host tuning scripts, and pubsub-sub-bench-microsecond.patch is the timestamp patch.
