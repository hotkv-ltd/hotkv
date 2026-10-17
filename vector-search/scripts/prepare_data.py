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
"""Download the benchmark dataset and build the arrays the benchmark reads.

Dataset: KShivendu/dbpedia-entities-openai-1M on Hugging Face (MIT license).
1,000,000 DBpedia entities embedded with OpenAI text-embedding-ada-002
(1,536 dimensions). Attribution requested by the dataset card:
Kumar Shivendu and Nirant Kasliwal, "OpenAI 1M / dbpedia-entities-openai-1M",
https://huggingface.co/datasets/KShivendu/dbpedia-entities-openai-1M,
doi:10.57967/hf/6768

Row selection (rows are taken in the order of the parquet shards, shard 0 first):
  * the last 1,000 rows (999,000 to 999,999) are the held-out queries;
  * the base set is the first N rows, for N in --sizes (default 100000 999000).
    The 100,000-row base is a prefix of the 999,000-row base.
No query vector is in any base set.

Ground truth: the exact top 10 by cosine similarity, computed by brute force in
float64 on the float32 vectors both servers receive, independent of either server.
Ties at rank 10 are not broken specially (none were seen, see ground_truth_*.json).

Outputs in --data-dir:
  vectors.npy            float32, all 1,000,000 rows
  gt_<N>.npy             int32, shape (1000, 10): row numbers of the 10 nearest base rows
  dataset_meta.json      sizes, shard list with byte sizes, SHA-256 of vectors.npy
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import pyarrow.parquet as pq

DATASET = "KShivendu/dbpedia-entities-openai-1M"
API = f"https://huggingface.co/api/datasets/{DATASET}/tree/main/data"
BASE_URL = f"https://huggingface.co/datasets/{DATASET}/resolve/main/data"
DIMS = 1536
N_TOTAL = 1_000_000
N_QUERY = 1_000


def list_shards():
    with urllib.request.urlopen(API, timeout=60) as r:
        items = json.load(r)
    shards = sorted((i["path"].split("/")[-1], int(i["size"])) for i in items if i["path"].endswith(".parquet"))
    return shards


def fetch(args):
    raw_dir, name, size = args
    dest = os.path.join(raw_dir, name)
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        return name
    tmp = dest + ".part"
    urllib.request.urlretrieve(f"{BASE_URL}/{name}", tmp)
    if os.path.getsize(tmp) != size:
        raise RuntimeError(f"{name}: got {os.path.getsize(tmp)} bytes, expected {size}")
    os.replace(tmp, dest)
    return name


def sha256_file(path, chunk=1 << 24):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", default="data")
    ap.add_argument("--sizes", type=int, nargs="+", default=[100_000, 999_000])
    ap.add_argument("--gt-only", action="store_true",
                    help="vectors.npy already exists: only compute ground truth for --sizes (used for the smaller tuning sizes)")
    args = ap.parse_args()
    data_dir = os.path.abspath(args.data_dir)
    raw_dir = os.path.join(data_dir, "raw")
    os.makedirs(raw_dir, exist_ok=True)

    if args.gt_only:
        vecs = np.load(os.path.join(data_dir, "vectors.npy"), mmap_mode="r")
        meta_path = os.path.join(data_dir, "dataset_meta.json")
        meta = json.load(open(meta_path))
    else:
        shards = list_shards()
        print(f"{len(shards)} shards, {sum(s for _, s in shards) / 1e9:.2f} GB")
        t0 = time.time()
        with ThreadPoolExecutor(8) as ex:
            for name in ex.map(fetch, [(raw_dir, n, s) for n, s in shards]):
                pass
        print(f"downloaded in {time.time() - t0:.0f}s")

        vecs = np.empty((N_TOTAL, DIMS), dtype=np.float32)
        row = 0
        for name, _ in shards:
            t = pq.read_table(os.path.join(raw_dir, name), columns=["openai"])
            col = t.column("openai").combine_chunks()
            n = len(col)
            offsets = np.asarray(col.offsets)
            if not (np.diff(offsets) == DIMS).all():
                raise RuntimeError(f"{name}: not every embedding has {DIMS} values")
            flat = col.values.to_numpy(zero_copy_only=False)
            if row + n > N_TOTAL:
                raise RuntimeError("more rows than expected")
            vecs[row:row + n] = flat.reshape(n, DIMS).astype(np.float32)
            row += n
        if row != N_TOTAL:
            raise RuntimeError(f"read {row} rows, expected {N_TOTAL}")
        if not np.isfinite(vecs).all():
            raise RuntimeError("non-finite values in the embeddings")
        np.save(os.path.join(data_dir, "vectors.npy"), vecs)
        norms = np.linalg.norm(vecs[:10000].astype(np.float64), axis=1)
        print(f"{row} rows; norm of first 10000 rows: min {norms.min():.6f} max {norms.max():.6f}")
        meta = {"dataset": DATASET, "dims": DIMS, "n_total": N_TOTAL, "query_rows": [N_TOTAL - N_QUERY, N_TOTAL - 1],
                "shards": [{"name": n, "bytes": s} for n, s in shards], "ground_truth": {}}

    q0 = N_TOTAL - N_QUERY
    queries = np.asarray(vecs[q0:], dtype=np.float64)
    queries /= np.linalg.norm(queries, axis=1, keepdims=True)
    for n_base in args.sizes:
        if n_base > q0:
            raise SystemExit(f"base size {n_base} overlaps the query rows (limit {q0})")
        t0 = time.time()
        base = np.asarray(vecs[:n_base], dtype=np.float64)
        base /= np.linalg.norm(base, axis=1, keepdims=True)
        gt = np.empty((N_QUERY, 10), dtype=np.int32)
        margin_min = 1.0
        for s in range(0, N_QUERY, 50):
            sims = queries[s:s + 50] @ base.T
            top = np.argpartition(-sims, 10, axis=1)[:, :11]  # 11 so the rank 10/11 gap is visible
            for r in range(top.shape[0]):
                order = top[r][np.argsort(-sims[r, top[r]])]
                gt[s + r] = order[:10]
                margin_min = min(margin_min, float(sims[r, order[9]] - sims[r, order[10]]))
        np.save(os.path.join(data_dir, f"gt_{n_base}.npy"), gt)
        meta["ground_truth"][str(n_base)] = {"seconds": round(time.time() - t0, 1),
                                             "min_similarity_gap_rank10_to_rank11": margin_min}
        print(f"ground truth for {n_base} base rows in {time.time() - t0:.0f}s; smallest rank-10/11 gap {margin_min:.3e}")
        del base
    if "vectors_sha256" not in meta:
        meta["vectors_sha256"] = sha256_file(os.path.join(data_dir, "vectors.npy"))
    with open(os.path.join(data_dir, "dataset_meta.json"), "w") as fh:
        json.dump(meta, fh, indent=2)
    print("DATA DONE")


if __name__ == "__main__":
    main()
