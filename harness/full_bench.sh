#!/bin/bash
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
#
# File:        harness/full_bench.sh
# Description: Full isolated benchmark - HotKV vs Redis vs Valkey vs Dragonfly
# Author:      HotKV Ltd
# =============================================================================
set -euo pipefail

# Ensure high fd limit for large thread/client counts
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true

# Dragonfly's io_uring allocates locked memory per proactor thread. The default
# memlock limit starves it past roughly 64 threads and it fails to start at all,
# which would silently leave Dragonfly running on a fraction of the box while
# HotKV gets all of it - exactly the detuning this benchmark exists to avoid.
ulimit -l unlimited 2>/dev/null || true

RUNS="${1:-5}"
DATASIZE="${2:-512}"
PIPELINE="${3:-1}"
PORT=6399
TOTAL_CORES=$(nproc)

# --- Network accounting -------------------------------------------------------
# The single most important thing to know about any result here is whether the
# server was actually working or just filling a cable. On the 512B runs every
# server tied at 1.00x because the NIC was saturated - the throughput divided
# exactly by payload multiple - and that looked like a real tie until the wire
# was measured. Sample the interface counters across every command so the report
# can state the achieved Gbps and what share of the link it used, rather than
# leaving the reader to infer it.
NET_IFACE="${NET_IFACE:-$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)}"
[ -z "$NET_IFACE" ] && NET_IFACE=$(ip -br link 2>/dev/null | awk '$1!="lo" && $2=="UP"{print $1; exit}')
# ethtool reports "Unknown!" on ENA and most virtio NICs, so the advertised link
# speed has to be supplied by whoever knows the instance type. 0 = unknown, and
# the report then omits the utilisation column rather than inventing a
# denominator.
NET_LINK_GBPS="${NET_LINK_GBPS:-0}"

# --- Keyspace -----------------------------------------------------------------
# The benchmark used to populate 50,000 keys and then read from memtier's default
# 0..10,000,000 key range, so 99.5% of every GET was a miss on paper. It did not
# look like that in the output, because memtier seeds every client with the SAME
# constant by default (--randomize's help: "default is constant value"): all
# clients walk an identical key sequence, so they collectively re-read the same
# small set of keys the populate step happened to write. The measured hit rate
# then depended on how far through that sequence each client got, which means it
# moved with thread count and test duration: 76% hits at -t 60 -c 50, 28% at
# -t 4 -c 10, 14% at -t 2 -c 5. A GET benchmark whose hit rate is a function of
# its own thread count is not measuring GET, and misses are cheap - they return
# nil instead of a $DATASIZE value, so they inflate ops/sec and understate bytes
# on the wire.
#
# Fix, applied identically to every server:
#   - populate walks the whole range exactly once (--command-key-pattern=P,
#     --requests=allkeys), so every key in it really exists;
#   - the benchmark reads from that same bounded range, so hits are ~100% and
#     reproducible;
#   - --distinct-client-seed gives each client its own sequence, so thousands of
#     connections stop marching in lockstep through identical keys. Dragonfly's
#     own published benchmark uses this flag for the same reason.
# 5M x 256B is ~1.3 GB of values: far past any L3, so this stays a memory
# workload rather than a cache toy.
KEY_MINIMUM="${KEY_MINIMUM:-1}"
KEY_MAXIMUM="${KEY_MAXIMUM:-5000000}"
KEYSPACE_ARGS="--key-minimum=$KEY_MINIMUM --key-maximum=$KEY_MAXIMUM"
# The 4KB exclusive tests need their own, smaller range: 5M x 4KB would be ~20 GB
# per populate and dominate the run. 500K x 4KB is ~2 GB - still far past cache,
# which is the property that matters.
KEY_MAXIMUM_4K="${KEY_MAXIMUM_4K:-500000}"
KEYSPACE_ARGS_4K="--key-minimum=$KEY_MINIMUM --key-maximum=$KEY_MAXIMUM_4K"
# Off by default only for LPOP/RPOP-style destructive reads, where a bounded
# range plus distinct seeds still cannot outrun the drain; see keyspace.drained.
SEED_ARGS="${SEED_ARGS:---distinct-client-seed}"

# --- Load-generation topology -------------------------------------------------
# BENCH_CLIENTS: space-separated SSH targets that run memtier. When set, this box
# runs ONLY the server, so the load generator stops competing with it for cores.
# Empty keeps the old loopback mode: still fine on small boxes, but it shares the
# machine with the server and caps what any server can be measured at.
BENCH_CLIENTS="${BENCH_CLIENTS:-}"
SSH_USER="${SSH_USER:-$(id -un)}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

if [ -n "$BENCH_CLIENTS" ]; then
    REMOTE_MODE=1
    BIND_ADDR="0.0.0.0"
    SERVER_ADDR="${SERVER_ADDR:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
else
    REMOTE_MODE=0
    BIND_ADDR="127.0.0.1"
    SERVER_ADDR="127.0.0.1"
fi
CLI_HOST="127.0.0.1"            # redis-cli + populate always run on the server box

if [ "$TOTAL_CORES" -le 4 ]; then
    BENCH_CORES=$TOTAL_CORES
elif [ "$TOTAL_CORES" -le 16 ]; then
    BENCH_CORES=$(( TOTAL_CORES - 2 ))
else
    BENCH_CORES=$(( TOTAL_CORES - 4 ))
fi
THREADS=${BENCH_CORES}          # memtier threads (per client machine in remote mode)
if [ "$TOTAL_CORES" -ge 64 ]; then
    CLIENTS=50
elif [ "$TOTAL_CORES" -le 4 ]; then
    CLIENTS=5
else
    CLIENTS=25
fi
# OPT-IN connection ceiling for HotKV, Redis and Valkey. Unset (the default),
# nothing is passed and every launch line is exactly the original. All three
# default to 10,000 clients; the load generators open threads x connections per
# client box (64 x 50 = 3,200), so up to three boxes fit (9,600) and a rig with
# more must raise the ceiling or the surplus connections are refused. When set,
# it is passed to all three, read back into the report and named in its notes.
MAXCLIENTS="${MAXCLIENTS:-}"
MAXCLIENTS_ARG=""
[ -n "$MAXCLIENTS" ] && MAXCLIENTS_ARG=" --maxclients $MAXCLIENTS"

# Overridable so the whole pipeline can be smoke-tested in a couple of minutes
# (TEST_TIME=2 RUNS=1 SWEEP=0) before committing to a multi-hour publishable run.
# Anything below 10 is for validation only; short samples are noise.
TEST_TIME="${TEST_TIME:-10}"
OUTDIR="${OUTDIR:-/tmp/full_bench_p${PIPELINE}}"

# --- Platform label -----------------------------------------------------------
# Bare metal vs VM is the headline finding, so record it at run time rather than
# trying to infer it from a directory name months later.
if [ -z "${PLATFORM_KIND:-}" ]; then
    # systemd-detect-virt prints "none" AND exits 1 when there is no
    # virtualization. The obvious $(cmd || echo none) therefore captures BOTH the
    # command's "none" and the fallback's, giving "none\nnone", which fails the
    # equality test and mislabels bare metal as a VM. Swallow the exit code
    # instead and treat empty as none.
    _virt=$(systemd-detect-virt 2>/dev/null || true)
    [ -z "$_virt" ] && _virt="none"
    if [ "$_virt" = "none" ]; then PLATFORM_KIND="metal"; else PLATFORM_KIND="vm"; fi
fi
PLATFORM_NAME="${PLATFORM_NAME:-$(hostname)}"

# --- Per-server thread tuning -------------------------------------------------
# SWEEP=1 measures each server at several thread counts and keeps its best.
# SWEEP=0 gives every server the same count (FIXED_THREADS, clamped to what
# each server accepts).
SWEEP="${SWEEP:-1}"
SWEEP_TIME="${SWEEP_TIME:-10}"
declare -A SRV_THREADS          # tuned thread count per server, filled by sweep_tuning()

# Keep these in step with setup_server.sh. Globbing the version out of /opt means
# a version bump in setup_server.sh does not silently leave this script
# benchmarking the older build that is still sitting on disk.
REDIS_DIR="${REDIS_DIR:-$(ls -d /opt/redis-*/ 2>/dev/null | sort -V | tail -1)}"
VALKEY_DIR="${VALKEY_DIR:-$(ls -d /opt/valkey-*/ 2>/dev/null | sort -V | tail -1)}"

HOTKV_BIN="${HOTKV_BIN:-/opt/hotkv/build/release/src/hotkv}"
REDIS_BIN="${REDIS_BIN:-${REDIS_DIR}src/redis-server}"
VALKEY_BIN="${VALKEY_BIN:-${VALKEY_DIR}src/valkey-server}"
DRAGONFLY_BIN="${DRAGONFLY_BIN:-/opt/dragonfly/build-opt/dragonfly}"
REDIS_CLI="${REDIS_CLI:-${REDIS_DIR}src/redis-cli}"

for _b in "$HOTKV_BIN" "$REDIS_BIN" "$VALKEY_BIN" "$REDIS_CLI"; do
    if [ ! -x "$_b" ]; then
        echo "ERROR: missing or not executable: $_b"
        echo "       Run setup_server.sh first, or override the *_BIN env vars."
        exit 1
    fi
done

# Dragonfly is multi-threaded and shared-nothing, like HotKV. Skipped if not built.
# Overridable so a run can target one comparison instead of the whole field:
#   SERVERS="hotkv dragonfly" ./full_bench.sh 1 256 30
# Redis and Valkey are single-execution-thread, so once their ratio is known it
# does not move; Dragonfly is the architectural peer and the one worth re-running
# after a change. Cloud time is not free - skipping two servers halves the bill.
SERVERS="${SERVERS:-hotkv redis valkey}"
if [ -z "${SERVERS##*dragonfly*}" ] || [ "${SERVERS:-}" = "hotkv redis valkey" ]; then
    if [ -x "$DRAGONFLY_BIN" ]; then
        case " $SERVERS " in
            *" dragonfly "*) : ;;                       # explicitly requested already
            *) SERVERS="$SERVERS dragonfly" ;;          # default field: append it
        esac
    else
        echo "NOTE: no dragonfly binary at $DRAGONFLY_BIN - skipping it this run."
        SERVERS="${SERVERS// dragonfly/}"
    fi
fi

# The HotKV-exclusive section (TAG.*, NEXPIRE/NTTL, 4KB, compression) is a
# HotKV-only showcase, not part of any comparison, and it costs several minutes
# of populate. SKIP_EXCLUSIVE=1 drops it when the question is "how do we compare".
SKIP_EXCLUSIVE="${SKIP_EXCLUSIVE:-0}"

# LPOP/RPOP are deliberately absent. A destructive read at 15-20M ops/sec drains
# any list depth that fits in RAM within the 10s window, so the figure degrades
# to nil-reply throughput rather than measuring the pop - the keyspace_drained
# check flagged exactly this in earlier runs. LPUSH/RPUSH already cover list
# write performance honestly. To measure sustained pops without draining you
# need a mixed push/pop workload (never net-negative); that is a different
# benchmark and can be added deliberately, not smuggled in under "LPOP".
COMMANDS="${COMMANDS:-SET GET MGET SETNX APPEND INCR LPUSH RPUSH SADD HSET MSET PING}"

# --- Detect server versions and source revisions ------------------------------
# A version string alone is not reproducible: "0.1.17" is whatever HEAD happened
# to be that afternoon. Record the commit SHA of every source tree we built from
# so a published number can be traced back to code someone else can check out.
# -c safe.directory='*' because the source trees under /opt are root-owned while
# the benchmark usually runs as a normal user. Without it git refuses with
# "dubious ownership", git_sha silently returns empty, and the run ships with no
# provenance at all - which is the one thing these fields exist to prevent.
git_sha() {
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir/.git" ] || { echo ""; return; }
    git -c safe.directory='*' -C "$dir" rev-parse HEAD 2>/dev/null || echo ""
}

# Fallback version when a binary does not self-report one. Dragonfly built from a
# shallow clone reports "dev-0000000" because git describe has no tags to find.
git_describe() {
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir/.git" ] || { echo ""; return; }
    git -c safe.directory='*' -C "$dir" describe --tags --always 2>/dev/null || echo ""
}

src_dir_of() {
    # Walk up from build/release/src/hotkv to the source root.
    local bin="$1" d
    d=$(dirname "$bin")
    while [ "$d" != "/" ] && [ -n "$d" ]; do
        [ -d "$d/.git" ] && { echo "$d"; return; }
        d=$(dirname "$d")
    done
    echo ""
}

detect_versions() {
    HOTKV_VER=$($HOTKV_BIN --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    REDIS_VER=$($REDIS_BIN --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    VALKEY_VER=$($VALKEY_BIN --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    DRAGONFLY_VER=""
    if [ -x "$DRAGONFLY_BIN" ]; then
        DRAGONFLY_VER=$($DRAGONFLY_BIN --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
        # A shallow clone leaves the binary self-reporting "dev-0000000". Fall back
        # to the checked-out tag, then to whatever the operator pinned in setup.
        if [ -z "$DRAGONFLY_VER" ]; then
            DRAGONFLY_VER=$(git_describe "$(src_dir_of "$DRAGONFLY_BIN")" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
        fi
        [ -z "$DRAGONFLY_VER" ] && DRAGONFLY_VER="${DRAGONFLY_VERSION:-}"
    fi

    # A source tarball has no .git, so a rig that ships HotKV that way would
    # publish a run with no commit at all. HOTKV_SHA_OVERRIDE carries the commit
    # the tarball was cut from; the git tree, when there is one, still wins.
    HOTKV_SHA=$(git_sha "$(src_dir_of "$HOTKV_BIN")")
    [ -z "$HOTKV_SHA" ] && HOTKV_SHA="${HOTKV_SHA_OVERRIDE:-}"
    REDIS_SHA=$(git_sha "$(src_dir_of "$REDIS_BIN")")
    VALKEY_SHA=$(git_sha "$(src_dir_of "$VALKEY_BIN")")
    DRAGONFLY_SHA=""
    [ -x "$DRAGONFLY_BIN" ] && DRAGONFLY_SHA=$(git_sha "$(src_dir_of "$DRAGONFLY_BIN")")
    MEMTIER_VER=$(memtier_benchmark --version 2>&1 | head -1 || echo "")

    # Provenance is the point of this whole section. If a server is going into the
    # published table with neither a version nor a commit, say so now rather than
    # discovering it in the JSON afterwards.
    for _s in $SERVERS; do
        case "$_s" in
            hotkv)     _v="$HOTKV_VER";     _sha="$HOTKV_SHA" ;;
            redis)     _v="$REDIS_VER";     _sha="$REDIS_SHA" ;;
            valkey)    _v="$VALKEY_VER";    _sha="$VALKEY_SHA" ;;
            dragonfly) _v="$DRAGONFLY_VER"; _sha="$DRAGONFLY_SHA" ;;
        esac
        if [ -z "$_v" ] && [ -z "$_sha" ]; then
            echo "WARNING: $_s has neither a version nor a commit SHA - results for it will not be traceable."
        fi
    done

    echo "Detected versions:"
    printf "  %-10s %-10s %s\n" "HotKV"     "$HOTKV_VER"     "${HOTKV_SHA:-(no git tree)}"
    printf "  %-10s %-10s %s\n" "Redis"     "$REDIS_VER"     "${REDIS_SHA:-(release tarball)}"
    printf "  %-10s %-10s %s\n" "Valkey"    "$VALKEY_VER"    "${VALKEY_SHA:-(release tarball)}"
    [ -x "$DRAGONFLY_BIN" ] && printf "  %-10s %-10s %s\n" "Dragonfly" "$DRAGONFLY_VER" "${DRAGONFLY_SHA:-(no git tree)}"
    printf "  %-10s %s\n" "memtier" "$MEMTIER_VER"
    echo "  Platform: $PLATFORM_NAME ($PLATFORM_KIND, ${TOTAL_CORES} cores)"
}
detect_versions

# --- Client machines ----------------------------------------------------------
# Each client sizes memtier to its own core count. The rig requires clients at
# least as large as the server; if a client is smaller, the run is client-bound
# and the numbers are a property of the client, not the server.
declare -A CLIENT_THREADS
ssh_client() {
    local host="$1"; shift
    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${host}" "$@"
}

if [ "$REMOTE_MODE" -eq 1 ]; then
    echo ""
    echo "Load generators (memtier runs remotely, server box is dedicated):"
    for c in $BENCH_CLIENTS; do
        ccores=$(ssh_client "$c" "nproc" 2>/dev/null || echo "")
        if [ -z "$ccores" ]; then
            echo "ERROR: cannot ssh to client $c (user=$SSH_USER key=$SSH_KEY)"
            exit 1
        fi
        if ! ssh_client "$c" "command -v memtier_benchmark" > /dev/null 2>&1; then
            echo "ERROR: memtier_benchmark not installed on client $c"
            exit 1
        fi
        CLIENT_THREADS[$c]=$ccores
        warn=""
        [ "$ccores" -lt "$TOTAL_CORES" ] && warn="  <-- WARNING: smaller than the server, will bottleneck the run"
        printf "  %-18s %s cores%s\n" "$c" "$ccores" "$warn"
    done
    echo "  Server dialled at: $SERVER_ADDR:$PORT"
else
    echo ""
    echo "NOTE: loopback mode - memtier shares this box with the server."
    echo "      Set BENCH_CLIENTS=\"host1 host2\" to drive load from dedicated machines."
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# --- Helper: wait for server to respond to PING ---
# The default wait is ~10 seconds. READY_TIMEOUT_S raises it for a rig where a
# server is merely slow to start (hundreds of threads) and would otherwise be
# skipped as "failed to start". Unset, the behaviour is exactly the original.
READY_TIMEOUT_S="${READY_TIMEOUT_S:-10}"
wait_ready() {
    local i tries=$(( READY_TIMEOUT_S * 4 ))
    for i in $(seq 1 "$tries"); do
        if $REDIS_CLI -p $PORT PING 2>/dev/null | grep -q PONG; then
            # Cooldown so IO threads settle and CPU stats stabilize before
            # we start timing.
            sleep 2
            return 0
        fi
        sleep 0.25
    done
    echo "ERROR: server did not become ready on port $PORT"
    return 1
}

# --- Helper: record resource usage across a call ------------------------------
# Samples CPU, memory and NIC counters before and after each benchmark so the
# report can answer "what did this cost?" rather than only "how fast was it?".
# Three things get measured:
#   CPU - /proc/<pid>/stat utime+stime. Divided by wall time this gives the
#         familiar top-style percentage (800% = 8 cores busy). Ops per CPU-second
#         is the efficiency number that survives comparison across machines.
#   MEM - /proc/<pid>/status VmRSS (resident at the end of the run) and VmHWM
#         (the high-water mark since the process started). VmHWM includes the
#         populate phase, which is intentional: that is the real peak footprint
#         the server needed to serve the workload.
#   NET - /sys/class/net/<iface>/statistics. Counts the whole box, not just this
#         process, which is fine because the benchmark runs nothing else and it
#         catches load the server's own PID would miss.
res_snapshot() {
    local pid="$1"
    local cpu=0
    [ -n "$pid" ] && cpu=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0)
    local s="/sys/class/net/$NET_IFACE/statistics"
    # Disk from /proc/<pid>/io: read_bytes / write_bytes are the bytes that
    # actually hit the block layer, so an in-memory store with persistence off
    # should read ~0 here - and the report showing that zero is the point. This
    # file is only readable by the process owner or root, so on an unreadable
    # sample the fields fall back to 0 rather than aborting.
    local dr=0 dw=0
    if [ -n "$pid" ] && [ -r "/proc/$pid/io" ]; then
        dr=$(awk '/^read_bytes:/{print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
        dw=$(awk '/^write_bytes:/{print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
    fi
    echo "${cpu:-0} $(cat "$s/rx_bytes" 2>/dev/null || echo 0) $(cat "$s/tx_bytes" 2>/dev/null || echo 0) $(cat "$s/rx_packets" 2>/dev/null || echo 0) $(cat "$s/tx_packets" 2>/dev/null || echo 0) ${dr:-0} ${dw:-0}"
}

# Emits: cpu_ms rx_bytes tx_bytes rx_packets tx_packets
# Emits: cpu_ms rx_bytes tx_bytes rx_packets tx_packets disk_read_bytes disk_write_bytes
res_delta() {
    local pid="$1"; shift
    local start=($1); shift
    local now=($(res_snapshot "$pid"))
    local hz; hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    echo "$(( (${now[0]} - ${start[0]}) * 1000 / hz )) $(( ${now[1]} - ${start[1]} )) $(( ${now[2]} - ${start[2]} )) $(( ${now[3]} - ${start[3]} )) $(( ${now[4]} - ${start[4]} )) $(( ${now[5]} - ${start[5]} )) $(( ${now[6]} - ${start[6]} ))"
}

# Peak (VmHWM) and current (VmRSS) resident memory in kB.
mem_snapshot() {
    local pid="$1"
    [ -z "$pid" ] && { echo "0 0"; return; }
    awk '/^VmRSS:/{r=$2} /^VmHWM:/{h=$2} END{print (r?r:0), (h?h:0)}' "/proc/$pid/status" 2>/dev/null || echo "0 0"
}

# --- Helper: get current server PID for the bound port ---
current_server_pid() {
    lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | head -1
}

# --- Helper: io-threads flags for the Redis family -----------------------------
# Redis and Valkey treat io-threads <= 2 as disabled, which is their single
# threaded default and often their fastest configuration. Newer releases folded
# io-threads-do-reads into the default and REMOVED the directive, and an unknown
# directive makes the server refuse to start - so probe it once per binary rather
# than assuming, and cache the answer.
declare -A DO_READS_SUPPORTED
probe_do_reads() {
    local srv="$1" bin="$2"
    [ -n "${DO_READS_SUPPORTED[$srv]:-}" ] && return
    local probe_log="/tmp/${srv}_probe.log"
    rm -f "$probe_log" 2>/dev/null || true
    if $bin --port 0 --io-threads 4 --io-threads-do-reads yes --save "" --appendonly no \
            --loglevel warning --test-memory 0 > "$probe_log" 2>&1 </dev/null; then
        DO_READS_SUPPORTED[$srv]=1
    elif grep -qiE "Bad directive|argument couldn't be parsed|Unknown|invalid" "$probe_log" 2>/dev/null; then
        DO_READS_SUPPORTED[$srv]=0
    else
        # Server started fine and we killed it, or the probe was inconclusive.
        DO_READS_SUPPORTED[$srv]=1
    fi
    rm -f "$probe_log" 2>/dev/null || true
}

redis_family_flags() {
    local srv="$1" nthreads="$2"
    if [ "$nthreads" -le 2 ]; then
        echo ""   # single-threaded default: their tuned sweet spot on many boxes
    elif [ "${DO_READS_SUPPORTED[$srv]:-1}" -eq 1 ]; then
        echo "--io-threads $nthreads --io-threads-do-reads yes"
    else
        echo "--io-threads $nthreads"
    fi
}

# --- Helper: start a server at a given thread count ----------------------------
# The exact argv used here is recorded (LAST_CMDLINE, then capture_server_config)
# and shipped in the artifact. "We did not cripple your server" is not a claim a
# reader should have to take on trust - the launch line and the effective config
# are the evidence, so they travel with the numbers.
declare -A SRV_CMDLINE
start_server() {
    local srv="$1"
    local nthreads="${2:-${SRV_THREADS[$srv]:-$BENCH_CORES}}"
    # Belt and braces: nothing reaches a server above its own hard ceiling.
    nthreads=$(clamp_threads "$srv" "$nthreads")
    sudo fuser -k ${PORT}/tcp 2>/dev/null || true
    wait_port_free || true
    rm -f /tmp/${srv}_bench.log 2>/dev/null; sudo rm -f /tmp/${srv}_bench.log 2>/dev/null
    local cmdline=""
    case "$srv" in
        hotkv)
            # --no-snapshot for the same reason Redis/Valkey get --save '' and
            # Dragonfly gets its snapshotting turned off: no server in this
            # comparison should be paying for persistence when the others are
            # not. HotKV had no way to express this until 0.1.23, so it was the
            # only server here still writing a snapshot on shutdown and reading
            # it back on the next start - which also silently carried a previous
            # run's dataset into the next one's "empty" baseline.
            # --protected-mode no as Redis/Valkey get it: with no password, a
            # server bound to 0.0.0.0 refuses the load boxes otherwise.
            cmdline="$HOTKV_BIN --port $PORT --bind $BIND_ADDR --threads $nthreads --no-snapshot --protected-mode no${MAXCLIENTS_ARG} --loglevel warning"
            ;;
        redis)
            probe_do_reads redis "$REDIS_BIN"
            cmdline="$REDIS_BIN --port $PORT --bind $BIND_ADDR --save  --appendonly no --protected-mode no${MAXCLIENTS_ARG} $(redis_family_flags redis "$nthreads") --loglevel warning"
            ;;
        valkey)
            probe_do_reads valkey "$VALKEY_BIN"
            cmdline="$VALKEY_BIN --port $PORT --bind $BIND_ADDR --save  --appendonly no --protected-mode no${MAXCLIENTS_ARG} $(redis_family_flags valkey "$nthreads") --loglevel warning"
            ;;
        dragonfly)
            # --dbfilename= disables snapshotting, matching --save "" on the others.
            # If io_uring is unavailable on the kernel, add --force_epoll.
            cmdline="$DRAGONFLY_BIN --port $PORT --bind $BIND_ADDR --proactor_threads=$nthreads --dbfilename= --noversion_check --logtostderr ${DRAGONFLY_EXTRA_FLAGS:-}"
            ;;
    esac
    SRV_CMDLINE[$srv]="$cmdline"
    case "$srv" in
        hotkv)
            nohup $HOTKV_BIN --port $PORT --bind $BIND_ADDR --threads $nthreads \
                --no-snapshot --protected-mode no${MAXCLIENTS_ARG} --loglevel warning > /tmp/${srv}_bench.log 2>&1 &
            ;;
        redis)
            nohup $REDIS_BIN --port $PORT --bind $BIND_ADDR --save "" --appendonly no \
                --protected-mode no${MAXCLIENTS_ARG} $(redis_family_flags redis "$nthreads") \
                --loglevel warning > /tmp/${srv}_bench.log 2>&1 &
            ;;
        valkey)
            nohup $VALKEY_BIN --port $PORT --bind $BIND_ADDR --save "" --appendonly no \
                --protected-mode no${MAXCLIENTS_ARG} $(redis_family_flags valkey "$nthreads") \
                --loglevel warning > /tmp/${srv}_bench.log 2>&1 &
            ;;
        dragonfly)
            nohup $DRAGONFLY_BIN --port $PORT --bind $BIND_ADDR \
                --proactor_threads=$nthreads --dbfilename= --noversion_check \
                --logtostderr ${DRAGONFLY_EXTRA_FLAGS:-} > /tmp/${srv}_bench.log 2>&1 &
            ;;
    esac
    wait_ready
}

# --- Helper: record the configuration a server is actually running under -------
# Asks the live server rather than trusting the launch line: defaults differ
# between Redis, Valkey and Dragonfly, and a directive that was silently ignored
# (or renamed upstream) would otherwise never show up. The settings picked are
# the ones that would make the comparison unfair if they differed between
# servers - a memory cap that triggers eviction, persistence stealing IO, a
# throttled connection backlog.
CONFIG_KEYS="maxmemory maxmemory-policy maxmemory-clients io-threads io-threads-do-reads appendonly save protected-mode tcp-backlog tcp-keepalive timeout hz dynamic-hz list-max-listpack-size hash-max-listpack-entries set-max-intset-entries activerehashing lazyfree-lazy-eviction lazyfree-lazy-expire repl-backlog-size databases"
# Only when the ceiling was changed: read it back so the report shows what ran.
[ -n "$MAXCLIENTS" ] && CONFIG_KEYS="maxclients $CONFIG_KEYS"
capture_server_config() {
    local srv="$1"
    local out="$OUTDIR/config_${srv}.json"
    [ -f "$out" ] && return 0   # identical every run; capture once
    local pid; pid=$(current_server_pid)
    {
        echo "{"
        echo "  \"launch_cmdline\": $(printf '%s' "${SRV_CMDLINE[$srv]:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),"
        echo "  \"threads_configured\": ${SRV_THREADS[$srv]:-0},"
        echo "  \"effective_config\": {"
        local first=1 k v
        for k in $CONFIG_KEYS; do
            # CONFIG GET returns an empty result for directives a given server
            # does not have; absent means "not a knob on this server", which is
            # itself worth recording, so skip rather than fake a value.
            v=$($REDIS_CLI -p $PORT CONFIG GET "$k" 2>/dev/null | sed -n '2p')
            [ -z "$v" ] && continue
            [ $first -eq 0 ] && echo ","
            first=0
            printf '    %s: %s' \
                "$(printf '%s' "$k" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
                "$(printf '%s' "$v" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
        done
        [ $first -eq 0 ] && echo ""
        echo "  },"
        # Total system memory is the real cap when maxmemory is 0 (unlimited),
        # which is how all four are run here.
        echo "  \"maxmemory_is_unlimited\": $([ "$($REDIS_CLI -p $PORT CONFIG GET maxmemory 2>/dev/null | sed -n '2p')" = "0" ] && echo true || echo false),"
        echo "  \"pid\": ${pid:-0}"
        echo "}"
    } > "$out" 2>/dev/null || true
}

# --- Helper: stop server ---
# Kill whatever holds the port, then WAIT for the kernel to actually release it.
# A fixed sleep here is not enough, and it fails in a way that costs a whole run:
# after a benchmark the dying server still holds a listening socket with
# thousands of connections, and the next server inherits an "Address already in
# use". Redis, Valkey and HotKV set SO_REUSEADDR so they bind over it and nobody
# noticed; Dragonfly does not, so it refused to start and `set -e` took the run
# down with it - after HotKV had already been measured and with no artifact
# written. Poll the port instead of guessing at a duration.
wait_port_free() {
    local i
    for i in $(seq 1 60); do
        # ss is authoritative about LISTEN sockets; fuser only knows processes.
        if ! ss -ltn 2>/dev/null | grep -qE "[:.]${PORT}\b"; then
            sleep 0.5   # let the listener's TIME_WAIT clear
            return 0
        fi
        sleep 0.25
    done
    echo "WARNING: port $PORT still held after ~15s; the next server may fail to bind."
    return 1
}

stop_server() {
    sudo fuser -k ${PORT}/tcp 2>/dev/null || true
    wait_port_free || true
}

# --- Helper: run a single memtier command benchmark ---
# --- Helper: drive load from the remote client machines ------------------------
# Every client runs memtier concurrently against the server and writes its own
# JSON; we pull them back and sum. Summing is the point: if two clients together
# beat one client, the single-client figure was measuring the client.
run_memtier_remote() {
    local srv="$1" run="$2" name="$3" outfile="$4"
    shift 4
    local partdir="$OUTDIR/parts/${srv}_run${run}_${name}"
    rm -rf "$partdir"; mkdir -p "$partdir"
    local remote_json="/tmp/mt_${srv}_${run}_${name}.json"

    # Quote args for the remote shell: they contain spaces (--command="SET __key__ __data__").
    local extra=""
    local a
    for a in "$@"; do extra+=" $(printf '%q' "$a")"; done

    local pids=()
    local c
    for c in $BENCH_CLIENTS; do
        local ct=${CLIENT_THREADS[$c]:-$THREADS}
        # ulimit -n on the client is the quiet killer here: a default 1024 soft
        # limit against -t 60 -c 50 (3,000 sockets) makes memtier fail to open
        # most of its connections and report a fraction of the load it was asked
        # for - with no error anyone would notice, because stderr goes to
        # /dev/null. The ssh session gets its own limits, so raise it inside the
        # remote command rather than relying on the login shell.
        # CLIENT_CPU markers bracket the run so the client's own CPU cost can be
        # compared with the server's: if the load generator is working harder
        # than the thing it is measuring, the number is the client's, not the
        # server's.
        ssh_client "$c" "ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true; \
            rm -f $remote_json ${remote_json}.res; \
            _c0=\$(awk '/^cpu /{print \$2+\$3+\$4+\$6+\$7+\$8}' /proc/stat); _t0=\$(date +%s%N); \
            memtier_benchmark -s $SERVER_ADDR -p $PORT \
            -t $ct -c $CLIENTS --pipeline $PIPELINE -d $DATASIZE --test-time=$TEST_TIME \
            $KEYSPACE_ARGS $SEED_ARGS \
            --hide-histogram --json-out-file=$remote_json $extra > /dev/null 2>&1; \
            _c1=\$(awk '/^cpu /{print \$2+\$3+\$4+\$6+\$7+\$8}' /proc/stat); _t1=\$(date +%s%N); \
            echo \"\$(( (_c1-_c0) * 10 )) \$(( (_t1-_t0)/1000000 )) \$(nproc)\" > ${remote_json}.res" > /dev/null 2>&1 &
        pids+=($!)
    done
    local p
    for p in "${pids[@]}"; do wait "$p" || true; done

    for c in $BENCH_CLIENTS; do
        scp $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${c}:${remote_json}" \
            "$partdir/${c}.json" > /dev/null 2>&1 || true
        scp $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${c}:${remote_json}.res" \
            "$partdir/${c}.res" > /dev/null 2>&1 || true
    done

    # Merge parts into one memtier-shaped JSON so everything downstream is unchanged.
    python3 - "$partdir" "$outfile" <<'MERGEEOF'
import json, os, sys, glob
partdir, outfile = sys.argv[1], sys.argv[2]
parts = []
for f in sorted(glob.glob(os.path.join(partdir, "*.json"))):
    try:
        with open(f) as fh:
            parts.append((os.path.basename(f)[:-5], json.load(fh)))
    except Exception:
        pass
if not parts:
    sys.exit(0)

tot_ops = 0.0
wsum_lat = 0.0
wsum_p50 = 0.0
max_p99 = 0.0
tot_hits = 0.0
tot_misses = 0.0
per_client = {}
for host, d in parts:
    t = d.get("ALL STATS", {}).get("Totals", {}) or {}
    ops = t.get("Ops/sec", 0) or 0
    lat = t.get("Average Latency", 0) or 0
    pl = t.get("Percentile Latencies", {}) or {}
    p50 = pl.get("p50.00") or pl.get("p50") or 0
    p99 = pl.get("p99.00") or pl.get("p99") or 0
    tot_ops += ops
    wsum_lat += lat * ops
    wsum_p50 += p50 * ops
    max_p99 = max(max_p99, p99)
    per_client[host] = {"ops": ops, "p50_ms": p50, "p99_ms": p99}
    # Hit rate is the proof that a read workload read anything. A GET run at a
    # low hit rate is measuring the miss path: nil costs no payload, so it
    # inflates ops/sec and understates bytes on the wire.
    g = d.get("ALL STATS", {}).get("Gets", {}) or {}
    hits, misses = g.get("Hits/sec", 0) or 0, g.get("Misses/sec", 0) or 0
    if hits or misses:
        tot_hits += hits
        tot_misses += misses
    # Whole-box CPU on the load generator. A client pinned near 100% while the
    # server idles means the ceiling being measured belongs to memtier.
    resf = os.path.join(partdir, host + ".res")
    if os.path.exists(resf):
        try:
            cpu_ms, wall_ms, ncores = open(resf).read().split()
            cpu_ms, wall_ms, ncores = int(cpu_ms), max(int(wall_ms), 1), int(ncores)
            per_client[host].update({
                "client_cpu_pct": (cpu_ms / wall_ms) * 100.0,
                "client_cores": ncores,
                "client_cpu_saturation_pct": (cpu_ms / wall_ms) * 100.0 / ncores,
            })
        except Exception:
            pass

sat = [c["client_cpu_saturation_pct"] for c in per_client.values()
       if c.get("client_cpu_saturation_pct") is not None]
merged = {
    "ALL STATS": {"Totals": {
        "Ops/sec": tot_ops,
        # Latency is averaged across clients weighted by throughput; p99 is the
        # worst client, which is the honest read for a tail number.
        "Average Latency": (wsum_lat / tot_ops) if tot_ops else 0,
        "Percentile Latencies": {
            "p50.00": (wsum_p50 / tot_ops) if tot_ops else 0,
            "p99.00": max_p99,
        },
    }},
    "clients_detail": per_client,
    "client_count": len(parts),
    "client_cpu_saturation_pct": (sum(sat) / len(sat)) if sat else None,
    "hits_per_sec": tot_hits,
    "misses_per_sec": tot_misses,
    "hit_rate_pct": (tot_hits / (tot_hits + tot_misses) * 100.0)
                    if (tot_hits + tot_misses) else None,
}
with open(outfile, "w") as fh:
    json.dump(merged, fh)
MERGEEOF
}

run_cmd() {
    local srv="$1"
    local run="$2"
    local name="$3"
    shift 3
    local outfile="$OUTDIR/${srv}_run${run}_${name}.json"
    local pid; pid=$(current_server_pid)
    # Keyspace size across the run. A destructive read (LPOP/RPOP) that empties
    # the store is no longer measuring the operation it names - it is measuring
    # how fast the server can say "nil". Record the before/after so the
    # artifact carries the evidence.
    local keys_before; keys_before=$($REDIS_CLI -p $PORT DBSIZE 2>/dev/null | tr -dc '0-9')
    local res_start; res_start=$(res_snapshot "$pid")
    local wall_start; wall_start=$(date +%s%N)
    if [ "$REMOTE_MODE" -eq 1 ]; then
        run_memtier_remote "$srv" "$run" "$name" "$outfile" "$@"
    else
        memtier_benchmark -s $SERVER_ADDR -p $PORT -t $THREADS -c $CLIENTS \
            --pipeline $PIPELINE -d $DATASIZE --test-time=$TEST_TIME \
            $KEYSPACE_ARGS $SEED_ARGS \
            --hide-histogram --json-out-file="$outfile" "$@" > /dev/null 2>&1
    fi
    local wall_end; wall_end=$(date +%s%N)
    local res; res=($(res_delta "$pid" "$res_start"))
    local mem; mem=($(mem_snapshot "$pid"))
    local keys_after; keys_after=$($REDIS_CLI -p $PORT DBSIZE 2>/dev/null | tr -dc '0-9')
    local wall_ms=$(( (wall_end - wall_start) / 1000000 ))
    # Attach the resource picture to the memtier JSON so every downstream
    # consumer sees cost and speed together and cannot quote one without the
    # other.
    CMD_NAME="$name" CPU_MS="${res[0]}" WALL_MS="$wall_ms" \
    RX_B="${res[1]}" TX_B="${res[2]}" RX_P="${res[3]}" TX_P="${res[4]}" \
    DISK_R="${res[5]:-0}" DISK_W="${res[6]:-0}" \
    RSS_KB="${mem[0]}" HWM_KB="${mem[1]}" LINK_GBPS="$NET_LINK_GBPS" \
    NTHREADS="${SRV_THREADS[$srv]:-0}" OUTFILE="$outfile" \
    KEYS_BEFORE="${keys_before:-0}" KEYS_AFTER="${keys_after:-0}" \
    python3 <<'RESEOF'
import json, os, sys

outfile = os.environ["OUTFILE"]
cpu_ms  = int(os.environ["CPU_MS"]); wall_ms = max(int(os.environ["WALL_MS"]), 1)
rx_b    = int(os.environ["RX_B"]);   tx_b    = int(os.environ["TX_B"])
rx_p    = int(os.environ["RX_P"]);   tx_p    = int(os.environ["TX_P"])
disk_r  = int(os.environ.get("DISK_R", 0)); disk_w = int(os.environ.get("DISK_W", 0))
link    = float(os.environ["LINK_GBPS"])
try:
    with open(outfile) as f:
        d = json.load(f)
    ops = d["ALL STATS"]["Totals"]["Ops/sec"]
    secs = wall_ms / 1000.0
    cpu_pct = (cpu_ms / wall_ms) * 100.0
    total_bits = (rx_b + tx_b) * 8.0
    gbps = total_bits / secs / 1e9 if secs else 0.0
    res = {
        # CPU
        "cpu_ms": cpu_ms,
        "wall_ms": wall_ms,
        "cpu_pct": cpu_pct,
        "cores_busy": cpu_pct / 100.0,
        "threads_configured": int(os.environ["NTHREADS"]),
        # The number that survives moving to another machine: how much work each
        # second of CPU bought. Zero CPU time means the sample was too short to
        # measure, not infinite efficiency, so leave it null.
        "ops_per_cpu_sec": (ops / (cpu_ms / 1000.0)) if cpu_ms > 0 else None,
        # Memory
        "rss_mb": int(os.environ["RSS_KB"]) / 1024.0,
        "peak_rss_mb": int(os.environ["HWM_KB"]) / 1024.0,
        # Disk - block-layer bytes for the server process during the command.
        # For an in-memory store with persistence off these are ~0, and showing
        # that zero is the point: it proves nothing was spilling to disk.
        "disk_read_mb": disk_r / 1048576.0,
        "disk_write_mb": disk_w / 1048576.0,
        # Network - host-wide counters, server box
        "rx_bytes": rx_b, "tx_bytes": tx_b,
        "rx_packets": rx_p, "tx_packets": tx_p,
        "gbps": gbps,
        "packets_per_sec": (rx_p + tx_p) / secs if secs else 0.0,
        "bytes_per_op": ((rx_b + tx_b) / (ops * secs)) if ops and secs else 0.0,
        # Share of the advertised link. Anything near 100 means the result is a
        # measurement of the cable, not of the server.
        "link_gbps": link or None,
        "link_util_pct": (gbps / link * 100.0) if link else None,
    }
    d["server_resources"] = res
    # Keyspace integrity. A read workload that ends with an empty store spent
    # most of the run being answered with nil.
    kb, ka = int(os.environ["KEYS_BEFORE"]), int(os.environ["KEYS_AFTER"])
    d["keyspace"] = {
        "keys_before": kb,
        "keys_after": ka,
        "drained": bool(kb > 0 and ka == 0),
    }
    # Kept under the old key as well: compare.py and the April results readers
    # both expect server_cpu.cpu_pct to exist.
    d["server_cpu"] = {"cpu_ms": cpu_ms, "wall_ms": wall_ms, "cpu_pct": cpu_pct}
    with open(outfile, "w") as f:
        json.dump(d, f)
    print(f"{ops:.0f}")
except Exception:
    print("0", file=sys.stderr)
    print("0")
RESEOF
}

# --- Pre-populate keys for a specific command ---
# Each command type needs its own data type to avoid WRONGTYPE errors and to
# ensure INCR operates on integer values, not random binary data.
#
# Every populate below walks $KEY_MINIMUM..$KEY_MAXIMUM exactly once:
#   --command-key-pattern=P  each client takes a disjoint slice of the range
#   --requests=allkeys       cover the whole slice, no repeats, no gaps
# so the range the benchmark then reads from is fully populated and the hit rate
# is ~100% by construction instead of an accident of the PRNG. The old version
# fired a fixed 50,000 random writes into a 10,000,000-wide range and left 99.5%
# of it empty. Parallelised (-t/-c) because filling 5M keys single-threaded at
# ~200K ops/sec took ~25s per command per run.
POPULATE_THREADS="${POPULATE_THREADS:-8}"
POPULATE_CLIENTS="${POPULATE_CLIENTS:-10}"

# --requests is PER CLIENT, and "allkeys" resolves to the size of the whole key
# range - per client. With 80 clients that is 80 x 5M = 400M writes to fill 5M
# keys: each client wraps its subrange ~80 times, taking 85s per populate. At
# 14 commands x 3 runs x 4 servers that is over four hours of pure setup.
# The P pattern already hands each client a disjoint slice, so each one only
# needs range/clients requests to cover its slice exactly once. Ceiling-divide
# so the last slice is not left short.
populate_requests_per_client() {
    local total_clients=$(( POPULATE_THREADS * POPULATE_CLIENTS ))
    local range=$(( KEY_MAXIMUM - KEY_MINIMUM + 1 ))
    echo $(( (range + total_clients - 1) / total_clients ))
}

populate() {
    local cmd="$1"
    local spec=""
    case "$cmd" in
        SET|GET|SETNX|APPEND|MGET|MSET|PING) spec="SET __key__ __data__" ;;
        INCR)                                spec="SET __key__ 0" ;;   # INCR needs an integer
        LPUSH|RPUSH|LPOP|RPOP)               spec="LPUSH __key__ __data__" ;;
        SADD)                                spec="SADD __key__ __data__" ;;
        HSET)                                spec="HSET __key__ field __data__" ;;
        *) return 0 ;;
    esac
    local dflag="-d $DATASIZE"
    [ "$cmd" = "INCR" ] && dflag=""   # value is the literal 0, not random data
    local rpc; rpc=$(populate_requests_per_client)
    echo "  Pre-populating ${KEY_MAXIMUM} keys for ${cmd}..."
    memtier_benchmark -s 127.0.0.1 -p $PORT \
        -t $POPULATE_THREADS -c $POPULATE_CLIENTS --pipeline 100 \
        $dflag $KEYSPACE_ARGS --requests=$rpc --hide-histogram \
        --command="$spec" --command-key-pattern=P > /dev/null 2>&1
}

# --- Per-server thread ceilings ------------------------------------------------
# These are NOT the same across servers and getting them wrong is not a tuning
# nicety: Redis hard-caps io-threads at IO_THREADS_MAX_NUM (128) and treats
# anything higher as a FATAL config error, so the old "give everyone $BENCH_CORES"
# made Redis refuse to boot outright on a box with >128 usable cores. Valkey's
# constant is 256. Read the real value out of the source we actually built so
# this keeps working when upstream changes it.
detect_io_cap() {
    local dir="$1" default="$2" v
    [ -n "$dir" ] && [ -d "$dir" ] || { echo "$default"; return; }
    v=$(grep -rhoE '#define[[:space:]]+IO_THREADS_MAX_NUM[[:space:]]+[0-9]+' "$dir"src/*.h 2>/dev/null \
        | grep -oE '[0-9]+$' | head -1)
    echo "${v:-$default}"
}
REDIS_MAX_THREADS="${REDIS_MAX_THREADS:-$(detect_io_cap "$REDIS_DIR" 128)}"
VALKEY_MAX_THREADS="${VALKEY_MAX_THREADS:-$(detect_io_cap "$VALKEY_DIR" 256)}"

max_threads_for() {
    case "$1" in
        redis)  echo "$REDIS_MAX_THREADS" ;;
        valkey) echo "$VALKEY_MAX_THREADS" ;;
        *)      echo "$TOTAL_CORES" ;;   # hotkv and dragonfly take the whole box
    esac
}

clamp_threads() {
    local srv="$1" n="$2" cap
    cap=$(max_threads_for "$srv")
    [ "$cap" -gt "$TOTAL_CORES" ] && cap=$TOTAL_CORES
    [ "$n" -gt "$cap" ] && n=$cap
    echo "$n"
}

# --- Tuning sweep --------------------------------------------------------------
# Candidate thread counts: powers of two up to this server's ceiling, plus the
# "give it everything" points, plus the ceiling itself (the most this server is
# allowed to take, which it is owed a fair test at).
thread_candidates() {
    local srv="$1" cap n=1 out="" extra
    cap=$(max_threads_for "$srv")
    [ "$cap" -gt "$TOTAL_CORES" ] && cap=$TOTAL_CORES
    while [ "$n" -le "$cap" ]; do
        out="$out $n"
        n=$(( n * 2 ))
    done
    for extra in "$BENCH_CORES" "$TOTAL_CORES" "$cap"; do
        [ "$extra" -le "$cap" ] && out="$out $extra"
    done
    echo "$out" | tr ' ' '\n' | grep -vE '^$' | sort -n -u | tr '\n' ' '
}

SWEEP_TSV="$OUTDIR/sweep.tsv"

sweep_tuning() {
    local saved_time=$TEST_TIME
    TEST_TIME=$SWEEP_TIME

    echo "============================================================"
    echo "  Tuning sweep - each server gets its own best thread count"
    echo "  Scored on SET+GET at ${DATASIZE}B, ${SWEEP_TIME}s per point"
    echo "  Ceilings: redis=${REDIS_MAX_THREADS} valkey=${VALKEY_MAX_THREADS} others=${TOTAL_CORES}"
    echo "============================================================"
    echo ""
    : > "$SWEEP_TSV"

    local srv n ops_set ops_get total best_ops best_n cands
    for srv in $SERVERS; do
        cands=$(thread_candidates "$srv")
        echo "=== sweeping $srv (candidates: $cands) ==="
        best_ops=0
        best_n=$(clamp_threads "$srv" "$BENCH_CORES")
        for n in $cands; do
            if ! start_server "$srv" "$n" > /dev/null 2>&1; then
                printf "    %-4s threads: FAILED to start\n" "$n"
                continue
            fi
            $REDIS_CLI -h $CLI_HOST -p $PORT FLUSHALL > /dev/null 2>&1
            populate SET > /dev/null 2>&1
            ops_set=$(run_cmd "sweep_${srv}" 0 "SET_n${n}" --command="SET __key__ __data__" --command-key-pattern=R)
            ops_get=$(run_cmd "sweep_${srv}" 0 "GET_n${n}" --command="GET __key__" --command-key-pattern=R)
            stop_server
            ops_set=${ops_set:-0}; ops_get=${ops_get:-0}
            total=$(( ${ops_set%.*} + ${ops_get%.*} ))
            printf "%s\t%s\t%s\t%s\t%s\n" "$srv" "$n" "$ops_set" "$ops_get" "$total" >> "$SWEEP_TSV"
            printf "    %-4s threads:  SET %'12d   GET %'12d\n" "$n" "${ops_set%.*}" "${ops_get%.*}"
            if [ "$total" -gt "$best_ops" ]; then best_ops=$total; best_n=$n; fi
        done
        SRV_THREADS[$srv]=$best_n
        echo "    -> best: $best_n threads"
        echo ""
    done

    TEST_TIME=$saved_time

    echo "------------------------------------------------------------"
    echo "  Tuned thread counts (used for the comparison below):"
    for srv in $SERVERS; do
        printf "    %-10s %s\n" "$srv" "${SRV_THREADS[$srv]}"
    done
    echo "------------------------------------------------------------"
    echo ""
}

if [ "$SWEEP" = "1" ]; then
    sweep_tuning
else
    # No sweep: one number for everyone (the published runs give every server
    # all the cores), still clamped to each server's hard ceiling so Redis does
    # not simply refuse to start.
    for srv in $SERVERS; do
        SRV_THREADS[$srv]=$(clamp_threads "$srv" "${FIXED_THREADS:-$BENCH_CORES}")
    done
    echo "NOTE: SWEEP=0 - every server runs ${FIXED_THREADS:-$BENCH_CORES} threads (clamped to each server's maximum)."
    echo "      Redis and Valkey execute commands on one thread; their threads here are I/O threads,"
    echo "      and they may do better with fewer of them (SWEEP=1 finds each server's best)."
    echo ""
fi

echo "============================================================"
echo "  Full Isolated Benchmark: $RUNS runs per server"
if [ "$REMOTE_MODE" -eq 1 ]; then
    _ct=""
    for c in $BENCH_CLIENTS; do _ct="$_ct ${CLIENT_THREADS[$c]:-$THREADS}"; done
    echo "  Memtier: Threads per client box =${_ct}  Clients=$CLIENTS  Pipeline=$PIPELINE  TestTime=${TEST_TIME}s"
else
    echo "  Memtier: Threads=$THREADS  Clients=$CLIENTS  Pipeline=$PIPELINE  TestTime=${TEST_TIME}s"
fi
echo "  Data size: ${DATASIZE} bytes"
echo "  Platform: $PLATFORM_NAME ($PLATFORM_KIND)  CPU cores=$TOTAL_CORES"
if [ "$REMOTE_MODE" -eq 1 ]; then
    echo "  Load: $(echo $BENCH_CLIENTS | wc -w) remote client machine(s) -> $SERVER_ADDR"
else
    echo "  Load: loopback (client shares this box with the server)"
fi
echo -n "  Server threads:"
for srv in $SERVERS; do echo -n " $srv=${SRV_THREADS[$srv]}"; done
echo ""
echo "============================================================"
echo ""

# --- Main benchmark loop ---
MEASURED_SERVERS=""
FAILED_SERVERS=""
for srv in $SERVERS; do
    echo "=== $srv ==="
    for run in $(seq 1 $RUNS); do
        echo "  --- Run $run/$RUNS ---"
        # One server failing to boot must not destroy the whole run. Under set -e
        # it used to: Dragonfly hit "Address already in use" after HotKV had been
        # fully measured, the script died, and NO artifact was written - hours of
        # cloud time for nothing. Skip the server, record that it was skipped,
        # and still emit results for everything that did run.
        if ! start_server "$srv"; then
            echo "  ERROR: $srv failed to start - skipping it. See /tmp/${srv}_bench.log"
            tail -3 "/tmp/${srv}_bench.log" 2>/dev/null | sed 's/^/    | /'
            FAILED_SERVERS="$FAILED_SERVERS $srv"
            stop_server
            continue 2
        fi
        capture_server_config "$srv"

        for cmd in $COMMANDS; do
            # Clean slate before each command to prevent data accumulation
            # from previous commands inflating the store and skewing results.
            $REDIS_CLI -p $PORT FLUSHALL > /dev/null 2>&1
            populate "$cmd"

            case "$cmd" in
                SET)   ops=$(run_cmd "$srv" "$run" SET   --command="SET __key__ __data__" --command-key-pattern=R) ;;
                GET)   ops=$(run_cmd "$srv" "$run" GET   --command="GET __key__" --command-key-pattern=R) ;;
                MGET)  ops=$(run_cmd "$srv" "$run" MGET  --command="MGET __key__ __key__ __key__ __key__ __key__ __key__ __key__ __key__" --command-key-pattern=R) ;;
                SETNX) ops=$(run_cmd "$srv" "$run" SETNX --command="SETNX __key__ __data__" --command-key-pattern=R) ;;
                APPEND) ops=$(run_cmd "$srv" "$run" APPEND --command="APPEND __key__ __data__" --command-key-pattern=R) ;;
                INCR)  ops=$(run_cmd "$srv" "$run" INCR  --command="INCR __key__" --command-key-pattern=R) ;;
                LPUSH) ops=$(run_cmd "$srv" "$run" LPUSH --command="LPUSH __key__ __data__" --command-key-pattern=R) ;;
                RPUSH) ops=$(run_cmd "$srv" "$run" RPUSH --command="RPUSH __key__ __data__" --command-key-pattern=R) ;;
                LPOP)  ops=$(run_cmd "$srv" "$run" LPOP  --command="LPOP __key__" --command-key-pattern=R) ;;
                RPOP)  ops=$(run_cmd "$srv" "$run" RPOP  --command="RPOP __key__" --command-key-pattern=R) ;;
                SADD)  ops=$(run_cmd "$srv" "$run" SADD  --command="SADD __key__ __data__" --command-key-pattern=R) ;;
                HSET)  ops=$(run_cmd "$srv" "$run" HSET  --command="HSET __key__ __data__ __data__" --command-key-pattern=R) ;;
                MSET)  ops=$(run_cmd "$srv" "$run" MSET  --command="MSET __key__ __data__ __key__ __data__ __key__ __data__ __key__ __data__" --command-key-pattern=R) ;;
                PING)  ops=$(run_cmd "$srv" "$run" PING  --command="PING") ;;
            esac
            printf "    %-10s %s ops/sec\n" "$cmd" "$ops"
        done

        stop_server
    done
    MEASURED_SERVERS="$MEASURED_SERVERS $srv"
    echo ""
done

if [ -n "$FAILED_SERVERS" ]; then
    echo "!! These servers never started and are ABSENT from the results:$FAILED_SERVERS"
    echo "   A missing server is not a slow server - do not read its absence as a win."
    echo ""
    # Keep the artifact honest: only claim to have measured what actually ran.
    SERVERS="$(echo $MEASURED_SERVERS | xargs)"
fi

# --- Assemble results into compare.py-compatible JSON ---
echo "Assembling results..."

# --- HotKV Exclusive Feature Benchmarks ---
if [ "$SKIP_EXCLUSIVE" = "1" ]; then
    echo ""
    echo "Skipping HotKV exclusive features (SKIP_EXCLUSIVE=1)."
fi
if [ "$SKIP_EXCLUSIVE" != "1" ]; then
echo ""
echo "============================================================"
echo "  HotKV Exclusive Features Benchmark"
echo "============================================================"
echo ""

HOTKV_EXCLUSIVE_CMDS="TAG.SET TAG.GET TAG.COUNT NEXPIRE NTTL SET_4K GET_4K SET_4K_COMP GET_4K_COMP"

# --- Run without compression (baseline large values) ---
echo "=== HotKV (no compression, 4KB values) ==="
for run in $(seq 1 $RUNS); do
    echo "  --- Run $run/$RUNS ---"
    start_server hotkv

    # Tag commands: need existing keys
    $REDIS_CLI -p $PORT FLUSHALL > /dev/null 2>&1
    populate SET
    ops=$(run_cmd hotkv_exclusive "$run" TAG.SET --command="TAG.SET __key__ bench_tag_a bench_tag_b" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "TAG.SET" "$ops"

    $REDIS_CLI -p $PORT FLUSHALL > /dev/null 2>&1
    populate SET
    ops=$(run_cmd hotkv_exclusive "$run" TAG.GET --command="TAG.GET __key__" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "TAG.GET" "$ops"

    $REDIS_CLI -p $PORT FLUSHALL > /dev/null 2>&1
    populate SET
    ops=$(run_cmd hotkv_exclusive "$run" TAG.COUNT --command="TAG.COUNT __key__" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "TAG.COUNT" "$ops"

    # Nanosecond TTL
    $REDIS_CLI -p $PORT FLUSHALL > /dev/null 2>&1
    populate SET
    ops=$(run_cmd hotkv_exclusive "$run" NEXPIRE --command="NEXPIRE __key__ 60000000000" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "NEXPIRE" "$ops"

    $REDIS_CLI -p $PORT FLUSHALL > /dev/null 2>&1
    populate SET
    ops=$(run_cmd hotkv_exclusive "$run" NTTL --command="NTTL __key__" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "NTTL" "$ops"

    # Large value SET/GET without compression (baseline)
    # Populate with 4KB values (NOT $DATASIZE) so GET_4K measures real 4KB reads.
    $REDIS_CLI -p $PORT FLUSHALL > /dev/null 2>&1
    memtier_benchmark -s 127.0.0.1 -p $PORT -t $POPULATE_THREADS -c $POPULATE_CLIENTS --pipeline 100 \
        -d 4096 $KEYSPACE_ARGS_4K --requests=allkeys --hide-histogram \
        --command="SET __key__ __data__" --command-key-pattern=P > /dev/null 2>&1
    ops=$(run_cmd hotkv_exclusive "$run" SET_4K -d 4096 $KEYSPACE_ARGS_4K --command="SET __key__ __data__" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "SET (4KB)" "$ops"

    # Same pre-populated 4KB keys - do NOT flushall, or GET would miss.
    ops=$(run_cmd hotkv_exclusive "$run" GET_4K -d 4096 $KEYSPACE_ARGS_4K --command="GET __key__" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "GET (4KB)" "$ops"

    stop_server
done

# --- Run with compression enabled (4KB values) ---
echo ""
echo "=== HotKV (compression ON, 4KB values, threshold 512) ==="
COMP_CONF="/tmp/hotkv_bench_compression.conf"
sudo rm -f "$COMP_CONF" 2>/dev/null
sudo tee "$COMP_CONF" > /dev/null <<CONFEOF
bind $BIND_ADDR
port $PORT
threads ${SRV_THREADS[hotkv]}
loglevel warning
compression-enabled yes
compression-threshold 512
CONFEOF
# Opt-in only; with MAXCLIENTS unset the file is exactly the original.
[ -n "$MAXCLIENTS" ] && echo "maxclients $MAXCLIENTS" | sudo tee -a "$COMP_CONF" > /dev/null

for run in $(seq 1 $RUNS); do
    echo "  --- Run $run/$RUNS ---"
    sudo fuser -k ${PORT}/tcp 2>/dev/null || true
    sleep 0.5
    rm -f /tmp/hotkv_comp_bench.log 2>/dev/null; sudo rm -f /tmp/hotkv_comp_bench.log 2>/dev/null
    nohup $HOTKV_BIN --config "$COMP_CONF" --no-snapshot > /tmp/hotkv_comp_bench.log 2>&1 &
    wait_ready

    # Populate with 4KB values
    memtier_benchmark -s 127.0.0.1 -p $PORT -t $POPULATE_THREADS -c $POPULATE_CLIENTS --pipeline 100 \
        -d 4096 $KEYSPACE_ARGS_4K --requests=allkeys --hide-histogram \
        --command="SET __key__ __data__" --command-key-pattern=P > /dev/null 2>&1

    ops=$(run_cmd hotkv_compressed "$run" SET_4K_COMP -d 4096 $KEYSPACE_ARGS_4K --command="SET __key__ __data__" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "SET (4KB+comp)" "$ops"

    ops=$(run_cmd hotkv_compressed "$run" GET_4K_COMP -d 4096 $KEYSPACE_ARGS_4K --command="GET __key__" --command-key-pattern=R)
    printf "    %-14s %s ops/sec\n" "GET (4KB+comp)" "$ops"

    stop_server
done

fi  # SKIP_EXCLUSIVE

echo ""

# Provenance travels via the environment rather than a dozen positional args.
export PLATFORM_NAME PLATFORM_KIND SERVERS REMOTE_MODE BENCH_CLIENTS SERVER_ADDR
export HOTKV_VER REDIS_VER VALKEY_VER DRAGONFLY_VER
export HOTKV_SHA REDIS_SHA VALKEY_SHA DRAGONFLY_SHA MEMTIER_VER
export SWEEP SWEEP_TSV
export NET_IFACE NET_LINK_GBPS TEST_TIME
export KEY_MINIMUM KEY_MAXIMUM SEED_ARGS MAXCLIENTS
TUNED=""
for srv in $SERVERS; do TUNED="$TUNED $srv=${SRV_THREADS[$srv]}"; done
export TUNED_THREADS="$TUNED"
# In remote mode each client box runs as many memtier threads as it has cores
# (run_memtier_remote()), not the server-derived $THREADS.
CLIENT_THREADS_SUMMARY=""
if [ "$REMOTE_MODE" -eq 1 ]; then
    for c in $BENCH_CLIENTS; do CLIENT_THREADS_SUMMARY="$CLIENT_THREADS_SUMMARY $c=${CLIENT_THREADS[$c]:-$THREADS}"; done
fi
export CLIENT_THREADS_SUMMARY

python3 - "$OUTDIR" "$RUNS" "$DATASIZE" "$THREADS" "$PIPELINE" "$CLIENTS" <<'PYEOF'
import json, sys, os, re
from statistics import median, mean, stdev
from datetime import datetime, timezone

outdir = sys.argv[1]
num_runs = int(sys.argv[2])
datasize = int(sys.argv[3])
bench_threads = int(sys.argv[4])
pipeline_val = int(sys.argv[5])
clients_val = int(sys.argv[6])

env = os.environ.get
# The memtier threads each client box ran (remote mode): its own core count.
client_threads = {}
for item in (env("CLIENT_THREADS_SUMMARY") or "").split():
    host, _, n = item.partition("=")
    if n.isdigit():
        client_threads[host] = int(n)
if client_threads:
    bench_threads = min(client_threads.values())
servers_run = (env("SERVERS") or "hotkv redis valkey").split()

hotkv_ver = env("HOTKV_VER") or ""
redis_ver = env("REDIS_VER") or ""
valkey_ver = env("VALKEY_VER") or ""
dragonfly_ver = env("DRAGONFLY_VER") or ""

# Tuned thread count per server, e.g. "hotkv=92 redis=8 valkey=8 dragonfly=92".
tuned_threads = {}
for tok in (env("TUNED_THREADS") or "").split():
    if "=" in tok:
        k, v = tok.split("=", 1)
        try:
            tuned_threads[k] = int(v)
        except ValueError:
            pass

# Built from what actually ran, not from a hardcoded list. Naming a server that
# was never started puts an empty column in the report, which reads as "measured
# and scored nothing" rather than "not in this run" - the most flattering
# possible misreading of a competitor's absence, and the one most likely to be
# quoted back at us.
_KNOWN_SERVERS = {
    "hotkv": "HotKV",
    "redis": "Redis",
    "valkey": "Valkey",
    "dragonfly": "Dragonfly",
}
server_map = {k: v for k, v in _KNOWN_SERVERS.items() if k in servers_run}

commands = ["SET", "GET", "MGET", "SETNX", "APPEND", "INCR", "LPUSH", "RPUSH", "LPOP", "RPOP", "SADD", "HSET", "MSET", "PING"]

# Collect per-run results.
# We track two parallel structures:
#   all_runs_detail: full per-run data (ops/lat/cpu) for the new summary
#   all_runs:        scalar ops/sec only, kept for compare.py backward-compat
all_runs = []
all_runs_detail = []
for run_idx in range(1, num_runs + 1):
    run_detail = {}
    run_scalar = {}
    for srv_key, srv_name in server_map.items():
        run_detail[srv_name] = {}
        run_scalar[srv_name] = {}
        for cmd in commands:
            jf = os.path.join(outdir, f"{srv_key}_run{run_idx}_{cmd}.json")
            if os.path.exists(jf):
                try:
                    with open(jf) as f:
                        d = json.load(f)
                    totals = d.get("ALL STATS", {}).get("Totals", {})
                    ops = totals.get("Ops/sec", 0)
                    lat_avg = totals.get("Average Latency", 0)
                    plat = totals.get("Percentile Latencies", {}) or {}
                    p50 = plat.get("p50.00") or plat.get("p50") or 0
                    p99 = plat.get("p99.00") or plat.get("p99") or 0
                    cpu = d.get("server_cpu", {})
                    res = d.get("server_resources", {}) or {}
                    if ops > 0:
                        run_detail[srv_name][cmd] = {
                            "ops": ops,
                            "lat_avg_ms": lat_avg,
                            "p50_ms": p50,
                            "p99_ms": p99,
                            "server_cpu_pct": cpu.get("cpu_pct", 0),
                            # Resource cost travels with every single sample so
                            # the median row can never be quoted without it.
                            "cores_busy": res.get("cores_busy", 0),
                            "ops_per_cpu_sec": res.get("ops_per_cpu_sec"),
                            "rss_mb": res.get("rss_mb", 0),
                            "peak_rss_mb": res.get("peak_rss_mb", 0),
                            "disk_read_mb": res.get("disk_read_mb", 0),
                            "disk_write_mb": res.get("disk_write_mb", 0),
                            "gbps": res.get("gbps", 0),
                            "link_util_pct": res.get("link_util_pct"),
                            "packets_per_sec": res.get("packets_per_sec", 0),
                            "bytes_per_op": res.get("bytes_per_op", 0),
                            "client_cpu_saturation_pct": d.get("client_cpu_saturation_pct"),
                            "keyspace_drained": (d.get("keyspace", {}) or {}).get("drained", False),
                            "hit_rate_pct": d.get("hit_rate_pct"),
                        }
                        run_scalar[srv_name][cmd] = ops
                except Exception:
                    pass
    all_runs_detail.append(run_detail)
    all_runs.append(run_scalar)

# Compute median results (ops/sec) and also carry latency/CPU.
# "results" stays as scalar ops/sec for compare.py backward compatibility.
# "results_detail" carries latency and CPU breakdown for the new summary.
results = {}
results_detail = {}
for srv_name in server_map.values():
    results[srv_name] = {}
    results_detail[srv_name] = {}
    for cmd in commands:
        entries = [r[srv_name].get(cmd) for r in all_runs_detail if srv_name in r]
        entries = [e for e in entries if e and e.get("ops", 0) > 0]
        if entries:
            def med(key, default=0):
                vals = [e.get(key) for e in entries if e.get(key) is not None]
                return median(vals) if vals else default
            results[srv_name][cmd] = median([e["ops"] for e in entries])
            results_detail[srv_name][cmd] = {
                "ops": median([e["ops"] for e in entries]),
                "p50_ms": med("p50_ms"),
                "p99_ms": med("p99_ms"),
                "server_cpu_pct": med("server_cpu_pct"),
                "cores_busy": med("cores_busy"),
                "ops_per_cpu_sec": med("ops_per_cpu_sec", None),
                "rss_mb": med("rss_mb"),
                "peak_rss_mb": med("peak_rss_mb"),
                "disk_read_mb": med("disk_read_mb"),
                "disk_write_mb": med("disk_write_mb"),
                "gbps": med("gbps"),
                "link_util_pct": med("link_util_pct", None),
                "packets_per_sec": med("packets_per_sec"),
                "bytes_per_op": med("bytes_per_op"),
                "client_cpu_saturation_pct": med("client_cpu_saturation_pct", None),
                "keyspace_drained": any(e.get("keyspace_drained") for e in entries),
                "hit_rate_pct": med("hit_rate_pct", None),
            }

# System info
# "model name" is an x86-ism; /proc/cpuinfo has no such field on aarch64, so an
# ARM run would record its CPU as "Unknown". lscpu resolves the part number to a
# real name ("Neoverse-V2") on both architectures, so prefer it and keep
# /proc/cpuinfo as the fallback.
cpu_model = "Unknown"
try:
    import subprocess
    out = subprocess.run(["lscpu"], capture_output=True, text=True, timeout=10).stdout
    for line in out.splitlines():
        if line.split(":")[0].strip() in ("Model name", "BIOS Model name"):
            v = line.split(":", 1)[1].strip()
            if v:
                cpu_model = v
                break
except Exception:
    pass
if cpu_model == "Unknown":
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    cpu_model = line.split(":", 1)[1].strip()
                    break
    except Exception:
        pass

total_ram = "Unknown"
try:
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal"):
                kb = int(re.search(r"(\d+)", line).group(1))
                total_ram = f"{kb / (1024*1024):.1f} GB"
                break
except Exception:
    pass

import platform
system_info = {
    "os": "Linux",
    "os_version": platform.version(),
    "os_release": platform.release(),
    "architecture": platform.machine(),
    "cpu_model": cpu_model,
    "cpu_cores": os.cpu_count(),
    "total_ram": total_ram,
    "benchmark_tool": "memtier_benchmark",
    "memtier_version": env("MEMTIER_VER") or "",
    "bench_threads": bench_threads,
    # "io_threads" used to be a single number forced on every server. It is now
    # per-server and tuned; see tuning.tuned_threads.
    "platform_name": env("PLATFORM_NAME") or "",
    "platform_kind": env("PLATFORM_KIND") or "",
}

# --- Load generation topology -------------------------------------------------
remote = (env("REMOTE_MODE") or "0") == "1"
bench_clients = (env("BENCH_CLIENTS") or "").split()
load_gen = {
    "mode": "remote" if remote else "loopback",
    "client_machines": bench_clients,
    "client_count": len(bench_clients) if remote else 1,
    "server_addr": env("SERVER_ADDR") or "127.0.0.1",
    # Loopback shares cores between memtier and the server, so absolute
    # throughput is capped by the load generator. Every server takes the same
    # handicap, so the ratios hold; the absolute numbers understate all of them.
    # Recorded as a fact about the run, not a verdict on it.
    "shared_host": not remote,
}

# --- Tuning -------------------------------------------------------------------
sweep_rows = []
sweep_tsv = env("SWEEP_TSV") or os.path.join(outdir, "sweep.tsv")
if os.path.exists(sweep_tsv):
    with open(sweep_tsv) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 5:
                srv, n, s_ops, g_ops, total = parts
                sweep_rows.append({
                    "server": server_map.get(srv, srv),
                    "threads": int(n),
                    "set_ops": float(s_ops or 0),
                    "get_ops": float(g_ops or 0),
                    "score": float(total or 0),
                })

tuning = {
    "swept": (env("SWEEP") or "1") == "1",
    # Each server's own best, not one number imposed on all of them. The full
    # sweep ships too: anyone claiming we detuned their server can check.
    "tuned_threads": {server_map.get(k, k): v for k, v in tuned_threads.items()},
    "sweep": sweep_rows,
    "sweep_metric": "SET+GET ops/sec at the run's datasize",
}

# --- Benchmark configuration --------------------------------------------------
# What every server was actually run with. The point of publishing this is that
# "we did not handicap Redis" stops being a promise and becomes something a
# reader can check: the launch line, the effective config as the live server
# reported it, and the memtier flags are all here. If a server was capped,
# evicting, or persisting to disk, it shows up in this block.
server_configs = {}
for key in ("hotkv", "redis", "valkey", "dragonfly"):
    cf = os.path.join(outdir, f"config_{key}.json")
    if os.path.exists(cf):
        try:
            with open(cf) as f:
                server_configs[server_map.get(key, key)] = json.load(f)
        except Exception:
            pass

memtier_flags = {
    "threads_per_client_machine": bench_threads,
    **({"threads_by_client_machine": client_threads}
       if len(set(client_threads.values())) > 1 else {}),
    "connections_per_thread": clients_val,
    "total_connections_per_client_machine": bench_threads * clients_val,
    "pipeline": pipeline_val,
    "data_size_bytes": datasize,
    "test_time_sec": int(env("TEST_TIME") or 10),
    "key_pattern": "R (uniform random) over the populated range",
    "key_minimum": int(env("KEY_MINIMUM") or 1),
    "key_maximum": int(env("KEY_MAXIMUM") or 0),
    "populate_pattern": "P (parallel sequential), --requests=allkeys",
    "distinct_client_seed": "--distinct-client-seed" in (env("SEED_ARGS") or ""),
    "runs_per_command": num_runs,
    "reported_statistic": "median of runs",
}

# Host-level settings that change results and are invisible in the numbers
# themselves. Recorded for every run so two runs can be diffed when they
# disagree.
host_settings = {}
try:
    for label, path in (
        ("transparent_hugepages", "/sys/kernel/mm/transparent_hugepage/enabled"),
        ("thp_defrag", "/sys/kernel/mm/transparent_hugepage/defrag"),
    ):
        if os.path.exists(path):
            host_settings[label] = open(path).read().strip()
    import subprocess
    for label, key in (
        ("overcommit_memory", "vm.overcommit_memory"),
        ("somaxconn", "net.core.somaxconn"),
        ("tcp_rmem", "net.ipv4.tcp_rmem"),
        ("tcp_wmem", "net.ipv4.tcp_wmem"),
    ):
        r = subprocess.run(["sysctl", "-n", key], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            host_settings[label] = r.stdout.strip()
    host_settings["nofile_limit"] = subprocess.run(
        ["bash", "-c", "ulimit -n"], capture_output=True, text=True, timeout=5).stdout.strip()
    host_settings["net_iface"] = env("NET_IFACE") or ""
    host_settings["net_link_gbps"] = float(env("NET_LINK_GBPS") or 0) or None
except Exception:
    pass

def memory_note():
    """What each server's memory cap was, as it reported it, and whether the
    run came near it."""
    uncapped, capped = [], []
    for name, cfg in server_configs.items():
        mm = str((cfg.get("effective_config") or {}).get("maxmemory", ""))
        if mm in ("0", ""):
            uncapped.append(name)
        else:
            peak = max((r.get("peak_rss_mb", 0) for r in results_detail.get(name, {}).values()),
                       default=0)
            capped.append(f"{name} kept its default cap (maxmemory {int(mm) / 1e9:.0f} GB; "
                          f"its largest resident set in the run was {peak / 1e3:.0f} GB)")
    parts = []
    if uncapped:
        parts.append("maxmemory=0 (no memory cap) on " + ", ".join(uncapped))
    parts += capped
    return "; ".join(parts) + "." if parts else "Memory caps not recorded."

def connection_note():
    """The one setting changed besides thread count, stated with the numbers
    that made it necessary."""
    mc = env("MAXCLIENTS") or ""
    base = "No server-specific tuning beyond thread count"
    if not mc:
        return base + "; see tuning.tuned_threads."
    total = memtier_flags["total_connections_per_client_machine"] * max(len(bench_clients), 1)
    why = (f"the load generators open {total:,} connections, above the 10,000 default"
           if total > 10000 else f"the load generators open {total:,} connections")
    return (f"{base} and the client-connection ceiling: maxclients {mc} on HotKV, Redis "
            f"and Valkey ({why}); Dragonfly was left at its default. "
            "See tuning.tuned_threads.")

benchmark_config = {
    "servers": server_configs,
    "memtier": memtier_flags,
    "host": host_settings,
    "notes": [
        memory_note(),
        "Persistence off everywhere (Redis/Valkey --save '' --appendonly no; "
        "Dragonfly --dbfilename= ). No server pays disk IO the others do not.",
        connection_note(),
        "The read range is exactly the range populate filled, so reads hit ~100% "
        "and measure the value path rather than the nil path.",
        "--distinct-client-seed: every client gets its own key sequence. Without "
        "it memtier seeds all clients identically and thousands of connections "
        "replay one key order, which manufactures cache locality no real "
        "workload has. Applied to every server equally.",
    ],
}

# --- Provenance ---------------------------------------------------------------
# Version strings are not reproducible on their own; SHAs are.
server_versions = {}
server_revisions = {}
for key, name, ver, sha in (
    ("hotkv", "HotKV", hotkv_ver, env("HOTKV_SHA")),
    ("redis", "Redis", redis_ver, env("REDIS_SHA")),
    ("valkey", "Valkey", valkey_ver, env("VALKEY_SHA")),
    ("dragonfly", "Dragonfly", dragonfly_ver, env("DRAGONFLY_SHA")),
):
    if key not in server_map:
        continue
    if ver:
        server_versions[name] = ver
    if sha:
        server_revisions[name] = sha

output = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "tool": "memtier",
    "clients": clients_val,
    "requests": 0,
    "pipeline": pipeline_val,
    "datasize": datasize,
    "threads": bench_threads,
    "runs": num_runs,
    "results": results,
    "results_detail": results_detail,
    "all_runs": all_runs,
    "all_runs_detail": all_runs_detail,
    "server_versions": server_versions,
    "server_revisions": server_revisions,
    "system_info": system_info,
    "load_generation": load_gen,
    "tuning": tuning,
    "benchmark_config": benchmark_config,
}

# --- HotKV Exclusive Feature Results ---
exclusive_cmds = ["TAG.SET", "TAG.GET", "TAG.COUNT", "NEXPIRE", "NTTL", "SET_4K", "GET_4K"]
compressed_cmds = ["SET_4K_COMP", "GET_4K_COMP"]

exclusive_results = {}
for cmd in exclusive_cmds:
    vals = []
    for run_idx in range(1, num_runs + 1):
        jf = os.path.join(outdir, f"hotkv_exclusive_run{run_idx}_{cmd}.json")
        if os.path.exists(jf):
            try:
                with open(jf) as f:
                    d = json.load(f)
                ops = d.get("ALL STATS", {}).get("Totals", {}).get("Ops/sec", 0)
                if ops > 0:
                    vals.append(ops)
            except Exception:
                pass
    if vals:
        exclusive_results[cmd] = median(vals)

compressed_results = {}
for cmd in compressed_cmds:
    vals = []
    for run_idx in range(1, num_runs + 1):
        jf = os.path.join(outdir, f"hotkv_compressed_run{run_idx}_{cmd}.json")
        if os.path.exists(jf):
            try:
                with open(jf) as f:
                    d = json.load(f)
                ops = d.get("ALL STATS", {}).get("Totals", {}).get("Ops/sec", 0)
                if ops > 0:
                    vals.append(ops)
            except Exception:
                pass
    if vals:
        compressed_results[cmd] = median(vals)

output["exclusive_results"] = exclusive_results
output["compressed_results"] = compressed_results

out_path = os.path.join(outdir, "comparison.json")
with open(out_path, "w") as f:
    json.dump(output, f, indent=2)

print(f"Results saved to: {out_path}")

# Print summary
print()
display_servers = list(server_map.values())
width = 8 + 28 * len(display_servers)
print("=" * width)
print(f"  RESULTS (median of {num_runs} runs)  -  ops/sec | p50 ms | p99 ms | server CPU %")
print(f"  {load_gen['mode']} load, tuned per server: " +
      ", ".join(f"{k}={v}t" for k, v in tuning["tuned_threads"].items()))
print("=" * width)
header = f"{'Command':>8}"
for s in display_servers:
    header += f"  {s:>26}"
print(header)
print("-" * width)
for cmd in commands:
    row = f"{cmd:>8}"
    best_ops = max((results_detail.get(s, {}).get(cmd, {}).get("ops", 0) for s in display_servers), default=0)
    for s in display_servers:
        r = results_detail.get(s, {}).get(cmd, {})
        ops = r.get("ops", 0)
        p50 = r.get("p50_ms", 0)
        p99 = r.get("p99_ms", 0)
        cpu = r.get("server_cpu_pct", 0)
        marker = "*" if ops == best_ops and ops > 0 else " "
        row += f"  {ops:>9,.0f}{marker} {p50:>5.2f} {p99:>5.2f} {cpu:>5.0f}"
    print(row)
print("=" * width)
print()

# --- Resource usage -----------------------------------------------------------
# Throughput on its own is half a result. A server that matches another while
# using a tenth of the machine is not "tied", and one that is filling the NIC is
# not being measured at all - both facts live here, not in the ops/sec table.
print("=" * 108)
print("  RESOURCE USAGE (median of runs)")
print("=" * 108)
print(f"{'Command':>8} {'Server':>11} {'ops/sec':>12} {'cores':>7} {'ops/CPU-s':>11} "
      f"{'RSS MB':>9} {'peak MB':>9} {'Gbps':>7} {'link%':>7} {'Mpps':>7}")
print("-" * 108)
for cmd in commands:
    for s in display_servers:
        r = results_detail.get(s, {}).get(cmd)
        if not r:
            continue
        opcs = r.get("ops_per_cpu_sec")
        util = r.get("link_util_pct")
        print(f"{cmd:>8} {s:>11} {r.get('ops',0):>12,.0f} {r.get('cores_busy',0):>7.1f} "
              f"{(f'{opcs:,.0f}' if opcs else '-'):>11} "
              f"{r.get('rss_mb',0):>9,.0f} {r.get('peak_rss_mb',0):>9,.0f} "
              f"{r.get('gbps',0):>7.2f} {(f'{util:.0f}' if util else '-'):>7} "
              f"{r.get('packets_per_sec',0)/1e6:>7.2f}")
    print("-" * 108)
print()

# A read workload that mostly missed measured the nil path. With the keyspace
# bounded to what populate actually filled this should sit near 100%; anything
# low means the range and the populate have drifted apart again.
LOW_HIT = 90.0
low_hits = [(cmd, s, results_detail[s][cmd]["hit_rate_pct"])
            for cmd in commands for s in display_servers
            if results_detail.get(s, {}).get(cmd, {}).get("hit_rate_pct") is not None
            and results_detail[s][cmd]["hit_rate_pct"] < LOW_HIT]
if low_hits:
    print(f"  !! LOW HIT RATE: these read workloads found fewer than {LOW_HIT:.0f}% of the keys")
    print("     they asked for, so they are measuring the miss path. A miss returns nil")
    print("     instead of a value: cheaper for the server and near-free on the wire.")
    for cmd, s, h in low_hits[:12]:
        print(f"       {cmd:>8}  {s:<11} {h:.1f}% hits")
    if len(low_hits) > 12:
        print(f"       ... and {len(low_hits) - 12} more")
    print()

# A destructive read that emptied the store measured nil replies, not the
# command. Flag it loudly: this one silently inflated LPOP/RPOP to ~24M ops/sec
# in every previous result set.
drained = [(cmd, s) for cmd in commands for s in display_servers
           if results_detail.get(s, {}).get(cmd, {}).get("keyspace_drained")]
if drained:
    print("  !! KEYSPACE DRAINED: these ran the store empty part-way through, so most")
    print("     replies were nil. The figure is nil-reply throughput, NOT the command:")
    for cmd, s in drained:
        print(f"       {cmd:>8}  {s}")
    print("     They do not measure the command named.")
    print()

# Anything sitting on the link is not a measurement of the server. Say so here
# rather than letting a 1.00x "tie" reach a chart.
WIRE_WARN = 85.0
wire_bound = [(cmd, s, results_detail[s][cmd]["link_util_pct"])
              for cmd in commands for s in display_servers
              if results_detail.get(s, {}).get(cmd, {}).get("link_util_pct") is not None
              and results_detail[s][cmd]["link_util_pct"] >= WIRE_WARN]
if wire_bound:
    print(f"  !! WIRE-BOUND: {len(wire_bound)} server/command pairs used >={WIRE_WARN:.0f}% of the")
    print("     advertised link. Those results measure the NIC, not the server, and any")
    print("     ratio between two wire-bound servers is meaningless:")
    for cmd, s, u in wire_bound[:12]:
        print(f"       {cmd:>8}  {s:<11} {u:.0f}% of link")
    if len(wire_bound) > 12:
        print(f"       ... and {len(wire_bound) - 12} more")
    print()

# Same logic on the other side of the cable.
CLIENT_WARN = 85.0
client_bound = [(cmd, s, results_detail[s][cmd]["client_cpu_saturation_pct"])
                for cmd in commands for s in display_servers
                if results_detail.get(s, {}).get(cmd, {}).get("client_cpu_saturation_pct") is not None
                and results_detail[s][cmd]["client_cpu_saturation_pct"] >= CLIENT_WARN]
if client_bound:
    print(f"  !! CLIENT-BOUND: {len(client_bound)} server/command pairs ran with the load")
    print(f"     generator above {CLIENT_WARN:.0f}% CPU. Those numbers may be the load generators'")
    print("     ceiling rather than the server's; read them as lower bounds:")
    for cmd, s, u in client_bound[:12]:
        print(f"       {cmd:>8}  {s:<11} client at {u:.0f}% CPU")
    if len(client_bound) > 12:
        print(f"       ... and {len(client_bound) - 12} more")
    print()

# --- Configuration ------------------------------------------------------------
print("=" * 108)
print("  BENCHMARK CONFIGURATION")
print("=" * 108)
print(f"  memtier: -t {memtier_flags['threads_per_client_machine']} "
      f"-c {memtier_flags['connections_per_thread']} "
      f"--pipeline {memtier_flags['pipeline']} "
      f"-d {memtier_flags['data_size_bytes']} "
      f"--test-time={memtier_flags['test_time_sec']}  "
      f"({memtier_flags['total_connections_per_client_machine']:,} connections per client box, "
      f"{memtier_flags['runs_per_command']} runs, median reported)")
if host_settings:
    print(f"  host:    THP={host_settings.get('transparent_hugepages','?')}  "
          f"overcommit={host_settings.get('overcommit_memory','?')}  "
          f"somaxconn={host_settings.get('somaxconn','?')}  "
          f"nofile={host_settings.get('nofile_limit','?')}  "
          f"iface={host_settings.get('net_iface','?')}"
          + (f" @ {host_settings['net_link_gbps']:.0f} Gbps" if host_settings.get("net_link_gbps") else ""))
print()
for sname, cfg in server_configs.items():
    print(f"  --- {sname} ---")
    print(f"    launch: {cfg.get('launch_cmdline','')}")
    eff = cfg.get("effective_config", {}) or {}
    interesting = [(k, v) for k, v in eff.items() if k in (
        "maxmemory", "maxmemory-policy", "io-threads", "appendonly", "save",
        "protected-mode", "tcp-backlog", "timeout", "hz", "databases")]
    if interesting:
        print("    effective: " + "  ".join(
            f"{k}={v!r}" if v == "" else f"{k}={v}" for k, v in interesting))
    if cfg.get("maxmemory_is_unlimited"):
        print("    memory cap: none (maxmemory=0) - no eviction during the run")
print("=" * 108)
print()

# Report every command on which another server measured higher than HotKV.
if "HotKV" in display_servers:
    losses = []
    for cmd in commands:
        ours = results_detail.get("HotKV", {}).get(cmd, {}).get("ops", 0)
        if not ours:
            continue
        for s in display_servers:
            if s == "HotKV":
                continue
            theirs = results_detail.get(s, {}).get(cmd, {}).get("ops", 0)
            if theirs > ours:
                losses.append((cmd, s, ours, theirs))
    if losses:
        print("  Commands where another server measured higher than HotKV:")
        for cmd, s, ours, theirs in losses:
            print(f"    {cmd:>8}  {s}: {theirs:,.0f} vs HotKV {ours:,.0f}  ({(theirs/ours - 1)*100:.1f}% higher)")
        print()

# Print HotKV exclusive features
if exclusive_results or compressed_results:
    print("=" * 60)
    print("  HotKV EXCLUSIVE FEATURES (median of {} runs)".format(num_runs))
    print("=" * 60)
    print(f"{'Command':>18}  {'ops/sec':>14}")
    print("-" * 36)

    display_names = {
        "TAG.SET": "TAG.SET",
        "TAG.GET": "TAG.GET",
        "TAG.COUNT": "TAG.COUNT",
        "NEXPIRE": "NEXPIRE",
        "NTTL": "NTTL",
        "SET_4K": "SET (4KB)",
        "GET_4K": "GET (4KB)",
    }
    for cmd in exclusive_cmds:
        if cmd in exclusive_results:
            label = display_names.get(cmd, cmd)
            print(f"{label:>18}  {exclusive_results[cmd]:>14,.0f}")

    if compressed_results:
        print()
        print("  With transparent compression (threshold 512 bytes):")
        comp_names = {
            "SET_4K_COMP": "SET (4KB+comp)",
            "GET_4K_COMP": "GET (4KB+comp)",
        }
        for cmd in compressed_cmds:
            if cmd in compressed_results:
                label = comp_names.get(cmd, cmd)
                print(f"{label:>18}  {compressed_results[cmd]:>14,.0f}")
                # Show overhead vs baseline
                baseline_cmd = cmd.replace("_COMP", "")
                if baseline_cmd in exclusive_results and exclusive_results[baseline_cmd] > 0:
                    overhead = ((exclusive_results[baseline_cmd] - compressed_results[cmd]) / exclusive_results[baseline_cmd]) * 100
                    print(f"{'(overhead)':>18}  {overhead:>13.1f}%")

    print("=" * 60)
    print()
PYEOF

echo ""
echo "JSON output: $OUTDIR/comparison.json"
echo "Done!"
