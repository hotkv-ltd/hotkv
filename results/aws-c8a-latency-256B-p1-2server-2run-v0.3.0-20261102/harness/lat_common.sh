#!/usr/bin/env bash
# Shared helpers for lat_sweep.sh and ps_sweep.sh. Runs ON THE LOAD GENERATOR.
# Server-side control goes over ssh to the server (one product at a time, so
# nothing overlaps and nothing shares the NIC).
SRV_PRIV="${SRV_PRIV:?set SRV_PRIV}"
PORT=6399
SSH_KEY="$HOME/.ssh/lat_id"
SSHS="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY ubuntu@$SRV_PRIV"
SERVER_CPUS="${SERVER_CPUS:-0-39}"
NTHREADS="${NTHREADS:-40}"
HOTKV_BIN=/opt/hotkv/build/release/src/hotkv
DRAGONFLY_BIN=/opt/dragonfly/build-opt/dragonfly
REDIS_BIN=/opt/redis-8.10.3/src/redis-server
VALKEY_BIN=/opt/valkey-9.1.3/src/valkey-server

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# name -> launch line (everything pinned to the same CPUs, persistence off for all)
cfg_cmdline() {
    case "$1" in
        hotkv)       echo "$HOTKV_BIN --port $PORT --bind 0.0.0.0 --threads $NTHREADS --no-snapshot --protected-mode no --loglevel warning" ;;
        dragonfly)   echo "$DRAGONFLY_BIN --port $PORT --bind 0.0.0.0 --proactor_threads=$NTHREADS --dbfilename= --noversion_check --logtostderr" ;;
        redis-1)     echo "$REDIS_BIN --port $PORT --bind 0.0.0.0 --save '' --appendonly no --protected-mode no --loglevel warning" ;;
        redis-io8)   echo "$REDIS_BIN --port $PORT --bind 0.0.0.0 --save '' --appendonly no --protected-mode no --loglevel warning --io-threads 8" ;;
        valkey-1)    echo "$VALKEY_BIN --port $PORT --bind 0.0.0.0 --save '' --appendonly no --protected-mode no --loglevel warning" ;;
        valkey-io8)  echo "$VALKEY_BIN --port $PORT --bind 0.0.0.0 --save '' --appendonly no --protected-mode no --loglevel warning --io-threads 8" ;;
        *) echo "unknown cfg $1" >&2; return 1 ;;
    esac
}

stop_server() {
    $SSHS "sudo fuser -k ${PORT}/tcp >/dev/null 2>&1; for i in \$(seq 1 40); do sudo fuser -s ${PORT}/tcp 2>/dev/null || exit 0; sleep 0.5; done; exit 1" || log "WARN port still busy"
}

start_server() {
    local cfg="$1" cmd; cmd=$(cfg_cmdline "$cfg") || return 1
    stop_server
    $SSHS "ulimit -n 1048576; cd /tmp; nohup taskset -c $SERVER_CPUS $cmd > /tmp/srv_${cfg}.log 2>&1 < /dev/null & echo started" > /dev/null
    for i in $(seq 1 60); do
        redis-cli -h "$SRV_PRIV" -p $PORT ping 2>/dev/null | grep -q PONG && return 0
        sleep 0.5
    done
    log "ERROR $cfg did not start"; $SSHS "tail -n 15 /tmp/srv_${cfg}.log"; return 1
}

# Record the launch line and the effective config the live server reports.
record_server() {
    local cfg="$1" dir="$2"
    cfg_cmdline "$cfg" > "$dir/cmdline_${cfg}.txt"
    redis-cli -h "$SRV_PRIV" -p $PORT config get '*' > "$dir/config_${cfg}.txt" 2>&1 || true
    redis-cli -h "$SRV_PRIV" -p $PORT info server 2>/dev/null | grep -E 'version|redis_version|valkey_version|dragonfly' > "$dir/version_${cfg}.txt" || true
}

# busy% of a set of cpus between two /proc/stat snapshots.
# usage: snap_local > file ; snap_remote lo hi > file ; busy_pct before after
snap_local()  { awk '/^cpu[0-9]+ /{u=$2+$3+$4+$7+$8+$9; t=u+$5+$6; U+=u; T+=t} END{print U, T}' /proc/stat; }
snap_remote() { $SSHS "awk -v lo=${SERVER_CPUS%-*} -v hi=${SERVER_CPUS#*-} '/^cpu[0-9]+ /{n=substr(\$1,4)+0; if(n>=lo&&n<=hi){u=\$2+\$3+\$4+\$7+\$8+\$9; t=u+\$5+\$6; U+=u; T+=t}} END{print U, T}' /proc/stat"; }
busy_pct() { echo "$1 $2" | awk '{du=$3-$1; dt=$4-$2; if(dt>0) printf "%.1f", 100*du/dt; else print "0.0"}'; }

populate() {
    local keys="$1" vsize="$2"
    redis-cli -h "$SRV_PRIV" -p $PORT flushall > /dev/null 2>&1 || true
    memtier_benchmark -s "$SRV_PRIV" -p $PORT --protocol=redis -t 8 -c 25 --pipeline 100 -d "$vsize" \
        --key-minimum=1 --key-maximum="$keys" --ratio=1:0 -n allkeys --key-pattern=P:P --hide-histogram > /dev/null 2>&1
    local n; n=$(redis-cli -h "$SRV_PRIV" -p $PORT dbsize | tr -dc '0-9')
    [ "${n:-0}" -ge "$keys" ] || { log "ERROR populate: dbsize=$n expected $keys"; return 1; }
}
