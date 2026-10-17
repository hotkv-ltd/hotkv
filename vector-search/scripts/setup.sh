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
# Provision a fresh Ubuntu 24.04 machine for the vector-search benchmark.
#
#   HOTKV_SRC_TGZ=/path/to/hotkv-source.tgz bash setup.sh
#
# What it does, and nothing else:
#   1. installs the build toolchain and the Python packages the harness uses;
#   2. applies the host settings the harness depends on (transparent hugepages
#      off, vm.overcommit_memory=1);
#   3. builds Redis ${REDIS_VERSION} from its GitHub release tag, stock `make`;
#   4. builds HotKV from the source archive in HOTKV_SRC_TGZ with the `release`
#      CMake preset (default flags, no -march=native);
#   5. prints the version and SHA-256 of both binaries.
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-8.10.2}"
HOTKV_SRC_TGZ="${HOTKV_SRC_TGZ:?set HOTKV_SRC_TGZ to the HotKV source archive (.tgz)}"
HOTKV_DIR="${HOTKV_DIR:-/opt/hotkv}"
JOBS="$(nproc)"

echo "=== packages ==="
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential cmake ninja-build git pkg-config wget curl lsof numactl \
    python3 python3-venv python3-pip \
    libjemalloc-dev liburing-dev libboost-all-dev libssl-dev zlib1g-dev

echo "=== Python environment (/opt/vsb-venv) ==="
if [ ! -x /opt/vsb-venv/bin/python ]; then
    sudo mkdir -p /opt/vsb-venv
    sudo chown "$(id -un)" /opt/vsb-venv
    python3 -m venv /opt/vsb-venv
    /opt/vsb-venv/bin/pip install --quiet numpy pyarrow
fi
/opt/vsb-venv/bin/pip freeze | grep -i -E '^(numpy|pyarrow)=='

echo "=== host settings ==="
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null || true
sudo sysctl -w vm.overcommit_memory=1 >/dev/null
echo "transparent_hugepage: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "vm.overcommit_memory: $(cat /proc/sys/vm/overcommit_memory)"

echo "=== Redis ${REDIS_VERSION} ==="
if [ ! -x "/opt/redis-${REDIS_VERSION}/src/redis-server" ]; then
    cd /tmp
    wget -q "https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz" \
        -O "redis-${REDIS_VERSION}.tar.gz"
    sha256sum "redis-${REDIS_VERSION}.tar.gz"
    sudo tar xzf "redis-${REDIS_VERSION}.tar.gz" -C /opt
    sudo chown -R "$(id -un)" "/opt/redis-${REDIS_VERSION}"
    cd "/opt/redis-${REDIS_VERSION}"
    make -j"${JOBS}" BUILD_TLS=no
fi
"/opt/redis-${REDIS_VERSION}/src/redis-server" --version

echo "=== HotKV ==="
if [ ! -x "${HOTKV_DIR}/build/release/src/hotkv" ]; then
    sudo mkdir -p "${HOTKV_DIR}"
    sudo chown "$(id -un)" "${HOTKV_DIR}"
    tar xzf "${HOTKV_SRC_TGZ}" -C "${HOTKV_DIR}"
    find "${HOTKV_DIR}" -type f \( -name '*.txt' -o -name '*.cmake' -o -name '*.json' \) \
        -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    cd "${HOTKV_DIR}"
    cmake --preset release -DHOTKV_BUILD_TESTS=OFF -DHOTKV_BUILD_BENCHMARKS=OFF
    cmake --build build/release -j"${JOBS}"
fi
"${HOTKV_DIR}/build/release/src/hotkv" --version || true

echo "=== binaries ==="
sha256sum "/opt/redis-${REDIS_VERSION}/src/redis-server" "${HOTKV_DIR}/build/release/src/hotkv"
echo "SETUP DONE"
