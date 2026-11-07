#!/usr/bin/env bash
# Runs ON THE LOAD GENERATOR. .NET 10 SDK + Resp.benchmark from the Garnet v2.2.7 tag.
set -uo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl redis-tools python3 build-essential >/dev/null
curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$HOME/dotnet" > /tmp/dotnet_install.log 2>&1 || { tail /tmp/dotnet_install.log; echo DOTNET_FAIL; exit 1; }
export DOTNET_ROOT="$HOME/dotnet" PATH="$HOME/dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1
dotnet --version
rm -rf ~/garnet && git clone --depth 1 --branch v2.2.7 https://github.com/microsoft/garnet ~/garnet > /tmp/clone.log 2>&1 || { tail /tmp/clone.log; echo CLONE_FAIL; exit 1; }
cd ~/garnet && git rev-parse HEAD
dotnet build -c Release --framework=net10.0 benchmark/Resp.benchmark/Resp.benchmark.csproj > /tmp/respbench_build.log 2>&1 || { tail -30 /tmp/respbench_build.log; echo BUILD_FAIL; exit 1; }
echo DRV_SETUP_DONE
