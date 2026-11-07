#!/usr/bin/env bash
# Runs ON THE SERVER. Installs the Microsoft Garnet release binary (self-contained, no .NET install needed).
set -euo pipefail
VER="${GARNET_VERSION:-v2.2.7}"
SHA="${GARNET_SHA256:-ec06a6b1acb9069f66b34bb202d01a9ade3696be80791c80c89264fc0d48e8d6}"
sudo mkdir -p /opt/garnet && cd /tmp
curl -fsSL -o garnet.tar.xz "https://github.com/microsoft/garnet/releases/download/${VER}/linux-x64-based.tar.xz"
echo "$SHA  garnet.tar.xz" | sha256sum -c -
sudo tar -xJf garnet.tar.xz -C /opt/garnet --strip-components=1
sudo chmod +x /opt/garnet/GarnetServer
/opt/garnet/GarnetServer --version 2>&1 | head -2 || true
/opt/garnet/GarnetServer --help 2>&1 | grep -E -- '--(index|memory|port|bind|protected-mode|no-pubsub|no-obj|minthreads|maxthreads|aof|checkpointfreq)' | head -20
