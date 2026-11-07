# HotKV vs Microsoft Garnet benchmark, Azure D48als_v7, 2026-11-06

Every number below comes from raw/throughput.txt. Each cell is the mean of 2 runs of 10 seconds.

## Setup

- Two Azure Standard_D48als_v7 machines (AMD EPYC 9V45, 48 vCPUs), Ubuntu 24.04, same subnet. One ran the server, the other the load generator.
- One server ran at a time. Before each product started, the other was stopped.
- Garnet 2.2.7, the official release binary (harness/garnet_install.sh checks its SHA-256), default settings plus `--index 1g --protected-mode no` (cmdline_garnet.txt).
- HotKV 0.3.3 with 48 threads, snapshots off, protected mode off and its workers pinned with `server-cpulist 0-47` (cmdline_hotkv.txt).
- Load from `Resp.benchmark` built from the Garnet v2.2.7 tag with .NET 10 (harness/client_setup.sh), the tool Microsoft uses for its own [Garnet benchmark results](https://microsoft.github.io/garnet/docs/benchmarking/results-resp-bench).
- 8-byte keys, 8-byte values, 1,024 keys, as in Microsoft's published runs.

## Method

- Pipelined tests: `--batchsize 4096` with 1, 32 and 128 connections (`--threads`).
- One request at a time: `--batchsize 1` with 128 connections.
- 10 seconds per test (`--runtime 10`), the `[Throughput]` line recorded.
- Two rounds, Garnet then HotKV, then HotKV then Garnet. harness/run_throughput.sh reproduces the sequence.

## Results

Pipelined tests in millions of requests per second, one request at a time in thousands. Higher is better.

| Test | Garnet 2.2.7 | HotKV 0.3.3 | HotKV vs Garnet |
|---|---|---|---|
| GET, 1 connection | 10.89 | 8.67 | -20% |
| GET, 32 connections | 139.8 | 106.2 | -24% |
| GET, 128 connections | 134.6 | 135.2 | level |
| GET, 128 connections, one at a time | 1,002 | 1,088 | +9% |
| SET, 1 connection | 8.28 | 6.51 | -21% |
| SET, 32 connections | 80.3 | 76.2 | -5% |
| SET, 128 connections | 90.3 | 85.2 | -6% |
| SET, 128 connections, one at a time | 997 | 1,110 | +11% |

## Findings

1. With 128 connections sending one request at a time, HotKV served 9% more GETs and 11% more SETs than Garnet.
2. With 128 pipelined connections the two were level on GET at about 135 million requests a second. Garnet was 6% faster on SET.
3. With 1 or 32 pipelined connections Garnet was faster on both GET and SET.

## Scope

- One machine type, one run date, two runs per test.
- Tiny keys and values and only 1,024 keys, so the data set fits in CPU cache. No claim here covers larger values, larger key sets, other commands, persistence, replication, TLS or cluster mode.

## Files

- raw/throughput.txt holds the throughput line of every run.
- cmdline_garnet.txt and cmdline_hotkv.txt are the server launch lines, host.txt the machine.
- harness holds the Garnet install script, the load generator setup and the run script.

Garnet and Microsoft are trademarks of Microsoft Corporation. They are named only to identify the software measured.
