#!/usr/bin/env python3
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
# File:        harness/render_report.py
# Description: Render a publishable RESULTS.md from a full_bench.sh comparison.json
# Author:      HotKV Ltd
# =============================================================================
"""Turn comparison.json into the report a reader can actually check.

A throughput table on its own invites two questions that it cannot answer:
"what did it cost?" and "was the other server crippled?". This renders both
alongside the numbers - resource usage per command, and the exact launch line
and effective config of every server - plus the validity checks that say when a
result is measuring the network or the load generator instead of the server.

Usage:
    python3 render_report.py comparison.json > RESULTS.md
    python3 render_report.py comparison.json -o RESULTS.md
"""

import argparse
import json
import sys
from datetime import datetime

# A result at or above these is not a measurement of the server.
WIRE_BOUND_PCT = 85.0
CLIENT_BOUND_PCT = 85.0
# Below this, a read workload is measuring the nil path rather than the value path.
LOW_HIT_PCT = 90.0


def fmt(n, nd=0):
    if n is None:
        return "-"
    return f"{n:,.{nd}f}"


def load(path):
    with open(path) as f:
        return json.load(f)


def rig_section(d):
    si = d.get("system_info", {}) or {}
    lg = d.get("load_generation", {}) or {}
    host = (d.get("benchmark_config", {}) or {}).get("host", {}) or {}
    kind = si.get("platform_kind", "")
    kind_label = {"metal": "bare metal", "vm": "virtual machine"}.get(kind, kind or "unknown")

    rows = [
        ("Platform", f"{si.get('platform_name','?')} ({kind_label})"),
        ("CPU", f"{si.get('cpu_model','?')}, {si.get('cpu_cores','?')} cores, {si.get('architecture','?')}"),
        ("RAM", si.get("total_ram", "?")),
        ("OS", f"{si.get('os','?')} {si.get('os_release','')}".strip()),
    ]
    if lg.get("mode") == "remote":
        n = lg.get("client_count", 0)
        rows.append(("Load generator",
                     f"{n} dedicated client machine(s): {', '.join(lg.get('client_machines', []))}"))
    else:
        rows.append(("Load generator",
                     "loopback - memtier shares this box with the server "
                     "(absolute numbers are the client's ceiling, not the server's)"))
    if host.get("net_iface"):
        link = host.get("net_link_gbps")
        rows.append(("Network", f"{host['net_iface']}" + (f", {link:.0f} Gbps link" if link else "")))
    rows.append(("Benchmark tool", f"memtier_benchmark {si.get('memtier_version','')}".strip()))

    out = ["## Rig", "", "| | |", "|---|---|"]
    out += [f"| {k} | {v} |" for k, v in rows]

    vers = d.get("server_versions", {}) or {}
    if vers:
        out += ["", "### Versions", "", "| server | version |", "|---|---|"]
        for name, v in vers.items():
            out.append(f"| {name} | {v} |")
    return "\n".join(out)


def config_section(d):
    """User ask #3: what was each server actually run with?"""
    bc = d.get("benchmark_config", {}) or {}
    mt = bc.get("memtier", {}) or {}
    host = bc.get("host", {}) or {}
    servers = bc.get("servers", {}) or {}
    tuning = d.get("tuning", {}) or {}

    out = ["## Benchmark configuration", "",
           "Everything needed to reproduce this run, and to check that no server was",
           "handicapped. The launch lines and effective configs below are read back from",
           "each live server, not copied from the script.", ""]

    out += ["### Load", "", "| | |", "|---|---|"]
    for k, label in (
        ("data_size_bytes", "Value size"),
        ("pipeline", "Pipeline depth"),
        ("threads_per_client_machine", "memtier threads per client box"),
        ("memtier_processes_per_client_box", "memtier processes per client box"),
        ("connections_per_thread", "Connections per thread"),
        ("total_connections_per_client_machine", "Total connections per client box"),
        ("test_time_sec", "Test duration per command"),
        ("runs_per_command", "Runs per command"),
        ("reported_statistic", "Reported statistic"),
        ("key_pattern", "Key pattern"),
        ("key_maximum", "Keyspace size (keys)"),
        ("populate_pattern", "Populate"),
        ("distinct_client_seed", "Distinct seed per client"),
    ):
        if k in mt:
            v = mt[k]
            if k == "distinct_client_seed":
                v = "yes" if v else "**no** - all clients replay one key sequence"
            elif isinstance(v, int) and k != "data_size_bytes":
                v = f"{v:,}"
            if k == "data_size_bytes":
                v = f"{v} bytes"
            if k == "test_time_sec":
                v = f"{v} s"
            out.append(f"| {label} | {v} |")

    if tuning:
        tt = tuning.get("tuned_threads", {}) or {}
        if tt:
            swept = tuning.get("swept")
            how = ("swept per server, each server's own best"
                   if swept else "the same for every server: all the machine's cores, "
                   "clamped to each server's maximum")
            out += ["", f"**Server threads** ({how}): "
                    + ", ".join(f"{k}={v}" for k, v in tt.items())]
            if not swept:
                out += ["",
                        "> Redis and Valkey execute commands on a single thread; the threads they",
                        "> were given here are I/O threads. They can reach higher throughput with",
                        "> fewer I/O threads than this, so their figures may be below their best",
                        "> on this machine. Each was run as a single instance, not as a cluster."]

    if host:
        out += ["", "### Host", "", "| setting | value |", "|---|---|"]
        for k, label in (
            ("transparent_hugepages", "Transparent hugepages"),
            ("overcommit_memory", "vm.overcommit_memory"),
            ("somaxconn", "net.core.somaxconn"),
            ("nofile_limit", "Open file limit"),
            ("net_iface", "Interface"),
        ):
            if host.get(k):
                out.append(f"| {label} | `{host[k]}` |")

    if servers:
        out += ["", "### Per-server", ""]
        for name, cfg in servers.items():
            out += [f"**{name}**", "", "```", cfg.get("launch_cmdline", "?"), "```", ""]
            eff = cfg.get("effective_config", {}) or {}
            if eff:
                shown = {k: v for k, v in eff.items() if k in (
                    "maxmemory", "maxmemory-policy", "io-threads", "io-threads-do-reads",
                    "appendonly", "save", "protected-mode", "tcp-backlog", "timeout",
                    "hz", "databases")}
                if shown:
                    out += ["| directive | effective value |", "|---|---|"]
                    for k, v in shown.items():
                        out.append(f"| `{k}` | `{v if v != '' else '(empty)'}` |")
                    out.append("")
            if cfg.get("maxmemory_is_unlimited"):
                out += ["No memory cap (`maxmemory=0`): nothing was evicted during the run.", ""]

    notes = bc.get("notes", []) or []
    if notes:
        out += ["### Fairness notes", ""] + [f"- {n}" for n in notes]
    return "\n".join(out)


def throughput_section(d):
    rd = d.get("results_detail", {}) or {}
    servers = list(rd.keys())
    if not servers:
        return ""
    commands = []
    for s in servers:
        for c in rd[s]:
            if c not in commands:
                commands.append(c)

    runs = d.get("runs", "?")
    if runs == 1:
        heading = "## Throughput (ops/sec, single run)"
        caveat = ["", "> **One run per command, so there is no variance information here.** A single",
                  "> sample cannot distinguish a real difference from run-to-run noise. Treat",
                  "> these as indicative.", ""]
    else:
        heading = f"## Throughput (ops/sec, median of {runs} runs)"
        caveat = [""]
    out = [heading] + caveat + [
        "| command | " + " | ".join(servers) + " |",
        "|---" * (len(servers) + 1) + "|"]
    for cmd in commands:
        best = max((rd[s].get(cmd, {}).get("ops", 0) for s in servers), default=0)
        cells = []
        for s in servers:
            ops = rd[s].get(cmd, {}).get("ops", 0)
            cell = fmt(ops) if ops else "-"
            if ops and ops == best:
                cell = f"**{cell}**"
            cells.append(cell)
        out.append(f"| {cmd} | " + " | ".join(cells) + " |")
    return "\n".join(out)


def resource_section(d):
    """User ask #2: what did each server actually consume?"""
    rd = d.get("results_detail", {}) or {}
    servers = list(rd.keys())
    if not servers:
        return ""
    commands = []
    for s in servers:
        for c in rd[s]:
            if c not in commands:
                commands.append(c)

    has_link = any(rd[s].get(c, {}).get("link_util_pct") is not None
                   for s in servers for c in rd[s])
    has_hit = any(rd[s].get(c, {}).get("hit_rate_pct") is not None
                  for s in servers for c in rd[s])

    out = ["## Resource usage", "",
           "Per command and server, each column is the median of that metric over the runs,",
           "so a row need not come from one single run. `cores` is CPU time over",
           "wall time (8.0 = eight cores fully busy). `ops/CPU-s` is throughput per second",
           "of CPU consumed - the efficiency figure that still means something on a",
           "different machine. Memory is the server process's resident set; `peak` is its",
           "high-water mark including the populate phase.", ""]

    hdr = "| command | server | ops/sec | cores | ops/CPU-s | RSS MB | peak MB | Gbps |"
    sep = "|---|---|---|---|---|---|---|---|"
    if has_link:
        hdr += " link % |"
        sep += "---|"
    if has_hit:
        hdr += " hit % |"
        sep += "---|"
    out += [hdr, sep]

    for cmd in commands:
        for s in servers:
            r = rd[s].get(cmd)
            if not r:
                continue
            row = (f"| {cmd} | {s} | {fmt(r.get('ops'))} | {fmt(r.get('cores_busy'), 1)} | "
                   f"{fmt(r.get('ops_per_cpu_sec'))} | {fmt(r.get('rss_mb'))} | "
                   f"{fmt(r.get('peak_rss_mb'))} | {fmt(r.get('gbps'), 2)} |")
            if has_link:
                u = r.get("link_util_pct")
                row += f" {fmt(u, 0) if u is not None else '-'} |"
            if has_hit:
                h = r.get("hit_rate_pct")
                row += f" {fmt(h, 1) if h is not None else '-'} |"
            out.append(row)
    return "\n".join(out)


def validity_section(d):
    """The checks that decide whether any of this is publishable."""
    rd = d.get("results_detail", {}) or {}
    servers = list(rd.keys())
    commands = []
    for s in servers:
        for c in rd[s]:
            if c not in commands:
                commands.append(c)

    wire, client, drained, lowhit = [], [], [], []
    for cmd in commands:
        for s in servers:
            r = rd[s].get(cmd) or {}
            u = r.get("link_util_pct")
            if u is not None and u >= WIRE_BOUND_PCT:
                wire.append((cmd, s, u))
            c = r.get("client_cpu_saturation_pct")
            if c is not None and c >= CLIENT_BOUND_PCT:
                client.append((cmd, s, c))
            if r.get("keyspace_drained"):
                drained.append((cmd, s))
            h = r.get("hit_rate_pct")
            if h is not None and h < LOW_HIT_PCT:
                lowhit.append((cmd, s, h))

    if not (wire or client or drained or lowhit):
        return ("## Validity checks\n\n"
                "- No command saturated the network link.\n"
                "- The load generator stayed below its CPU ceiling.\n"
                "- No workload ran its keyspace empty.\n"
                "- Read workloads found the keys they asked for.\n\n"
                "Every figure above is a property of the server under test.")

    out = ["## Validity checks", "",
           "These decide which numbers mean anything. A result produced against a full",
           "cable or a maxed-out load generator is a measurement of the rig, not the",
           "server.", "",
           "**What \"wire-bound\" means, in plain terms:** every request and reply travels",
           "over the machine's network connection, which has a fixed top speed (its",
           "bandwidth). When a command moves enough data to fill that connection, the",
           "network, not the server, becomes the bottleneck: the server could go faster but",
           "the wire cannot carry any more. The ops/sec figure then measures the cable",
           "rather than the software. Read a wire-bound number as a floor (the true server",
           "number is higher, and shows up on a faster link or with a smaller value size,",
           "which puts fewer bytes on the wire per operation). Any ratio between two servers",
           "that are both wire-bound is meaningless. The \"link used\" column is the share of",
           "the link a command consumed; the threshold for the flag is "
           f"{WIRE_BOUND_PCT:.0f}%.", "",
           "> Caveat for cloud NICs: the \"link used\" figure assumes one link speed for both",
           "> directions. Some cloud instances cap outbound (send) and inbound (receive)",
           "> differently, so an inbound-heavy command (writes) can show a high figure",
           "> without actually being limited. Where that applies it is called out in a",
           "> NOTES.md next to this report.", ""]
    if wire:
        out += [f"### Wire-bound ({len(wire)})", "",
                f"These used at or above {WIRE_BOUND_PCT:.0f}% of the network link, so the link set the",
                "number, not the server. Treat them as lower bounds, and see the caveat above",
                "if this instance meters send and receive bandwidth differently.", "",
                "| command | server | link used |", "|---|---|---|"]
        out += [f"| {c} | {s} | {u:.0f}% |" for c, s, u in wire]
        out.append("")
    if client:
        out += [f"### Client-bound ({len(client)})", "",
                f"The load generators sat above {CLIENT_BOUND_PCT:.0f}% CPU, so these figures may be",
                "the load generators' ceiling rather than the server's. Treat them as lower bounds.", "",
                "| command | server | client CPU |", "|---|---|---|"]
        out += [f"| {c} | {s} | {u:.0f}% |" for c, s, u in client]
        out.append("")
    if drained:
        out += [f"### Keyspace drained ({len(drained)})", "",
                "These ran the store empty part-way through, so most replies were nil.",
                "The figure is nil-reply throughput, not the command named.", "",
                "| command | server |", "|---|---|"]
        out += [f"| {c} | {s} |" for c, s in drained]
        out.append("")
    if lowhit:
        out += [f"### Low hit rate ({len(lowhit)})", "",
                f"Below {LOW_HIT_PCT:.0f}% of reads found their key, so these measure the miss",
                "path. A miss returns nil rather than a value: cheap for the server and",
                "nearly free on the wire, which inflates ops/sec.", "",
                "| command | server | hit rate |", "|---|---|---|"]
        out += [f"| {c} | {s} | {h:.1f}% |" for c, s, h in lowhit]
        out.append("")
    return "\n".join(out)


def ratio_section(d, base="HotKV"):
    rd = d.get("results_detail", {}) or {}
    if base not in rd:
        return ""
    others = [s for s in rd if s != base]
    if not others:
        return ""
    commands = [c for c in rd[base]]

    def capped(r):
        return (r.get("link_util_pct") or 0) >= WIRE_BOUND_PCT or \
               (r.get("client_cpu_saturation_pct") or 0) >= CLIENT_BOUND_PCT

    out = [f"## {base} vs each server", "",
           f"{base}'s throughput divided by the other server's, on the same command. Where a",
           "figure was flagged above (wire-bound or client-bound), the true figure may be",
           f"higher, and the ratio is given as a bound: `>=` where {base}'s was flagged, `<=`",
           "where the other server's was, and no ratio where both were.", "",
           "| command | " + " | ".join(f"vs {o}" for o in others) + " |",
           "|---" * (len(others) + 1) + "|"]
    for cmd in commands:
        ours = rd[base].get(cmd, {}).get("ops", 0)
        if not ours:
            continue
        ours_capped = capped(rd[base].get(cmd, {}))
        cells = []
        for o in others:
            theirs = rd[o].get(cmd, {}).get("ops", 0)
            if not theirs:
                cells.append("-")
                continue
            theirs_capped = capped(rd[o].get(cmd, {}))
            ratio = ours / theirs
            if ours_capped and theirs_capped:
                cells.append("n/a (both limited by the rig)")
            elif ours_capped:
                cells.append(f">= {ratio:.2f}x")
            elif theirs_capped:
                cells.append(f"<= {ratio:.2f}x")
            else:
                cells.append(f"{ratio:.2f}x")
        out.append(f"| {cmd} | " + " | ".join(cells) + " |")

    # The median per server stands for the whole run, where the best single
    # ratio would stand for one command. A capped figure of base's is a floor,
    # so with any in, the median is a floor too; ratios over the other server's
    # capped figures are left out.
    medians = []
    for o in others:
        ratios, floors = [], False
        for cmd in commands:
            ours = rd[base].get(cmd, {}).get("ops", 0)
            theirs = rd[o].get(cmd, {}).get("ops", 0)
            if not ours or not theirs or capped(rd[o].get(cmd, {})):
                continue
            ratios.append(ours / theirs)
            floors = floors or capped(rd[base].get(cmd, {}))
        if ratios:
            ratios.sort()
            mid = len(ratios) // 2
            med = ratios[mid] if len(ratios) % 2 else (ratios[mid - 1] + ratios[mid]) / 2
            medians.append(f"{'>= ' if floors else ''}{med:.2f}x vs {o} ({len(ratios)} commands)")
    if medians:
        out += ["", "Median ratio over the commands above: " + ", ".join(medians) + "."]

    losses = []
    for cmd in commands:
        ours = rd[base].get(cmd, {}).get("ops", 0)
        if not ours:
            continue
        for o in others:
            theirs = rd[o].get(cmd, {}).get("ops", 0)
            if theirs > ours:
                losses.append((cmd, o, ours, theirs))
    if losses:
        out += ["", f"### Where {base} is slower", "",
                f"Commands on which another server measured higher throughput than {base}.", "",
                "| command | server | theirs | ours | gap |", "|---|---|---|---|---|"]
        for cmd, o, ours, theirs in losses:
            out.append(f"| {cmd} | {o} | {fmt(theirs)} | {fmt(ours)} | "
                       f"{(theirs/ours - 1)*100:.1f}% faster |")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("comparison_json")
    ap.add_argument("-o", "--output", help="write here instead of stdout")
    ap.add_argument("--title", default=None)
    ap.add_argument("--banner", default=None,
                    help="Callout inserted right after the title, rendered as a blockquote "
                         "(e.g. a rig-specific caveat). Use '\\n' for line breaks.")
    args = ap.parse_args()

    d = load(args.comparison_json)
    si = d.get("system_info", {}) or {}
    ts = d.get("timestamp", "")
    try:
        date = datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%Y-%m-%d")
    except Exception:
        date = ts[:10] or "unknown date"

    title = args.title or (
        f"{si.get('platform_name','benchmark')}, {d.get('datasize','?')}B, "
        f"pipeline={d.get('pipeline','?')} - {date}")

    banner = None
    if args.banner:
        banner = "> " + args.banner.replace("\\n", "\n> ")

    parts = [
        f"# {title}",
        "",
        *([banner, ""] if banner else []),
        rig_section(d),
        "",
        config_section(d),
        "",
        throughput_section(d),
        "",
        resource_section(d),
        "",
        validity_section(d),
        "",
        ratio_section(d),
        "",
        "---",
        "",
        f"Data: `{args.comparison_json.split('/')[-1]}`. It carries every individual run, not just the medians shown here.",
        "",
        "Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named only to identify the software that was measured; this implies no sponsorship, endorsement or affiliation.",
    ]
    text = "\n".join(p for p in parts if p is not None)

    if args.output:
        with open(args.output, "w") as f:
            f.write(text + "\n")
        print(f"Wrote {args.output}", file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    main()
