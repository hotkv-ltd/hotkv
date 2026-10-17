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
# =============================================================================
"""Vector-search benchmark: HotKV (VSIM.*) against Redis 8 vector sets (VADD/VSIM).

One program drives both servers with the same code:
  * start each server on its own fixed set of CPUs, the load generators on others;
  * load N vectors into an HNSW index (same M and ef_construction on both,
    full-precision float32 on both: Redis runs with NOQUANT);
  * measure recall@10 against exact brute-force ground truth;
  * measure queries per second and latency with 1..50 concurrent client connections.

Only plain vector search is used: no filters, no attributes, no quantization,
none of HotKV's AI engines. The client is a small RESP2 client written for this
benchmark; the request bytes are built once, before the timed part, so client-side
float formatting is not in the measured query time.

Run `python3 vsbench.py --help` for the options. The orchestration for the published
results is in run_all.sh.
"""
from __future__ import annotations

import argparse
import array
import json
import multiprocessing as mp
import os
import platform
import resource
import signal
import socket
import statistics
import subprocess
import sys
import time

import numpy as np

DIMS = 1536
K = 10
CLK_TCK = os.sysconf("SC_CLK_TCK")
HOTKV_BIN = os.environ.get("HOTKV_BIN", "/opt/hotkv/build/release/src/hotkv")
REDIS_BIN = os.environ.get("REDIS_BIN", "/opt/redis-8.10.2/src/redis-server")
PORTS = {"hotkv": 6440, "redis": 6441}

# --------------------------------------------------------------------------- RESP


class RespError(Exception):
    pass


class Conn:
    """Minimal RESP2 client. Replies this benchmark sees are simple strings,
    errors, integers, bulk strings and flat arrays of those."""

    __slots__ = ("s", "buf", "pos")

    def __init__(self, port, host="127.0.0.1", timeout=300.0):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        self.pos = 0

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass

    def _more(self):
        chunk = self.s.recv(1 << 16)
        if not chunk:
            raise ConnectionError("server closed the connection")
        self.buf = self.buf[self.pos:] + chunk
        self.pos = 0

    def _line(self):
        while True:
            i = self.buf.find(b"\r\n", self.pos)
            if i >= 0:
                line = self.buf[self.pos:i]
                self.pos = i + 2
                return line
            self._more()

    def reply(self):
        line = self._line()
        t = line[:1]
        if t == b"+":
            return line[1:]
        if t == b"-":
            raise RespError(line[1:].decode(errors="replace"))
        if t == b":":
            return int(line[1:])
        if t == b"$":
            n = int(line[1:])
            if n < 0:
                return None
            while len(self.buf) - self.pos < n + 2:
                self._more()
            d = self.buf[self.pos:self.pos + n]
            self.pos += n + 2
            return d
        if t == b"*":
            n = int(line[1:])
            if n < 0:
                return None
            return [self.reply() for _ in range(n)]
        raise RespError(f"unexpected reply {line!r}")

    def call(self, payload: bytes):
        self.s.sendall(payload)
        return self.reply()

    def cmd(self, *parts):
        return self.call(resp(parts))


def _b(x) -> bytes:
    if isinstance(x, bytes):
        return x
    return str(x).encode()


def bulk(x) -> bytes:
    b = _b(x)
    return b"$%d\r\n%s\r\n" % (len(b), b)


def resp(parts) -> bytes:
    return b"*%d\r\n" % len(parts) + b"".join(bulk(p) for p in parts)


def vec_fragment(row: np.ndarray) -> bytes:
    """The 1,536 components of one vector as consecutive RESP bulk strings.
    %.9g is enough digits to round-trip a float32 exactly."""
    return b"".join(bulk("%.9g" % x) for x in row.tolist())


def command(prefix, frag: bytes, suffix) -> bytes:
    n = len(prefix) + DIMS + len(suffix)
    return b"*%d\r\n" % n + b"".join(bulk(p) for p in prefix) + frag + b"".join(bulk(p) for p in suffix)


# --------------------------------------------------------------------------- engines


def add_cmd(engine, idx, key, frag, m, efc, cas):
    if engine == "hotkv":
        return command(["VSIM.SET", idx, key], frag, [])
    suffix = [key] + (["CAS"] if cas else []) + ["NOQUANT", "EF", efc, "M", m]
    return command(["VADD", idx, "VALUES", DIMS], frag, suffix)


def search_cmd(engine, idx, frag, ef):
    if engine == "hotkv":
        return command(["VSIM.SEARCH", idx, K], frag, ["EF", ef])
    return command(["VSIM", idx, "VALUES", DIMS], frag, ["WITHSCORES", "COUNT", K, "EF", ef])


def create_index(engine, c: Conn, idx, m, efc):
    if engine == "hotkv":
        c.cmd("VSIM.CREATEINDEX", idx, DIMS, "METRIC", "cosine", "M", m, "EF_CONSTRUCTION", efc)


def drop_index(engine, c: Conn, idx):
    if engine == "hotkv":
        c.cmd("VSIM.DROPINDEX", idx)
    else:
        c.cmd("DEL", idx)


def index_count(engine, c: Conn, idx) -> int:
    if engine == "hotkv":
        r = c.cmd("VSIM.INFO", idx)
        for i in range(0, len(r) - 1, 2):
            if r[i] == b"vectors":
                return int(r[i + 1])
        raise RuntimeError(f"VSIM.INFO has no 'vectors' field: {r!r}")
    return int(c.cmd("VCARD", idx))


# --------------------------------------------------------------------------- servers


def proc_cpu_seconds(pid: int) -> float:
    with open(f"/proc/{pid}/stat") as fh:
        f = fh.read().rsplit(")", 1)[1].split()
    return (int(f[11]) + int(f[12])) / CLK_TCK


def proc_rss_bytes(pid: int) -> int:
    with open(f"/proc/{pid}/status") as fh:
        for line in fh:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) * 1024
    return -1


class Server:
    def __init__(self, engine, cpus, threads, log_dir, extra=None, port=None):
        self.engine, self.cpus, self.threads = engine, cpus, threads
        self.port = port or PORTS[engine]
        if engine == "hotkv":
            argv = [HOTKV_BIN, "--port", str(self.port), "--bind", "127.0.0.1", "--threads", str(threads),
                    "--no-snapshot", "--protected-mode", "no", "--loglevel", "warning"]
        else:
            argv = [REDIS_BIN, "--port", str(self.port), "--bind", "127.0.0.1", "--save", "",
                    "--appendonly", "no", "--protected-mode", "no", "--loglevel", "warning"]
            if threads > 1:
                argv += ["--io-threads", str(threads)]
        argv += list(extra or [])
        self.argv = ["taskset", "-c", cpus] + argv
        self.log = open(os.path.join(log_dir, f"{engine}_server.log"), "ab")
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(["bash", "-c", "ulimit -n 1048576; exec \"$@\"", "bash"] + self.argv,
                                     stdout=self.log, stderr=self.log, stdin=subprocess.DEVNULL)
        for _ in range(600):
            try:
                c = Conn(self.port, timeout=5)
                c.cmd("PING")
                c.close()
                return self
            except (OSError, RespError):
                if self.proc.poll() is not None:
                    raise RuntimeError(f"{self.engine} exited with {self.proc.returncode}, see its log")
                time.sleep(0.1)
        raise RuntimeError(f"{self.engine} did not start")

    @property
    def pid(self):
        return self.proc.pid

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()

    def info_text(self):
        c = Conn(self.port)
        out = c.cmd("INFO")
        c.close()
        return out.decode(errors="replace") if isinstance(out, bytes) else str(out)


# --------------------------------------------------------------------------- ingestion

VEC = None  # float32 memmap of all rows, set in main() before any fork


def _ingest_worker(p, nproc, engine, port, idx, n, depth, m, efc, cas, barrier, pipe):
    try:
        c = Conn(port)
        rows = range(1 + p, n, nproc)
        barrier.wait(120)
        sent = anomalies = 0
        batch = []
        t0 = time.monotonic()
        for r in rows:
            batch.append(add_cmd(engine, idx, "d%d" % r, vec_fragment(VEC[r]), m, efc, cas))
            if len(batch) == depth:
                c.s.sendall(b"".join(batch))
                for _ in batch:
                    rep = c.reply()
                    if engine == "redis" and rep != 1:
                        anomalies += 1
                sent += len(batch)
                batch = []
        if batch:
            c.s.sendall(b"".join(batch))
            for _ in batch:
                rep = c.reply()
                if engine == "redis" and rep != 1:
                    anomalies += 1
            sent += len(batch)
        pipe.send(("ok", sent, anomalies, time.monotonic() - t0))
    except Exception as e:  # noqa: BLE001
        pipe.send(("err", repr(e)))
    finally:
        pipe.close()


def ingest(server: Server, idx, n, nproc, depth, m, efc, cas, log):
    """Load rows 0..n-1 into a fresh index over `nproc` connections. Row 0 goes first on its
    own connection (it creates the set); the rest are spread over the connections."""
    engine = server.engine
    c = Conn(server.port)
    try:
        drop_index(engine, c, idx)
    except RespError:
        pass
    create_index(engine, c, idx, m, efc)
    c.call(add_cmd(engine, idx, "d0", vec_fragment(VEC[0]), m, efc, False))
    ctx = mp.get_context("fork")
    barrier = ctx.Barrier(nproc + 1)
    pipes, procs = [], []
    for p in range(nproc):
        a, b = ctx.Pipe(duplex=False)
        pr = ctx.Process(target=_ingest_worker, args=(p, nproc, engine, server.port, idx, n, depth, m, efc, cas, barrier, b))
        pr.start()
        pipes.append(a)
        procs.append(pr)
    barrier.wait(120)
    cpu0 = proc_cpu_seconds(server.pid)
    t0 = time.monotonic()
    results = [a.recv() for a in pipes]
    t1 = time.monotonic()
    cpu1 = proc_cpu_seconds(server.pid)
    for pr in procs:
        pr.join()
    bad = [r for r in results if r[0] != "ok"]
    if bad:
        raise RuntimeError(f"ingest worker failed: {bad[0]}")
    total = 1 + sum(r[1] for r in results)
    anomalies = sum(r[2] for r in results)
    count = index_count(engine, c, idx)
    c.close()
    secs = t1 - t0
    out = {"engine": engine, "index": idx, "vectors": n, "connections": nproc, "pipeline_depth": depth,
           "cas": bool(cas) if engine == "redis" else None, "seconds": round(secs, 2),
           "vectors_per_sec": round((n - 1) / secs, 1), "sent": total, "count_in_server": count,
           "nonstandard_replies": anomalies, "server_cpu_seconds": round(cpu1 - cpu0, 1),
           "server_cores_used": round((cpu1 - cpu0) / secs, 2), "server_rss_bytes": proc_rss_bytes(server.pid)}
    if count != n or total != n:
        raise RuntimeError(f"{engine} {idx}: sent {total}, server reports {count}, expected {n}")
    log(f"  ingest {engine} {idx}: {n} vectors, {nproc} conn, {secs:.1f}s = {out['vectors_per_sec']:.0f}/s, "
        f"server used {out['server_cores_used']} cores, rss {out['server_rss_bytes'] / 1e9:.2f} GB")
    return out


# --------------------------------------------------------------------------- queries


def encode_queries(engine, idx, ef, frags):
    return [search_cmd(engine, idx, f, ef) for f in frags]


def ids_of(reply):
    return [int(reply[i][1:]) for i in range(0, len(reply), 2)]


def recall_pass(port, cmds, gt):
    c = Conn(port)
    rec = []
    short = 0
    for qi, payload in enumerate(cmds):
        r = c.call(payload)
        ids = ids_of(r)
        if len(ids) < K:
            short += 1
        rec.append(len(set(ids[:K]) & set(gt[qi].tolist())) / K)
    c.close()
    a = np.asarray(rec)
    return {"recall_at_10": float(a.mean()), "stdev_per_query": float(a.std()), "queries": len(rec),
            "replies_with_fewer_than_10": short}


def _qps_worker(p, nproc, port, cmds, t_start, warm, dur, barrier, pipe):
    try:
        c = Conn(port)
        barrier.wait(120)
        L = len(cmds)
        i = (p * L) // nproc
        lat = array.array("d")
        short = 0
        count = 0
        mono = time.monotonic
        t_meas = t_start + warm
        t_end = t_meas + dur
        late = mono() > t_start + 0.05
        while mono() < t_start:
            pass
        ru0 = None
        sock, reply = c.s, c.reply
        while True:
            a = mono()
            if a >= t_end:
                break
            sock.sendall(cmds[i])
            r = reply()
            b = mono()
            i += 1
            if i == L:
                i = 0
            if b >= t_meas:
                if ru0 is None:
                    ru = resource.getrusage(resource.RUSAGE_SELF)
                    ru0 = (ru.ru_utime + ru.ru_stime, b)
                if b < t_end:
                    count += 1
                    lat.append(b - a)
                    if len(r) != 2 * K:
                        short += 1
        ru = resource.getrusage(resource.RUSAGE_SELF)
        cpu = (ru.ru_utime + ru.ru_stime) - ru0[0] if ru0 else 0.0
        busy = cpu / max(1e-9, mono() - ru0[1]) if ru0 else 0.0
        pipe.send(("ok", count, lat.tobytes(), short, busy, late))
    except Exception as e:  # noqa: BLE001
        pipe.send(("err", repr(e)))
    finally:
        pipe.close()


def measure(server: Server, cmds, nclients, warm, dur):
    ctx = mp.get_context("fork")
    barrier = ctx.Barrier(nclients + 1)
    t_start = time.monotonic() + 0.8 + 0.01 * nclients
    pipes, procs = [], []
    for p in range(nclients):
        a, b = ctx.Pipe(duplex=False)
        pr = ctx.Process(target=_qps_worker, args=(p, nclients, server.port, cmds, t_start, warm, dur, barrier, b))
        pr.start()
        pipes.append(a)
        procs.append(pr)
    barrier.wait(120)
    t_meas, t_end = t_start + warm, t_start + warm + dur
    while time.monotonic() < t_meas - 0.002:
        time.sleep(0.001)
    cpu0 = proc_cpu_seconds(server.pid)
    w0 = time.monotonic()
    while time.monotonic() < t_end - 0.002:
        time.sleep(0.001)
    cpu1 = proc_cpu_seconds(server.pid)
    w1 = time.monotonic()
    res = [a.recv() for a in pipes]
    for pr in procs:
        pr.join()
    bad = [r for r in res if r[0] != "ok"]
    if bad:
        raise RuntimeError(f"query worker failed: {bad[0]}")
    count = sum(r[1] for r in res)
    lat = np.frombuffer(b"".join(r[2] for r in res), dtype=np.float64)
    out = {"clients": nclients, "queries": count, "qps": count / dur,
           "p50_ms": float(np.percentile(lat, 50) * 1e3), "p99_ms": float(np.percentile(lat, 99) * 1e3),
           "mean_ms": float(lat.mean() * 1e3), "max_ms": float(lat.max() * 1e3),
           "server_cores_used": (cpu1 - cpu0) / (w1 - w0),
           "client_busy_max": max(r[4] for r in res), "client_busy_mean": statistics.mean(r[4] for r in res),
           "short_replies": sum(r[3] for r in res), "late_starts": sum(1 for r in res if r[5])}
    return out


# --------------------------------------------------------------------------- driver


def lscpu_text():
    return subprocess.run(["lscpu"], capture_output=True, text=True).stdout


def sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    global VEC
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--out", required=True, help="directory for results.json and logs")
    ap.add_argument("--engines", nargs="+", default=["hotkv", "redis"], choices=["hotkv", "redis"])
    ap.add_argument("--sizes", type=int, nargs="+", default=[100_000])
    ap.add_argument("--builds", type=int, nargs="+", default=[1], help="independent index builds per size (same order as --sizes)")
    ap.add_argument("--ef-recall", type=int, nargs="+", default=[10, 20, 40, 80, 150, 300, 500])
    ap.add_argument("--ef-qps", type=int, nargs="+", default=[20, 40, 80, 150, 300])
    ap.add_argument("--clients", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32, 50])
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--warm", type=float, default=1.5)
    ap.add_argument("--dur", type=float, default=6.0)
    ap.add_argument("--m", type=int, default=16)
    ap.add_argument("--ef-construction", type=int, default=200)
    ap.add_argument("--ingest-conns", type=int, default=32, help="loading connections (Redis; HotKV too unless --hotkv-ingest-conns)")
    ap.add_argument("--hotkv-ingest-conns", type=int, default=None)
    ap.add_argument("--ingest-depth", type=int, default=8)
    ap.add_argument("--redis-cas", action="store_true", help="VADD ... CAS (neighbour search in a background thread)")
    ap.add_argument("--hotkv-threads", type=int, default=96)
    ap.add_argument("--redis-io-threads", type=int, default=1)
    ap.add_argument("--server-cpus", default="0-95")
    ap.add_argument("--redis-rdb", default=None,
                    help="Redis only: if this file exists, Redis loads its indexes from it instead of building them; "
                         "otherwise the indexes are built and saved there (with <file>.ingest.json holding the load statistics)")
    ap.add_argument("--build-only", action="store_true", help="build (and save, with --redis-rdb) and stop")
    ap.add_argument("--port-offset", type=int, default=0, help="added to both server ports, so two runs can coexist")
    ap.add_argument("--note", default="")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    logf = open(os.path.join(args.out, "run.log"), "a")

    def log(msg):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    vectors = np.load(os.path.join(args.data_dir, "vectors.npy"), mmap_mode="r")
    VEC = vectors
    n_total = vectors.shape[0]
    q_rows = range(n_total - 1000, n_total)
    queries = [vec_fragment(vectors[r]) for r in q_rows]
    meta = {
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "args": vars(args), "python": sys.version, "numpy": np.__version__,
        "platform": platform.platform(), "lscpu": lscpu_text(),
        "client_cpus": sorted(os.sched_getaffinity(0)).__len__(),
        "binaries": {"hotkv": {"path": HOTKV_BIN, "sha256": sha256(HOTKV_BIN)},
                     "redis": {"path": REDIS_BIN, "sha256": sha256(REDIS_BIN)}},
        "hotkv_commit": open(os.path.expanduser("~/vsb/HOTKV_COMMIT")).read().strip() if os.path.exists(os.path.expanduser("~/vsb/HOTKV_COMMIT")) else None,
    }
    results = {"meta": meta, "ingest": [], "recall": [], "qps": []}

    def save():
        with open(os.path.join(args.out, "results.json"), "w") as fh:
            json.dump(results, fh, indent=1)

    save()
    log(f"engines {args.engines}, sizes {args.sizes}, clients {args.clients}, ef_qps {args.ef_qps}")
    for si, size in enumerate(args.sizes):
        nbuilds = args.builds[si] if si < len(args.builds) else args.builds[-1]
        gt = np.load(os.path.join(args.data_dir, f"gt_{size}.npy"))
        servers = {}
        rdb = args.redis_rdb.format(size=size) if args.redis_rdb else None
        rdb_exists = bool(rdb and os.path.exists(rdb))
        try:
            for e in args.engines:
                thr = args.hotkv_threads if e == "hotkv" else args.redis_io_threads
                extra = ["--dir", os.path.dirname(os.path.abspath(rdb)), "--dbfilename", os.path.basename(rdb)]                     if (e == "redis" and rdb) else None
                servers[e] = Server(e, args.server_cpus, thr, args.out, extra, PORTS[e] + args.port_offset).start()
                log(f"started {e} pid {servers[e].pid}: {' '.join(servers[e].argv)}")
            # ---- builds
            for b in range(1, nbuilds + 1):
                for e in args.engines:
                    if e == "redis" and rdb_exists:
                        cc = Conn(servers[e].port)
                        n_loaded = index_count(e, cc, f"bench{b}")
                        cc.close()
                        if n_loaded != size:
                            raise RuntimeError(f"{rdb}: bench{b} holds {n_loaded} vectors, expected {size}")
                        side = json.load(open(rdb + ".ingest.json"))
                        rec = dict(next(r for r in side if r["build"] == b))
                        rec["loaded_from_rdb"] = os.path.basename(rdb)
                        log(f"  redis bench{b}: {n_loaded} vectors loaded from {os.path.basename(rdb)} "
                            f"(built earlier at {rec['vectors_per_sec']:.0f}/s)")
                    else:
                        conns = args.hotkv_ingest_conns if (e == "hotkv" and args.hotkv_ingest_conns) else args.ingest_conns
                        rec = ingest(servers[e], f"bench{b}", size, conns, args.ingest_depth,
                                     args.m, args.ef_construction, args.redis_cas, log)
                        rec.update({"size": size, "build": b})
                        cc = Conn(servers[e].port)
                        info = cc.cmd("INFO", "memory")
                        cc.close()
                        for line in info.decode().splitlines():
                            if line.startswith("used_memory:"):
                                rec["used_memory_bytes"] = int(line.split(":")[1])
                    results["ingest"].append(rec)
                    save()
                    if args.build_only:
                        continue
                    for ef in args.ef_recall:
                        cmds = encode_queries(e, f"bench{b}", ef, queries)
                        r = recall_pass(servers[e].port, cmds, gt)
                        r.update({"engine": e, "size": size, "build": b, "ef": ef})
                        results["recall"].append(r)
                        log(f"  recall {e} build {b} ef {ef}: {r['recall_at_10']:.4f}")
                    save()
            if rdb and not rdb_exists and "redis" in servers:
                cc = Conn(servers["redis"].port, timeout=1800)
                t0 = time.monotonic()
                cc.cmd("SAVE")
                cc.close()
                log(f"  redis SAVE to {rdb}: {time.monotonic() - t0:.0f}s, {os.path.getsize(rdb) / 1e9:.2f} GB")
                with open(rdb + ".ingest.json", "w") as fh:
                    json.dump([r for r in results["ingest"] if r["engine"] == "redis" and r["size"] == size], fh, indent=1)
            if args.build_only:
                continue
            # ---- throughput on build 1, engines interleaved within every cell
            for ef in args.ef_qps:
                cmds = {e: encode_queries(e, "bench1", ef, queries) for e in args.engines}
                for nc in args.clients:
                    for trial in range(1, args.trials + 1):
                        order = list(args.engines)
                        if trial % 2 == 0:
                            order.reverse()
                        for e in order:
                            m_ = measure(servers[e], cmds[e], nc, args.warm, args.dur)
                            m_.update({"engine": e, "size": size, "ef": ef, "trial": trial})
                            results["qps"].append(m_)
                            log(f"  qps size {size} ef {ef} clients {nc:>2} trial {trial} {e:5}: {m_['qps']:9.0f} q/s "
                                f"p50 {m_['p50_ms']:.2f} ms p99 {m_['p99_ms']:.2f} ms server {m_['server_cores_used']:.1f} cores "
                                f"client-busy-max {m_['client_busy_max']:.2f}")
                    save()
            for e, s in servers.items():
                results.setdefault("server_info", {})[f"{e}_{size}"] = s.info_text()
            save()
        finally:
            for s in servers.values():
                s.stop()
    results["meta"]["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save()
    log("RUN DONE")


if __name__ == "__main__":
    main()
