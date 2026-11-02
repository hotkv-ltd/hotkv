#!/usr/bin/env bash
# Cluster benchmark with a shard-count sweep: HotKV, Redis, Valkey and Dragonfly run as a cluster on a
# few server hosts, with N nodes (processes) per host, and the load comes from one load generator host
# that runs several memtier_benchmark processes with --cluster-mode.
#
# Why this script exists. full_bench.sh runs one instance of each server. Redis and Valkey run commands
# on one thread and are meant to be scaled out by running several processes, so a single instance on a
# large machine is not how they are deployed. This script gives every server the same cluster layout,
# lets you sweep the number of nodes per host, and reports every result, so you can see where each
# server does best.
#
# What every server gets (the same for all):
#   - the same hosts, ports and nodes per host, one cluster over all nodes, 16384 slots spread evenly
#   - persistence off, protected-mode no, bound to the host's address, cluster-node-timeout 15000
#   - HotKV `threads` and Redis/Valkey `io-threads` = the host's vCPUs divided by the nodes per host
#     (override with THREADS_PER_NODE=N), nodes are not pinned to CPUs
#   - Dragonfly runs with --cluster_mode=yes, one node per port; its slots are assigned with
#     DFLYCLUSTER CONFIG (it has no cluster manager like redis-cli --cluster create)
#   - before every command the keyspace is emptied and written completely with that command's own data
#     type (the same populate as full_bench.sh), DBSIZE over all primaries is checked against it, and
#     the hit ratio of every run is recorded
#   - commands: the same as full_bench.sh, except MGET, MSET and PING. MGET and MSET with several random
#     keys fail with CROSSSLOT in a cluster, and PING has no key to route by, so memtier cannot spread
#     it over the nodes. They are not in the default COMMANDS; add them to try.
#   - memtier_benchmark with --cluster-mode, --distinct-client-seed and --randomize on every process,
#     PROCS processes x THREADS threads on the load generator (one process does not scale to
#     hundreds of threads, see README.md), CPU of the load generator and of every server host
#     sampled in the middle of each run
#
# Run it ON the load generator. That host needs ssh access (key only) to every server host, the
# binaries redis-server, redis-cli, valkey-server, valkey-cli and memtier_benchmark in OPT_DIR, a
# HotKV binary (HotKV is commercial: get one from HotKV Ltd, see hotkv.com) and, to include
# Dragonfly, a dragonfly binary (setup_server.sh builds one). The script copies the server binaries
# to the server hosts. python3 is needed on the load generator.
#
#   NODES="10.0.0.11 10.0.0.12 10.0.0.13" HOTKV_BIN=/path/to/hotkv \
#   SERVERS="hotkv redis valkey" KS="1 2 4 8 16" PIPELINES="30" RUNS=3 TEST_TIME=15 \
#   bash cluster_bench_sweep.sh
#
# Settings (environment variables):
#   NODES            server host addresses, space separated (required)
#   HOTKV_BIN        path to the HotKV binary (required when SERVERS includes hotkv)
#   DRAGONFLY_BIN    path to the dragonfly binary (required when SERVERS includes dragonfly)
#   SERVERS          servers to run (default "hotkv redis valkey dragonfly")
#   COMMANDS         commands to run (default "SET GET SETNX APPEND INCR LPUSH RPUSH SADD HSET")
#   KS               nodes per host to sweep (default "1 4 16")
#   PIPELINES        pipeline depths (default "30")
#   RUNS, TEST_TIME  runs per cell and seconds per run (default 1 and 10)
#   KEYSPACE, VALUE  keys and value bytes (default 5000000 and 256)
#   PROCS, THREADS   memtier processes and threads per process (default 16 and 12, set so that
#                    PROCS x THREADS is the load generator's vCPU count)
#   CONNS_BASE       connections per thread and node at 1 node per host (default 16; divided by the
#                    nodes per host, minimum 1, so the total stays about constant)
#   NODE_VCPUS       vCPUs of one server host (default: nproc of the first server host)
#   THREADS_PER_NODE threads per node instead of NODE_VCPUS / KS
#   SSH_USER, SSH_KEY  ssh login (default ubuntu and ~/.ssh/bench_id)
#   OPT_DIR          directory with the Redis, Valkey and memtier binaries (default ~/bench/opt)
#   BASE_PORT        first node port (default 7400)
#   OUT              output directory (default ~/cluster-sweep-<date>)
#
# Output: OUT/results.csv (one line per run), OUT/raw/ (memtier JSON and output, CPU samples),
# OUT/run.log. A result is client-bound when driver_cpu_pct is about 90 or more: the figure is then
# a floor, not the server's limit.
set -uo pipefail

NODES=(${NODES:-})
[ "${#NODES[@]}" -ge 1 ] || { echo "NODES is required (server host addresses), see the header of this script" >&2; exit 2; }
SSH_USER=${SSH_USER:-ubuntu}
KEY=${SSH_KEY:-$HOME/.ssh/bench_id}
BIN=${OPT_DIR:-$HOME/bench/opt}
HOTKV_BIN=${HOTKV_BIN:-}
DRAGONFLY_BIN=${DRAGONFLY_BIN:-}
SERVERS=${SERVERS:-"hotkv redis valkey dragonfly"}
COMMANDS=${COMMANDS:-"SET GET SETNX APPEND INCR LPUSH RPUSH SADD HSET"}
POPULATE_THREADS=${POPULATE_THREADS:-48}
POPULATE_CLIENTS=${POPULATE_CLIENTS:-4}
KS=${KS:-"1 4 16"}
PIPELINES=${PIPELINES:-"30"}
RUNS=${RUNS:-1}
TEST_TIME=${TEST_TIME:-10}
KEYSPACE=${KEYSPACE:-5000000}
VALUE=${VALUE:-256}
PROCS=${PROCS:-16}
THREADS=${THREADS:-12}
CONNS_BASE=${CONNS_BASE:-16}
BASE_PORT=${BASE_PORT:-7400}
RD=${RD:-csw}                      # work directory on the server hosts, relative to the login home
OUT=${OUT:-$HOME/cluster-sweep-$(date +%Y%m%d-%H%M)}
case " $SERVERS " in *" hotkv "*) [ -x "$HOTKV_BIN" ] || { echo "HOTKV_BIN must be an executable HotKV binary" >&2; exit 2; } ;; esac
case " $SERVERS " in *" dragonfly "*) [ -x "$DRAGONFLY_BIN" ] || { echo "DRAGONFLY_BIN must be an executable dragonfly binary" >&2; exit 2; } ;; esac
for b in redis-server redis-cli valkey-server valkey-cli memtier_benchmark; do
  [ -x "$BIN/$b" ] || { echo "$BIN/$b missing" >&2; exit 2; }
done
command -v python3 > /dev/null || { echo "python3 missing" >&2; exit 2; }

mkdir -p "$OUT"
CSV="$OUT/results.csv"
[ -f "$CSV" ] || echo "server,command,nodes_per_host,primaries,threads_per_node,pipeline,run,ops_per_sec,hit_ratio,driver_cpu_pct,node_cpu_pct,note" > "$CSV"

RS="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10"
rsh() { local h=$1; shift; $RS "$SSH_USER@$h" "$@"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/run.log"; }
cli_for() { [ "$1" = valkey ] && echo "$BIN/valkey-cli" || echo "$BIN/redis-cli"; }
NODE_VCPUS=${NODE_VCPUS:-$(rsh "${NODES[0]}" nproc)}

stage() {
  local h
  for h in "${NODES[@]}"; do
    rsh "$h" "mkdir -p $RD/bin" || return 1
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -q \
      "$BIN/redis-server" "$BIN/valkey-server" "$SSH_USER@$h:$RD/bin/" || return 1
    if [ -n "$HOTKV_BIN" ]; then
      scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -q \
        "$HOTKV_BIN" "$SSH_USER@$h:$RD/bin/hotkv" || return 1
    fi
    if [ -n "$DRAGONFLY_BIN" ]; then
      scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -q \
        "$DRAGONFLY_BIN" "$SSH_USER@$h:$RD/bin/dragonfly" || return 1
    fi
  done
  return 0
}

stop_all() {
  local h
  for h in "${NODES[@]}"; do
    rsh "$h" "for f in $RD/n*/node.pid; do [ -f \$f ] && kill \$(cat \$f) 2>/dev/null; done; sleep 2; for f in $RD/n*/node.pid; do [ -f \$f ] && kill -9 \$(cat \$f) 2>/dev/null; done; rm -rf $RD/n*" > /dev/null 2>&1 || true
  done
}
trap stop_all EXIT

node_conf() { # server host port threads
  cat <<EOF
port $3
bind $2
protected-mode no
dir .
daemonize no
save ""
appendonly no
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 15000
cluster-announce-ip $2
tcp-backlog 65535
maxclients 65000
loglevel notice
EOF
  case $1 in
    hotkv) echo "threads $4" ;;
    redis | valkey) [ "$4" -gt 1 ] && echo "io-threads $4" ;;
  esac
  # opt-in: extra lines for every node's configuration of this server (EXTRA_NODE_CONF_<SERVER>, e.g. EXTRA_NODE_CONF_HOTKV="pipeline-prefetch yes")
  local extra="EXTRA_NODE_CONF_${1^^}"
  [ -n "${!extra:-}" ] && printf '%s\n' "${!extra}"
  return 0
}

start_nodes() { # server k threads
  local s=$1 k=$2 tpn=$3 h i p d bin cli PIN=""
  [ -n "${SERVER_CPUS:-}" ] && PIN="taskset -c $SERVER_CPUS "   # opt-in: confine each server host's nodes to these CPUs
  case $s in hotkv) bin=$RD/bin/hotkv ;; redis) bin=$RD/bin/redis-server ;; valkey) bin=$RD/bin/valkey-server ;; dragonfly) bin=$RD/bin/dragonfly ;; esac
  for h in "${NODES[@]}"; do
    for ((i = 0; i < k; i++)); do
      p=$((BASE_PORT + i)); d=$RD/n$p
      if [ "$s" = dragonfly ]; then
        rsh "$h" "rm -rf $d && mkdir -p $d && cd $d && setsid -f bash -c 'echo \$\$ > node.pid; ulimit -n 1048576; exec $PIN../../$bin --port=$p --bind=$h --proactor_threads=$tpn --dbfilename= --cluster_mode=yes --maxclients=65000 --tcp_backlog=65535 --logtostderr > node.log 2>&1 < /dev/null'" || return 1
      else
        node_conf "$s" "$h" "$p" "$tpn" | rsh "$h" "rm -rf $d && mkdir -p $d && cat > $d/node.conf" || return 1
        rsh "$h" "cd $d && setsid -f bash -c 'echo \$\$ > node.pid; ulimit -n 1048576; exec $PIN../../$bin node.conf > node.log 2>&1 < /dev/null'" || return 1
      fi
    done
  done
  cli=$(cli_for "$s")
  for h in "${NODES[@]}"; do
    for ((i = 0; i < k; i++)); do
      p=$((BASE_PORT + i))
      for t in $(seq 1 60); do [ "$("$cli" -h "$h" -p "$p" ping 2> /dev/null)" = PONG ] && break; sleep 1; done
      [ "$("$cli" -h "$h" -p "$p" ping 2> /dev/null)" = PONG ] || { log "node $h:$p did not answer PING"; rsh "$h" "tail -5 $RD/n$p/node.log"; return 1; }
    done
  done
}

# Dragonfly has no cluster manager: every node gets the same slot map through DFLYCLUSTER CONFIG,
# with the node ids the nodes report themselves (CLUSTER MYID) and the slots split evenly.
dfly_cluster() { # k
  local k=$1 cli="$BIN/redis-cli" h i p id spec="" json out
  for h in "${NODES[@]}"; do for ((i = 0; i < k; i++)); do
    p=$((BASE_PORT + i)); id=$("$cli" -h "$h" -p "$p" CLUSTER MYID 2> /dev/null | tr -d '\r\n')
    [ -n "$id" ] || { log "no node id from $h:$p"; return 1; }
    spec+="$h $p $id"$'\n'
  done; done
  json=$(printf '%s' "$spec" | python3 -c '
import json, sys
rows = [l.split() for l in sys.stdin.read().splitlines() if l.strip()]
n = len(rows)
cfg = [{"slot_ranges": [{"start": j * 16384 // n, "end": (j + 1) * 16384 // n - 1}],
        "master": {"id": r[2], "ip": r[0], "port": int(r[1])}, "replicas": []} for j, r in enumerate(rows)]
print(json.dumps(cfg))')
  for h in "${NODES[@]}"; do for ((i = 0; i < k; i++)); do
    out=$("$cli" -h "$h" -p "$((BASE_PORT + i))" DFLYCLUSTER CONFIG "$json" 2>&1)
    [ "$out" = OK ] || { log "DFLYCLUSTER CONFIG on $h:$((BASE_PORT + i)) said: $out"; return 1; }
  done; done
  sleep 3
}

make_cluster() { # server k
  local s=$1 k=$2 cli addrs="" h i want=$(($2 * ${#NODES[@]})) info
  [ "$s" = dragonfly ] && { dfly_cluster "$k"; return; }
  cli=$(cli_for "$s")
  for h in "${NODES[@]}"; do for ((i = 0; i < k; i++)); do addrs+="$h:$((BASE_PORT + i)) "; done; done
  "$cli" --cluster create $addrs --cluster-yes > "$OUT/cluster-create-$s-k$k.log" 2>&1 || { log "cluster create failed"; tail -5 "$OUT/cluster-create-$s-k$k.log"; return 1; }
  for t in $(seq 1 90); do
    info=$("$cli" -h "${NODES[0]}" -p "$BASE_PORT" cluster info 2> /dev/null)
    echo "$info" | grep -q 'cluster_state:ok' && echo "$info" | grep -q "cluster_known_nodes:$want" && return 0
    sleep 1
  done
  log "cluster did not converge"; return 1
}

dbsize_total() { # server k
  local cli tot=0 h i n; cli=$(cli_for "$1")
  for h in "${NODES[@]}"; do for ((i = 0; i < $2; i++)); do
    n=$("$cli" -h "$h" -p "$((BASE_PORT + i))" dbsize 2> /dev/null | tr -dc '0-9'); tot=$((tot + ${n:-0}))
  done; done
  echo "$tot"
}

# busy percent of all CPUs over a window: user+nice+system+irq+softirq+steal against the total
CPU_AWK='/^cpu /{print $2+$3+$4+$7+$8+$9, $2+$3+$4+$5+$6+$7+$8+$9}'
cpu_window() { # host|local seconds
  local cmd="awk '$CPU_AWK' /proc/stat; sleep $2; awk '$CPU_AWK' /proc/stat"
  { if [ "$1" = local ]; then bash -c "$cmd"; else rsh "$1" "$cmd"; fi; } |
    awk 'NR==1{b=$1;t=$2} NR==2{printf "%.0f", 100*($1-b)/($2-t)}'
}

nodes_alive() { # server k
  local cli h i; cli=$(cli_for "$1")
  for h in "${NODES[@]}"; do for ((i = 0; i < $2; i++)); do
    [ "$("$cli" -h "$h" -p "$((BASE_PORT + i))" ping 2> /dev/null)" = PONG ] || return 1
  done; done
}

flush_all() { # server k
  local cli h i; cli=$(cli_for "$1")
  for h in "${NODES[@]}"; do for ((i = 0; i < $2; i++)); do "$cli" -h "$h" -p "$((BASE_PORT + i))" flushall > /dev/null 2>&1; done; done
}

# the data type each command needs, as in full_bench.sh (INCR needs integers, lists need lists, ...)
populate_spec() {
  case $1 in
    SET | GET | SETNX | APPEND | MGET | MSET | PING) echo "SET __key__ __data__" ;;
    INCR) echo "SET __key__ 0" ;;
    LPUSH | RPUSH) echo "LPUSH __key__ __data__" ;;
    SADD) echo "SADD __key__ __data__" ;;
    HSET) echo "HSET __key__ field __data__" ;;
    *) return 1 ;;
  esac
}

run_spec() {
  case $1 in
    SET) echo "SET __key__ __data__" ;;
    GET) echo "GET __key__" ;;
    SETNX) echo "SETNX __key__ __data__" ;;
    APPEND) echo "APPEND __key__ __data__" ;;
    INCR) echo "INCR __key__" ;;
    LPUSH) echo "LPUSH __key__ __data__" ;;
    RPUSH) echo "RPUSH __key__ __data__" ;;
    SADD) echo "SADD __key__ __data__" ;;
    HSET) echo "HSET __key__ __data__ __data__" ;;
    MGET) echo "MGET __key__ __key__ __key__ __key__ __key__ __key__ __key__ __key__" ;;
    MSET) echo "MSET __key__ __data__ __key__ __data__ __key__ __data__ __key__ __data__" ;;
    PING) echo "PING" ;;
    *) return 1 ;;
  esac
}

populate() { # server k command
  local s=$1 k=$2 c=$3 spec dflag="-d $VALUE" tc=$((POPULATE_THREADS * POPULATE_CLIENTS)) rpc n
  spec=$(populate_spec "$c") || { log "  unknown command $c"; return 1; }
  [ "$c" = INCR ] && dflag=""
  rpc=$(((KEYSPACE + tc - 1) / tc))
  flush_all "$s" "$k"
  "$BIN/memtier_benchmark" -s "${NODES[0]}" -p "$BASE_PORT" --cluster-mode -t "$POPULATE_THREADS" -c "$POPULATE_CLIENTS" --pipeline 100 \
    $dflag --key-minimum 1 --key-maximum "$KEYSPACE" --requests="$rpc" --hide-histogram \
    --command="$spec" --command-key-pattern=P > "$OUT/populate-$s-k$k-$c.log" 2>&1
  n=$(dbsize_total "$s" "$k")
  log "  $c populated: DBSIZE $n (expected $KEYSPACE)"
  [ "$n" -eq "$KEYSPACE" ]
}

run_cmd() { # server k threads command pipeline run
  local s=$1 k=$2 tpn=$3 c=$4 p=$5 r=$6 conns=$((CONNS_BASE / $2)) j rd w h spec kp="--command-key-pattern=R"
  [ "$conns" -ge 1 ] || conns=1
  spec=$(run_spec "$c"); [ "$c" = PING ] && kp=""
  rd="$OUT/raw/$s-k$k-$c-p$p-r$r"; mkdir -p "$rd"
  for ((j = 0; j < PROCS; j++)); do
    "$BIN/memtier_benchmark" -s "${NODES[0]}" -p "$BASE_PORT" --cluster-mode -t "$THREADS" -c "$conns" --pipeline "$p" -d "$VALUE" \
      --key-minimum 1 --key-maximum "$KEYSPACE" --command="$spec" $kp --test-time "$TEST_TIME" --hide-histogram --distinct-client-seed --randomize \
      --json-out-file "$rd/mt-$j.json" > "$rd/mt-$j.out" 2>&1 &
  done
  # opt-in: more load generators (EXTRA_CLIENTS="host:processes ..."), the same load from each, the results added up
  local ec ch cn=0
  for ec in ${EXTRA_CLIENTS:-}; do
    ch=${ec%%:*}; cn=$((cn + 1))
    rsh "$ch" "mkdir -p $rd; ulimit -n 1048576; for j in \$(seq 0 $((${ec##*:} - 1))); do $BIN/memtier_benchmark -s ${NODES[0]} -p $BASE_PORT --cluster-mode -t $THREADS -c $conns --pipeline $p -d $VALUE --key-minimum 1 --key-maximum $KEYSPACE --command='$spec' $kp --test-time $TEST_TIME --hide-histogram --distinct-client-seed --randomize --json-out-file $rd/x$cn-mt-\$j.json > $rd/x$cn-mt-\$j.out 2>&1 & done; wait" &
  done
  sleep 4
  w=$((TEST_TIME - 6)); [ "$w" -ge 3 ] || w=3
  cpu_window local "$w" > "$rd/cpu-driver" 2> /dev/null &
  for h in "${NODES[@]}"; do cpu_window "$h" "$w" > "$rd/cpu-$h" 2> /dev/null & done
  cn=0
  for ec in ${EXTRA_CLIENTS:-}; do cn=$((cn + 1)); cpu_window "${ec%%:*}" "$w" > "$rd/cpuclient-$cn" 2> /dev/null & done
  wait
  cn=0
  for ec in ${EXTRA_CLIENTS:-}; do
    cn=$((cn + 1))
    rsh "${ec%%:*}" "cd $rd && tar cf - x$cn-mt-*.json" | tar xf - -C "$rd"
  done
  python3 - "$rd" "$s" "$k" "$tpn" "$p" "$r" "${#NODES[@]}" "$c" >> "$CSV" <<'PY'
import glob, json, os, sys
rd, s, k, tpn, p, r, nn, c = sys.argv[1:9]
ops = hits = miss = 0.0
bad = 0
for f in glob.glob(rd + "/*mt-*.json"):
    try:
        t = json.load(open(f))["ALL STATS"]["Totals"]
        ops += t.get("Ops/sec", 0); hits += t.get("Hits/sec", 0); miss += t.get("Misses/sec", 0)
    except Exception:
        bad += 1
def cpu(path):
    try: return int(open(path).read().strip())
    except Exception: return -1
node = [cpu(x) for x in sorted(glob.glob(rd + "/cpu-*")) if not x.endswith("cpu-driver")]
hit = "%.4f" % (hits / (hits + miss)) if c == "GET" and hits + miss else "-"
note = "unreadable_json=%d" % bad if bad else ""
flood = [f for f in glob.glob(rd + "/*mt-*.out") if os.path.getsize(f) > 5000000]
if flood:
    note = (note + " " if note else "") + "client_output_flood=%d" % len(flood)
extra = [cpu(x) for x in sorted(glob.glob(rd + "/cpuclient-*"))]
if extra:
    note = (note + " " if note else "") + "extra_client_cpu=" + "/".join(map(str, extra))
print(f"{s},{c},{k},{int(k)*int(nn)},{tpn},{p},{r},{ops:.0f},{hit},{cpu(rd + '/cpu-driver')},{'/'.join(map(str,node))},{note}")
PY
  tail -n 1 "$CSV" | tee -a "$OUT/run.log"
}

log "output $OUT, server hosts: ${NODES[*]}, $NODE_VCPUS vCPUs each"
stage || { log "copying the server binaries failed"; exit 1; }
for s in $SERVERS; do
  for k in $KS; do
    tpn=${THREADS_PER_NODE:-$((NODE_VCPUS / k))}; [ "$tpn" -ge 1 ] || tpn=1
    log "== $s, $k node(s) per host, $((k * ${#NODES[@]})) primaries, $tpn threads per node"
    stop_all
    start_nodes "$s" "$k" "$tpn" || { log "  start failed"; continue; }
    make_cluster "$s" "$k" || { log "  cluster failed"; continue; }
    for c in $COMMANDS; do
      for p in $PIPELINES; do for ((r = 1; r <= RUNS; r++)); do
        # every run starts from a fresh, identical dataset; a dead node is restarted first
        if ! nodes_alive "$s" "$k"; then
          log "  a node is down, restarting the cluster"
          stop_all
          start_nodes "$s" "$k" "$tpn" && make_cluster "$s" "$k" || { log "  restart failed"; continue 3; }
        fi
        populate "$s" "$k" "$c" || { log "  populate $c failed"; continue; }
        run_cmd "$s" "$k" "$tpn" "$c" "$p" "$r"
      done; done
    done
    stop_all
  done
done
log "DONE"
