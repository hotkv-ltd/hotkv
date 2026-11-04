#!/usr/bin/env bash
# Spread NIC receive processing (RPS/RFS) over every CPU. Run as the login user; uses sudo.
I=$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
N=$(nproc)
MASK=$(python3 - <<PY
n=$N
m=(1<<n)-1
h="%0*x"%(((n+3)//4),m)
h=h.zfill(((len(h)+7)//8)*8)
print(",".join(h[i:i+8] for i in range(0,len(h),8)))
PY
)
sudo sysctl -w net.core.rps_sock_flow_entries=1048576 > /dev/null
Q=$(ls -d /sys/class/net/$I/queues/rx-* | wc -l)
for q in /sys/class/net/$I/queues/rx-*; do
  echo "$MASK" | sudo tee $q/rps_cpus > /dev/null
  echo $((1048576 / Q)) | sudo tee $q/rps_flow_cnt > /dev/null
done
echo "$(hostname): $I rx queues=$Q cpus=$N rps_cpus(rx-0)=$(cat /sys/class/net/$I/queues/rx-0/rps_cpus | cut -c1-40)... flow_cnt=$(cat /sys/class/net/$I/queues/rx-0/rps_flow_cnt) sock_flow_entries=$(sysctl -n net.core.rps_sock_flow_entries)"
