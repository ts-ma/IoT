"""Lab3-B9 subject-wise 10-fold CV on datasetJan2026, for her model and mine.

Folds: exact replica of make_folds() in Lab3 / Lab3_trained.ipynb (seed 0; the Learn fold CSV is not
available, so these are the same self-made folds she used). Test windows: window W, step 25, as in B9.
  her  : teammate_cnn (= build_cnn_fold), Adam 1e-3, 32 fixed epochs, batch 64, seed SEED + k   (her B9)
  mine : harry_full (HAR W=50, social W=100), recipe "harry_b9" (same 32 epochs / step 25 budget)
  mine_shipped_real : models/harry_<task>.tflite trained on IoT/data only, just scored on each test fold
usage: python run_b9.py --task har|social --model her|mine|mine_shipped_real
Writes results/b9/<task>_<model>.json incrementally (one entry per fold).
"""
import argparse
import json
import os
import re
import time
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
import numpy as np
import pandas as pd
import keras

from harry.data import HAR_CLASSES, SOCIAL_CLASSES, list_jan, jan_windows
from harry.metrics import per_class_recall, summarise, recording_vote
from harry.models import teammate_cnn, harry
from harry.train import fit, RECIPES
from harry.export import TFLiteRunner

N_FOLDS, SEED, TEST_STEP = 10, 0, 25


def subject_id(path: Path) -> str:
    m = re.fullmatch(r"N_(\d+)\.csv", path.name)
    return m.group(1) if m else path.stem


def make_folds(recs, n_folds=N_FOLDS, seed=SEED):
    """Verbatim logic of the Lab 3 make_folds()."""
    rng = np.random.default_rng(seed)
    out = pd.Series(-1, index=recs.index)
    for label, idx in recs.groupby("label").groups.items():
        subjects = recs.loc[idx, "path"].map(subject_id)
        unique = rng.permutation(subjects.unique())
        fold_of = {s: k % n_folds for k, s in enumerate(unique)}
        out.loc[idx] = subjects.map(fold_of)
    return out


ap = argparse.ArgumentParser()
ap.add_argument("--task", required=True, choices=["har", "social"])
ap.add_argument("--model", required=True, choices=["her", "mine", "mine_shipped_real"])
a = ap.parse_args()

classes = HAR_CLASSES if a.task == "har" else SOCIAL_CLASSES
recs = list_jan("daily_activity" if a.task == "har" else "social_signal", classes)
recs["subject"] = recs.path.map(subject_id)
recs["fold"] = make_folds(recs)
assert (recs.groupby(["label", "subject"]).fold.nunique() == 1).all()

out_path = Path(f"results/b9/{a.task}_{a.model}.json"); out_path.parent.mkdir(parents=True, exist_ok=True)
res = json.loads(out_path.read_text()) if out_path.exists() else {
    "fold_table": pd.crosstab(recs.label, recs.fold).reindex(classes).to_dict(), "folds": {}}
W = 50 if (a.task == "har" or a.model == "her") else 100
n = len(classes)
lite = TFLiteRunner(f"models/harry_{a.task}.tflite") if a.model == "mine_shipped_real" else None

for k in range(N_FOLDS):
    if str(k) in res["folds"]:
        continue
    t0 = time.time()
    te = recs[recs.fold == k]
    Xte, yte, rte = jan_windows(te, W, TEST_STEP)
    if lite is not None:
        prob = lite.predict(Xte)
    else:
        tr = recs[recs.fold != k]
        recipe = "teammate" if a.model == "her" else "harry_b9"
        Xtr, ytr, _ = jan_windows(tr, W, RECIPES[recipe]["train_step"])
        keras.utils.set_random_seed(SEED + k)
        m = (teammate_cnn(W, n, Xtr) if a.model == "her" else harry(a.task, W, n, Xtr))
        fit(m, Xtr, ytr, n, recipe, seed=SEED + k)
        prob = m.predict(Xte, batch_size=2048, verbose=0)
        keras.backend.clear_session()
    p = prob.argmax(1)
    rec, cm = per_class_recall(yte, p, n)
    res["folds"][str(k)] = summarise(a.task, rec) | {
        "window_acc": float((p == yte).mean()), "recording_vote_acc": recording_vote(yte, p, rte),
        "n_test_windows": int(len(yte)), "confusion": cm.tolist(), "seconds": round(time.time() - t0, 1)}
    out_path.write_text(json.dumps(res, indent=1))
    f = res["folds"][str(k)]
    print(f"{a.task} {a.model} fold {k}: window acc {f['window_acc']:.4f}  score {f['SCORE']:.4f}  ({f['seconds']} s)",
          flush=True)
print(f"{a.task} {a.model} DONE", flush=True)
