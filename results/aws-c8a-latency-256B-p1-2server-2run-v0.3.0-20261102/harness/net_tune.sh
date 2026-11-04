#!/usr/bin/env bash
# Network host tuning for the ENA NIC (documented in the hotkv README). Run as the login user (uses sudo).
bash /tmp/rps_on.sh
I=$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
sudo ethtool -G $I rx 8192 2>&1 | tail -1
sudo sysctl -w net.core.netdev_budget=4800 net.core.netdev_budget_usecs=16000 > /dev/null
echo "$(hostname) $I mtu=$(cat /sys/class/net/$I/mtu) rings: $(ethtool -g $I | awk '/Current/{f=1} f&&/^RX:|^TX:/{printf "%s%s ", $1,$2}') budget=$(sysctl -n net.core.netdev_budget) rps=$(cut -c1-9 /sys/class/net/$I/queues/rx-0/rps_cpus) flow=$(sysctl -n net.core.rps_sock_flow_entries)"
