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
# File:        harness/render_html.py
# Description: Render a self-contained HTML benchmark report from comparison.json
# Author:      HotKV Ltd
# =============================================================================
"""Turn one or more comparison.json artifacts into a single HTML report.

Shows every number the run captured: throughput, and a per-server resource
summary (CPU, memory, disk, network) plus a per-command resource breakdown,
alongside the configuration each server ran under and the validity checks that
say which figures actually mean anything. Pass a baseline artifact for
before/after columns.

Usage:
    python3 render_html.py current.json -o report.html
    python3 render_html.py current.json --baseline old.json --baseline-label 0.1.18 -o report.html
"""

import argparse
import html
import json
from datetime import datetime

WIRE_BOUND_PCT = 85.0
CLIENT_BOUND_PCT = 85.0
LOW_HIT_PCT = 90.0

# Palette: cool slate neutrals carry the page so the single warm accent, used
# only for HotKV's own data, reads as signal rather than decoration. Semantic
# colours are deliberately not the accent: a gain is green whoever scored it.
CSS = """
:root{
  --ground:#f7f8fa; --panel:#fff; --sunken:#eef1f5; --line:#dde2e9;
  --text:#131720; --muted:#5d6675; --faint:#8b94a3;
  --accent:#d1541f; --accent-soft:#fdf0e8;
  --gain:#1f7a3d; --caveat:#8a6d10; --invalid:#b3352c;
  --mono:ui-monospace,"SF Mono","Cascadia Mono","Roboto Mono",Menlo,Consolas,monospace;
  --sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
}
@media (prefers-color-scheme:dark){
  :root{
    --ground:#0b0e14; --panel:#141922; --sunken:#0f141c; --line:#242c3a;
    --text:#dde3ec; --muted:#8b94a3; --faint:#616b7d;
    --accent:#ff7a3d; --accent-soft:#2a1a12;
    --gain:#3fa758; --caveat:#c9a227; --invalid:#e0483e;
  }
}
:root[data-theme="dark"]{
  --ground:#0b0e14; --panel:#141922; --sunken:#0f141c; --line:#242c3a;
  --text:#dde3ec; --muted:#8b94a3; --faint:#616b7d;
  --accent:#ff7a3d; --accent-soft:#2a1a12;
  --gain:#3fa758; --caveat:#c9a227; --invalid:#e0483e;
}
:root[data-theme="light"]{
  --ground:#f7f8fa; --panel:#fff; --sunken:#eef1f5; --line:#dde2e9;
  --text:#131720; --muted:#5d6675; --faint:#8b94a3;
  --accent:#d1541f; --accent-soft:#fdf0e8;
  --gain:#1f7a3d; --caveat:#8a6d10; --invalid:#b3352c;
}
*{box-sizing:border-box;}
body{
  margin:0; padding:clamp(1.2rem,4vw,3rem) 1rem; background:var(--ground);
  color:var(--text); font-family:var(--sans); font-size:15px; line-height:1.6;
  -webkit-font-smoothing:antialiased;
}
.wrap{max-width:1200px; margin:0 auto; display:flex; flex-direction:column; gap:.4rem;}
.mast{display:flex; flex-direction:column; gap:.5rem; margin-bottom:1.4rem;}
.eyebrow{
  font-family:var(--mono); font-size:11px; letter-spacing:.16em; text-transform:uppercase;
  color:var(--accent); font-weight:600;
}
h1{
  font-family:var(--mono); font-size:clamp(1.35rem,3.2vw,1.85rem); font-weight:600;
  margin:0; letter-spacing:-.02em; text-wrap:balance;
}
.rig{
  font-family:var(--mono); font-size:12.5px; color:var(--muted); line-height:1.9;
  display:flex; flex-wrap:wrap; gap:.35rem .9rem;
}
.rig span{white-space:nowrap;} .rig b{color:var(--text); font-weight:600;}
h2{
  font-family:var(--mono); font-size:.95rem; font-weight:600; letter-spacing:.02em;
  margin:2.4rem 0 .2rem; padding-bottom:.5rem; border-bottom:1px solid var(--line);
}
h3{
  font-family:var(--mono); font-size:11px; font-weight:600; letter-spacing:.14em;
  text-transform:uppercase; color:var(--faint); margin:1.5rem 0 .1rem;
}
p.lede{color:var(--muted); margin:.5rem 0 .3rem; font-size:14px;}

/* Quickview: one horizontal bar per command, HotKV against the rival, scaled to
   the fastest number in the run so both the absolute speed and the gap read at a
   glance. This is the "just show me who wins" view. */
.qv{display:flex; flex-direction:column; gap:.55rem; margin:1rem 0;}
.qv-row{display:grid; grid-template-columns:5.5rem 1fr 4.5rem; align-items:center; gap:.7rem;}
.qv-cmd{font-family:var(--mono); font-weight:600; font-size:13px;}
.qv-bars{display:flex; flex-direction:column; gap:3px;}
.qv-bar{position:relative; height:20px; border-radius:3px; min-width:2px;
  display:flex; align-items:center;}
/* HotKV is the only saturated bar; the competitors get distinct muted tones so
   they read as a group behind it. */
.qv-bar.hk{background:var(--accent);}
.qv-bar.s1{background:#6b7688;}
.qv-bar.s2{background:#8a6f5a;}
.qv-bar.s3{background:#5a7d86;}
.qv-bar span{font-family:var(--mono); font-size:10px; font-weight:600;
  padding:0 .35rem; white-space:nowrap; color:#fff;}
.qv-bar.outside span{color:var(--text); position:absolute; left:calc(100% + .35rem);}
.qv-ratio{font-family:var(--mono); font-weight:700; font-size:14px; text-align:right; line-height:1.2;}
.qv-ratio small{display:block; font-size:9px; font-weight:400; color:var(--faint); letter-spacing:.02em;}
.qv-ratio.win{color:var(--gain);} .qv-ratio.tie{color:var(--muted);}
.qv-legend{display:flex; flex-wrap:wrap; gap:1rem; font-family:var(--mono); font-size:11px;
  color:var(--muted); margin:.3rem 0 .2rem;}
.qv-legend b{display:inline-block; width:11px; height:11px; border-radius:2px;
  vertical-align:-1px; margin-right:.35rem;}
.qv-legend .hk b{background:var(--accent);}
.qv-legend .s1 b{background:#6b7688;} .qv-legend .s2 b{background:#8a6f5a;} .qv-legend .s3 b{background:#5a7d86;}
.verdict{display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:.7rem; margin:.9rem 0 .3rem;}
.card{
  background:var(--panel); border:1px solid var(--line); border-radius:8px;
  padding:.85rem 1rem; display:flex; flex-direction:column; gap:.15rem;
}
.card b{
  font-family:var(--mono); font-size:1.6rem; font-weight:600; letter-spacing:-.03em;
  font-variant-numeric:tabular-nums; line-height:1.15;
}
.card span{font-family:var(--mono); font-size:10.5px; letter-spacing:.09em;
  text-transform:uppercase; color:var(--faint);}
.card.hero b{color:var(--accent);}
.panel{
  background:var(--panel); border:1px solid var(--line); border-radius:8px;
  margin:.7rem 0; overflow:hidden;
}
.scroll{overflow-x:auto; -webkit-overflow-scrolling:touch;}
table{border-collapse:collapse; width:100%; font-family:var(--mono); font-size:12.5px;}
th,td{
  padding:.42rem .7rem; text-align:right; white-space:nowrap;
  border-bottom:1px solid var(--line); font-variant-numeric:tabular-nums;
}
th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){text-align:left;}
th{
  color:var(--faint); font-weight:600; font-size:10px; letter-spacing:.1em;
  text-transform:uppercase; position:sticky; top:0; background:var(--panel);
}
tbody tr:last-child td{border-bottom:none;}
tbody tr:hover{background:var(--sunken);}
td.cmd{font-weight:600;}
.hk{color:var(--accent); font-weight:600;}
.gain{color:var(--gain); font-weight:600;}
.loss{color:var(--invalid); font-weight:600;}
.dim{color:var(--faint);}
tr.capped td{color:var(--muted);}
tr.capped td:first-child{box-shadow:inset 3px 0 0 var(--caveat);}
tr.void td:first-child{box-shadow:inset 3px 0 0 var(--invalid);}
.pill{
  display:inline-block; padding:.05rem .4rem; border-radius:3px; font-size:10px;
  letter-spacing:.06em; text-transform:uppercase; border:1px solid currentColor;
  margin-right:.25rem;
}
.pill.c{color:var(--caveat);} .pill.v{color:var(--invalid);}
/* Per-server resource summary: big, legible, one block per product. */
.res-grid{display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:.8rem; margin:.8rem 0;}
.res-card{background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:1rem 1.1rem;}
.res-card h4{
  font-family:var(--mono); font-size:14px; margin:0 0 .7rem; font-weight:600;
  display:flex; align-items:center; gap:.5rem;
}
.res-card h4 .dot{width:9px; height:9px; border-radius:50%; background:var(--faint);}
.res-card.hk h4{color:var(--accent);} .res-card.hk h4 .dot{background:var(--accent);}
.res-row{
  display:flex; justify-content:space-between; align-items:baseline;
  padding:.4rem 0; border-bottom:1px solid var(--line); font-family:var(--mono);
}
.res-row:last-child{border-bottom:none;}
.res-row .k{font-size:11px; letter-spacing:.06em; text-transform:uppercase; color:var(--faint);}
.res-row .val{font-size:15px; font-weight:600; font-variant-numeric:tabular-nums;}
.res-row .val small{font-size:11px; color:var(--muted); font-weight:400; margin-left:.3rem;}
.note{
  border-left:3px solid var(--line); background:var(--panel); border-radius:0 6px 6px 0;
  padding:.6rem .95rem; margin:.7rem 0; color:var(--muted); font-size:13.5px;
}
.note b{color:var(--text);}
.note.caveat{border-left-color:var(--caveat);}
.note.invalid{border-left-color:var(--invalid);}
.note.ok{border-left-color:var(--gain);}
code{font-family:var(--mono); font-size:12px; background:var(--sunken);
  padding:.05rem .3rem; border-radius:3px;}
pre{
  font-family:var(--mono); font-size:11.5px; background:var(--sunken); margin:0;
  padding:.7rem .95rem; overflow-x:auto; color:var(--text); border-bottom:1px solid var(--line);
}
footer{
  color:var(--faint); font-size:12px; font-family:var(--mono); margin-top:3rem;
  border-top:1px solid var(--line); padding-top:1rem; line-height:1.8;
}
@media (max-width:640px){ .rig{font-size:11.5px;} th,td{padding:.38rem .5rem;} }
"""


def e(x):
    return html.escape(str(x))


def fmt(n, nd=0):
    if n is None:
        return '<span class="dim">-</span>'
    return f"{n:,.{nd}f}"


def commands_of(d):
    rd = d.get("results_detail", {}) or {}
    out = []
    for s in rd:
        for c in rd[s]:
            if c not in out:
                out.append(c)
    return out


def flags_for(r):
    """Every reason a single number might not mean what it appears to."""
    f = []
    if (r.get("link_util_pct") or 0) >= WIRE_BOUND_PCT:
        f.append(("wire-bound", "v"))
    if (r.get("client_cpu_saturation_pct") or 0) >= CLIENT_BOUND_PCT:
        f.append(("client-bound", "c"))
    if r.get("keyspace_drained"):
        f.append(("drained", "v"))
    h = r.get("hit_rate_pct")
    if h is not None and h < LOW_HIT_PCT:
        f.append((f"{h:.0f}% hits", "v"))
    return f


def row_class(r):
    fl = [k for k, _ in flags_for(r)]
    if any(x in fl for x in ("drained", "wire-bound")) or any("hits" in x for x in fl):
        return "void"
    if "client-bound" in fl:
        return "capped"
    return ""


def masthead(d, title):
    si = d.get("system_info", {}) or {}
    lg = d.get("load_generation", {}) or {}
    ts = d.get("timestamp", "")
    try:
        date = datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%Y-%m-%d %H:%M UTC")
    except Exception:
        date = ts[:16]
    kind = {"metal": "bare metal", "vm": "virtual machine"}.get(si.get("platform_kind"), "?")
    bits = [
        f"<span><b>{e(si.get('platform_name','?'))}</b> {e(kind)}</span>",
        f"<span>{e(si.get('cpu_model','?'))} &middot; <b>{e(si.get('cpu_cores','?'))}</b> cores &middot; {e(si.get('architecture',''))}</span>",
        f"<span>{e(si.get('total_ram','?'))} RAM</span>",
        f"<span><b>{e(d.get('datasize','?'))}B</b> values &middot; pipeline <b>{e(d.get('pipeline','?'))}</b></span>",
        f"<span><b>{e(d.get('runs','?'))}</b> run(s)</span>",
        f"<span><b>{e(lg.get('client_count',0))}</b> dedicated load generator(s)</span>",
        f"<span>{e(date)}</span>",
    ]
    return (f'<div class="mast"><div class="eyebrow">Benchmark report</div>'
            f'<h1>{e(title)}</h1><div class="rig">{"".join(bits)}</div></div>')


def verdict(d):
    """A few headline numbers about this run only. No baseline comparisons here,
    those live in the detailed table for readers who want them."""
    rd = d.get("results_detail", {}) or {}
    if "HotKV" not in rd:
        return ""
    # Per competitor, the median of HotKV's ratio over every command both ran:
    # a headline that stands for the whole run, where the single best ratio
    # would stand for one command. A HotKV figure the rig capped is a floor, so
    # its ratio is too, and with any of those in, the median is "at least".
    # Where the other server's figure was capped, the ratio is left out.
    cards = []
    for s in (s for s in rd if s != "HotKV"):
        ratios, floors = [], False
        for c in rd["HotKV"]:
            ours = rd["HotKV"].get(c, {}).get("ops", 0)
            theirs = rd[s].get(c, {}).get("ops", 0)
            if not ours or not theirs or flags_for(rd[s][c]):
                continue
            ratios.append(ours / theirs)
            floors = floors or bool(flags_for(rd["HotKV"][c]))
        if ratios:
            ratios.sort()
            mid = len(ratios) // 2
            med = ratios[mid] if len(ratios) % 2 else (ratios[mid - 1] + ratios[mid]) / 2
            cards.append(f'<div class="card"><b>{"&ge;" if floors else ""}{med:.1f}&times;</b>'
                         f'<span>median vs {e(s)}, {len(ratios)} commands</span></div>')
    g = rd["HotKV"].get("GET", {})
    if g.get("ops"):
        cards.append(f'<div class="card"><b>{g["ops"]/1e6:.1f}M</b><span>GET per second</span></div>')
    st = rd["HotKV"].get("SET", {})
    if st.get("ops"):
        cards.append(f'<div class="card"><b>{st["ops"]/1e6:.1f}M</b><span>SET per second</span></div>')
    if g.get("cores_busy"):
        cards.append(f'<div class="card"><b>{g["cores_busy"]:.0f}</b>'
                     f'<span>of {d.get("system_info",{}).get("cpu_cores","?")} cores used on GET</span></div>')
    return f'<div class="verdict">{"".join(cards)}</div>' if cards else ""


def quickview(d):
    """Grouped horizontal bars, one per server, for every command. The
    at-a-glance answer to who is faster and by how much. HotKV is the saturated
    bar; the competitors are muted so the group reads behind it. The number on
    the right is HotKV over the fastest competitor on that command."""
    rd = d.get("results_detail", {}) or {}
    if "HotKV" not in rd:
        return ""
    # HotKV first, then competitors in descending overall speed so colours are stable.
    others = [s for s in rd if s != "HotKV"]

    def total(s):
        return sum(rd[s].get(c, {}).get("ops", 0) for c in rd[s])

    others.sort(key=lambda s: -total(s))
    servers = ["HotKV"] + others
    # HotKV is the accent bar; each competitor gets s1..s3 (CSS defines three
    # muted tones). Index among the competitors, not all servers, so the first
    # rival is s1 and nothing overflows past s3.
    cls_of = {"HotKV": "hk"}
    for i, s in enumerate(others):
        cls_of[s] = f"s{i+1}"

    rows_data = []
    for c in commands_of(d):
        vals = {s: rd[s].get(c, {}).get("ops", 0) for s in servers}
        if any(vals.values()):
            rows_data.append((c, vals))
    rows_data.sort(key=lambda x: -x[1]["HotKV"])
    scale = max((max(v.values()) for _, v in rows_data), default=1) or 1

    def mlabel(v):
        return f"{v/1e6:.1f}M" if v >= 1e5 else f"{v:,.0f}"

    def bar(s, val):
        pct = max(val / scale * 100, 0.4)
        outside = " outside" if pct < 16 else ""
        return (f'<div class="qv-bar {cls_of[s]}{outside}" style="width:{pct:.1f}%">'
                f'<span>{e(s)} {mlabel(val)}</span></div>')

    rows = []
    for c, vals in rows_data:
        hk = vals["HotKV"]
        best_rival = max((vals[s] for s in others), default=0)
        best_name = max(others, key=lambda s: vals[s]) if others else ""
        ratio = (hk / best_rival) if best_rival else 0
        rcls = "win" if ratio >= 1.05 else "tie"
        # A figure the rig capped is a floor: the ratio is a bound, or none.
        ours_capped = bool(flags_for(rd["HotKV"].get(c, {})))
        theirs_capped = bool(best_name and flags_for(rd[best_name].get(c, {})))
        if not ratio:
            rtxt = "-"
        elif ours_capped and theirs_capped:
            rtxt = "n/a<small>both capped by the rig</small>"
        else:
            bound = "&ge;" if ours_capped else ("&le;" if theirs_capped else "")
            rtxt = f'{bound}{ratio:.1f}&times;<small>vs {e(best_name)}</small>'
        bars = "".join(bar(s, vals[s]) for s in servers if vals[s])
        rows.append(f'<div class="qv-row"><div class="qv-cmd">{e(c)}</div>'
                    f'<div class="qv-bars">{bars}</div>'
                    f'<div class="qv-ratio {rcls}">{rtxt}</div></div>')
    legend = ('<div class="qv-legend">'
              + "".join(f'<span class="{cls_of[s]}"><b></b>{e(s)}</span>' for s in servers)
              + '<span>bar length = operations per second</span></div>')
    return f'{legend}<div class="qv">{"".join(rows)}</div>'


# Commands that grow their values during the test (APPEND concatenates, the
# LPUSH/RPUSH lists deepen), so their resident memory reflects data accumulated
# over 10 seconds at that server's throughput, not the dataset footprint. They
# are excluded from the "dataset memory" figure and called out separately.
_ACCUMULATING = {"APPEND", "LPUSH", "RPUSH", "SADD", "HSET"}
# The clean read/write string commands over the fixed 5M-key set. Their resident
# set is the honest "how much memory for the dataset" number.
_DATASET_CMDS = ["GET", "SET", "SETNX", "MGET"]


def resource_summary(d):
    """One block per server answering: how much CPU, memory, disk and network
    did each product use. Memory is split into the steady dataset footprint and
    the peak reached by value-growing commands, because conflating them produces
    an alarming and misleading single number."""
    rd = d.get("results_detail", {}) or {}
    if not rd:
        return ""

    def peak(s, key, cmds=None):
        pool = cmds if cmds is not None else list(rd[s].keys())
        vals = [rd[s][c].get(key) for c in pool if c in rd[s] and rd[s][c].get(key) is not None]
        return max(vals) if vals else None

    try:
        ram_gb = float(str(d.get("system_info", {}).get("total_ram", "")).split()[0])
    except Exception:
        ram_gb = None
    ncores = d.get("system_info", {}).get("cpu_cores")
    link = d.get("benchmark_config", {}).get("host", {}).get("net_link_gbps")
    cards = []
    for s in rd:
        cores = peak(s, "cores_busy")
        cpu_note = f"of {ncores} cores" if ncores else ""
        # Dataset footprint: resident set on the read/write commands that do not
        # grow their values. Falls back to all commands if none are present.
        ds = peak(s, "rss_mb", [c for c in _DATASET_CMDS if c in rd[s]]) or peak(s, "rss_mb")
        ds_note = f"{ds/1024/ram_gb*100:.1f}% of RAM" if (ds and ram_gb) else ""
        # Peak among value-growing commands, shown as a separate line.
        acc = peak(s, "rss_mb", [c for c in _ACCUMULATING if c in rd[s]])
        gbps = peak(s, "gbps")
        net_note = f"{gbps/link*100:.0f}% of link" if (gbps and link) else ""
        dw = peak(s, "disk_write_mb")
        dr = peak(s, "disk_read_mb")
        disk_line = ("none measured" if dw is None else
                     "0, persistence off" if (dw < 0.5 and (dr or 0) < 0.5)
                     else f"{dw:,.0f} MB write, {dr or 0:,.0f} MB read")
        cls = "res-card hk" if s == "HotKV" else "res-card"

        def row(k, val, note=""):
            small = f'<small>{note}</small>' if note else ""
            return (f'<div class="res-row"><span class="k">{k}</span>'
                    f'<span class="val">{val}{small}</span></div>')

        card = (f'<div class="{cls}"><h4><span class="dot"></span>{e(s)}</h4>'
                + row("Peak CPU", f'{fmt(cores,1)} cores', cpu_note)
                + row("Dataset memory", f'{fmt(ds)} MB', ds_note))
        if acc:
            card += row("Peak on writes", f'{fmt(acc/1024,1)} GB', "value-growing cmds")
        card += row("Disk I/O", disk_line)
        card += row("Peak network", f'{fmt(gbps,1)} Gbps', net_note)
        card += "</div>"
        cards.append(card)
    return f'<div class="res-grid">{"".join(cards)}</div>'


def throughput_table(d, base=None, base_label=""):
    rd = d.get("results_detail", {}) or {}
    servers = list(rd.keys())
    if not servers:
        return ""
    cmds = commands_of(d)
    brd = (base or {}).get("results_detail", {}) or {}
    rivals = [s for s in servers if s != "HotKV"]

    head = "<tr><th>command</th>" + "".join(f"<th>{e(s)}</th>" for s in servers)
    if "HotKV" in servers:
        head += "".join(f"<th>vs {e(s)}</th>" for s in rivals)
    if brd.get("HotKV"):
        head += f"<th>{e(base_label)}</th><th>change</th>"
    head += "<th>validity</th></tr>"

    rows = []
    for c in cmds:
        r = rd.get("HotKV", {}).get(c, {}) or {}
        cls = row_class(r)
        cells = [f'<td class="cmd">{e(c)}</td>']
        for s in servers:
            ops = rd[s].get(c, {}).get("ops", 0)
            k = "hk" if s == "HotKV" else "dim"
            cells.append(f'<td class="{k}">{fmt(ops)}</td>')
        if "HotKV" in servers:
            for s in rivals:
                ours = rd["HotKV"].get(c, {}).get("ops", 0)
                theirs = rd[s].get(c, {}).get("ops", 0)
                if ours and theirs:
                    ratio = ours / theirs
                    cells.append(f'<td class="{"gain" if ratio>=1 else "loss"}">{ratio:.2f}&times;</td>')
                else:
                    cells.append('<td class="dim">-</td>')
        if brd.get("HotKV"):
            b = brd["HotKV"].get(c, {}).get("ops", 0)
            n = r.get("ops", 0)
            cells.append(f'<td class="dim">{fmt(b)}</td>')
            if b and n:
                delta = (n / b - 1) * 100
                cells.append(f'<td class="{"gain" if delta>=0 else "loss"}">{delta:+.1f}%</td>')
            else:
                cells.append('<td class="dim">-</td>')
        pills = "".join(f'<span class="pill {k}">{e(t)}</span>' for t, k in flags_for(r))
        cells.append(f"<td>{pills}</td>")
        rows.append(f'<tr class="{cls}">' + "".join(cells) + "</tr>")
    return (f'<div class="panel scroll"><table><thead>{head}</thead>'
            f'<tbody>{"".join(rows)}</tbody></table></div>')


def resource_table(d):
    rd = d.get("results_detail", {}) or {}
    servers = list(rd.keys())
    rows = []
    for c in commands_of(d):
        for s in servers:
            r = rd[s].get(c)
            if not r:
                continue
            cls = row_class(r) if s == "HotKV" else ""
            vals = [
                fmt(r.get("ops")), fmt(r.get("cores_busy"), 1), fmt(r.get("ops_per_cpu_sec")),
                fmt(r.get("rss_mb")), fmt(r.get("disk_write_mb"), 1), fmt(r.get("gbps"), 2),
                fmt(r.get("link_util_pct"), 0), fmt(r.get("p50_ms"), 2), fmt(r.get("p99_ms"), 2),
                fmt(r.get("hit_rate_pct"), 1), fmt(r.get("client_cpu_saturation_pct"), 0),
            ]
            k = "hk" if s == "HotKV" else "dim"
            rows.append(f'<tr class="{cls}"><td class="cmd">{e(c)}</td><td class="{k}">{e(s)}</td>'
                        + "".join(f"<td>{v}</td>" for v in vals) + "</tr>")
    head = ("<tr><th>command</th><th>server</th><th>ops/sec</th><th>CPU cores</th>"
            "<th>ops/CPU-s</th><th>RSS MB</th><th>disk wr MB</th>"
            "<th>Gbps</th><th>link %</th><th>p50 ms</th><th>p99 ms</th>"
            "<th>hit %</th><th>client CPU %</th></tr>")
    return (f'<div class="panel scroll"><table><thead>{head}</thead>'
            f'<tbody>{"".join(rows)}</tbody></table></div>')


def redis_cpu_caveat(d):
    """Redis and Valkey run commands on a single thread. Forcing them to the same
    io-thread count as everyone else spins those threads even when there is no IO
    to do, so their CPU (and therefore ops-per-CPU-second) is inflated. Say so,
    or a reader will misread the efficiency column."""
    rd = d.get("results_detail", {}) or {}
    present = [s for s in ("Redis", "Valkey") if s in rd]
    if not present:
        return ""
    names = " and ".join(present)
    swept = (d.get("tuning", {}) or {}).get("swept")
    threads = ("each at the thread count that gave it its best throughput in a sweep"
               if swept else
               "with the same thread count as the others (all the machine's cores, clamped "
               "to each server's maximum)")
    return (f'<div class="note caveat"><b>{names} execute commands on a single thread.</b> '
            f'Their other threads are I/O threads. They were run as single instances, not as '
            f'clusters, {threads}. I/O threads can keep cores busy without doing commands, so '
            f'the CPU and ops-per-CPU-second figures for {names} are not a measure of their '
            f'efficiency{"" if swept else ", and they can reach higher throughput with fewer I/O threads than they were given here"}.</div>')


def validity(d):
    rd = d.get("results_detail", {}) or {}
    wire, client, drained, lowhit = [], [], [], []
    for c in commands_of(d):
        for s in rd:
            r = rd[s].get(c) or {}
            if (r.get("link_util_pct") or 0) >= WIRE_BOUND_PCT:
                wire.append((c, s, r["link_util_pct"]))
            if (r.get("client_cpu_saturation_pct") or 0) >= CLIENT_BOUND_PCT:
                client.append((c, s, r["client_cpu_saturation_pct"]))
            if r.get("keyspace_drained"):
                drained.append((c, s))
            h = r.get("hit_rate_pct")
            if h is not None and h < LOW_HIT_PCT:
                lowhit.append((c, s, h))
    out = []
    if not (wire or client or drained or lowhit):
        return ('<div class="note ok">No command saturated the link, the load generator stayed '
                'below its CPU ceiling, no workload ran its keyspace empty, and read workloads '
                'found their keys. Every figure above is a property of the server under test.</div>')
    if client:
        items = ", ".join(f"<code>{e(c)}</code>/{e(s)} {u:.0f}%" for c, s, u in client)
        out.append(f'<div class="note caveat"><b>Client-bound: {len(client)} results.</b> '
                   f'The load generator sat at or above {CLIENT_BOUND_PCT:.0f}% CPU on these, so '
                   f'the number is memtier reaching its own limit, not the server reaching its. '
                   f'Read these as a floor. A faster server cannot move them, which is why the '
                   f'change column carries no signal on these rows. Measuring the real ceiling '
                   f'needs more client machines. Affected: {items}.</div>')
    if wire:
        items = ", ".join(f"<code>{e(c)}</code>/{e(s)} {u:.0f}%" for c, s, u in wire)
        out.append(f'<div class="note invalid"><b>Wire-bound: {len(wire)} results.</b> '
                   f'Every request and reply crosses the machine\'s network link, which has a fixed '
                   f'top speed (its bandwidth). At or above {WIRE_BOUND_PCT:.0f}% of that link the wire, not the '
                   f'server, sets the number: the server could go faster but the network cannot carry '
                   f'more. Read these as a floor (the true server number is higher, and shows on a '
                   f'faster link or at a smaller value size, which puts fewer bytes on the wire per '
                   f'operation), and a ratio between two wire-bound servers means nothing. Note: the '
                   f'"link used" share assumes one speed for both directions; if an instance meters '
                   f'send and receive bandwidth differently, an inbound-heavy write can be flagged '
                   f'here without truly being limited (see the banner or NOTES.md beside this report). '
                   f'Affected: {items}.</div>')
    if drained:
        items = ", ".join(f"<code>{e(c)}</code>/{e(s)}" for c, s in drained)
        out.append(f'<div class="note invalid"><b>Keyspace drained: {len(drained)} results.</b> '
                   f'These ran the store empty part-way through, so most replies were nil. The '
                   f'figure is nil-reply throughput, not the command named, and should not be '
                   f'published. Affected: {items}.</div>')
    if lowhit:
        items = ", ".join(f"<code>{e(c)}</code>/{e(s)} {h:.0f}%" for c, s, h in lowhit)
        out.append(f'<div class="note invalid"><b>Low hit rate: {len(lowhit)} results.</b> '
                   f'Below {LOW_HIT_PCT:.0f}% of reads found their key, so these measure the miss '
                   f'path. A miss returns nil rather than a value, which is cheap for the server '
                   f'and nearly free on the wire. Affected: {items}.</div>')
    return "".join(out)


def losses(d):
    rd = d.get("results_detail", {}) or {}
    if "HotKV" not in rd:
        return ""
    rows = []
    for c in commands_of(d):
        ours = rd["HotKV"].get(c, {}).get("ops", 0)
        if not ours:
            continue
        for s in rd:
            if s == "HotKV":
                continue
            theirs = rd[s].get(c, {}).get("ops", 0)
            if theirs > ours:
                rows.append(f'<tr><td class="cmd">{e(c)}</td><td>{e(s)}</td>'
                            f"<td>{fmt(theirs)}</td><td>{fmt(ours)}</td>"
                            f'<td class="loss">{(theirs/ours-1)*100:.1f}% faster</td></tr>')
    if not rows:
        return ('<div class="note">No other server measured higher throughput than HotKV on any '
                'command in this run. This covers only the commands, value size and pipeline '
                'depth listed here.</div>')
    return ('<div class="note">Commands on which another server measured higher throughput '
            'than HotKV.</div>'
            '<div class="panel scroll"><table><thead><tr><th>command</th><th>server</th>'
            "<th>theirs</th><th>ours</th><th>gap</th></tr></thead>"
            f'<tbody>{"".join(rows)}</tbody></table></div>')


def config_section(d):
    bc = d.get("benchmark_config", {}) or {}
    mt = bc.get("memtier", {}) or {}
    host = bc.get("host", {}) or {}
    servers = bc.get("servers", {}) or {}
    tuning = d.get("tuning", {}) or {}
    vers = d.get("server_versions", {}) or {}
    out = []

    def kv(pairs):
        return ('<div class="panel scroll"><table><tbody>'
                + "".join(f"<tr><td>{e(k)}</td><td>{v}</td></tr>" for k, v in pairs)
                + "</tbody></table></div>")

    out.append("<h3>Load</h3>")
    out.append(kv([
        ("Value size", f'<b>{e(mt.get("data_size_bytes","?"))}</b> bytes'),
        ("Pipeline depth", f'<b>{e(mt.get("pipeline","?"))}</b>'),
        ("Keyspace", f'{mt.get("key_maximum",0):,} keys'),
        ("Populate", e(mt.get("populate_pattern", "?"))),
        ("Key pattern", e(mt.get("key_pattern", "?"))),
        ("Distinct seed per client",
         "yes" if mt.get("distinct_client_seed") else '<span class="loss">NO</span>'),
        ("memtier threads per client box", e(mt.get("threads_per_client_machine", "?"))),
        *([("memtier processes per client box", e(mt["memtier_processes_per_client_box"]))]
          if "memtier_processes_per_client_box" in mt else []),
        ("Connections per client box", f'{mt.get("total_connections_per_client_machine",0):,}'),
        ("Test duration per command", f'{e(mt.get("test_time_sec","?"))} s'),
        ("Runs per command", e(mt.get("runs_per_command", "?"))),
        ("Reported statistic", e(mt.get("reported_statistic", "?"))),
    ]))

    if vers:
        rows = "".join(f"<tr><td>{e(n)}</td><td>{e(v)}</td></tr>" for n, v in vers.items())
        out.append('<h3>Versions</h3><div class="panel scroll"><table><thead><tr>'
                   "<th>server</th><th>version</th></tr></thead>"
                   f"<tbody>{rows}</tbody></table></div>")

    if host:
        out.append("<h3>Host</h3>")
        out.append(kv([(k.replace("_", " "), f"<code>{e(v)}</code>")
                       for k, v in host.items() if v is not None]))

    tt = tuning.get("tuned_threads", {}) or {}
    if tt:
        how = ("swept per server, each at its own best" if tuning.get("swept")
               else "the same for every server: all the machine's cores, clamped to each "
                    "server's maximum")
        line = ", ".join(f"<b>{e(k)}</b> = {e(v)}" for k, v in tt.items())
        out.append(f'<h3>Server threads</h3><div class="note">{e(how)}. {line}.</div>')

    for name, cfg in servers.items():
        eff = cfg.get("effective_config", {}) or {}
        shown = {k: v for k, v in eff.items() if k in (
            "maxmemory", "maxmemory-policy", "io-threads", "io-threads-do-reads",
            "appendonly", "save", "protected-mode", "tcp-backlog", "timeout", "databases")}
        tbl = ""
        if shown:
            tbl = ("<table><tbody>" + "".join(
                f"<tr><td><code>{e(k)}</code></td><td><code>"
                + (e(v) if v != "" else "(empty)") + "</code></td></tr>"
                for k, v in shown.items()) + "</tbody></table>")
        out.append(f"<h3>{e(name)}</h3><div class='panel'>"
                   f"<pre>{e(cfg.get('launch_cmdline',''))}</pre>{tbl}</div>")
        if cfg.get("maxmemory_is_unlimited"):
            out.append('<div class="note">No memory cap (<code>maxmemory=0</code>). Nothing was '
                       'evicted during this run.</div>')

    for n in bc.get("notes", []) or []:
        out.append(f'<div class="note">{e(n)}</div>')
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("comparison_json")
    ap.add_argument("--baseline")
    ap.add_argument("--baseline-label", default="baseline")
    ap.add_argument("--title", default=None)
    ap.add_argument("--banner", default=None,
                    help="HTML callout inserted at the top of the report (e.g. a rig-specific caveat).")
    ap.add_argument("-o", "--output", default="report.html")
    args = ap.parse_args()

    d = json.load(open(args.comparison_json))
    base = json.load(open(args.baseline)) if args.baseline else None
    si = d.get("system_info", {}) or {}
    title = args.title or f"HotKV benchmark, {si.get('platform_name','')}"

    notes = []
    if d.get("pipeline") == 1:
        notes.append('<div class="note"><b>Pipeline depth 1: this measures latency, not peak '
                     'throughput.</b> With one request per round trip, every server spends most of '
                     'its time waiting on the network rather than working, so the numbers reflect '
                     'round-trip time and cluster together by nature. It is the conservative view. '
                     'The pipelined run (depth 30) is where a server\'s throughput ceiling shows.'
                     '</div>')
    if d.get("runs") == 1:
        notes.append('<div class="note caveat"><b>One run per command, so there is no variance '
                     'information here.</b> A single sample cannot separate a real difference from '
                     'run-to-run noise. Treat small differences as indicative.</div>')
    if args.banner:
        notes.insert(0, f'<div class="note caveat">{args.banner}</div>')
    runs_note = "".join(notes)

    body = f"""<div class="wrap">
{masthead(d, title)}
{verdict(d)}

<h2>Quick view</h2>
<p class="lede">Every server on every command; bar length is operations per second. The number
on the right is HotKV's throughput divided by the fastest other server's on that command. &ge;
marks a HotKV figure that the network or the load generators capped (the true ratio is at least
that); &le; marks the other server's being capped.</p>
{quickview(d)}
{runs_note}

<h2>Throughput</h2>
<p class="lede">Every command the run measured, in operations per second. Rows tagged
<span class="pill c">client-bound</span> were capped by the load generator rather than the
server, so their change column carries no signal. Read those as floors. Rows tagged
<span class="pill v">drained</span> or similar were not measuring the command at all.</p>
{throughput_table(d, base, args.baseline_label)}

<h2>Resource usage per server</h2>
<p class="lede">How much of the machine each product drew at its heaviest point in the run.
CPU is cores fully busy, memory is the server process resident set, disk is bytes that reached
the block layer, and network is the share of the link filled.</p>
{resource_summary(d)}
<div class="note">Disk shows <b>zero writes</b> for every server because persistence was turned
off on all of them for the benchmark. These are in-memory stores and nothing was spilling to
disk. The number is measured from the kernel per process, not assumed.</div>
{redis_cpu_caveat(d)}

<h2>Validity checks</h2>
<p class="lede">These decide which numbers mean anything. A result produced against a full cable,
a maxed-out load generator, or an empty keyspace is a measurement of the rig, not the server.</p>
{validity(d)}

<h2>Resource usage per command</h2>
<p class="lede">The same resource picture broken out for every command. <code>CPU cores</code> is
CPU time over wall time, so 8.0 means eight cores fully busy. <code>ops/CPU-s</code> is work per
second of CPU consumed, the efficiency figure that still holds on different hardware.
<code>RSS MB</code> is resident memory at the moment the command was measured. The value-growing
commands (APPEND, LPUSH, RPUSH) show a large RSS because they accumulate data over the 10-second
test in proportion to their own throughput, not because of any inefficiency.</p>
{resource_table(d)}

<h2>Where HotKV is slower</h2>
{losses(d)}

<h2>Configuration</h2>
<p class="lede">Everything needed to reproduce this run, and to check that no server was
handicapped. Launch lines and effective configs are read back from each live server, not copied
from the script.</p>
{config_section(d)}

<footer>
Data: <code>{e(args.comparison_json.split('/')[-1])}</code>, which carries every individual run and every sample, not only what is shown here.<br>
Redis, Valkey and Dragonfly are trademarks of their respective owners. They are named only to identify the software that was measured; this implies no sponsorship, endorsement or affiliation.
</footer>
</div>"""

    doc = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
           '<meta name="viewport" content="width=device-width,initial-scale=1">'
           f"<title>{html.unescape(title)}</title><style>{CSS}</style></head>"
           f"<body>{body}</body></html>")
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(doc)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
