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
# File:        harness/setup_server.sh
# Description: Benchmark server setup - installs build tools, dependencies, and servers
# Author:      HotKV Ltd
# =============================================================================
set -e

# Non-interactive apt (no dialog/whiptail prompts during SSH).
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
APT_OPTS='-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'

echo "=== HotKV Benchmark Server Setup ==="
echo "Setting up on $(hostname) - $(date)"

# --- Disk guard ---------------------------------------------------------------
# Dragonfly vendors its whole dependency tree and is by far the biggest build
# here; libboost-all-dev alone is ~1 GB. A default 8 GB AWS root volume runs out
# mid-build, which wastes 20 minutes before it fails. Check up front instead.
# Override with SKIP_DISK_CHECK=1.
BUILD_DRAGONFLY="${BUILD_DRAGONFLY:-1}"
if [ "${SKIP_DISK_CHECK:-0}" != "1" ]; then
    avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    need_gb=12
    [ "$BUILD_DRAGONFLY" = "1" ] && need_gb=30
    if [ "${avail_gb:-0}" -lt "$need_gb" ]; then
        echo ""
        echo "ERROR: only ${avail_gb}G free on / but this needs ~${need_gb}G"
        echo "       (Dragonfly is the bulk of it; BUILD_DRAGONFLY=0 drops the need to ~12G)"
        echo ""
        echo "  On AWS: grow the root EBS volume in the console, then on the box:"
        echo "    sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1"
        echo ""
        echo "  Bypass this check with SKIP_DISK_CHECK=1"
        exit 1
    fi
    echo "Disk: ${avail_gb}G free on / (need ~${need_gb}G) - OK"
fi

# Update packages
apt-get update $APT_OPTS
apt-get upgrade $APT_OPTS

# Build tools
apt-get install $APT_OPTS \
    build-essential \
    cmake \
    ninja-build \
    git \
    pkg-config \
    python3 \
    python3-pip \
    libjemalloc-dev \
    liburing-dev \
    libboost-all-dev \
    libssl-dev \
    autoconf \
    automake \
    libevent-dev \
    libpcre2-dev \
    zlib1g-dev \
    tcl \
    wget \
    curl \
    lsof \
    redis-tools

# --- Compiler -----------------------------------------------------------------
# HotKV needs C++20 (CMAKE_CXX_STANDARD 20), which any GCC >= 11 provides. The
# old code pinned gcc-13 and pulled ppa:ubuntu-toolchain-r/test to get it, but
# that PPA has no build for newer releases (Ubuntu 26.04 "resolute"), so the
# add-apt-repository path fails outright there. Distro GCC is new enough on
# every release we bench on, so use it and only reach for the PPA if it is not.
need_gcc_major=11
gcc_major_of() { "$1" -dumpversion 2>/dev/null | cut -d. -f1; }

CXX_BIN=""
for cand in g++ g++-15 g++-14 g++-13; do
    if command -v "$cand" > /dev/null 2>&1; then
        maj=$(gcc_major_of "$cand")
        if [ -n "$maj" ] && [ "$maj" -ge "$need_gcc_major" ]; then CXX_BIN="$cand"; break; fi
    fi
done

if [ -z "$CXX_BIN" ]; then
    echo "No g++ >= ${need_gcc_major} found; installing distro default..."
    apt-get install $APT_OPTS g++ gcc || true
    if command -v g++ > /dev/null 2>&1 && [ "$(gcc_major_of g++)" -ge "$need_gcc_major" ]; then
        CXX_BIN=g++
    else
        # Last resort: the toolchain PPA. Only works on releases it publishes for.
        echo "Distro g++ still too old; trying ppa:ubuntu-toolchain-r/test..."
        add-apt-repository -y ppa:ubuntu-toolchain-r/test || true
        apt-get update $APT_OPTS || true
        apt-get install $APT_OPTS gcc-13 g++-13 || true
        command -v g++-13 > /dev/null 2>&1 && CXX_BIN=g++-13
    fi
fi

if [ -z "$CXX_BIN" ]; then
    echo "ERROR: no C++ compiler >= GCC ${need_gcc_major} available. Cannot build HotKV."
    exit 1
fi

echo "C++ compiler:  $($CXX_BIN --version | head -1)  [$CXX_BIN]"
echo "CMake version: $(cmake --version | head -1)"
echo "Architecture:  $(uname -m)"

# Kernel tuning for benchmarks
sysctl vm.overcommit_memory=1 > /dev/null 2>&1 || true
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

# --- Competitor versions ------------------------------------------------------
# Pinned, not "fetch latest at run time": a benchmark has to name the versions it
# measured, and a rerun months later must build the same thing. Bump these when
# upstream ships a new stable, then re-run. Verified latest stable 2026-10-09 (GitHub release tags).
REDIS_VERSION="${REDIS_VERSION:-8.10.2}"
VALKEY_VERSION="${VALKEY_VERSION:-9.1.2}"
DRAGONFLY_VERSION="${DRAGONFLY_VERSION:-v2.0.2}"

# --- Redis --------------------------------------------------------------------
echo ""
echo "=== Building Redis ${REDIS_VERSION} ==="
if [ ! -f /opt/redis-${REDIS_VERSION}/src/redis-server ]; then
    cd /opt
    wget -q https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz \
        -O redis-${REDIS_VERSION}.tar.gz
    tar xzf redis-${REDIS_VERSION}.tar.gz
    cd redis-${REDIS_VERSION}
    # Stock build. Redis's own Makefile already defaults to -O3 plus -flto, so
    # this is upstream's intended release configuration, not a handicap.
    make -j$(nproc) BUILD_TLS=no
    echo "Redis built: $(./src/redis-server --version)"
else
    echo "Redis already built: $(/opt/redis-${REDIS_VERSION}/src/redis-server --version)"
fi

# --- Valkey -------------------------------------------------------------------
echo ""
echo "=== Building Valkey ${VALKEY_VERSION} ==="
if [ ! -f /opt/valkey-${VALKEY_VERSION}/src/valkey-server ]; then
    cd /opt
    wget -q https://github.com/valkey-io/valkey/archive/refs/tags/${VALKEY_VERSION}.tar.gz \
        -O valkey-${VALKEY_VERSION}.tar.gz
    tar xzf valkey-${VALKEY_VERSION}.tar.gz
    cd valkey-${VALKEY_VERSION}
    make -j$(nproc) BUILD_TLS=no
    echo "Valkey built: $(./src/valkey-server --version)"
else
    echo "Valkey already built: $(/opt/valkey-${VALKEY_VERSION}/src/valkey-server --version)"
fi

# --- memtier_benchmark ---
echo ""
echo "=== Installing memtier_benchmark ==="
if ! command -v memtier_benchmark &> /dev/null; then
    cd /tmp
    git clone https://github.com/RedisLabs/memtier_benchmark.git
    cd memtier_benchmark
    # Pinned to the build the published results used (its build string in RESULTS.md shows this SHA).
    git checkout 272eeb64
    autoreconf -ivf
    ./configure
    make -j$(nproc)
    make install
    cd /
    rm -rf /tmp/memtier_benchmark
    echo "memtier_benchmark installed: $(memtier_benchmark --version 2>&1 | head -1)"
else
    echo "memtier_benchmark already installed: $(memtier_benchmark --version 2>&1 | head -1)"
fi

# --- Dragonfly ----------------------------------------------------------------
# Multi-threaded and shared-nothing, like HotKV. Built from a git checkout so
# full_bench.sh can record the commit SHA. BUILD_DRAGONFLY=0 to skip.
if [ "$BUILD_DRAGONFLY" = "1" ]; then
    echo ""
    echo "=== Building Dragonfly ==="
    if [ ! -x /opt/dragonfly/build-opt/dragonfly ]; then
        apt-get install $APT_OPTS \
            ninja-build libunwind-dev libboost-context-dev libboost-system-dev \
            autoconf-archive libtool bison zstd libzstd-dev || true
        cd /opt
        # Pinned to a release tag, not main: main moves under us and a published
        # number has to name what it measured.
        [ -d /opt/dragonfly ] || git clone --recursive --depth 1 \
            --branch "${DRAGONFLY_VERSION}" \
            https://github.com/dragonflydb/dragonfly.git /opt/dragonfly
        cd /opt/dragonfly
        # blaze.sh configures build-opt/; ninja then builds the server binary.
        ./helio/blaze.sh -release
        cd build-opt
        ninja dragonfly
        echo "Dragonfly built: $(/opt/dragonfly/build-opt/dragonfly --version 2>&1 | head -1)"
    else
        echo "Dragonfly already built: $(/opt/dragonfly/build-opt/dragonfly --version 2>&1 | head -1)"
    fi
else
    echo ""
    echo "=== Skipping Dragonfly (BUILD_DRAGONFLY=0) ==="
fi

echo ""
echo "=== Server setup complete ==="
df -h / | tail -1
echo "Ready for HotKV source upload and build."
