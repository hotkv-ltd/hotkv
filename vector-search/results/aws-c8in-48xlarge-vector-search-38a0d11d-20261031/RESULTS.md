# Vector search: HotKV and Redis 8.10.3 on AWS c8in.48xlarge (192 vCPUs)

Plain vector search on both servers: build an HNSW index, then run top-10 nearest-neighbour queries. No filters, no attributes, no quantization, none of HotKV's AI engines. Every figure below is computed by `scripts/render_report.py` from the raw trials in `raw/`.

## Setup

|  |  |
|---|---|
| Machine | AWS c8in.48xlarge: Intel(R) Xeon(R) 6975P-C, 192 vCPUs, one VM |
| Kernel / OS | Linux-7.0.0-1014-aws-x86_64-with-glibc2.39 |
| HotKV | commit `38a0d11d`, binary SHA-256 `499a3a848a9aaa6e...`, release build, portable flags (no -march=native) |
| Redis | 8.10.3 from the GitHub release tag, stock `make`, binary SHA-256 `8accf550b2070924...` |
| CPU placement | servers pinned to vCPUs 0-63,96-159; load generators on 64 other vCPUs; same CPU set for both servers; loopback |
| HotKV launch | `hotkv --threads 128 --no-snapshot --protected-mode no` |
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
| HotKV | build 1 | 32 connections | 220 s | 4,531 | 18.8 | 6.77 GB |
| Redis | build 1 | 32 connections, `CAS` | 1143 s | 874 | 3.1 | 7.01 GB |

### Recall@10 against exact ground truth

Build 1 is the index the throughput numbers were measured on. With several builds the range over all independent builds is shown.

| ef | HotKV | Redis |
|---|---|---|
| 10 | 0.7957 | 0.7441 |
| 20 | 0.8814 | 0.8602 |
| 40 | 0.9403 | 0.9319 |
| 80 | 0.9715 | 0.9628 |
| 150 | 0.9857 | 0.9811 |
| 300 | 0.9926 | 0.9890 |
| 500 | 0.9966 | 0.9925 |

### Queries per second at matched recall

For each recall target, each engine's fastest measured `ef` whose build-1 recall reaches the target. The `ef` values and recalls reached are shown, because the two engines do not reach a target at the same `ef`. Cells are the median of the trials.

**Recall@10 of 0.90 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,195 (ef 40, recall 0.940) | 963 (ef 40, recall 0.932) | 1.24x | 0.84 / 1.03 ms |
| 2 | 2,306 (ef 40, recall 0.940) | 1,876 (ef 40, recall 0.932) | 1.23x | 0.87 / 1.06 ms |
| 4 | 4,660 (ef 40, recall 0.940) | 3,536 (ef 40, recall 0.932) | 1.32x | 0.86 / 1.12 ms |
| 8 | 9,460 (ef 40, recall 0.940) | 6,114 (ef 40, recall 0.932) | 1.55x | 0.84 / 1.29 ms |
| 16 | 18,730 (ef 40, recall 0.940) | 7,542 (ef 40, recall 0.932) | 2.48x | 0.85 / 2.09 ms |
| 32 | 33,782 (ef 40, recall 0.940) | 7,429 (ef 80, recall 0.963) | 4.55x | 0.94 / 4.15 ms |
| 50 | 46,694 (ef 40, recall 0.940) | 7,407 (ef 80, recall 0.963) | 6.30x | 1.07 / 6.96 ms |
| 100 | 57,783 (ef 40, recall 0.940) | 7,413 (ef 40, recall 0.932) | 7.80x | 1.69 / 13.43 ms |

**Recall@10 of 0.95 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 727 (ef 80, recall 0.972) | 690 (ef 80, recall 0.963) | 1.05x | 1.40 / 1.46 ms |
| 2 | 1,520 (ef 80, recall 0.972) | 1,366 (ef 80, recall 0.963) | 1.11x | 1.34 / 1.47 ms |
| 4 | 3,264 (ef 80, recall 0.972) | 2,690 (ef 80, recall 0.963) | 1.21x | 1.25 / 1.49 ms |
| 8 | 6,174 (ef 80, recall 0.972) | 4,897 (ef 80, recall 0.963) | 1.26x | 1.31 / 1.64 ms |
| 16 | 11,869 (ef 80, recall 0.972) | 7,438 (ef 80, recall 0.963) | 1.60x | 1.38 / 2.16 ms |
| 32 | 21,387 (ef 80, recall 0.972) | 7,429 (ef 80, recall 0.963) | 2.88x | 1.52 / 4.15 ms |
| 50 | 29,223 (ef 80, recall 0.972) | 7,407 (ef 80, recall 0.963) | 3.95x | 1.74 / 6.96 ms |
| 100 | 37,621 (ef 80, recall 0.972) | 7,253 (ef 80, recall 0.963) | 5.19x | 2.61 / 13.14 ms |

**Recall@10 of 0.99 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 307 (ef 300, recall 0.993) | 216 (ef 500, recall 0.993) | 1.42x | 3.34 / 4.48 ms |
| 2 | 623 (ef 300, recall 0.993) | 438 (ef 500, recall 0.993) | 1.42x | 3.28 / 4.40 ms |
| 4 | 1,217 (ef 300, recall 0.993) | 863 (ef 500, recall 0.993) | 1.41x | 3.36 / 4.48 ms |
| 8 | 2,378 (ef 300, recall 0.993) | 1,639 (ef 500, recall 0.993) | 1.45x | 3.42 / 4.73 ms |
| 16 | 4,539 (ef 300, recall 0.993) | 2,930 (ef 500, recall 0.993) | 1.55x | 3.58 / 5.35 ms |
| 32 | 7,843 (ef 300, recall 0.993) | 3,985 (ef 500, recall 0.993) | 1.97x | 4.14 / 7.92 ms |
| 50 | 9,573 (ef 300, recall 0.993) | 4,135 (ef 500, recall 0.993) | 2.32x | 5.16 / 11.32 ms |
| 100 | 11,066 (ef 300, recall 0.993) | 4,126 (ef 500, recall 0.993) | 2.68x | 8.82 / 19.77 ms |

### Throughput and latency at every search depth

Median queries per second (lowest to highest trial), median and 99th-percentile latency, and the CPU cores each server kept busy (CPU seconds per wall second, from /proc). `ef` is the search-time beam width.

**ef 40** (recall@10: HotKV 0.9403, Redis 0.9319)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,195 (1,157 to 1,428) | 963 (958 to 964) | 1.24x | 0.84 / 1.34 | 1.03 / 1.55 | 0.8 / 0.9 |
| 2 | 2,306 (2,276 to 2,440) | 1,876 (1,795 to 1,880) | 1.23x | 0.87 / 1.38 | 1.06 / 1.60 | 1.6 / 1.7 |
| 4 | 4,660 (4,505 to 4,670) | 3,536 (3,508 to 3,585) | 1.32x | 0.86 / 1.40 | 1.12 / 1.71 | 3.2 / 3.3 |
| 8 | 9,460 (9,456 to 9,806) | 6,114 (6,094 to 6,177) | 1.55x | 0.84 / 1.39 | 1.29 / 1.99 | 6.6 / 6.2 |
| 16 | 18,730 (17,528 to 18,935) | 7,542 (7,520 to 7,620) | 2.48x | 0.85 / 1.46 | 2.09 / 2.98 | 13.4 / 7.7 |
| 32 | 33,782 (32,062 to 34,070) | 7,387 (7,251 to 7,389) | 4.57x | 0.94 / 1.61 | 4.45 / 5.70 | 26.9 / 7.5 |
| 50 | 46,694 (46,148 to 46,953) | 7,261 (7,243 to 7,342) | 6.43x | 1.07 / 1.88 | 6.29 / 8.86 | 46.1 / 7.7 |
| 100 | 57,783 (57,372 to 58,116) | 7,413 (7,304 to 7,427) | 7.80x | 1.69 / 3.16 | 13.43 / 18.07 | 95.6 / 7.9 |

**ef 80** (recall@10: HotKV 0.9715, Redis 0.9628)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 727 (724 to 727) | 690 (682 to 728) | 1.05x | 1.40 / 2.19 | 1.46 / 2.13 | 0.9 / 0.9 |
| 2 | 1,520 (1,494 to 1,555) | 1,366 (1,358 to 1,398) | 1.11x | 1.34 / 2.10 | 1.47 / 2.09 | 1.7 / 1.8 |
| 4 | 3,264 (3,055 to 3,308) | 2,690 (2,658 to 2,718) | 1.21x | 1.25 / 1.94 | 1.49 / 2.23 | 3.6 / 3.5 |
| 8 | 6,174 (6,121 to 6,444) | 4,897 (4,897 to 4,922) | 1.26x | 1.31 / 2.15 | 1.64 / 2.46 | 7.2 / 6.9 |
| 16 | 11,869 (11,769 to 11,961) | 7,438 (7,396 to 7,454) | 1.60x | 1.38 / 2.09 | 2.16 / 3.19 | 13.6 / 11.1 |
| 32 | 21,387 (21,316 to 21,642) | 7,429 (7,398 to 7,452) | 2.88x | 1.52 / 2.36 | 4.15 / 5.77 | 27.7 / 11.1 |
| 50 | 29,223 (28,900 to 29,278) | 7,407 (7,360 to 7,427) | 3.95x | 1.74 / 2.73 | 6.96 / 8.02 | 45.6 / 11.0 |
| 100 | 37,621 (37,511 to 37,717) | 7,253 (7,205 to 7,370) | 5.19x | 2.61 / 4.61 | 13.14 / 18.47 | 95.7 / 11.2 |

**ef 150** (recall@10: HotKV 0.9857, Redis 0.9811)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 524 (512 to 532) | 461 (440 to 479) | 1.14x | 1.97 / 2.83 | 2.17 / 3.28 | 0.9 / 0.9 |
| 2 | 1,053 (1,014 to 1,062) | 962 (894 to 970) | 1.09x | 1.95 / 2.84 | 2.08 / 3.09 | 1.8 / 1.8 |
| 4 | 2,009 (2,004 to 2,016) | 1,852 (1,830 to 1,863) | 1.08x | 2.04 / 2.97 | 2.17 / 3.27 | 3.6 / 3.6 |
| 8 | 4,018 (3,959 to 4,034) | 3,530 (3,519 to 3,544) | 1.14x | 2.05 / 2.97 | 2.29 / 3.39 | 7.2 / 7.1 |
| 16 | 7,595 (7,558 to 7,637) | 6,024 (6,016 to 6,109) | 1.26x | 2.16 / 3.21 | 2.67 / 4.38 | 14.2 / 13.5 |
| 32 | 13,310 (13,145 to 13,466) | 7,241 (7,221 to 7,299) | 1.84x | 2.46 / 3.62 | 4.42 / 6.39 | 28.6 / 16.9 |
| 50 | 16,977 (16,459 to 17,296) | 7,240 (7,111 to 7,262) | 2.34x | 3.00 / 4.55 | 6.69 / 9.07 | 46.2 / 16.8 |
| 100 | 20,890 (20,641 to 21,259) | 7,164 (7,102 to 7,165) | 2.92x | 4.72 / 8.56 | 15.12 / 17.74 | 95.8 / 17.1 |

**ef 300** (recall@10: HotKV 0.9926, Redis 0.9890)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 307 (307 to 308) | 295 (291 to 306) | 1.04x | 3.34 / 4.93 | 3.35 / 5.29 | 0.9 / 0.9 |
| 2 | 623 (619 to 624) | 616 (613 to 622) | 1.01x | 3.28 / 4.88 | 3.17 / 5.12 | 1.9 / 1.8 |
| 4 | 1,217 (1,205 to 1,218) | 1,201 (1,200 to 1,203) | 1.01x | 3.36 / 5.01 | 3.28 / 5.22 | 3.7 / 3.7 |
| 8 | 2,378 (2,353 to 2,388) | 2,292 (2,290 to 2,308) | 1.04x | 3.42 / 5.18 | 3.46 / 5.43 | 7.5 / 7.4 |
| 16 | 4,539 (4,502 to 4,574) | 4,086 (4,079 to 4,109) | 1.11x | 3.58 / 5.45 | 3.90 / 6.20 | 14.9 / 14.7 |
| 32 | 7,843 (7,780 to 8,051) | 5,316 (5,307 to 5,356) | 1.48x | 4.14 / 6.26 | 6.00 / 9.67 | 29.9 / 23.9 |
| 50 | 9,573 (9,475 to 9,805) | 5,539 (5,532 to 5,597) | 1.73x | 5.16 / 8.60 | 8.98 / 13.64 | 47.3 / 25.8 |
| 100 | 11,066 (10,978 to 11,152) | 5,454 (5,411 to 5,461) | 2.03x | 8.82 / 16.02 | 18.67 / 25.37 | 96.8 / 25.4 |

**ef 500** (recall@10: HotKV 0.9966, Redis 0.9925)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 204 (203 to 209) | 216 (216 to 217) | 0.94x | 4.97 / 7.69 | 4.48 / 7.65 | 1.0 / 0.9 |
| 2 | 412 (411 to 412) | 438 (438 to 444) | 0.94x | 4.95 / 7.60 | 4.40 / 7.66 | 1.9 / 1.9 |
| 4 | 811 (806 to 818) | 863 (862 to 866) | 0.94x | 5.02 / 7.66 | 4.48 / 7.81 | 3.8 / 3.8 |
| 8 | 1,595 (1,593 to 1,604) | 1,639 (1,637 to 1,655) | 0.97x | 5.09 / 7.80 | 4.73 / 8.09 | 7.6 / 7.6 |
| 16 | 3,046 (3,045 to 3,050) | 2,930 (2,926 to 2,942) | 1.04x | 5.32 / 8.15 | 5.35 / 9.02 | 15.2 / 15.1 |
| 32 | 5,480 (5,446 to 5,486) | 3,985 (3,984 to 4,017) | 1.38x | 5.90 / 9.20 | 7.92 / 13.42 | 30.6 / 28.2 |
| 50 | 7,042 (6,968 to 7,071) | 4,135 (4,126 to 4,151) | 1.70x | 7.18 / 11.23 | 11.32 / 27.52 | 48.0 / 32.5 |
| 100 | 8,249 (8,131 to 8,358) | 4,126 (4,114 to 4,128) | 2.00x | 11.82 / 21.76 | 19.77 / 92.55 | 97.6 / 33.2 |

## 100,000 vectors

### Loading

Time and vectors per second are for the whole load, including the load generator's own formatting of each vector. RSS is the size of the server process after that load; the server holds every build made so far, so with several builds it grows. The Redis indexes were built in an earlier run (`raw/redis_build/`) and saved with `SAVE`; the measurements started Redis from the saved file, and the Redis figures here are from the run that built the index.

| Engine | Build | Loaded over | Time | Vectors/s | Server cores busy | Process RSS after load |
|---|---|---|---|---|---|---|
| HotKV | build 1 | 32 connections | 16 s | 6,070 | 14.2 | 0.75 GB |
| HotKV | build 2 | 32 connections | 17 s | 5,840 | 13.5 | 1.46 GB |
| HotKV | build 3 | 32 connections | 17 s | 5,938 | 14.0 | 2.17 GB |
| Redis | build 1 | 32 connections, `CAS` | 63 s | 1,597 | 2.8 | 0.72 GB |
| Redis | build 2 | 32 connections, `CAS` | 63 s | 1,595 | 2.8 | 1.42 GB |
| Redis | build 3 | 32 connections, `CAS` | 63 s | 1,584 | 2.8 | 2.13 GB |

### Recall@10 against exact ground truth

Build 1 is the index the throughput numbers were measured on. With several builds the range over all independent builds is shown.

| ef | HotKV | Redis |
|---|---|---|
| 10 | 0.7613 (0.7612 to 0.7754 over 3 builds) | 0.7047 (0.7047 to 0.7318 over 3 builds) |
| 20 | 0.8686 (0.8686 to 0.8770 over 3 builds) | 0.8323 (0.8323 to 0.8488 over 3 builds) |
| 40 | 0.9412 (0.9395 to 0.9412 over 3 builds) | 0.9178 (0.9178 to 0.9224 over 3 builds) |
| 80 | 0.9746 (0.9727 to 0.9775 over 3 builds) | 0.9666 (0.9626 to 0.9666 over 3 builds) |
| 150 | 0.9891 (0.9891 to 0.9914 over 3 builds) | 0.9851 (0.9851 to 0.9861 over 3 builds) |
| 300 | 0.9958 (0.9958 to 0.9969 over 3 builds) | 0.9943 (0.9943 to 0.9943 over 3 builds) |
| 500 | 0.9979 (0.9979 to 0.9983 over 3 builds) | 0.9969 (0.9969 to 0.9977 over 3 builds) |

### Queries per second at matched recall

For each recall target, each engine's fastest measured `ef` whose build-1 recall reaches the target. The `ef` values and recalls reached are shown, because the two engines do not reach a target at the same `ef`. Cells are the median of the trials.

**Recall@10 of 0.90 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,749 (ef 40, recall 0.941) | 1,172 (ef 40, recall 0.918) | 1.49x | 0.56 / 0.83 ms |
| 2 | 3,488 (ef 40, recall 0.941) | 2,485 (ef 40, recall 0.918) | 1.40x | 0.56 / 0.78 ms |
| 4 | 7,208 (ef 40, recall 0.941) | 4,470 (ef 40, recall 0.918) | 1.61x | 0.53 / 0.87 ms |
| 8 | 13,212 (ef 40, recall 0.941) | 7,026 (ef 40, recall 0.918) | 1.88x | 0.59 / 1.12 ms |
| 16 | 27,791 (ef 40, recall 0.941) | 7,643 (ef 150, recall 0.985) | 3.64x | 0.53 / 2.07 ms |
| 32 | 48,164 (ef 40, recall 0.941) | 7,853 (ef 150, recall 0.985) | 6.13x | 0.62 / 4.15 ms |
| 50 | 68,419 (ef 40, recall 0.941) | 7,829 (ef 150, recall 0.985) | 8.74x | 0.69 / 6.44 ms |
| 100 | 73,422 (ef 40, recall 0.941) | 7,882 (ef 40, recall 0.918) | 9.32x | 1.33 / 12.69 ms |

**Recall@10 of 0.95 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 1,184 (ef 80, recall 0.975) | 973 (ef 80, recall 0.967) | 1.22x | 0.84 / 1.00 ms |
| 2 | 2,646 (ef 80, recall 0.975) | 1,916 (ef 80, recall 0.967) | 1.38x | 0.75 / 1.02 ms |
| 4 | 5,008 (ef 80, recall 0.975) | 3,440 (ef 80, recall 0.967) | 1.46x | 0.78 / 1.14 ms |
| 8 | 9,147 (ef 80, recall 0.975) | 5,979 (ef 80, recall 0.967) | 1.53x | 0.86 / 1.31 ms |
| 16 | 17,760 (ef 80, recall 0.975) | 7,643 (ef 150, recall 0.985) | 2.32x | 0.88 / 2.07 ms |
| 32 | 31,436 (ef 80, recall 0.975) | 7,853 (ef 150, recall 0.985) | 4.00x | 0.99 / 4.15 ms |
| 50 | 42,570 (ef 80, recall 0.975) | 7,829 (ef 150, recall 0.985) | 5.44x | 1.14 / 6.44 ms |
| 100 | 47,432 (ef 80, recall 0.975) | 7,470 (ef 150, recall 0.985) | 6.35x | 2.07 / 12.60 ms |

**Recall@10 of 0.99 or better**

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | Median latency HotKV / Redis |
|---|---|---|---|---|
| 1 | 486 (ef 300, recall 0.996) | 393 (ef 300, recall 0.994) | 1.24x | 2.03 / 2.51 ms |
| 2 | 956 (ef 300, recall 0.996) | 788 (ef 300, recall 0.994) | 1.21x | 2.05 / 2.49 ms |
| 4 | 1,860 (ef 300, recall 0.996) | 1,544 (ef 300, recall 0.994) | 1.21x | 2.09 / 2.50 ms |
| 8 | 3,534 (ef 300, recall 0.996) | 3,051 (ef 300, recall 0.994) | 1.16x | 2.19 / 2.56 ms |
| 16 | 6,728 (ef 300, recall 0.996) | 5,582 (ef 300, recall 0.994) | 1.21x | 2.30 / 2.77 ms |
| 32 | 11,517 (ef 300, recall 0.996) | 7,480 (ef 300, recall 0.994) | 1.54x | 2.69 / 4.20 ms |
| 50 | 13,654 (ef 300, recall 0.996) | 7,410 (ef 300, recall 0.994) | 1.84x | 3.52 / 6.90 ms |
| 100 | 15,717 (ef 300, recall 0.996) | 7,320 (ef 300, recall 0.994) | 2.15x | 6.14 / 14.58 ms |

### Throughput and latency at every search depth

Median queries per second (lowest to highest trial), median and 99th-percentile latency, and the CPU cores each server kept busy (CPU seconds per wall second, from /proc). `ef` is the search-time beam width.

**ef 40** (recall@10: HotKV 0.9412, Redis 0.9178)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,749 (1,619 to 1,934) | 1,172 (1,162 to 1,367) | 1.49x | 0.56 / 0.94 | 0.83 / 1.41 | 0.8 / 0.8 |
| 2 | 3,488 (3,448 to 3,845) | 2,485 (2,288 to 2,498) | 1.40x | 0.56 / 0.94 | 0.78 / 1.25 | 1.5 / 1.8 |
| 4 | 7,208 (6,815 to 7,240) | 4,470 (4,196 to 4,714) | 1.61x | 0.53 / 0.97 | 0.87 / 1.42 | 3.2 / 3.4 |
| 8 | 13,212 (13,049 to 13,279) | 7,026 (6,987 to 7,344) | 1.88x | 0.59 / 1.02 | 1.12 / 1.70 | 6.1 / 5.7 |
| 16 | 27,791 (26,597 to 28,352) | 7,584 (7,572 to 7,643) | 3.66x | 0.53 / 1.02 | 2.06 / 2.84 | 13.0 / 6.2 |
| 32 | 48,164 (47,902 to 48,648) | 7,316 (7,276 to 7,335) | 6.58x | 0.62 / 1.17 | 4.60 / 5.53 | 25.3 / 6.0 |
| 50 | 68,419 (67,365 to 70,032) | 7,210 (7,186 to 7,732) | 9.49x | 0.69 / 1.23 | 6.58 / 9.11 | 46.2 / 6.1 |
| 100 | 73,422 (72,900 to 74,746) | 7,882 (7,851 to 7,885) | 9.32x | 1.33 / 2.41 | 12.69 / 15.57 | 95.6 / 6.7 |

**ef 80** (recall@10: HotKV 0.9746, Redis 0.9666)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 1,184 (1,177 to 1,371) | 973 (916 to 984) | 1.22x | 0.84 / 1.25 | 1.00 / 1.60 | 0.8 / 1.0 |
| 2 | 2,646 (2,120 to 2,809) | 1,916 (1,823 to 1,928) | 1.38x | 0.75 / 1.13 | 1.02 / 1.61 | 1.9 / 1.9 |
| 4 | 5,008 (4,815 to 5,018) | 3,440 (3,296 to 3,476) | 1.46x | 0.78 / 1.24 | 1.14 / 1.77 | 3.5 / 3.5 |
| 8 | 9,147 (8,879 to 9,536) | 5,979 (5,970 to 6,021) | 1.53x | 0.86 / 1.37 | 1.31 / 1.95 | 6.9 / 6.6 |
| 16 | 17,760 (17,378 to 18,289) | 7,636 (7,614 to 7,690) | 2.33x | 0.88 / 1.43 | 2.08 / 2.82 | 13.5 / 8.7 |
| 32 | 31,436 (31,006 to 32,065) | 7,418 (7,330 to 7,487) | 4.24x | 0.99 / 1.64 | 4.34 / 5.42 | 28.0 / 8.2 |
| 50 | 42,570 (40,918 to 43,044) | 7,255 (7,251 to 7,260) | 5.87x | 1.14 / 1.95 | 7.29 / 8.68 | 46.3 / 8.5 |
| 100 | 47,432 (46,965 to 48,149) | 7,276 (6,944 to 7,292) | 6.52x | 2.07 / 3.65 | 13.59 / 18.53 | 95.5 / 8.7 |

**ef 150** (recall@10: HotKV 0.9891, Redis 0.9851)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 792 (752 to 797) | 642 (639 to 648) | 1.23x | 1.25 / 1.88 | 1.53 / 2.32 | 0.9 / 0.9 |
| 2 | 1,568 (1,488 to 1,627) | 1,274 (1,272 to 1,290) | 1.23x | 1.26 / 1.94 | 1.55 / 2.27 | 1.7 / 1.8 |
| 4 | 3,082 (3,034 to 3,200) | 2,523 (2,431 to 2,556) | 1.22x | 1.29 / 1.94 | 1.55 / 2.45 | 3.4 / 3.5 |
| 8 | 6,266 (6,125 to 6,334) | 4,538 (4,506 to 4,564) | 1.38x | 1.25 / 2.01 | 1.73 / 2.66 | 7.1 / 6.7 |
| 16 | 11,609 (11,438 to 11,891) | 7,643 (7,593 to 7,664) | 1.52x | 1.36 / 2.14 | 2.07 / 3.01 | 13.6 / 12.1 |
| 32 | 20,671 (20,248 to 20,803) | 7,853 (7,802 to 7,864) | 2.63x | 1.52 / 2.43 | 4.15 / 5.28 | 27.7 / 12.4 |
| 50 | 26,868 (26,743 to 26,975) | 7,829 (7,791 to 7,862) | 3.43x | 1.81 / 3.01 | 6.44 / 7.95 | 45.6 / 12.4 |
| 100 | 29,474 (29,419 to 29,882) | 7,470 (7,406 to 7,526) | 3.95x | 3.28 / 6.00 | 12.60 / 18.19 | 95.7 / 12.3 |

**ef 300** (recall@10: HotKV 0.9958, Redis 0.9943)

| Clients | HotKV q/s | Redis q/s | HotKV / Redis | HotKV p50 / p99 ms | Redis p50 / p99 ms | Cores busy HotKV / Redis |
|---|---|---|---|---|---|---|
| 1 | 486 (483 to 486) | 393 (392 to 394) | 1.24x | 2.03 / 3.13 | 2.51 / 3.75 | 0.9 / 0.9 |
| 2 | 956 (910 to 985) | 788 (786 to 792) | 1.21x | 2.05 / 3.15 | 2.49 / 3.77 | 1.8 / 1.8 |
| 4 | 1,860 (1,786 to 1,882) | 1,544 (1,504 to 1,573) | 1.21x | 2.09 / 3.45 | 2.50 / 4.03 | 3.7 / 3.5 |
| 8 | 3,534 (3,530 to 3,638) | 3,051 (3,009 to 3,088) | 1.16x | 2.19 / 3.63 | 2.56 / 3.97 | 7.2 / 7.3 |
| 16 | 6,728 (6,706 to 6,884) | 5,582 (5,565 to 5,631) | 1.21x | 2.30 / 3.80 | 2.77 / 4.39 | 14.4 / 14.0 |
| 32 | 11,517 (11,397 to 11,641) | 7,480 (7,445 to 7,523) | 1.54x | 2.69 / 4.35 | 4.20 / 5.92 | 28.8 / 19.3 |
| 50 | 13,654 (13,567 to 13,833) | 7,410 (7,306 to 7,419) | 1.84x | 3.52 / 5.97 | 6.90 / 8.84 | 46.4 / 19.2 |
| 100 | 15,717 (15,713 to 15,852) | 7,320 (7,285 to 7,332) | 2.15x | 6.14 / 11.63 | 14.58 / 16.58 | 96.5 / 19.0 |

## Checks

- Busiest load-generator process in any cell: 11% of one CPU. A value near 100% would mean the client, not the server, set the limit.
- Query replies with fewer than 10 results: 0. Load-generator processes that started late: 0.
- Every load was followed by a check that the server holds exactly the number of vectors sent.

## Limits of this measurement

- One machine, one dataset (1,536-dimension OpenAI embeddings), top 10 only, float32 vectors, cosine similarity.
- The load generators run on the same machine as the servers, on separate vCPUs, over loopback. The two engines share the CPU set, the memory system and the last-level cache with their load generators.
- vCPUs are hyperthreads: a pinned set of N vCPUs is N/2 physical cores.
- Redis is a stock build. Its vector sets run at most 32 searches at once (a compile-time limit, `HNSW_MAX_THREADS`) and add vectors on the main thread, so it uses a small part of this machine; that is how it behaves, not something this benchmark configured.
- Recall is measured once per index build and `ef`. Independent builds of the same engine differ in recall; the range is shown where several builds were made.
- The HotKV build is an unreleased commit (see Setup). Redis was loaded with `VADD ... CAS` and run with its default I/O threads; the tuning runs that led to those choices are in `raw/tuning/`.
- HotKV ran with 128 threads on 128 vCPUs (64 cores, both hyperthreads of each; vCPUs 0-63 and 96-159) of this one-socket 192-vCPU machine, and the load generators on the other 64 vCPUs. The Azure D160 run used 128 threads on a 160-vCPU machine and the Google Cloud run 192 threads on a 384-vCPU machine, so the runs are not directly comparable.
- Loading is not like for like: the Redis index was built with Redis pinned to four vCPUs (92, 93, 188 and 189) in an earlier step, while HotKV loaded on its 128-thread set. Treat the Redis load time as a lower bound.
- The four Redis I/O-thread checks in `raw/tuning/redis_io*` gave 7,388, 7,031, 5,541 and 6,358 queries per second at 16 clients with 1, 4, 8 and 16 I/O threads, so Redis ran with 1 I/O thread, its default.
