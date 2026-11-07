#!/usr/bin/env bash
# Runs on a control machine with ssh access to both hosts.
# Garnet 2.2.7 against HotKV 0.3.3, GET and SET, 1/32/128 connections with batches of 4096,
# and 128 connections one request at a time. Two rounds, the second in reverse order.
#   SERVER=user@server CLIENT=user@client SERVER_IP=10.x.x.x HOTKV=/path/to/hotkv ./run_throughput.sh > throughput.txt
set -u
: "${SERVER:?}" "${CLIENT:?}" "${SERVER_IP:?}" "${HOTKV:?}"
HFLAGS="--port 6399 --bind 0.0.0.0 --threads 48 --no-snapshot --protected-mode no --loglevel warning --server-cpulist 0-47"
GCMD="/opt/garnet/GarnetServer --bind 0.0.0.0 --port 6399 --index 1g --protected-mode no"

start() {  # process-name, command line. Only one server runs at a time.
  ssh "$SERVER" "pkill -x hotkv; pkill -x GarnetServer; sleep 3; (nohup $2 >/tmp/srv.log 2>&1 </dev/null &); sleep 8; pgrep -x $1 >/dev/null || echo NOT_STARTED" </dev/null
}

load() {  # op threads batch
  ssh "$CLIENT" "export DOTNET_ROOT=\$HOME/dotnet; \$HOME/dotnet/dotnet \$HOME/garnet/benchmark/Resp.benchmark/bin/Release/net10.0/Resp.benchmark.dll --host $SERVER_IP --port 6399 --op $1 --keylength 8 --valuelength 8 --dbsize 1024 --runtime 10 --threads $2 --batchsize $3 2>&1 | grep -E '^\[Throughput\]' | tail -1 | sed 's/.*: //; s/ ops.sec//; s/,//g'" </dev/null
}

variant() {  # label procname cmd
  start "$2" "$3"
  for op in GET SET; do
    printf "%-22s %-3s c1 %11s  c32 %11s  c128 %11s  p1c128 %9s\n" "$1" $op \
      "$(load $op 1 4096)" "$(load $op 32 4096)" "$(load $op 128 4096)" "$(load $op 128 1)"
  done
}

for order in "g h" "h g"; do
  for v in $order; do
    case $v in
      g) variant "garnet 2.2.7" GarnetServer "$GCMD" ;;
      h) variant "hotkv 0.3.3"  hotkv "$HOTKV $HFLAGS" ;;
    esac
  done
done
ssh "$SERVER" "pkill -x hotkv; pkill -x GarnetServer" </dev/null
