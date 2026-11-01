# Vector search benchmark

A benchmark of plain vector search on HotKV and on Redis 8.10.2 vector sets: HNSW index, top-10 nearest neighbours, cosine
similarity, float32 vectors. It measures recall, queries per second, latency and loading time, and comes with the scripts that
produced the results and the raw data behind every figure. Nothing here uses HotKV's AI engines or any feature that Redis does
not also have.

Results:

- Azure `Standard_D160alds_v7`, 160 vCPUs: [`results/azure-d160alds-v7-vector-search-c8dafd37-20261014/RESULTS.md`](results/azure-d160alds-v7-vector-search-c8dafd37-20261014/RESULTS.md)
- Google Cloud `c4d-standard-384`, 384 vCPUs, Redis 8.10.3: [`results/gcp-c4d-standard-384-vector-search-38a0d11d-20261027/RESULTS.md`](results/gcp-c4d-standard-384-vector-search-38a0d11d-20261027/RESULTS.md)
- AWS `c8in.48xlarge`, 192 vCPUs, Redis 8.10.3: [`results/aws-c8in-48xlarge-vector-search-38a0d11d-20261031/RESULTS.md`](results/aws-c8in-48xlarge-vector-search-38a0d11d-20261031/RESULTS.md)

## What is measured

Both servers are driven by the same program (`scripts/vsbench.py`) and build an HNSW graph with `M=16` and `ef_construction=200`,
cosine similarity and float32 vectors (Redis `NOQUANT`):

| | HotKV | Redis 8.10.2 |
|---|---|---|
| Create | `VSIM.CREATEINDEX <index> 1536 METRIC cosine M 16 EF_CONSTRUCTION 200` | none (the first `VADD` creates the set) |
| Add a vector | `VSIM.SET <index> d<row> <1536 floats>` | `VADD <key> VALUES 1536 <1536 floats> d<row> CAS NOQUANT EF 200 M 16` |
| Query | `VSIM.SEARCH <index> 10 <1536 floats> EF <ef>` | `VSIM <key> VALUES 1536 <1536 floats> WITHSCORES COUNT 10 EF <ef>` |

Two settings matter for reading the ratios. `NOQUANT` turns off the int8 quantization Redis vector sets apply by default, so both
servers compare float32 vectors. Redis vector sets search with at most 32 threads (a compile-time limit, `HNSW_MAX_THREADS`) and
add vectors on the main thread, while HotKV ran with 128 threads; above about 32 concurrent clients the ratio therefore also
reflects how many cores each server can put to work, not only the search itself.

- **Data.** The first N rows of `dbpedia-entities-openai-1M` (OpenAI `text-embedding-ada-002` embeddings, 1,536 dimensions, MIT
  license, by Kumar Shivendu and Nirant Kasliwal), with N = 100,000 and N = 999,000. The last 1,000 rows are the queries.
- **Recall.** Recall@10 against the exact top 10, computed by brute force in float64.
- **Throughput and latency.** Search depths (`ef`) 40, 80, 150 and 300 (and 500 on the larger index), with 1, 2, 4, 8, 16, 32, 50
  and 100 clients. Each client keeps one request outstanding. One second of warm-up, then four seconds counted, three trials per
  cell; the report shows the median and the lowest and highest trial.
- **Loading.** The time each server takes to load the vectors over 32 connections. In the published run the Redis load was done in an earlier step with Redis pinned to four vCPUs, so its load time is a lower bound (see the report's limits).
- **Placement.** One Azure `Standard_D160alds_v7` (160 vCPUs). Both servers run on vCPUs 0 to 127 and the load generators on
  vCPUs 128 to 159, over loopback. HotKV runs with `--threads 128`, Redis with its default I/O threads. Persistence is off.

## Run it yourself

On a fresh Ubuntu 24.04 machine with 160 vCPUs (for another size, set `SERVER_CPUS` and `CLIENT_CPUS`; they must not overlap):

```bash
HOTKV_SRC_TGZ=/path/to/hotkv-source.tgz bash scripts/run_all.sh
```

This installs the toolchain, builds Redis 8.10.2 from its release tag and HotKV from the source archive, downloads the dataset,
builds the Redis indexes (about 20 minutes), runs the settings checks and the measurements (about 70 minutes) and writes
`RESULTS.md`. HotKV is commercial software: the source archive, or a binary (`HOTKV_BIN`), has to come from HotKV Ltd. To have the
commit of your HotKV build recorded in the results, write it to `~/vsb/HOTKV_COMMIT` before the run. The scripts need Python 3.12
with numpy and pyarrow, which `setup.sh` installs into `/opt/vsb-venv`.

To render the report again from the raw files:

```bash
python3 scripts/render_report.py --title "..." --out RESULTS.md \
    results/<run>/raw/run_999000/results.json,results/<run>/raw/run_999000_ef500/results.json \
    results/<run>/raw/run_100000/results.json
```

## What is in this folder

| Path | What |
|---|---|
| `scripts/vsbench.py` | the benchmark: loads both servers, measures recall, throughput and latency |
| `scripts/run_all.sh` | the whole sequence from a fresh machine to `RESULTS.md` |
| `scripts/setup.sh`, `prepare_data.py`, `tune.sh`, `render_report.py` | machine setup, dataset and ground truth, settings checks, report |
| `results/<run>/RESULTS.md` | the report |
| `results/<run>/raw/` | every trial of every cell (`results.json`), the logs of every step, the server logs |
| `results/<run>/environment/` | machine, versions, dataset description, unit-test and ThreadSanitizer results of the HotKV build |

## Check the files

Every file is listed with its SHA-256 checksum:

```bash
sha256sum -c SHA256SUMS
```

## License and notices

The scripts (`scripts/`) are licensed under the Apache License 2.0 (`../LICENSE`). The results, raw data, reports and
documentation are licensed under the Creative Commons Attribution 4.0 International License (`../LICENSE-DATA`): reuse and
quote them freely, credit HotKV Ltd, link here, and say whether you changed anything. Anyone, including makers of competing
products, may run the scripts and publish what they measure. See `../NOTICE`.

Redis is a trademark of its owner. It is named only to identify the software that was measured; its use does not imply any
sponsorship, endorsement or affiliation. The results describe the tested configuration, hardware and dataset; other data,
dimensions or hardware will give different results. This is a best effort benchmark and no benchmark is perfect. If you find an
error, or a setting that is unfair to either server, please open an issue in this repository (or contact HotKV Ltd through
hotkv.com) and we will re-measure and correct the results. Your own benchmarks and bug reports are welcome too. See the main
[README](../README.md).
