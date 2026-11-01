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
# Settings checks. Run after the Redis indexes have been built (run_all.sh does that), before the main run.
#
#   bash tune.sh <data-dir> <out-dir>
#
# Two questions, answered with the same harness (vsbench.py) as the main run, on the
# 100,000-vector index:
#
#   1. Does Redis's io-threads setting change its vector-search throughput?
#      (io-threads 1, 4, 8, 16; ef 80; 1, 16 and 50 clients; the Redis index is the one saved
#      by run_all.sh's build step, so every setting searches the identical graph.)
#   2. How many connections should HotKV be loaded over?  (8, 16, 32; load time and recall.)
#
# The choices these runs led to are the defaults of run_all.sh. The output of each run is kept.
set -euo pipefail

DATA="${1:?data dir}"
OUT="${2:?output dir}"
PY="${PY:-/opt/vsb-venv/bin/python}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER_CPUS="${SERVER_CPUS:-0-127}"
CLIENT_CPUS="${CLIENT_CPUS:-128-139}"
# (the default is set apart: a "}" inside ${RDB:-...} would end the expansion at "{size")
RDB_DEFAULT="$HOME/vsb/rdb/redis_{size}.rdb"
RDB="${RDB:-$RDB_DEFAULT}"
export HOTKV_BIN="${HOTKV_BIN:-/opt/hotkv/build/release/src/hotkv}"
mkdir -p "$OUT/tuning"

run() {  # tag, then vsbench.py arguments
    local tag="$1"; shift
    echo "=== $tag"
    taskset -c "$CLIENT_CPUS" "$PY" "$HERE/vsbench.py" --data-dir "$DATA" --out "$OUT/tuning/$tag" \
        --sizes 100000 --builds 1 --ef-recall 80 --ef-qps 80 --trials 1 --warm 1.5 --dur 5 \
        --server-cpus "$SERVER_CPUS" "$@" > "$OUT/tuning/$tag.log" 2>&1 || echo "FAILED: $tag"
    grep -E "ingest|recall|qps" "$OUT/tuning/$tag.log" | cut -c12-175
}

echo "##### 1. Redis io-threads"
for io in 1 4 8 16; do
    run "redis_io${io}" --engines redis --clients 1 16 50 --redis-rdb "$RDB" --redis-io-threads "$io"
done

echo "##### 2. HotKV loading connections"
for P in 8 16 32; do
    run "hotkv_p${P}" --engines hotkv --clients 1 --warm 0.5 --dur 1 --ingest-conns "$P" --hotkv-threads 128
done
echo "TUNING DONE"
