"""Cross-validation runner shared by run_cv.py and compare.py (PLAN.md G1, G4.3, G7)."""
import time

import numpy as np
import keras

from .data import (HAR_CLASSES, SOCIAL_CLASSES, list_real, har_folds, social_folds, windows_from_pieces)
from .metrics import per_class_recall, summarise, recording_vote
from .models import build
from .train import fit, RECIPES, rot_y, rotate

TEST_STEP = 12                       # same evaluation windows for every model
ROT_PROBES = (15, 30)                # degrees about Y (G4.3)


def folds(task, recs=None):
    recs = list_real() if recs is None else recs
    return list(har_folds(recs) if task == "har" else social_folds(recs))


def _rotated(X, deg):
    return rotate(X, rot_y(np.full(len(X), np.deg2rad(deg))))


def evaluate_predict_fn(task, predict_fn, window, fold_list):
    """Score a fixed predictor (e.g. a teammate TFLite file) on exactly the CV test folds."""
    n = len(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
    per_fold, ys, ps, metas, rot = [], [], [], [], {d: [] for d in ROT_PROBES}
    for name, _, te in fold_list:
        X, y, meta = windows_from_pieces(te, window, TEST_STEP, task)
        p = predict_fn(X).argmax(1)
        per_fold.append(summarise(task, per_class_recall(y, p, n)[0]) | {"fold": name})
        for d in ROT_PROBES:
            rot[d].append(summarise(task, per_class_recall(y, predict_fn(_rotated(X, d)).argmax(1), n)[0])["SCORE"])
        ys.append(y); ps.append(p); metas.append(meta)
    return _aggregate(task, per_fold, ys, ps, metas, rot)


def run_candidate(task, cand, seed, fold_list, verbose=0):
    n = len(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
    W, recipe = cand["window"], cand["recipe"]
    per_fold, ys, ps, metas, rot = [], [], [], [], {d: [] for d in ROT_PROBES}
    t0 = time.time()
    for name, tr, te in fold_list:
        keras.utils.set_random_seed(seed)
        Xtr, ytr, _ = windows_from_pieces(tr, W, RECIPES[recipe]["train_step"], task)
        Xte, yte, mte = windows_from_pieces(te, W, TEST_STEP, task)
        m = build(task, cand, n, Xtr)
        fit(m, Xtr, ytr, n, recipe, seed=seed, verbose=verbose)
        pred = lambda X: m.predict(X, batch_size=1024, verbose=0)
        p = pred(Xte).argmax(1)
        per_fold.append(summarise(task, per_class_recall(yte, p, n)[0]) | {"fold": name})
        for d in ROT_PROBES:
            rot[d].append(summarise(task, per_class_recall(yte, pred(_rotated(Xte, d)).argmax(1), n)[0])["SCORE"])
        ys.append(yte); ps.append(p); metas.append(mte)
        keras.backend.clear_session()
    out = _aggregate(task, per_fold, ys, ps, metas, rot)
    out["train_seconds"] = round(time.time() - t0, 1)
    return out


def _aggregate(task, per_fold, ys, ps, metas, rot):
    import pandas as pd
    n = len(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
    y, p, meta = np.concatenate(ys), np.concatenate(ps), pd.concat(metas, ignore_index=True)
    keys = [k for k in per_fold[0] if k != "fold"]
    mean = {k: float(np.nanmean([f[k] for f in per_fold])) for k in keys}       # marking: mean over folds
    std = {k: float(np.nanstd([f[k] for f in per_fold])) for k in keys}
    pooled_rec, cm = per_class_recall(y, p, n)
    res = {"fold_mean": mean, "fold_std": std, "per_fold": per_fold,
           "pooled": summarise(task, pooled_rec), "confusion": cm.tolist(),
           "recording_vote_acc": recording_vote(y, p, meta.rec_id.to_numpy()),
           "rotation_score": {str(d): float(np.mean(v)) for d, v in rot.items()}}
    if task == "har":                    # static posture recall split by the behaviour performed (P8)
        st = meta["sub"].notna() & np.isin(y, range(5))
        res["static_recall_by_behaviour"] = {
            s: float((p[st & (meta["sub"] == s)] == y[st & (meta["sub"] == s)]).mean())
            for s in sorted(meta.loc[st, "sub"].unique())}
    return res
