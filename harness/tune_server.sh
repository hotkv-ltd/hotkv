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
# =============================================================================
set -e

# File descriptor limits
echo "* soft nofile 1048576" >> /etc/security/limits.conf
echo "* hard nofile 1048576" >> /etc/security/limits.conf
echo "root soft nofile 1048576" >> /etc/security/limits.conf
echo "root hard nofile 1048576" >> /etc/security/limits.conf

# Locked-memory limits. Dragonfly's io_uring allocates locked memory per proactor
# thread and simply fails to start past ~64 threads under the default limit
# ("io_uring does not have enough memory"). Without this, Dragonfly quietly runs
# on a fraction of a big box while the others get all of it.
echo "* soft memlock unlimited" >> /etc/security/limits.conf
echo "* hard memlock unlimited" >> /etc/security/limits.conf
echo "root soft memlock unlimited" >> /etc/security/limits.conf
echo "root hard memlock unlimited" >> /etc/security/limits.conf

# Systemd override
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitMEMLOCK=infinity
EOF

# Sysctl tuning
sysctl -w fs.file-max=2097152
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sysctl -w net.core.netdev_max_backlog=65535
sysctl -w vm.overcommit_memory=1
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

# PAM limits
grep -q pam_limits /etc/pam.d/common-session 2>/dev/null || echo "session required pam_limits.so" >> /etc/pam.d/common-session

echo "=== Tuning applied ==="
echo "fs.file-max = $(sysctl -n fs.file-max)"
echo "somaxconn = $(sysctl -n net.core.somaxconn)"
echo "NOTE: You must reconnect SSH for ulimit changes to take effect"
