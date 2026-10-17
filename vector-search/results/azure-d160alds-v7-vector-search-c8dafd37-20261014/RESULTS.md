# Vector search: HotKV and Redis 8.10.2 on 160 vCPUs

Plain vector search on both servers: build an HNSW index, then run top-10 nearest-neighbour queries. No filters, no attributes, no quantization, none of HotKV's AI engines. Every figure below is computed by `scripts/render_report.py` from the raw trials in `raw/`.

## Setup

|  |  |
|---|---|
| Machine | Azure Standard_D160alds_v7: AMD EPYC 9V45 96-Core Processor, 160 vCPUs, one VM |
| Kernel / OS | Linux-6.17.0-1022-azure-x86_64-with-glibc2.39 |
| HotKV | commit `c8dafd375b83907320473937f66d55b03c934668`, binary SHA-256 `b5769236b47637c0...`, release build, portable flags (no -march=native) |
| Redis | 8.10.2 from the GitHub release tag, stock `make`, binary SHA-256 `e0a9716bc5abd009...` |
| CPU placement | servers pinned to vCPUs 0-127; load generators on 32 other vCPUs; same CPU set for both servers; loopback |
| HotKV launch | `hotkv --threads 128 --no-snapshot --protected-mode no` |
| Redis launch | `redis-server --save "" --appendonly no --protected-mode no` (default I/O threads) |
| Index | HNSW, cosine, M=16, ef_construction=200, float32 on both (Redis: `NOQUANT`) |
| Dataset | dbpedia-entities-openai-1M (OpenAI ada-002, 1,536 dimensions, MIT). Base set = first N rows; queries = the last 1,000 rows; no overlap |
| Ground truth | exact top-10 by cosine similarity, brute force in float64, independent of either server |
| Trials | 3 per cell; 1 s warm-up then 4 s measured; engines alternate within each cell |

## 999,000 vectors

### Loading

Time and vectors per second are for the whole load, including the load generator's own formatting of each vector. RSS is the size of the server process after that load; the server holds every build made so far, so with several builds it grows. The Redis indexes were built in an earlier run (`raw/redis_build/`) and saved with `SAVE`; the measurements started Redis from the saved file, and the Redis figures here are from the run that built the index. That earlier run built the Redis index with Redis pinned to four vCPUs (two physical cores, vCPUs 140 to 143), and the settings checks under `raw/tuning/` ran on other vCPUs during part of it, while HotKV loaded alone on 128 vCPUs. Redis adds vectors on its main thread, but with `CAS` it also uses other threads, so the Redis loading figures are a lower bound on what it would do with the same 128 vCPUs to itself; the loading comparison is not like for like.

| Engine | Build | Loaded over | Time | Vectors/s | Server cores busy | Process RSS after load |
|---|---|---|---|---|---|---|
| HotKV | build 1 | 32 connections | 188 s | 5,325 | 15.4 | 6.77 GB |
| Redis | build 1 | 32 connections, `CAS` | 935 s | 1,069 | 3.0 | 7.01 GB |

### Recall@10 against exact ground truth

Build 1 is the index the throughput numbers were measured on. With several builds the range over all independent builds is shown.

| ef | HotKV | Redis |
|---|---|---|
| 10 | 0.7822 | 0.7374 |
| 20 | 0.8773 | 0.8575 |
| 40 | 0.9404 | 0.9233 |
| 80 | 0.9704 | 0.9616 |
| 150 | 0.9866 | 0.9804 |
| 300 | 0.9933 | 0.9897 |
| 500 | 0.9972 | 0.9940 |

### Queries per second at matched recall

For each recall target, each engine's fastest measured `ef` whose build-1 recall reaches the target. The `ef` values and recalls reached are shown, because the two engines do not reach a target at the same `ef`. Cells are the median of the trials.

**Recall@10 of 0.90 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 2,108 (ef 40, recall 0.940) | 1,259 (ef 40, recall 0.923) | 1.67x | 0.48 / 0.80 ms |
| 2 | 4,066 (ef 40, recall 0.940) | 2,467 (ef 40, recall 0.923) | 1.65x | 0.50 / 0.81 ms |
| 4 | 8,304 (ef 40, recall 0.940) | 4,468 (ef 40, recall 0.923) | 1.86x | 0.49 / 0.88 ms |
| 8 | 15,989 (ef 40, recall 0.940) | 7,146 (ef 40, recall 0.923) | 2.24x | 0.51 / 1.09 ms |
| 16 | 29,604 (ef 40, recall 0.940) | 8,508 (ef 40, recall 0.923) | 3.48x | 0.54 / 1.86 ms |
| 32 | 49,630 (ef 40, recall 0.940) | 8,258 (ef 40, recall 0.923) | 6.01x | 0.65 / 3.66 ms |
| 50 | 63,897 (ef 40, recall 0.940) | 8,061 (ef 40, recall 0.923) | 7.93x | 0.78 / 6.41 ms |
| 100 | 90,003 (ef 40, recall 0.940) | 7,973 (ef 40, recall 0.923) | 11.29x | 1.07 / 11.05 ms |

**Recall@10 of 0.95 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,328 (ef 80, recall 0.970) | 946 (ef 80, recall 0.962) | 1.40x | 0.77 / 1.07 ms |
| 2 | 2,710 (ef 80, recall 0.970) | 1,854 (ef 80, recall 0.962) | 1.46x | 0.76 / 1.09 ms |
| 4 | 5,358 (ef 80, recall 0.970) | 3,334 (ef 80, recall 0.962) | 1.61x | 0.77 / 1.20 ms |
| 8 | 10,342 (ef 80, recall 0.970) | 5,531 (ef 80, recall 0.962) | 1.87x | 0.79 / 1.43 ms |
| 16 | 18,500 (ef 80, recall 0.970) | 7,265 (ef 80, recall 0.962) | 2.55x | 0.87 / 2.15 ms |
| 32 | 29,014 (ef 80, recall 0.970) | 7,230 (ef 80, recall 0.962) | 4.01x | 1.05 / 4.31 ms |
| 50 | 37,508 (ef 80, recall 0.970) | 6,825 (ef 80, recall 0.962) | 5.50x | 1.33 / 7.17 ms |
| 100 | 51,146 (ef 80, recall 0.970) | 6,510 (ef 80, recall 0.962) | 7.86x | 1.91 / 13.49 ms |

**Recall@10 of 0.99 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 507 (ef 300, recall 0.993) | 287 (ef 500, recall 0.994) | 1.77x | 1.99 / 3.31 ms |
| 2 | 992 (ef 300, recall 0.993) | 592 (ef 500, recall 0.994) | 1.68x | 2.03 / 3.19 ms |
| 4 | 1,967 (ef 300, recall 0.993) | 1,111 (ef 500, recall 0.994) | 1.77x | 2.05 / 3.41 ms |
| 8 | 3,768 (ef 300, recall 0.993) | 1,836 (ef 500, recall 0.994) | 2.05x | 2.14 / 4.20 ms |
| 16 | 6,961 (ef 300, recall 0.993) | 2,322 (ef 500, recall 0.994) | 3.00x | 2.30 / 6.70 ms |
| 32 | 10,874 (ef 300, recall 0.993) | 2,456 (ef 500, recall 0.994) | 4.43x | 2.94 / 12.81 ms |
| 50 | 12,393 (ef 300, recall 0.993) | 2,483 (ef 500, recall 0.994) | 4.99x | 4.02 / 18.91 ms |
| 100 | 13,843 (ef 300, recall 0.993) | 2,583 (ef 500, recall 0.994) | 5.36x | 7.11 / 37.65 ms |

### Throughput and latency at every search depth

Median queries per second (lowest to highest trial), median and 99th-percentile latency, and the CPU cores each server kept busy (CPU seconds per wall second, from /proc). `ef` is the search-time beam width.

**ef 40** (recall@10: HotKV 0.9404, Redis 0.9233)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 2,108 (2,097 to 2,119) | 1,259 (1,242 to 1,268) | 1.67x | 0.48 / 0.69 | 0.80 / 1.17 | 0.9 / 1.0 |
| 2 | 4,066 (3,936 to 4,202) | 2,467 (2,466 to 2,467) | 1.65x | 0.50 / 0.75 | 0.81 / 1.21 | 1.9 / 1.9 |
| 4 | 8,304 (8,276 to 8,308) | 4,468 (4,445 to 4,529) | 1.86x | 0.49 / 0.71 | 0.88 / 1.34 | 3.8 / 3.7 |
| 8 | 15,989 (15,777 to 16,042) | 7,146 (7,127 to 7,181) | 2.24x | 0.51 / 0.76 | 1.09 / 1.69 | 7.5 / 6.5 |
| 16 | 29,604 (29,538 to 29,624) | 8,508 (8,464 to 8,570) | 3.48x | 0.54 / 0.83 | 1.86 / 2.55 | 15.0 / 7.7 |
| 32 | 49,630 (49,436 to 49,806) | 8,258 (8,181 to 8,290) | 6.01x | 0.65 / 1.00 | 3.66 / 7.81 | 29.5 / 7.7 |
| 50 | 63,897 (62,340 to 66,159) | 8,061 (8,059 to 8,077) | 7.93x | 0.78 / 1.23 | 6.41 / 10.90 | 45.6 / 7.8 |
| 100 | 90,003 (81,987 to 97,144) | 7,973 (7,928 to 7,987) | 11.29x | 1.07 / 2.07 | 11.05 / 22.30 | 91.1 / 7.7 |

**ef 80** (recall@10: HotKV 0.9704, Redis 0.9616)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,328 (1,324 to 1,330) | 946 (945 to 953) | 1.40x | 0.77 / 1.12 | 1.07 / 1.55 | 1.0 / 1.0 |
| 2 | 2,710 (2,696 to 2,713) | 1,854 (1,845 to 1,858) | 1.46x | 0.76 / 1.09 | 1.09 / 1.60 | 1.9 / 2.0 |
| 4 | 5,358 (5,306 to 5,359) | 3,334 (3,332 to 3,336) | 1.61x | 0.77 / 1.08 | 1.20 / 1.79 | 3.8 / 3.8 |
| 8 | 10,342 (10,292 to 10,436) | 5,531 (5,531 to 5,608) | 1.87x | 0.79 / 1.12 | 1.43 / 2.18 | 7.7 / 7.1 |
| 16 | 18,500 (17,788 to 19,176) | 7,265 (7,168 to 7,514) | 2.55x | 0.87 / 1.51 | 2.15 / 3.84 | 15.3 / 11.2 |
| 32 | 29,014 (28,721 to 31,246) | 7,230 (7,157 to 7,712) | 4.01x | 1.05 / 2.26 | 4.31 / 8.38 | 30.0 / 11.3 |
| 50 | 37,508 (36,327 to 37,778) | 6,825 (6,681 to 6,856) | 5.50x | 1.33 / 2.13 | 7.17 / 11.92 | 46.9 / 11.0 |
| 100 | 51,146 (48,614 to 51,494) | 6,510 (6,444 to 6,621) | 7.86x | 1.91 / 3.49 | 13.49 / 26.92 | 92.5 / 10.6 |

**ef 150** (recall@10: HotKV 0.9866, Redis 0.9804)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 875 (864 to 883) | 636 (618 to 642) | 1.38x | 1.17 / 1.61 | 1.57 / 2.38 | 1.0 / 1.0 |
| 2 | 1,743 (1,726 to 1,748) | 1,272 (1,270 to 1,282) | 1.37x | 1.17 / 1.62 | 1.56 / 2.40 | 2.0 / 2.0 |
| 4 | 3,420 (3,400 to 3,432) | 2,370 (2,358 to 2,381) | 1.44x | 1.20 / 1.66 | 1.67 / 2.55 | 3.9 / 3.9 |
| 8 | 6,603 (6,563 to 6,634) | 3,995 (3,976 to 4,040) | 1.65x | 1.24 / 1.74 | 2.00 / 2.98 | 7.8 / 7.5 |
| 16 | 11,954 (11,915 to 12,105) | 4,951 (4,938 to 4,958) | 2.41x | 1.36 / 1.97 | 3.17 / 5.39 | 15.5 / 12.1 |
| 32 | 18,976 (17,768 to 19,386) | 5,363 (5,332 to 5,398) | 3.54x | 1.70 / 2.61 | 5.85 / 10.11 | 30.9 / 14.9 |
| 50 | 21,912 (20,428 to 22,061) | 5,241 (5,213 to 5,266) | 4.18x | 2.30 / 3.62 | 9.27 / 14.64 | 48.5 / 14.6 |
| 100 | 26,122 (23,551 to 26,311) | 4,942 (4,926 to 4,957) | 5.29x | 3.76 / 6.72 | 17.30 / 32.97 | 95.9 / 14.9 |

**ef 300** (recall@10: HotKV 0.9933, Redis 0.9897)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 507 (506 to 511) | 396 (386 to 404) | 1.28x | 1.99 / 2.87 | 2.43 / 4.17 | 1.0 / 1.0 |
| 2 | 992 (979 to 998) | 800 (799 to 807) | 1.24x | 2.03 / 3.04 | 2.42 / 4.11 | 2.0 / 2.0 |
| 4 | 1,967 (1,965 to 1,976) | 1,531 (1,528 to 1,540) | 1.28x | 2.05 / 2.97 | 2.52 / 4.24 | 3.9 / 3.9 |
| 8 | 3,768 (3,762 to 3,811) | 2,563 (2,560 to 2,567) | 1.47x | 2.14 / 3.11 | 3.05 / 4.93 | 7.8 / 7.7 |
| 16 | 6,961 (6,955 to 7,061) | 3,238 (3,212 to 3,272) | 2.15x | 2.30 / 3.52 | 4.89 / 7.90 | 15.5 / 14.3 |
| 32 | 10,874 (10,658 to 10,908) | 3,444 (3,421 to 3,478) | 3.16x | 2.94 / 4.43 | 9.18 / 14.86 | 31.5 / 22.6 |
| 50 | 12,393 (12,291 to 12,502) | 3,454 (3,451 to 3,462) | 3.59x | 4.02 / 6.47 | 14.38 / 21.22 | 49.1 / 23.3 |
| 100 | 13,843 (13,400 to 14,005) | 3,402 (3,374 to 3,688) | 4.07x | 7.11 / 12.32 | 30.39 / 41.71 | 97.9 / 23.6 |

**ef 500** (recall@10: HotKV 0.9972, Redis 0.9940)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 338 (338 to 339) | 287 (286 to 288) | 1.18x | 2.98 / 4.37 | 3.31 / 6.15 | 1.0 / 1.0 |
| 2 | 668 (667 to 669) | 592 (590 to 594) | 1.13x | 3.01 / 4.50 | 3.19 / 6.04 | 2.0 / 2.0 |
| 4 | 1,306 (1,290 to 1,307) | 1,111 (1,107 to 1,112) | 1.18x | 3.07 / 4.61 | 3.41 / 6.36 | 3.9 / 3.9 |
| 8 | 2,511 (2,500 to 2,520) | 1,836 (1,835 to 1,837) | 1.37x | 3.18 / 4.84 | 4.20 / 7.37 | 7.9 / 7.8 |
| 16 | 4,516 (4,513 to 4,559) | 2,322 (2,319 to 2,329) | 1.94x | 3.48 / 6.15 | 6.70 / 11.43 | 15.7 / 15.1 |
| 32 | 6,891 (6,119 to 7,036) | 2,456 (2,443 to 2,461) | 2.81x | 4.51 / 8.52 | 12.81 / 21.25 | 31.6 / 27.0 |
| 50 | 7,688 (7,477 to 8,019) | 2,483 (2,474 to 2,650) | 3.10x | 6.18 / 14.06 | 18.91 / 46.13 | 49.3 / 29.7 |
| 100 | 8,843 (8,656 to 8,927) | 2,583 (2,567 to 2,615) | 3.42x | 11.17 / 19.04 | 37.65 / 84.97 | 98.5 / 29.5 |

## 100,000 vectors

### Loading

Time and vectors per second are for the whole load, including the load generator's own formatting of each vector. RSS is the size of the server process after that load; the server holds every build made so far, so with several builds it grows. The Redis indexes were built in an earlier run (`raw/redis_build/`) and saved with `SAVE`; the measurements started Redis from the saved file, and the Redis figures here are from the run that built the index. That earlier run built the Redis index with Redis pinned to four vCPUs (two physical cores, vCPUs 140 to 143), and the settings checks under `raw/tuning/` ran on other vCPUs during part of it, while HotKV loaded alone on 128 vCPUs. Redis adds vectors on its main thread, but with `CAS` it also uses other threads, so the Redis loading figures are a lower bound on what it would do with the same 128 vCPUs to itself; the loading comparison is not like for like.

| Engine | Build | Loaded over | Time | Vectors/s | Server cores busy | Process RSS after load |
|---|---|---|---|---|---|---|
| HotKV | build 1 | 32 connections | 15 s | 6,590 | 13.0 | 0.75 GB |
| HotKV | build 2 | 32 connections | 15 s | 6,584 | 13.3 | 1.45 GB |
| HotKV | build 3 | 32 connections | 16 s | 6,214 | 14.2 | 2.16 GB |
| Redis | build 1 | 32 connections, `CAS` | 57 s | 1,755 | 2.8 | 0.72 GB |
| Redis | build 2 | 32 connections, `CAS` | 59 s | 1,688 | 2.8 | 1.42 GB |
| Redis | build 3 | 32 connections, `CAS` | 61 s | 1,638 | 2.7 | 2.12 GB |

### Recall@10 against exact ground truth

Build 1 is the index the throughput numbers were measured on. With several builds the range over all independent builds is shown.

| ef | HotKV | Redis |
|---|---|---|
| 10 | 0.7563 (0.7521 to 0.7608 over 3 builds) | 0.7124 (0.7124 to 0.7181 over 3 builds) |
| 20 | 0.8686 (0.8672 to 0.8687 over 3 builds) | 0.8284 (0.8284 to 0.8366 over 3 builds) |
| 40 | 0.9421 (0.9350 to 0.9421 over 3 builds) | 0.9109 (0.9109 to 0.9237 over 3 builds) |
| 80 | 0.9750 (0.9744 to 0.9750 over 3 builds) | 0.9618 (0.9618 to 0.9682 over 3 builds) |
| 150 | 0.9905 (0.9893 to 0.9907 over 3 builds) | 0.9832 (0.9832 to 0.9853 over 3 builds) |
| 300 | 0.9960 (0.9960 to 0.9960 over 3 builds) | 0.9926 (0.9926 to 0.9950 over 3 builds) |
| 500 | 0.9977 (0.9977 to 0.9982 over 3 builds) | 0.9972 (0.9967 to 0.9976 over 3 builds) |

### Queries per second at matched recall

For each recall target, each engine's fastest measured `ef` whose build-1 recall reaches the target. The `ef` values and recalls reached are shown, because the two engines do not reach a target at the same `ef`. Cells are the median of the trials.

**Recall@10 of 0.90 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 2,754 (ef 40, recall 0.942) | 1,506 (ef 40, recall 0.911) | 1.83x | 0.36 / 0.65 ms |
| 2 | 5,379 (ef 40, recall 0.942) | 3,027 (ef 40, recall 0.911) | 1.78x | 0.37 / 0.65 ms |
| 4 | 10,592 (ef 40, recall 0.942) | 5,314 (ef 40, recall 0.911) | 1.99x | 0.38 / 0.73 ms |
| 8 | 20,844 (ef 40, recall 0.942) | 8,375 (ef 40, recall 0.911) | 2.49x | 0.38 / 0.93 ms |
| 16 | 38,021 (ef 40, recall 0.942) | 8,637 (ef 40, recall 0.911) | 4.40x | 0.42 / 1.81 ms |
| 32 | 62,253 (ef 40, recall 0.942) | 8,320 (ef 80, recall 0.962) | 7.48x | 0.50 / 3.57 ms |
| 50 | 83,108 (ef 40, recall 0.942) | 8,225 (ef 40, recall 0.911) | 10.10x | 0.59 / 4.91 ms |
| 100 | 115,672 (ef 40, recall 0.942) | 7,894 (ef 40, recall 0.911) | 14.65x | 0.83 / 11.35 ms |

**Recall@10 of 0.95 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,816 (ef 80, recall 0.975) | 1,214 (ef 80, recall 0.962) | 1.50x | 0.55 / 0.82 ms |
| 2 | 3,550 (ef 80, recall 0.975) | 2,338 (ef 80, recall 0.962) | 1.52x | 0.56 / 0.85 ms |
| 4 | 7,078 (ef 80, recall 0.975) | 4,136 (ef 80, recall 0.962) | 1.71x | 0.57 / 0.95 ms |
| 8 | 13,691 (ef 80, recall 0.975) | 6,645 (ef 80, recall 0.962) | 2.06x | 0.58 / 1.19 ms |
| 16 | 24,702 (ef 80, recall 0.975) | 8,475 (ef 80, recall 0.962) | 2.91x | 0.64 / 1.87 ms |
| 32 | 39,279 (ef 80, recall 0.975) | 8,320 (ef 80, recall 0.962) | 4.72x | 0.80 / 3.57 ms |
| 50 | 48,250 (ef 80, recall 0.975) | 7,656 (ef 80, recall 0.962) | 6.30x | 1.03 / 6.68 ms |
| 100 | 63,247 (ef 80, recall 0.975) | 7,119 (ef 80, recall 0.962) | 8.88x | 1.53 / 12.43 ms |

**Recall@10 of 0.99 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,186 (ef 150, recall 0.991) | 545 (ef 300, recall 0.993) | 2.18x | 0.85 / 1.81 ms |
| 2 | 2,310 (ef 150, recall 0.991) | 1,072 (ef 300, recall 0.993) | 2.15x | 0.87 / 1.83 ms |
| 4 | 4,555 (ef 150, recall 0.991) | 2,002 (ef 300, recall 0.993) | 2.27x | 0.88 / 1.95 ms |
| 8 | 8,832 (ef 150, recall 0.991) | 3,227 (ef 300, recall 0.993) | 2.74x | 0.91 / 2.45 ms |
| 16 | 15,832 (ef 150, recall 0.991) | 3,859 (ef 300, recall 0.993) | 4.10x | 1.01 / 4.10 ms |
| 32 | 24,616 (ef 150, recall 0.991) | 4,096 (ef 300, recall 0.993) | 6.01x | 1.29 / 7.76 ms |
| 50 | 28,164 (ef 150, recall 0.991) | 4,669 (ef 300, recall 0.993) | 6.03x | 1.74 / 11.24 ms |
| 100 | 33,200 (ef 150, recall 0.991) | 3,968 (ef 300, recall 0.993) | 8.37x | 2.96 / 27.32 ms |

### Throughput and latency at every search depth

Median queries per second (lowest to highest trial), median and 99th-percentile latency, and the CPU cores each server kept busy (CPU seconds per wall second, from /proc). `ef` is the search-time beam width.

**ef 40** (recall@10: HotKV 0.9421, Redis 0.9109)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 2,754 (2,737 to 2,779) | 1,506 (1,485 to 1,554) | 1.83x | 0.36 / 0.53 | 0.65 / 1.06 | 0.9 / 1.0 |
| 2 | 5,379 (5,330 to 5,400) | 3,027 (2,984 to 3,040) | 1.78x | 0.37 / 0.55 | 0.65 / 0.97 | 1.8 / 1.9 |
| 4 | 10,592 (10,573 to 10,664) | 5,314 (5,260 to 5,327) | 1.99x | 0.38 / 0.55 | 0.73 / 1.17 | 3.7 / 3.6 |
| 8 | 20,844 (20,714 to 20,878) | 8,375 (8,330 to 8,400) | 2.49x | 0.38 / 0.57 | 0.93 / 1.47 | 7.4 / 6.0 |
| 16 | 38,021 (36,000 to 38,077) | 8,637 (8,521 to 8,666) | 4.40x | 0.42 / 0.64 | 1.81 / 2.46 | 14.5 / 6.0 |
| 32 | 62,253 (61,722 to 62,755) | 8,240 (8,160 to 8,448) | 7.56x | 0.50 / 0.86 | 3.83 / 6.30 | 29.1 / 6.1 |
| 50 | 83,108 (81,603 to 83,290) | 8,225 (8,173 to 8,361) | 10.10x | 0.59 / 1.03 | 4.91 / 10.10 | 45.1 / 6.2 |
| 100 | 115,672 (115,262 to 116,344) | 7,894 (7,866 to 7,994) | 14.65x | 0.83 / 1.56 | 11.35 / 23.07 | 91.5 / 6.0 |

**ef 80** (recall@10: HotKV 0.9750, Redis 0.9618)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,816 (1,790 to 1,820) | 1,214 (1,201 to 1,214) | 1.50x | 0.55 / 0.78 | 0.82 / 1.20 | 1.0 / 1.0 |
| 2 | 3,550 (3,547 to 3,582) | 2,338 (2,327 to 2,339) | 1.52x | 0.56 / 0.79 | 0.85 / 1.25 | 1.9 / 2.0 |
| 4 | 7,078 (7,048 to 7,094) | 4,136 (4,132 to 4,191) | 1.71x | 0.57 / 0.80 | 0.95 / 1.47 | 3.8 / 3.8 |
| 8 | 13,691 (13,673 to 13,714) | 6,645 (6,590 to 6,652) | 2.06x | 0.58 / 0.83 | 1.19 / 1.77 | 7.6 / 6.8 |
| 16 | 24,702 (23,718 to 25,003) | 8,475 (8,422 to 8,480) | 2.91x | 0.64 / 1.02 | 1.87 / 2.62 | 15.1 / 9.3 |
| 32 | 39,279 (36,608 to 39,372) | 8,320 (8,150 to 8,343) | 4.72x | 0.80 / 1.32 | 3.57 / 5.27 | 29.9 / 9.4 |
| 50 | 48,250 (47,251 to 48,367) | 7,656 (7,544 to 7,672) | 6.30x | 1.03 / 1.67 | 6.68 / 10.65 | 47.1 / 8.9 |
| 100 | 63,247 (60,249 to 68,443) | 7,119 (7,103 to 7,196) | 8.88x | 1.53 / 2.80 | 12.43 / 24.93 | 93.9 / 8.7 |

**ef 150** (recall@10: HotKV 0.9905, Redis 0.9832)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,186 (1,186 to 1,202) | 845 (836 to 847) | 1.40x | 0.85 / 1.18 | 1.18 / 1.68 | 1.0 / 1.0 |
| 2 | 2,310 (2,303 to 2,323) | 1,646 (1,643 to 1,665) | 1.40x | 0.87 / 1.22 | 1.21 / 1.79 | 1.9 / 2.0 |
| 4 | 4,555 (4,553 to 4,578) | 3,050 (3,028 to 3,081) | 1.49x | 0.88 / 1.23 | 1.29 / 2.00 | 3.9 / 3.9 |
| 8 | 8,832 (8,830 to 9,014) | 4,890 (4,858 to 4,914) | 1.81x | 0.91 / 1.28 | 1.61 / 2.46 | 7.7 / 7.3 |
| 16 | 15,832 (15,824 to 16,096) | 5,832 (5,773 to 5,855) | 2.71x | 1.01 / 1.49 | 2.67 / 4.34 | 15.5 / 11.0 |
| 32 | 24,616 (23,736 to 24,627) | 6,239 (6,123 to 6,271) | 3.95x | 1.29 / 2.03 | 5.17 / 7.78 | 30.5 / 12.3 |
| 50 | 28,164 (27,946 to 28,496) | 5,858 (5,823 to 5,915) | 4.81x | 1.74 / 2.70 | 8.49 / 12.56 | 48.5 / 12.2 |
| 100 | 33,200 (32,984 to 34,652) | 5,518 (5,515 to 5,528) | 6.02x | 2.96 / 4.89 | 15.67 / 30.91 | 96.5 / 11.7 |

**ef 300** (recall@10: HotKV 0.9960, Redis 0.9926)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 703 (703 to 712) | 545 (545 to 548) | 1.29x | 1.42 / 2.01 | 1.81 / 2.74 | 1.0 / 1.0 |
| 2 | 1,372 (1,371 to 1,386) | 1,072 (1,070 to 1,083) | 1.28x | 1.46 / 2.08 | 1.83 / 2.82 | 2.0 / 2.0 |
| 4 | 2,720 (2,703 to 2,722) | 2,002 (2,001 to 2,012) | 1.36x | 1.48 / 2.08 | 1.95 / 3.08 | 3.9 / 3.9 |
| 8 | 5,328 (5,325 to 5,342) | 3,227 (3,199 to 3,247) | 1.65x | 1.50 / 2.12 | 2.45 / 3.68 | 7.8 / 7.7 |
| 16 | 9,616 (9,591 to 9,619) | 3,859 (3,850 to 3,864) | 2.49x | 1.66 / 2.31 | 4.10 / 6.33 | 15.5 / 13.2 |
| 32 | 14,098 (12,680 to 14,314) | 4,096 (4,085 to 4,254) | 3.44x | 2.22 / 3.65 | 7.76 / 11.16 | 31.3 / 17.5 |
| 50 | 15,909 (15,845 to 16,096) | 4,669 (4,034 to 5,249) | 3.41x | 3.10 / 4.83 | 11.24 / 17.29 | 49.2 / 17.9 |
| 100 | 18,474 (18,070 to 18,672) | 3,968 (3,938 to 3,969) | 4.66x | 5.29 / 9.04 | 27.32 / 36.67 | 97.5 / 20.1 |

## Checks

- Busiest load-generator process in any cell: 8% of one CPU. A value near 100% would mean the client, not the server, set the limit.
- Query replies with fewer than 10 results: 0. Load-generator processes that started late: 0.
- Every load was followed by a check that the server holds exactly the number of vectors sent.

## Limits of this measurement

- One machine, one dataset (1,536-dimension OpenAI embeddings), top 10 only, float32 vectors, cosine similarity.
- The load generators run on the same machine as the servers, on separate vCPUs, over loopback. The two engines share the CPU set, the memory system and the last-level cache with their load generators.
- vCPUs are hyperthreads: a pinned set of N vCPUs is N/2 physical cores.
- Redis is a stock build. Its vector sets run at most 32 searches at once (a compile-time limit, `HNSW_MAX_THREADS`) and add vectors on the main thread, so it uses a small part of this machine; that is how it behaves, not something this benchmark configured.
- Loading is not like for like: the Redis index was built with Redis pinned to four vCPUs while other checks ran on the machine; HotKV loaded alone on 128 vCPUs. Treat the Redis load times as a lower bound on its loading speed.
- Redis was searched on an index reloaded from the saved file, HotKV on a freshly built one. In one check on 20,000 vectors (`raw/tuning/redis_rdb_reload_check_*`) the reloaded index served 1,620 queries per second against 1,799 freshly built, about 10 percent less, so the Redis query figures here may be low by a similar amount.
- Recall is measured once per index build and `ef`. Independent builds of the same engine differ in recall; the range is shown where several builds were made.
- The HotKV build is an unreleased commit (see Setup). Every figure in this report comes from that build; the settings checks under `raw/tuning/` were run with two earlier development builds of the same branch and were used only to choose the settings. Redis was loaded with `VADD ... CAS` and run with its default I/O threads; the tuning runs that led to those choices are in `raw/tuning/`.
