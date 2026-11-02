"""Pick the best pre-registered candidate per task from CV, train it on ALL real data, export TFLite (G6).

Selection rule (fixed in PLAN.md before results): mean over seeds of the CV fold-mean SCORE
  HAR    : SCORE = (static mean + dynamic mean) / 2
  social : SCORE = balanced per-class recall; ties (< 0.01) broken by the higher minimum class recall
The teammate replica is a control and is never selected.
"""
import json
import os
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
import numpy as np
import keras

from harry.data import list_real, all_pieces, windows_from_pieces, HAR_CLASSES, SOCIAL_CLASSES
from harry.models import CANDIDATES, build
from harry.train import fit, RECIPES
from harry.export import export


def seed_mean(res, name, key):
    return float(np.mean([v["fold_mean"][key] for k, v in res.items() if k.split("|")[0] == name]))


def select(task):
    res = json.loads(Path(f"results/cv_{task}.json").read_text())
    names = sorted({k.split("|")[0] for k in res if not k.startswith("teammate")})
    ranked = sorted(names, key=lambda n: (round(seed_mean(res, n, "SCORE"), 2),
                                          seed_mean(res, n, "MIN_CLASS" if task == "social" else "DYNAMIC_MEAN")),
                    reverse=True)
    return ranked[0], {n: seed_mean(res, n, "SCORE") for n in names}


report = {}
recs = list_real()
for task in ["har", "social"]:
    name, scores = select(task)
    cand = CANDIDATES[task][name]
    classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
    pieces = all_pieces(recs, task)
    X, y, _ = windows_from_pieces(pieces, cand["window"], RECIPES[cand["recipe"]]["train_step"], task)
    Xc, yc, _ = windows_from_pieces(pieces, cand["window"], 25, task)
    keras.utils.set_random_seed(0)
    m = build(task, cand, len(classes), X)
    fit(m, X, y, len(classes), cand["recipe"], seed=0)
    m.save(f"models/harry_{task}.keras")
    info = export(m, f"harry_{task}", "models", cand["window"], 25, classes,
                  "daily_activity" if task == "har" else "social_signal", Xc, yc,
                  extra_meta={"trained_on": "IoT/data real recordings only",
                              "candidate": name, "params": int(m.count_params())})
    report[task] = {"selected": name, "cv_scores": scores, "export": info, "params": int(m.count_params())}
    print(task, json.dumps(report[task], indent=1), flush=True)
Path("results/final_export.json").write_text(json.dumps(report, indent=1))
