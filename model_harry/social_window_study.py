"""Social-signal window study: CV accuracy vs. display latency for shorter / recency-trained windows.

Why: the app shows a new social result ~6-7 s after a change (8 s window + 2.56 s RESpeck packets).
Question: how much official-fold accuracy does a faster model cost?

Candidates (all harry_rnn, final social recipe: Jan recipe, class weights balanced^0.6, seed 0):
  w100      8 s window (the current design; reference)
  w75       6 s window
  w62       5 s window
  w50       4 s window
  w100rec   8 s window trained with "recency" splices: half of the training windows have their first
            25-62 samples replaced by another training window (gravity-aligned), label = the last part,
            so the model learns to answer from the most recent 3-6 s.

Per candidate and official fold k (trained on folds != k of datasetJan2026, listed recordings only):
  accuracy  per-class recall on fold k's test windows (step 25), exactly like the marking
  latency   replay of the app (32-sample packets every 2.56 s, update step 6 = 0.5 s, no smoothing):
            seconds from a social-signal change until the display shows the new class and keeps it 4 s.
            Streams: (a) pairs of fold-k test recordings (unseen subjects, gravity-aligned),
                     (b) same-posture pairs of both group members' recordings (never used for training here).

Output: results/social_window_study/{jobs/*.json, *.npz, summary.csv, report.md}
Run:    ./run_social_window_study.sh   (resumable; ~2-3 h on the M1 Pro with 4 workers)
"""
import argparse
import dataclasses
import itertools
import json
import os
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from multiprocessing import get_context
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
OUT = HERE / "results" / "social_window_study"
JOBS = OUT / "jobs"
CANDS = {"w100": (100, False), "w75": (75, False), "w62": (62, False), "w50": (50, False), "w100rec": (100, True)}
FOLDS = list(range(10))
PKT, FS, NA, NB = 32, 12.5, 200, 300           # packet size; 16 s before / 24 s after the change
STEPS = (6, 12)
SOCIAL = ["breathingNormally", "coughing", "hyperventilation", "other"]


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


# ───────────────────────── streams for the latency replay
def _pairs_jan(k, rng, n=80):
    from fullrun.data import load_set
    sig, meta = load_set("jan_social")
    idx = [i for i in np.flatnonzero(meta.fold.to_numpy() == k) if meta.n[i] >= max(NA, NB)]
    y = meta.y.to_numpy()
    out = []
    while len(out) < n:
        a, b = rng.choice(idx, 2, replace=False)
        if y[a] != y[b]:
            out.append((sig[a], sig[b], int(y[b])))
    return out


def _pairs_real(rng, per_person=40):
    from fullrun.data import load_set
    sig, meta = load_set("real")
    out = []
    for person in meta.person.unique():
        st = meta[(meta.person == person) & (meta.social_y >= 0)]
        cand = [(a, b) for a, b in itertools.permutations(st.index, 2)
                if st.posture[a] == st.posture[b] and st.social_y[a] != st.social_y[b]]
        for j in rng.choice(len(cand), min(per_person, len(cand)), replace=False):
            a, b = cand[j]
            out.append((sig[a], sig[b], int(meta.social_y[b]), person))
    return out


def _stream(a, b, align):
    A, B = a[-NA:], b[:NB]
    if align:                                       # different subjects: remove the gravity jump at the seam
        B = B - B[:25].mean(0) + A[-25:].mean(0)
    return np.concatenate([A, B]).astype(np.float32)


def _latency(P, target, step, phase, hold=int(4 * FS)):
    """P[t] = argmax of the window ending at sample t (-1 if none). Replays packets + step; returns seconds."""
    n = len(P)
    since, last, cur = 0, -1, -1
    disp = np.full(n, -1)
    for t in range(n):
        since += 1
        if P[t] >= 0 and since >= step:
            since, last = 0, P[t]
        if (t - phase) % PKT == PKT - 1:
            cur = last
        disp[t] = cur
    for t in range(NA, n):
        if disp[t] == target and np.all(disp[t:min(n, t + hold)] == target):
            return (t - NA + 1) / FS
    return np.nan


def _stream_rows(model, W, streams, align, tag):
    rows = []
    first = NA - 3 * PKT                            # earlier windows cannot affect the display after the change
    Xs, spans = [], []
    for s in streams:
        x = _stream(s[0], s[1], align)
        ends = np.arange(max(W - 1, first), len(x))
        Xs.append(np.stack([x[t - W + 1:t + 1] for t in ends])); spans.append(ends)
    Pall = model.predict(np.concatenate(Xs), batch_size=4096, verbose=0).argmax(1)
    o = 0
    for s, ends in zip(streams, spans):
        P = np.full(NA + NB, -1); P[ends] = Pall[o:o + len(ends)]; o += len(ends)
        target = s[2]
        row = {"stream": tag, "person": s[3] if len(s) > 3 else "jan", "target": SOCIAL[target],
               "steady_acc": float(np.mean(P[-150:] == target))}
        for step in STEPS:
            lat = [_latency(P, target, step, ph) for ph in range(0, PKT, 8)]
            row[f"lat_s{step}"] = float(np.nanmean(lat)) if not np.all(np.isnan(lat)) else np.nan
            row[f"miss_s{step}"] = float(np.mean(np.isnan(lat)))
        rows.append(row)
    return rows


# ───────────────────────── one (candidate, fold) job
def _recency(X, y, rng, p=0.5, kmin=38, kmax=75):
    X = X.copy()
    W = X.shape[1]
    for i in np.flatnonzero(rng.random(len(X)) < p):
        k = int(rng.integers(kmin, kmax + 1))       # samples of the labelled recording kept at the end
        j = int(rng.integers(len(X)))
        pre = X[j, :W - k] - X[j, :W - k].mean(0) + X[i, W - k:].mean(0)
        X[i] = np.concatenate([pre, X[i, W - k:]])
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
        zoo.ZOO["harry_rnn"] = dataclasses.replace(zoo.ZOO["harry_rnn"], windows={"har": 50, "social": W})
        keras.utils.set_random_seed(0)
        rng = np.random.default_rng(k)
        rec = dict(RECIPES[("harry", "jan")], balance_power=0.6)
        if epochs:
            rec["epochs"] = epochs
        Xtr, ytr, _, _ = windows([("jan_social", {"fold_ne": k}, rec["step"])], "social", W)
        if rec_aug:
            Xtr, ytr = _recency(Xtr, ytr, rng)
        model = zoo.build("harry_rnn", "social", 4, Xtr)
        hist = _fit(model, Xtr, ytr, 4, rec, {}, [], "social", {"seed_base": 0}, None)
        Xte, yte, _, rid = windows([("jan_social", {"fold_eq": k}, 25)], "social", W)
        P = model.predict(Xte, batch_size=4096, verbose=0)
        recall, cm = per_class_recall(yte, P.argmax(1), 4)
        np.savez_compressed(JOBS / f"{jid}.npz", P=P, y=yte, rid=rid)
        rows = _stream_rows(model, W, _pairs_jan(k, np.random.default_rng(100 + k)), True, "jan")
        rows += _stream_rows(model, W, _pairs_real(np.random.default_rng(7)), False, "real")
        res.update(status="ok", window=W, recency=rec_aug, n_train=int(len(ytr)), n_test=int(len(yte)),
                   recall=dict(zip(SOCIAL, map(float, recall))), confusion=cm.tolist(), streams=rows,
                   params=int(model.count_params()), epochs=rec["epochs"],
                   final_train_acc=hist[-1]["train_acc"] if hist else None)
        keras.backend.clear_session()
    except Exception:                                   # noqa: BLE001
        res.update(status="failed", error=traceback.format_exc())
    res["seconds"] = round(time.time() - t0, 1)
    (JOBS / f"{jid}.json").write_text(json.dumps(res, default=float))
    return jid, res["status"], res["seconds"]


# ───────────────────────── summary
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
    acc = R.groupby("cand")[SOCIAL].mean() * 100
    acc["mean"] = acc[SOCIAL].mean(1); acc["min_class"] = acc[SOCIAL].min(1)
    acc["folds"] = R.groupby("cand").size()
    worst_fold = R.assign(m=R[SOCIAL].min(1)).groupby("cand").m.min() * 100
    acc["worst_fold_min_class"] = worst_fold
    lat = S.groupby(["cand", "stream"]).agg(lat_med=("lat_s6", "median"), lat_mean=("lat_s6", "mean"),
                                            lat_p90=("lat_s6", lambda s: s.quantile(.9)),
                                            miss=("miss_s6", "mean"), steady=("steady_acc", "mean")).unstack("stream")
    lat.columns = [f"{a}_{b}" for a, b in lat.columns]
    lat_t = S[S.stream == "real"].groupby(["cand", "target"]).lat_s6.median().unstack()
    summ = acc.join(lat).reindex([c for c in CANDS if c in acc.index])
    summ.round(2).to_csv(OUT / "summary.csv")
    S.to_csv(OUT / "streams.csv", index=False); R.to_csv(OUT / "per_fold_recall.csv", index=False)
    lines = ["# Social window study", "",
             "Official 10-fold CV on datasetJan2026 (listed recordings), harry_rnn, class weights balanced^0.6, seed 0. "
             "Latency = app replay with 32-sample packets (2.56 s) and a 0.5 s update step: seconds from the change "
             "until the new class is shown and kept for 4 s (`miss` = never reached within 24 s).", "",
             "| candidate | window | breathing | coughing | hyperv. | other | mean | min class | worst fold min | folds | "
             "latency median (Jan / ours) | mean (Jan / ours) | p90 (Jan / ours) | miss % (Jan / ours) |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c, r in summ.iterrows():
        W, aug = CANDS[c]
        g = lambda k: r.get(k, np.nan)
        lines.append(f"| {c} | {W / FS:.0f} s{' + recency' if aug else ''} | " + " | ".join(f"{r[s]:.1f}" for s in SOCIAL)
                     + f" | {r['mean']:.1f} | {r['min_class']:.1f} | {r['worst_fold_min_class']:.1f} | {int(r['folds'])} | "
                     f"{g('lat_med_jan'):.1f} / {g('lat_med_real'):.1f} | {g('lat_mean_jan'):.1f} / {g('lat_mean_real'):.1f} | "
                     f"{g('lat_p90_jan'):.1f} / {g('lat_p90_real'):.1f} | {100 * g('miss_jan'):.0f} / {100 * g('miss_real'):.0f} |")
    lines += ["", "Median latency on our recordings by the class switched to (s):", "",
              "| candidate | " + " | ".join(lat_t.columns) + " |", "|---|" + "---|" * len(lat_t.columns)]
    for c, r in lat_t.reindex([c for c in CANDS if c in lat_t.index]).iterrows():
        lines.append(f"| {c} | " + " | ".join(f"{v:.1f}" for v in r) + " |")
    lines += ["", "Pass mark: every class >= 75 %. Our recordings were never used for training in this study, so their "
              "latency (and steady accuracy) is an unseen-person test."]
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
        for k in map(int, a.folds.split(",")):          # fold-major: a usable comparison exists early
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
