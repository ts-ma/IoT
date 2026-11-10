"""Activity (HAR) window study: CV accuracy vs. display latency for shorter / recency-trained windows.

Companion of social_window_study.py (same replay, same output layout). Asked 2026-11-09: how fast can the
activity display react, and what does it cost on the official folds?

Candidates (all harry_cnn, the final HAR recipe on datasetJan2026: AdamW, balanced weights, seed 0):
  w50       4 s window (the current app model; reference)
  w38       3 s window
  w25       2 s window
  w50rec    4 s window trained with "recency" splices: half of the training windows have their first
            12-25 samples replaced by another training window (no gravity alignment: a posture change
            *is* a gravity change), label = the last 2-3 s, so the model answers from the most recent seconds.

Per candidate and official fold k: per-class recall on fold k's test windows (step 25, the marking), and the
app replay (32-sample packets, 0.5 s step) on (a) pairs of fold-k test recordings of different classes and
(b) activity changes in both group members' recordings (never trained on here). Latency is reported raw
(smoothing off) and with the app's display smoothing (majority of the last 3 results).

Output: results/har_window_study/{jobs/*.json, *.npz, summary.csv, report.md}
Run:    ./run_har_window_study.sh   (resumable; ~30-40 min on the M1 Pro; waits for the social study)
"""
import argparse
import dataclasses
import itertools
import json
import os
import sys
import time
import traceback
from collections import Counter, deque
from concurrent.futures import ProcessPoolExecutor, as_completed
from multiprocessing import get_context
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
OUT = HERE / "results" / "har_window_study"
JOBS = OUT / "jobs"
CANDS = {"w50": (50, False), "w38": (38, False), "w25": (25, False), "w50rec": (50, True)}
FOLDS = list(range(10))
PKT, FS, NA, NB = 32, 12.5, 150, 150           # 12 s before / 12 s after the change
STEP = 6
HAR = ["sittingStanding", "lyingBack", "lyingLeft", "lyingRight", "lyingStomach", "normalWalking",
       "shuffleWalking", "ascending", "descending", "running", "miscMovement"]
STATIC, DYNAMIC = HAR[:5], HAR[5:]


def init_worker(threads):
    os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
    os.environ["CUDA_VISIBLE_DEVICES"] = "-1"
    import warnings
    warnings.filterwarnings("ignore")
    import tensorflow as tf
    tf.get_logger().setLevel("ERROR")
    try:
        tf.config.threading.set_intra_op_parallelism_threads(threads)
        tf.config.threading.set_inter_op_parallelism_threads(2)
    except RuntimeError:
        pass


def _pairs_jan(k, rng, n=80):
    from fullrun.data import load_set
    sig, meta = load_set("jan_har")
    idx = [i for i in np.flatnonzero(meta.fold.to_numpy() == k) if meta.n[i] >= max(NA, NB)]
    y = meta.y.to_numpy()
    out = []
    while len(out) < n:
        a, b = rng.choice(idx, 2, replace=False)
        if y[a] != y[b]:
            out.append((sig[a], sig[b], int(y[b]), "jan", HAR[int(y[a])]))
    return out


def _pairs_real(rng, per_person=50):
    from fullrun.data import load_set
    sig, meta = load_set("real")
    out = []
    for person in meta.person.unique():
        m = meta[(meta.person == person) & (~meta.stationary | (meta["sub"] == "normal"))]
        cand = [(a, b) for a, b in itertools.permutations(m.index, 2) if m.har_y[a] != m.har_y[b]]
        for j in rng.choice(len(cand), min(per_person, len(cand)), replace=False):
            a, b = cand[j]
            out.append((sig[a], sig[b], int(meta.har_y[b]), person, HAR[int(meta.har_y[a])]))
    return out


def _display(P, smooth, phase):
    """Per-sample display (changes only at packet ends). P[t] = argmax of the window ending at t or -1."""
    n = len(P)
    q = deque(maxlen=3)
    since, shown, cur = 0, -1, -1
    disp = np.full(n, -1)
    for t in range(n):
        since += 1
        if P[t] >= 0 and since >= STEP:
            since = 0
            if smooth:
                q.append(P[t]); c = Counter(q); top = max(c.values())
                shown = next(l for l in reversed(q) if c[l] == top)
            else:
                shown = P[t]
        if (t - phase) % PKT == PKT - 1:
            cur = shown
        disp[t] = cur
    return disp


def _latency(disp, target, hold=int(4 * FS)):
    n = len(disp)
    for t in range(NA, n):
        if disp[t] == target and np.all(disp[t:min(n, t + hold)] == target):
            return (t - NA + 1) / FS
    return np.nan


def _stream_rows(model, W, streams, tag):
    rows, Xs, spans = [], [], []
    first = NA - 4 * PKT
    for s in streams:
        x = np.concatenate([s[0][-NA:], s[1][:NB]]).astype(np.float32)
        ends = np.arange(max(W - 1, first), len(x))
        Xs.append(np.stack([x[t - W + 1:t + 1] for t in ends])); spans.append(ends)
    Pall = model.predict(np.concatenate(Xs), batch_size=4096, verbose=0).argmax(1)
    o = 0
    for s, ends in zip(streams, spans):
        P = np.full(NA + NB, -1); P[ends] = Pall[o:o + len(ends)]; o += len(ends)
        target, src = s[2], s[4]
        kind = ("static" if src in STATIC else "dynamic") + "->" + ("static" if HAR[target] in STATIC else "dynamic")
        row = {"stream": tag, "person": s[3], "from": src, "target": HAR[target], "kind": kind,
               "steady_acc": float(np.mean(P[-100:] == target))}
        for smooth in (False, True):
            lat = [_latency(_display(P, smooth, ph), target) for ph in range(0, PKT, 8)]
            key = "sm" if smooth else "raw"
            row[f"lat_{key}"] = float(np.nanmean(lat)) if not np.all(np.isnan(lat)) else np.nan
            row[f"miss_{key}"] = float(np.mean(np.isnan(lat)))
        rows.append(row)
    return rows


def _recency(X, y, rng, p=0.5, kmin=25, kmax=38):
    X = X.copy()
    W = X.shape[1]
    kmax = min(kmax, W - 5)
    for i in np.flatnonzero(rng.random(len(X)) < p):
        k = int(rng.integers(kmin, kmax + 1))
        j = int(rng.integers(len(X)))
        X[i] = np.concatenate([X[j, :W - k], X[i, W - k:]])
    return X, y


def run_job(cand, k, epochs):
    JOBS.mkdir(parents=True, exist_ok=True)
    jid = f"{cand}_f{k}"
    t0 = time.time()
    res = {"id": jid, "cand": cand, "fold": k}
    try:
        import keras
        import harry.zoo as zoo
        from harry.runner import RECIPES, _fit
        from harry.metrics import per_class_recall
        from fullrun.data import windows
        W, rec_aug = CANDS[cand]
        zoo.ZOO["harry_cnn"] = dataclasses.replace(zoo.ZOO["harry_cnn"], windows={"har": W, "social": 100})
        keras.utils.set_random_seed(0)
        rng = np.random.default_rng(k)
        rec = dict(RECIPES[("harry", "jan")])
        if epochs:
            rec["epochs"] = epochs
        Xtr, ytr, _, _ = windows([("jan_har", {"fold_ne": k}, rec["step"])], "har", W)
        if rec_aug:
            Xtr, ytr = _recency(Xtr, ytr, rng)
        model = zoo.build("harry_cnn", "har", 11, Xtr)
        hist = _fit(model, Xtr, ytr, 11, rec, {}, [], "har", {"seed_base": 0}, None)
        Xte, yte, _, rid = windows([("jan_har", {"fold_eq": k}, 25)], "har", W)
        P = model.predict(Xte, batch_size=4096, verbose=0)
        recall, cm = per_class_recall(yte, P.argmax(1), 11)
        np.savez_compressed(JOBS / f"{jid}.npz", P=P, y=yte, rid=rid)
        rows = _stream_rows(model, W, _pairs_jan(k, np.random.default_rng(100 + k)), "jan")
        rows += _stream_rows(model, W, _pairs_real(np.random.default_rng(7)), "real")
        res.update(status="ok", window=W, recency=rec_aug, n_train=int(len(ytr)), n_test=int(len(yte)),
                   recall=dict(zip(HAR, map(float, recall))), confusion=cm.tolist(), streams=rows,
                   params=int(model.count_params()), epochs=rec["epochs"],
                   final_train_acc=hist[-1]["train_acc"] if hist else None)
        keras.backend.clear_session()
    except Exception:                                   # noqa: BLE001
        res.update(status="failed", error=traceback.format_exc())
    res["seconds"] = round(time.time() - t0, 1)
    (JOBS / f"{jid}.json").write_text(json.dumps(res, default=float))
    return jid, res["status"], res["seconds"]


def summarise():
    recs, streams = [], []
    for f in sorted(JOBS.glob("*.json")):
        r = json.loads(f.read_text())
        if r.get("status") != "ok":
            continue
        recs.append({"cand": r["cand"], "fold": r["fold"], **r["recall"]})
        streams += [{"cand": r["cand"], "fold": r["fold"], **s} for s in r["streams"]]
    if not recs:
        return
    R, S = pd.DataFrame(recs), pd.DataFrame(streams)
    acc = R.groupby("cand")[HAR].mean() * 100
    acc["static"] = acc[STATIC].mean(1); acc["dynamic"] = acc[DYNAMIC].mean(1)
    acc["min_dynamic"] = acc[DYNAMIC].min(1); acc["folds"] = R.groupby("cand").size()
    lat = S.groupby(["cand", "stream"]).agg(
        raw_med=("lat_raw", "median"), raw_mean=("lat_raw", "mean"), sm_med=("lat_sm", "median"),
        sm_mean=("lat_sm", "mean"), sm_p90=("lat_sm", lambda s: s.quantile(.9)), miss=("miss_sm", "mean"),
        steady=("steady_acc", "mean")).unstack("stream")
    lat.columns = [f"{a}_{b}" for a, b in lat.columns]
    by_kind = S[S.stream == "real"].groupby(["cand", "kind"]).lat_sm.median().unstack()
    order = [c for c in CANDS if c in acc.index]
    summ = acc.join(lat).reindex(order)
    summ.round(2).to_csv(OUT / "summary.csv")
    S.to_csv(OUT / "streams.csv", index=False); R.to_csv(OUT / "per_fold_recall.csv", index=False)
    g = lambda r, k: r.get(k, np.nan)
    lines = ["# Activity (HAR) window study", "",
             "Official 10-fold CV on datasetJan2026, harry_cnn, final HAR recipe, seed 0. Latency = app replay "
             "(32-sample packets = 2.56 s, 0.5 s step): seconds from the change until the new class is shown and kept "
             "4 s; *raw* = smoothing off, *smoothed* = the app default (majority of the last 3 results).", "",
             "| candidate | window | static | dynamic | weakest dynamic | folds | raw median (Jan / ours) | "
             "smoothed median (Jan / ours) | smoothed mean (Jan / ours) | smoothed p90 (Jan / ours) | miss % (ours) |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for c, r in summ.iterrows():
        W, aug = CANDS[c]
        lines.append(f"| {c} | {W / FS:.0f} s{' + recency' if aug else ''} | {r['static']:.1f} | {r['dynamic']:.1f} | "
                     f"{r['min_dynamic']:.1f} | {int(r['folds'])} | {g(r, 'raw_med_jan'):.1f} / {g(r, 'raw_med_real'):.1f} | "
                     f"{g(r, 'sm_med_jan'):.1f} / {g(r, 'sm_med_real'):.1f} | {g(r, 'sm_mean_jan'):.1f} / {g(r, 'sm_mean_real'):.1f} | "
                     f"{g(r, 'sm_p90_jan'):.1f} / {g(r, 'sm_p90_real'):.1f} | {100 * g(r, 'miss_real'):.0f} |")
    lines += ["", "Per-class recall (%):", "", "| candidate | " + " | ".join(HAR) + " |", "|---|" + "---|" * len(HAR)]
    for c, r in acc.reindex(order).iterrows():
        lines.append(f"| {c} | " + " | ".join(f"{r[h]:.1f}" for h in HAR) + " |")
    lines += ["", "Smoothed median latency on our recordings by kind of change (s):", "",
              "| candidate | " + " | ".join(by_kind.columns) + " |", "|---|" + "---|" * len(by_kind.columns)]
    for c, r in by_kind.reindex(order).iterrows():
        lines.append(f"| {c} | " + " | ".join(f"{v:.1f}" for v in r) + " |")
    lines += ["", "Pass marks: static mean >= 90 %, dynamic mean >= 85 %. Our recordings were never used for training "
              "here, so their latency is an unseen-person test."]
    (OUT / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--epochs", type=int, default=0, help="override epochs (smoke test)")
    ap.add_argument("--cands", default=",".join(CANDS))
    ap.add_argument("--folds", default=",".join(map(str, FOLDS)))
    ap.add_argument("--summary-only", action="store_true")
    a = ap.parse_args()
    if not a.summary_only:
        from fullrun.data import build_cache
        build_cache()
        todo = []
        for k in map(int, a.folds.split(",")):
            for c in a.cands.split(","):
                f = JOBS / f"{c}_f{k}.json"
                if not (f.exists() and json.loads(f.read_text()).get("status") == "ok"):
                    todo.append((c, k))
        print(f"{len(todo)} jobs to run", flush=True)
        t0 = time.time()
        with ProcessPoolExecutor(a.workers, mp_context=get_context("spawn"), initializer=init_worker,
                                 initargs=(a.threads,)) as ex:
            futs = [ex.submit(run_job, c, k, a.epochs) for c, k in todo]
            for i, fu in enumerate(as_completed(futs), 1):
                jid, st, sec = fu.result()
                print(f"{time.strftime('%H:%M:%S')} [{i}/{len(todo)}] {jid} {st} in {sec / 60:.1f} min · "
                      f"elapsed {(time.time() - t0) / 3600:.1f} h", flush=True)
    summarise()


if __name__ == "__main__":
    main()
