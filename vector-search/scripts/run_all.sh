#!/usr/bin/env bash
# =============================================================================
# Copyright 2026 HotKV Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use
# this file except in compliance with the License. You may obtain a copy of the
# License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by
# applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the specific language
# governing permissions and limitations under the License.
#
# Website:     https://hotkv.com
# =============================================================================
# The whole vector-search benchmark, from a fresh Ubuntu 24.04 machine to RESULTS.md.
#
#   HOTKV_SRC_TGZ=/path/to/hotkv-source.tgz bash run_all.sh
#
# Steps (each can be run on its own; see README.md):
#   1. setup.sh            toolchain, Redis 8.10.2, HotKV from the source archive
#   2. prepare_data.py     dataset, ground truth
#   3. build_redis_indexes the Redis indexes are built once, saved to RDB files, and loaded for the measurements
#   4. tune.sh             the settings checks (Redis io-threads, HotKV loading connections)
#   5. vsbench.py          the measurements, one run per index size
#   6. render_report.py    RESULTS.md from the raw results
#
# CPU placement: the servers are pinned to SERVER_CPUS, the load generators to CLIENT_CPUS. On the
# 160-vCPU machine used for the published run: servers 0-127, load generators 128-159. Change both for
# another machine (they must not overlap).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HOME/vsb}"
PY="${PY:-/opt/vsb-venv/bin/python}"
SERVER_CPUS="${SERVER_CPUS:-0-127}"
CLIENT_CPUS="${CLIENT_CPUS:-128-159}"
HOTKV_THREADS="${HOTKV_THREADS:-128}"
export HOTKV_BIN="${HOTKV_BIN:-/opt/hotkv/build/release/src/hotkv}"
mkdir -p "$WORK/rdb" "$WORK/out"

if [ -z "${SKIP_PREP:-}" ]; then   # SKIP_PREP=1 runs only steps 5 and 6 (machine already prepared)
  bash "$HERE/setup.sh"
  "$PY" "$HERE/prepare_data.py" --data-dir "$WORK/data" --sizes 100000 999000

  # 3. Redis indexes: built with 32 connections and VADD ... CAS (the faster of Redis's two loading modes
  #    in the tuning checks), saved with SAVE. Cores 140-143 hold the Redis server, 144-159 the loaders,
  #    so this can run while other work uses the rest of the machine.
  taskset -c 144-159 "$PY" "$HERE/vsbench.py" --data-dir "$WORK/data" --out "$WORK/out/redis_build" \
      --engines redis --sizes 100000 999000 --builds 3 1 --build-only --redis-cas --ingest-conns 32 \
      --redis-rdb "$WORK/rdb/redis_{size}.rdb" --server-cpus 140-143 --port-offset 100

  bash "$HERE/tune.sh" "$WORK/data" "$WORK/out"
fi

for size in 999000 100000; do
    builds=1; [ "$size" = 100000 ] && builds=3
    taskset -c "$CLIENT_CPUS" "$PY" "$HERE/vsbench.py" --data-dir "$WORK/data" --out "$WORK/out/run_$size" \
        --sizes "$size" --builds "$builds" \
        --redis-rdb "$WORK/rdb/redis_{size}.rdb" --redis-cas --ingest-conns 32 \
        --ef-recall 10 20 40 80 150 300 500 --ef-qps 80 40 150 300 \
        --clients 1 2 4 8 16 32 50 100 --trials 3 --warm 1.0 --dur 4 \
        --server-cpus "$SERVER_CPUS" --hotkv-threads "$HOTKV_THREADS" --redis-io-threads 1
done

# Supplementary run: on the 999,000-vector index Redis does not reach 0.99 recall by ef 300, so ef 500 is
# measured as well (HotKV is rebuilt for it; Redis is loaded from the same saved file).
taskset -c "$CLIENT_CPUS" "$PY" "$HERE/vsbench.py" --data-dir "$WORK/data" --out "$WORK/out/run_999000_ef500"     --sizes 999000 --builds 1     --redis-rdb "$WORK/rdb/redis_{size}.rdb" --redis-cas --ingest-conns 32     --ef-recall 500 --ef-qps 500     --clients 1 2 4 8 16 32 50 100 --trials 3 --warm 1.0 --dur 4     --server-cpus "$SERVER_CPUS" --hotkv-threads "$HOTKV_THREADS" --redis-io-threads 1

"$PY" "$HERE/render_report.py" --title "Vector search: HotKV and Redis 8.10.2 on 160 vCPUs"     --out "$WORK/out/RESULTS.md"     "$WORK/out/run_999000/results.json,$WORK/out/run_999000_ef500/results.json" "$WORK/out/run_100000/results.json"
echo "DONE: $WORK/out/RESULTS.md"
