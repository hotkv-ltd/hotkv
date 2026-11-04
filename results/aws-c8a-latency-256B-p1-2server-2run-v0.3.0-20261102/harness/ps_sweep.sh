#!/usr/bin/env bash
# Pub/sub delivery latency and throughput, one server configuration at a time.
# pubsub-sub-bench (redis-performance, BSD-2) with the microsecond-timestamp fix
# (see pubsub-sub-bench-microsecond.patch). Subscribers and publishers run on this
# one host so the publish timestamp and the receive timestamp share one clock.
#   SRV_PRIV=<server private ip> bash ps_sweep.sh <outdir> [cfg ...]
set -uo pipefail
source "$(dirname "$0")/lat_common.sh"
OUT="${1:?outdir}"; shift
CONFIGS=("$@"); [ ${#CONFIGS[@]} -gt 0 ] || CONFIGS=(hotkv dragonfly redis-1 redis-io8 valkey-1 valkey-io8)
TEST_TIME="${TEST_TIME:-20}"; REPEATS="${REPEATS:-2}"; PAYLOAD=128; PUBLISHERS=64
# name channels subscribers publish_rate(msg/s total)
SCENARIOS=(${SCENARIOS:-"p2p_10k:100:100:10000" "p2p_50k:100:100:50000" "p2p_100k:100:100:100000" "fanout10_10k:10:100:10000" "fanout100_1k:1:100:1000"})
mkdir -p "$OUT"
{ echo "start $(date -u +%FT%TZ)"; echo "payload=$PAYLOAD publishers=$PUBLISHERS test_time=$TEST_TIME repeats=$REPEATS"; echo "scenarios=${SCENARIOS[*]}"; pubsub-sub-bench -version 2>&1 | head -1; } > "$OUT/sweep_meta.txt"

for cfg in "${CONFIGS[@]}"; do
    log "=== $cfg"
    start_server "$cfg" || continue
    record_server "$cfg" "$OUT"
    redis-cli -h "$SRV_PRIV" -p $PORT flushall > /dev/null 2>&1 || true
    for sc in "${SCENARIOS[@]}"; do
        IFS=: read -r name chans subs rate <<< "$sc"
        for rep in $(seq 1 "$REPEATS"); do
            d="$OUT/raw/${cfg}_${name}_run${rep}"; mkdir -p "$d"
            a=$(snap_local); b=$(snap_remote)
            pubsub-sub-bench -host "$SRV_PRIV" -port $PORT -mode subscribe -clients "$subs" \
                -channel-minimum 1 -channel-maximum "$chans" -data-size $PAYLOAD -measure-rtt-latency \
                -test-time "$TEST_TIME" -json-out-file "$d/sub.json" > "$d/sub.txt" 2>&1 &
            SUBPID=$!
            sleep 3
            timeout $((TEST_TIME+30)) pubsub-sub-bench -host "$SRV_PRIV" -port $PORT -mode publish -clients $PUBLISHERS \
                -channel-minimum 1 -channel-maximum "$chans" -data-size $PAYLOAD -measure-rtt-latency \
                -rps "$rate" -test-time $((TEST_TIME+3)) > "$d/pub.txt" 2>&1
            wait $SUBPID
            a2=$(snap_local); b2=$(snap_remote)
            echo "$(busy_pct "$a" "$a2") $(busy_pct "$b" "$b2")" > "$d/cpu_load_server.txt"
            log "${cfg} ${name} run${rep}: $(grep -E 'Message Rate|P50|P99 ' "$d/sub.txt" | tr -s ' ' | tr '\n' ';') cpu=$(cat "$d/cpu_load_server.txt")"
        done
    done
    stop_server
done
echo "end $(date -u +%FT%TZ)" >> "$OUT/sweep_meta.txt"
log "ps_sweep done"
