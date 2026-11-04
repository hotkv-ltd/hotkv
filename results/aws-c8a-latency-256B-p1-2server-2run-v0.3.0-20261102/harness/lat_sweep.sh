#!/usr/bin/env bash
# Latency at fixed offered load, one server configuration at a time.
# memtier_benchmark, pipeline 1, 192 connections, per-connection --rate-limiting,
# HDR histogram output. A point counts as sustained only if the achieved rate is
# >= 97% of the offered rate; the sweep for a configuration stops at the first
# point that is not.
#   SRV_PRIV=<server private ip> bash lat_sweep.sh <outdir> [cfg ...]
set -uo pipefail
source "$(dirname "$0")/lat_common.sh"
OUT="${1:?outdir}"; shift
CONFIGS=("$@"); [ ${#CONFIGS[@]} -gt 0 ] || CONFIGS=(hotkv dragonfly redis-1 redis-io8 valkey-1 valkey-io8)
KEYS="${KEYS:-1000000}"; VSIZE="${VSIZE:-256}"
THREADS=24; CONNS=34; NCONN=$((THREADS*CONNS))
TEST_TIME="${TEST_TIME:-20}"; REPEATS="${REPEATS:-2}"
RATES=(${RATES:-20000 50000 100000 200000 400000 800000 1200000 1600000 2400000 3200000 4000000 5000000 6000000})
WORKLOADS=(${WORKLOADS:-get mixed})
mkdir -p "$OUT"
{ echo "start $(date -u +%FT%TZ)"; echo "keys=$KEYS vsize=$VSIZE threads=$THREADS conns/thread=$CONNS test_time=$TEST_TIME repeats=$REPEATS"; echo "rates=${RATES[*]}"; echo "workloads=${WORKLOADS[*]}"; memtier_benchmark --version | head -1; } > "$OUT/sweep_meta.txt"

ratio_for() { case "$1" in get) echo "0:1" ;; mixed) echo "1:10" ;; esac; }

for cfg in "${CONFIGS[@]}"; do
    log "=== $cfg"
    start_server "$cfg" || continue
    record_server "$cfg" "$OUT"
    populate "$KEYS" "$VSIZE" || { stop_server; continue; }
    for wl in "${WORKLOADS[@]}"; do
        ratio=$(ratio_for "$wl")
        for rate in "${RATES[@]}"; do
            per_conn=$(( rate / NCONN )); [ "$per_conn" -ge 1 ] || per_conn=1
            offered=$(( per_conn * NCONN ))
            sustained=1
            for rep in $(seq 1 "$REPEATS"); do
                tag="${cfg}_${wl}_r${offered}_run${rep}"
                d="$OUT/raw/$tag"; mkdir -p "$d"
                a=$(snap_local); b=$(snap_remote)
                memtier_benchmark -s "$SRV_PRIV" -p $PORT --protocol=redis -t $THREADS -c $CONNS --pipeline 1 -d "$VSIZE" \
                    --key-minimum=1 --key-maximum="$KEYS" --ratio="$ratio" --rate-limiting="$per_conn" \
                    --test-time "$TEST_TIME" --print-percentiles 50,90,99,99.9,99.99 \
                    --json-out-file "$d/memtier.json" --hdr-file-prefix "$d/hdr" --hide-histogram > "$d/memtier.txt" 2>&1
                a2=$(snap_local); b2=$(snap_remote)
                echo "$(busy_pct "$a" "$a2") $(busy_pct "$b" "$b2")" > "$d/cpu_load_server.txt"
                ops=$(python3 -c "import json,sys;print(json.load(open('$d/memtier.json'))['ALL STATS']['Totals']['Ops/sec'])" 2>/dev/null || echo 0)
                ratio_ok=$(awk -v o="$ops" -v f="$offered" 'BEGIN{print (o>=0.97*f)?1:0}')
                log "$tag offered=$offered achieved=$ops cpu(load,server)=$(cat "$d/cpu_load_server.txt") ok=$ratio_ok"
                [ "$ratio_ok" = 1 ] || sustained=0
            done
            [ "$sustained" = 1 ] || { log "$cfg/$wl: not sustained at $offered, stopping this workload"; break; }
        done
    done
    stop_server
done
echo "end $(date -u +%FT%TZ)" >> "$OUT/sweep_meta.txt"
log "lat_sweep done"
