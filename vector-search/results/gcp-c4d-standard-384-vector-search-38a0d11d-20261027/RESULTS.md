# Vector search: HotKV and Redis 8.10.3 on GCP c4d-standard-384

Plain vector search on both servers: build an HNSW index, then run top-10 nearest-neighbour queries. No filters, no attributes, no quantization, none of HotKV's AI engines. Every figure below is computed by `scripts/render_report.py` from the raw trials in `raw/`.

## Setup

|  |  |
|---|---|
| Machine | Google Cloud c4d-standard-384: AMD EPYC 9B45, 384 vCPUs, one VM |
| Kernel / OS | Linux-7.0.0-1014-gcp-x86_64-with-glibc2.39 |
| HotKV | commit `38a0d11d`, binary SHA-256 `499a3a848a9aaa6e...`, release build, portable flags (no -march=native) |
| Redis | 8.10.3 from the GitHub release tag, stock `make`, binary SHA-256 `a9eb6a3c2ca5325c...` |
| CPU placement | servers pinned to vCPUs 0-95,192-287; load generators on 192 other vCPUs; same CPU set for both servers; loopback |
| HotKV launch | `hotkv --threads 192 --no-snapshot --protected-mode no` |
| Redis launch | `redis-server --save "" --appendonly no --protected-mode no` (default I/O threads) |
| Index | HNSW, cosine, M=16, ef_construction=200, float32 on both (Redis: `NOQUANT`) |
| Dataset | dbpedia-entities-openai-1M (OpenAI ada-002, 1,536 dimensions, MIT). Base set = first N rows; queries = the last 1,000 rows; no overlap |
| Ground truth | exact top-10 by cosine similarity, brute force in float64, independent of either server |
| Trials | 3 per cell; 1 s warm-up then 4 s measured; engines alternate within each cell |

## 999,000 vectors

### Loading

Time and vectors per second are for the whole load, including the load generator's own formatting of each vector. RSS is the size of the server process after that load; the server holds every build made so far, so with several builds it grows. The Redis indexes were built in an earlier run (`raw/redis_build/`) and saved with `SAVE`; the measurements started Redis from the saved file, and the Redis figures here are from the run that built the index.

| Engine | Build | Loaded over | Time | Vectors/s | Server cores busy | Process RSS after load |
|---|---|---|---|---|---|---|
| HotKV | build 1 | 32 connections | 124 s | 8,075 | 21.4 | 6.77 GB |
| Redis | build 1 | 32 connections, `CAS` | 751 s | 1,330 | 2.9 | 7.03 GB |

### Recall@10 against exact ground truth

Build 1 is the index the throughput numbers were measured on. With several builds the range over all independent builds is shown.

| ef | HotKV | Redis |
|---|---|---|
| 10 | 0.7929 | 0.7508 |
| 20 | 0.8834 | 0.8569 |
| 40 | 0.9400 | 0.9262 |
| 80 | 0.9733 | 0.9610 |
| 150 | 0.9863 | 0.9784 |
| 300 | 0.9933 | 0.9892 |
| 500 | 0.9965 | 0.9933 |

### Queries per second at matched recall

For each recall target, each engine's fastest measured `ef` whose build-1 recall reaches the target. The `ef` values and recalls reached are shown, because the two engines do not reach a target at the same `ef`. Cells are the median of the trials.

**Recall@10 of 0.90 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 2,201 (ef 40, recall 0.940) | 1,315 (ef 40, recall 0.926) | 1.67x | 0.46 / 0.76 ms |
| 2 | 4,386 (ef 40, recall 0.940) | 2,578 (ef 40, recall 0.926) | 1.70x | 0.46 / 0.78 ms |
| 4 | 8,738 (ef 40, recall 0.940) | 4,750 (ef 40, recall 0.926) | 1.84x | 0.46 / 0.84 ms |
| 8 | 17,064 (ef 40, recall 0.940) | 8,020 (ef 40, recall 0.926) | 2.13x | 0.48 / 0.99 ms |
| 16 | 31,812 (ef 40, recall 0.940) | 8,858 (ef 80, recall 0.961) | 3.59x | 0.51 / 1.80 ms |
| 32 | 54,927 (ef 40, recall 0.940) | 8,896 (ef 80, recall 0.961) | 6.17x | 0.59 / 3.59 ms |
| 50 | 69,616 (ef 40, recall 0.940) | 8,688 (ef 40, recall 0.926) | 8.01x | 0.72 / 4.59 ms |
| 100 | 87,372 (ef 40, recall 0.940) | 8,641 (ef 40, recall 0.926) | 10.11x | 1.13 / 9.93 ms |

**Recall@10 of 0.95 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,429 (ef 80, recall 0.973) | 944 (ef 80, recall 0.961) | 1.51x | 0.71 / 1.06 ms |
| 2 | 2,850 (ef 80, recall 0.973) | 1,861 (ef 80, recall 0.961) | 1.53x | 0.72 / 1.07 ms |
| 4 | 5,632 (ef 80, recall 0.973) | 3,527 (ef 80, recall 0.961) | 1.60x | 0.72 / 1.14 ms |
| 8 | 10,958 (ef 80, recall 0.973) | 6,110 (ef 80, recall 0.961) | 1.79x | 0.74 / 1.31 ms |
| 16 | 20,290 (ef 80, recall 0.973) | 8,858 (ef 80, recall 0.961) | 2.29x | 0.80 / 1.80 ms |
| 32 | 34,012 (ef 80, recall 0.973) | 8,896 (ef 80, recall 0.961) | 3.82x | 0.95 / 3.59 ms |
| 50 | 41,838 (ef 80, recall 0.973) | 8,679 (ef 150, recall 0.978) | 4.82x | 1.20 / 5.40 ms |
| 100 | 47,789 (ef 80, recall 0.973) | 8,395 (ef 80, recall 0.961) | 5.69x | 2.08 / 10.06 ms |

**Recall@10 of 0.99 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 536 (ef 300, recall 0.993) | 292 (ef 500, recall 0.993) | 1.84x | 1.88 / 3.25 ms |
| 2 | 1,063 (ef 300, recall 0.993) | 589 (ef 500, recall 0.993) | 1.80x | 1.90 / 3.20 ms |
| 4 | 2,084 (ef 300, recall 0.993) | 1,171 (ef 500, recall 0.993) | 1.78x | 1.93 / 3.24 ms |
| 8 | 4,039 (ef 300, recall 0.993) | 2,178 (ef 500, recall 0.993) | 1.85x | 1.99 / 3.52 ms |
| 16 | 7,434 (ef 300, recall 0.993) | 3,958 (ef 500, recall 0.993) | 1.88x | 2.16 / 3.91 ms |
| 32 | 11,971 (ef 300, recall 0.993) | 6,284 (ef 500, recall 0.993) | 1.90x | 2.67 / 4.94 ms |
| 50 | 13,984 (ef 300, recall 0.993) | 7,015 (ef 500, recall 0.993) | 1.99x | 3.57 / 6.81 ms |
| 100 | 15,596 (ef 300, recall 0.993) | 7,034 (ef 500, recall 0.993) | 2.22x | 6.36 / 13.65 ms |

### Throughput and latency at every search depth

Median queries per second (lowest to highest trial), median and 99th-percentile latency, and the CPU cores each server kept busy (CPU seconds per wall second, from /proc). `ef` is the search-time beam width.

**ef 40** (recall@10: HotKV 0.9400, Redis 0.9262)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 2,201 (2,193 to 2,220) | 1,315 (1,314 to 1,325) | 1.67x | 0.46 / 0.67 | 0.76 / 1.10 | 1.0 / 1.0 |
| 2 | 4,386 (4,353 to 4,419) | 2,578 (2,571 to 2,578) | 1.70x | 0.46 / 0.68 | 0.78 / 1.13 | 1.9 / 1.9 |
| 4 | 8,738 (8,720 to 8,770) | 4,750 (4,747 to 4,763) | 1.84x | 0.46 / 0.68 | 0.84 / 1.21 | 3.8 / 3.7 |
| 8 | 17,064 (17,025 to 17,105) | 8,020 (8,018 to 8,049) | 2.13x | 0.48 / 0.69 | 0.99 / 1.45 | 7.6 / 6.2 |
| 16 | 31,812 (31,778 to 31,854) | 8,858 (8,848 to 8,932) | 3.59x | 0.51 / 0.75 | 1.83 / 2.33 | 15.1 / 6.8 |
| 32 | 54,927 (54,687 to 55,457) | 8,750 (8,728 to 8,766) | 6.28x | 0.59 / 0.87 | 4.00 / 4.78 | 30.4 / 6.8 |
| 50 | 69,616 (69,325 to 72,050) | 8,688 (8,687 to 8,690) | 8.01x | 0.72 / 1.10 | 4.59 / 8.72 | 47.7 / 6.7 |
| 100 | 87,372 (86,175 to 90,357) | 8,641 (8,639 to 8,662) | 10.11x | 1.13 / 1.95 | 9.93 / 19.98 | 96.7 / 6.8 |

**ef 80** (recall@10: HotKV 0.9733, Redis 0.9610)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,429 (1,406 to 1,444) | 944 (944 to 945) | 1.51x | 0.71 / 1.05 | 1.06 / 1.52 | 1.0 / 1.0 |
| 2 | 2,850 (2,848 to 2,866) | 1,861 (1,856 to 1,866) | 1.53x | 0.72 / 1.06 | 1.07 / 1.54 | 1.9 / 2.0 |
| 4 | 5,632 (5,589 to 5,653) | 3,527 (3,516 to 3,529) | 1.60x | 0.72 / 1.07 | 1.14 / 1.62 | 3.9 / 3.8 |
| 8 | 10,958 (10,912 to 11,069) | 6,110 (6,100 to 6,116) | 1.79x | 0.74 / 1.10 | 1.31 / 1.87 | 7.7 / 6.9 |
| 16 | 20,290 (20,274 to 20,390) | 8,858 (8,835 to 8,910) | 2.29x | 0.80 / 1.18 | 1.80 / 2.42 | 15.4 / 9.8 |
| 32 | 34,012 (33,992 to 34,544) | 8,896 (8,816 to 8,904) | 3.82x | 0.95 / 1.41 | 3.59 / 4.66 | 30.9 / 10.0 |
| 50 | 41,838 (40,456 to 42,265) | 8,629 (8,549 to 8,656) | 4.85x | 1.20 / 1.83 | 5.78 / 8.10 | 48.5 / 9.7 |
| 100 | 47,789 (47,606 to 50,108) | 8,395 (8,384 to 8,429) | 5.69x | 2.08 / 3.52 | 10.06 / 19.06 | 97.5 / 9.6 |

**ef 150** (recall@10: HotKV 0.9863, Redis 0.9784)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 926 (916 to 936) | 659 (642 to 662) | 1.41x | 1.10 / 1.54 | 1.49 / 2.31 | 1.0 / 1.0 |
| 2 | 1,819 (1,804 to 1,821) | 1,310 (1,303 to 1,312) | 1.39x | 1.12 / 1.57 | 1.51 / 2.29 | 2.0 / 2.0 |
| 4 | 3,601 (3,592 to 3,606) | 2,519 (2,512 to 2,521) | 1.43x | 1.13 / 1.59 | 1.57 / 2.37 | 3.9 / 3.9 |
| 8 | 6,986 (6,850 to 7,031) | 4,555 (4,532 to 4,556) | 1.53x | 1.17 / 1.64 | 1.74 / 2.57 | 7.8 / 7.4 |
| 16 | 12,879 (12,800 to 12,915) | 7,396 (7,357 to 7,410) | 1.74x | 1.26 / 1.79 | 2.15 / 3.21 | 15.6 / 12.6 |
| 32 | 20,932 (20,841 to 21,343) | 8,766 (8,639 to 8,838) | 2.39x | 1.54 / 2.25 | 3.60 / 4.75 | 31.3 / 14.8 |
| 50 | 24,944 (24,783 to 25,232) | 8,679 (8,596 to 8,846) | 2.87x | 2.02 / 3.06 | 5.40 / 7.21 | 48.6 / 14.8 |
| 100 | 27,711 (27,365 to 27,940) | 8,248 (8,228 to 8,306) | 3.36x | 3.61 / 5.92 | 13.58 / 18.31 | 98.5 / 14.3 |

**ef 300** (recall@10: HotKV 0.9933, Redis 0.9892)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 536 (527 to 538) | 413 (407 to 414) | 1.30x | 1.88 / 2.74 | 2.34 / 3.98 | 1.0 / 1.0 |
| 2 | 1,063 (1,051 to 1,063) | 820 (818 to 822) | 1.30x | 1.90 / 2.77 | 2.36 / 3.97 | 2.0 / 2.0 |
| 4 | 2,084 (2,084 to 2,101) | 1,618 (1,611 to 1,618) | 1.29x | 1.93 / 2.82 | 2.39 / 3.99 | 3.9 / 3.9 |
| 8 | 4,039 (4,032 to 4,066) | 2,996 (2,994 to 3,008) | 1.35x | 1.99 / 2.92 | 2.60 / 4.20 | 7.8 / 7.7 |
| 16 | 7,434 (7,412 to 7,454) | 5,311 (5,306 to 5,314) | 1.40x | 2.16 / 3.21 | 2.95 / 4.65 | 15.6 / 14.6 |
| 32 | 11,971 (11,940 to 11,983) | 8,284 (8,266 to 8,309) | 1.45x | 2.67 / 4.04 | 3.80 / 5.84 | 31.4 / 24.8 |
| 50 | 13,984 (13,977 to 13,988) | 8,362 (8,282 to 8,374) | 1.67x | 3.57 / 5.65 | 5.94 / 8.21 | 49.3 / 25.0 |
| 100 | 15,596 (15,546 to 15,786) | 7,746 (7,678 to 7,768) | 2.01x | 6.36 / 10.74 | 13.05 / 17.80 | 99.0 / 23.0 |

**ef 500** (recall@10: HotKV 0.9965, Redis 0.9933)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 354 (353 to 358) | 292 (290 to 292) | 1.21x | 2.86 / 4.18 | 3.25 / 5.97 | 1.0 / 1.0 |
| 2 | 703 (702 to 708) | 589 (588 to 590) | 1.19x | 2.85 / 4.28 | 3.20 / 5.96 | 2.0 / 2.0 |
| 4 | 1,384 (1,384 to 1,393) | 1,171 (1,167 to 1,173) | 1.18x | 2.88 / 4.36 | 3.24 / 5.96 | 3.9 / 3.9 |
| 8 | 2,677 (2,676 to 2,688) | 2,178 (2,175 to 2,180) | 1.23x | 2.99 / 4.52 | 3.52 / 6.17 | 7.9 / 7.8 |
| 16 | 4,943 (4,917 to 4,949) | 3,958 (3,956 to 3,960) | 1.25x | 3.22 / 4.98 | 3.91 / 6.65 | 15.8 / 15.3 |
| 32 | 7,887 (7,842 to 7,894) | 6,284 (6,284 to 6,288) | 1.25x | 4.02 / 6.48 | 4.94 / 8.22 | 31.6 / 27.3 |
| 50 | 9,176 (9,174 to 9,180) | 7,015 (6,986 to 7,030) | 1.31x | 5.39 / 8.92 | 6.81 / 14.56 | 49.5 / 31.8 |
| 100 | 10,125 (10,055 to 10,240) | 7,034 (6,928 to 7,076) | 1.44x | 9.76 / 16.71 | 13.65 / 28.69 | 99.4 / 32.6 |

## 100,000 vectors

### Loading

Time and vectors per second are for the whole load, including the load generator's own formatting of each vector. RSS is the size of the server process after that load; the server holds every build made so far, so with several builds it grows. The Redis indexes were built in an earlier run (`raw/redis_build/`) and saved with `SAVE`; the measurements started Redis from the saved file, and the Redis figures here are from the run that built the index.

| Engine | Build | Loaded over | Time | Vectors/s | Server cores busy | Process RSS after load |
|---|---|---|---|---|---|---|
| HotKV | build 1 | 32 connections | 9 s | 10,982 | 18.2 | 0.78 GB |
| HotKV | build 2 | 32 connections | 9 s | 11,076 | 18.4 | 1.50 GB |
| HotKV | build 3 | 32 connections | 9 s | 11,065 | 18.4 | 2.21 GB |
| Redis | build 1 | 32 connections, `CAS` | 49 s | 2,034 | 2.5 | 0.72 GB |
| Redis | build 2 | 32 connections, `CAS` | 49 s | 2,033 | 2.6 | 1.43 GB |
| Redis | build 3 | 32 connections, `CAS` | 50 s | 2,018 | 2.6 | 2.13 GB |

### Recall@10 against exact ground truth

Build 1 is the index the throughput numbers were measured on. With several builds the range over all independent builds is shown.

| ef | HotKV | Redis |
|---|---|---|
| 10 | 0.7579 (0.7559 to 0.7781 over 3 builds) | 0.7311 (0.7114 to 0.7383 over 3 builds) |
| 20 | 0.8660 (0.8600 to 0.8732 over 3 builds) | 0.8411 (0.8341 to 0.8494 over 3 builds) |
| 40 | 0.9304 (0.9304 to 0.9374 over 3 builds) | 0.9190 (0.9184 to 0.9235 over 3 builds) |
| 80 | 0.9716 (0.9716 to 0.9734 over 3 builds) | 0.9639 (0.9639 to 0.9670 over 3 builds) |
| 150 | 0.9898 (0.9898 to 0.9903 over 3 builds) | 0.9852 (0.9852 to 0.9854 over 3 builds) |
| 300 | 0.9965 (0.9953 to 0.9965 over 3 builds) | 0.9951 (0.9940 to 0.9951 over 3 builds) |
| 500 | 0.9979 (0.9979 to 0.9983 over 3 builds) | 0.9977 (0.9970 to 0.9977 over 3 builds) |

### Queries per second at matched recall

For each recall target, each engine's fastest measured `ef` whose build-1 recall reaches the target. The `ef` values and recalls reached are shown, because the two engines do not reach a target at the same `ef`. Cells are the median of the trials.

**Recall@10 of 0.90 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 2,913 (ef 40, recall 0.930) | 1,679 (ef 40, recall 0.919) | 1.73x | 0.34 / 0.59 ms |
| 2 | 5,740 (ef 40, recall 0.930) | 3,240 (ef 40, recall 0.919) | 1.77x | 0.35 / 0.61 ms |
| 4 | 11,268 (ef 40, recall 0.930) | 5,846 (ef 40, recall 0.919) | 1.93x | 0.35 / 0.68 ms |
| 8 | 22,155 (ef 40, recall 0.930) | 8,904 (ef 40, recall 0.919) | 2.49x | 0.36 / 0.89 ms |
| 16 | 41,750 (ef 40, recall 0.930) | 9,133 (ef 80, recall 0.964) | 4.57x | 0.38 / 1.73 ms |
| 32 | 72,461 (ef 40, recall 0.930) | 8,943 (ef 80, recall 0.964) | 8.10x | 0.44 / 3.78 ms |
| 50 | 90,447 (ef 40, recall 0.930) | 8,875 (ef 40, recall 0.919) | 10.19x | 0.55 / 4.38 ms |
| 100 | 121,122 (ef 40, recall 0.930) | 8,823 (ef 40, recall 0.919) | 13.73x | 0.81 / 10.12 ms |

**Recall@10 of 0.95 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,904 (ef 80, recall 0.972) | 1,228 (ef 80, recall 0.964) | 1.55x | 0.52 / 0.82 ms |
| 2 | 3,756 (ef 80, recall 0.972) | 2,401 (ef 80, recall 0.964) | 1.56x | 0.53 / 0.83 ms |
| 4 | 7,426 (ef 80, recall 0.972) | 4,461 (ef 80, recall 0.964) | 1.66x | 0.54 / 0.90 ms |
| 8 | 14,545 (ef 80, recall 0.972) | 7,463 (ef 80, recall 0.964) | 1.95x | 0.55 / 1.06 ms |
| 16 | 27,042 (ef 80, recall 0.972) | 9,133 (ef 80, recall 0.964) | 2.96x | 0.59 / 1.73 ms |
| 32 | 44,859 (ef 80, recall 0.972) | 8,943 (ef 80, recall 0.964) | 5.02x | 0.71 / 3.78 ms |
| 50 | 54,332 (ef 80, recall 0.972) | 8,730 (ef 80, recall 0.964) | 6.22x | 0.92 / 5.90 ms |
| 100 | 62,978 (ef 80, recall 0.972) | 8,725 (ef 80, recall 0.964) | 7.22x | 1.57 / 9.79 ms |

**Recall@10 of 0.99 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 742 (ef 300, recall 0.996) | 548 (ef 300, recall 0.995) | 1.35x | 1.35 / 1.81 ms |
| 2 | 1,425 (ef 300, recall 0.996) | 1,103 (ef 300, recall 0.995) | 1.29x | 1.41 / 1.79 ms |
| 4 | 2,820 (ef 300, recall 0.996) | 2,152 (ef 300, recall 0.995) | 1.31x | 1.42 / 1.83 ms |
| 8 | 5,502 (ef 300, recall 0.996) | 3,904 (ef 300, recall 0.995) | 1.41x | 1.46 / 2.03 ms |
| 16 | 10,038 (ef 300, recall 0.996) | 6,507 (ef 300, recall 0.995) | 1.54x | 1.59 / 2.44 ms |
| 32 | 15,956 (ef 300, recall 0.996) | 8,825 (ef 300, recall 0.995) | 1.81x | 1.99 / 3.61 ms |
| 50 | 18,590 (ef 300, recall 0.996) | 8,684 (ef 300, recall 0.995) | 2.14x | 2.66 / 5.79 ms |
| 100 | 20,319 (ef 300, recall 0.996) | 7,845 (ef 300, recall 0.995) | 2.59x | 4.83 / 13.87 ms |

### Throughput and latency at every search depth

Median queries per second (lowest to highest trial), median and 99th-percentile latency, and the CPU cores each server kept busy (CPU seconds per wall second, from /proc). `ef` is the search-time beam width.

**ef 40** (recall@10: HotKV 0.9304, Redis 0.9190)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 2,913 (2,910 to 2,936) | 1,679 (1,666 to 1,680) | 1.73x | 0.34 / 0.51 | 0.59 / 0.83 | 0.9 / 1.0 |
| 2 | 5,740 (5,690 to 5,744) | 3,240 (3,234 to 3,242) | 1.77x | 0.35 / 0.52 | 0.61 / 0.86 | 1.9 / 1.9 |
| 4 | 11,268 (11,050 to 11,311) | 5,846 (5,842 to 5,864) | 1.93x | 0.35 / 0.53 | 0.68 / 0.96 | 3.7 / 3.6 |
| 8 | 22,155 (22,064 to 22,208) | 8,904 (8,826 to 8,927) | 2.49x | 0.36 / 0.54 | 0.89 / 1.22 | 7.4 / 5.3 |
| 16 | 41,750 (41,538 to 41,925) | 8,972 (8,876 to 9,101) | 4.65x | 0.38 / 0.58 | 1.76 / 2.27 | 14.9 / 5.3 |
| 32 | 72,461 (72,398 to 72,985) | 8,852 (8,818 to 8,889) | 8.19x | 0.44 / 0.67 | 3.64 / 5.08 | 29.9 / 5.4 |
| 50 | 90,447 (90,072 to 94,276) | 8,875 (8,870 to 8,906) | 10.19x | 0.55 / 0.86 | 4.38 / 9.02 | 47.4 / 5.4 |
| 100 | 121,122 (116,474 to 123,752) | 8,823 (8,806 to 8,839) | 13.73x | 0.81 / 1.41 | 10.12 / 20.37 | 95.8 / 5.5 |

**ef 80** (recall@10: HotKV 0.9716, Redis 0.9639)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,904 (1,898 to 1,906) | 1,228 (1,224 to 1,232) | 1.55x | 0.52 / 0.77 | 0.82 / 1.10 | 1.0 / 1.0 |
| 2 | 3,756 (3,746 to 3,760) | 2,401 (2,401 to 2,406) | 1.56x | 0.53 / 0.76 | 0.83 / 1.13 | 1.9 / 1.9 |
| 4 | 7,426 (7,375 to 7,430) | 4,461 (4,446 to 4,464) | 1.66x | 0.54 / 0.77 | 0.90 / 1.24 | 3.8 / 3.7 |
| 8 | 14,545 (14,537 to 14,564) | 7,463 (7,422 to 7,467) | 1.95x | 0.55 / 0.79 | 1.06 / 1.51 | 7.6 / 6.4 |
| 16 | 27,042 (26,564 to 27,102) | 9,133 (9,013 to 9,142) | 2.96x | 0.59 / 0.85 | 1.73 / 2.22 | 15.2 / 7.8 |
| 32 | 44,859 (44,814 to 45,133) | 8,943 (8,940 to 8,951) | 5.02x | 0.71 / 1.03 | 3.78 / 4.32 | 30.6 / 7.7 |
| 50 | 54,332 (54,194 to 56,012) | 8,730 (8,613 to 8,732) | 6.22x | 0.92 / 1.37 | 5.90 / 8.37 | 48.2 / 7.7 |
| 100 | 62,978 (62,301 to 67,578) | 8,725 (8,608 to 8,740) | 7.22x | 1.57 / 2.58 | 9.79 / 19.49 | 97.3 / 7.7 |

**ef 150** (recall@10: HotKV 0.9898, Redis 0.9852)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,228 (1,219 to 1,236) | 860 (857 to 868) | 1.43x | 0.82 / 1.14 | 1.16 / 1.61 | 1.0 / 1.0 |
| 2 | 2,418 (2,415 to 2,422) | 1,720 (1,716 to 1,724) | 1.41x | 0.83 / 1.17 | 1.16 / 1.63 | 2.0 / 2.0 |
| 4 | 4,744 (4,727 to 4,768) | 3,287 (3,285 to 3,290) | 1.44x | 0.85 / 1.19 | 1.21 / 1.71 | 3.9 / 3.8 |
| 8 | 9,244 (9,213 to 9,306) | 5,702 (5,698 to 5,710) | 1.62x | 0.87 / 1.22 | 1.40 / 1.99 | 7.8 / 7.1 |
| 16 | 17,157 (16,985 to 17,158) | 8,947 (8,930 to 8,954) | 1.92x | 0.93 / 1.34 | 1.78 / 2.42 | 15.5 / 11.3 |
| 32 | 27,976 (27,820 to 28,021) | 8,887 (8,886 to 8,912) | 3.15x | 1.14 / 1.63 | 3.46 / 4.51 | 31.0 / 11.2 |
| 50 | 33,153 (32,766 to 33,278) | 8,598 (8,588 to 8,653) | 3.86x | 1.51 / 2.27 | 5.61 / 7.86 | 48.7 / 10.9 |
| 100 | 36,666 (36,304 to 36,756) | 8,520 (8,492 to 8,522) | 4.30x | 2.70 / 4.38 | 9.89 / 18.86 | 98.0 / 11.1 |

**ef 300** (recall@10: HotKV 0.9965, Redis 0.9951)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 742 (734 to 747) | 548 (543 to 548) | 1.35x | 1.35 / 1.90 | 1.81 / 2.71 | 1.0 / 1.0 |
| 2 | 1,425 (1,420 to 1,426) | 1,103 (1,103 to 1,104) | 1.29x | 1.41 / 2.00 | 1.79 / 2.70 | 2.0 / 2.0 |
| 4 | 2,820 (2,805 to 2,823) | 2,152 (2,152 to 2,154) | 1.31x | 1.42 / 2.02 | 1.83 / 2.77 | 3.9 / 3.9 |
| 8 | 5,502 (5,491 to 5,506) | 3,904 (3,889 to 3,914) | 1.41x | 1.46 / 2.06 | 2.03 / 2.98 | 7.9 / 7.5 |
| 16 | 10,038 (9,980 to 10,055) | 6,507 (6,502 to 6,507) | 1.54x | 1.59 / 2.31 | 2.44 / 3.58 | 15.6 / 13.6 |
| 32 | 15,956 (15,944 to 15,986) | 8,825 (8,776 to 8,854) | 1.81x | 1.99 / 2.93 | 3.61 / 4.79 | 31.2 / 18.9 |
| 50 | 18,590 (18,372 to 18,880) | 8,684 (8,548 to 8,686) | 2.14x | 2.66 / 4.13 | 5.79 / 7.62 | 48.9 / 18.6 |
| 100 | 20,319 (20,289 to 20,392) | 7,845 (7,845 to 7,852) | 2.59x | 4.83 / 7.97 | 13.87 / 15.40 | 98.7 / 17.1 |

## Checks

- Busiest load-generator process in any cell: 8% of one CPU. A value near 100% would mean the client, not the server, set the limit.
- Query replies with fewer than 10 results: 0. Load-generator processes that started late: 0.
- Every load was followed by a check that the server holds exactly the number of vectors sent.

## Limits of this measurement

- One machine, one dataset (1,536-dimension OpenAI embeddings), top 10 only, float32 vectors, cosine similarity.
- The load generators run on the same machine as the servers, on separate vCPUs, over loopback. The two engines share the CPU set, the memory system and the last-level cache with their load generators.
- vCPUs are hyperthreads: a pinned set of N vCPUs is N/2 physical cores.
- Redis is a stock build. Its vector sets run at most 32 searches at once (a compile-time limit, `HNSW_MAX_THREADS`) and add vectors on the main thread, so it uses a small part of this machine; that is how it behaves, not something this benchmark configured.
- Recall is measured once per index build and `ef`. Independent builds of the same engine differ in recall; the range is shown where several builds were made.
- The HotKV build is an unreleased commit (see Setup). Redis was loaded with `VADD ... CAS` and run with its default I/O threads; the tuning runs that led to those choices are in `raw/tuning/`.
- HotKV ran with 192 threads on socket 0 of this two-socket machine (vCPUs 0-95 and 192-287) and the load generators on socket 1; the published Azure D160 run used 128 threads on a 160-vCPU machine, so the two runs are not directly comparable.
- Loading is not like for like: the Redis index was built with Redis pinned to four vCPUs (96 to 99) in an earlier step, while HotKV loaded on its 192-thread set. Treat the Redis load time as a lower bound.
- In this run the four Redis I/O-thread checks in `raw/tuning/redis_io*` did not run: `tune.sh` built the Redis index path wrongly and `vsbench.py` stopped with an error (the logs show it; fixed since). Redis ran with 1 I/O thread, its default, as in the Azure D160 run, where the same checks with 1, 4, 8 and 16 I/O threads gave 8,178, 7,832, 7,832 and 7,906 queries per second at 16 clients and 7,557, 7,939, 8,331 and 8,082 at 50 clients (`raw/tuning` of that run). The HotKV loading checks (`hotkv_p8`, `hotkv_p16`, `hotkv_p32`) ran normally.
