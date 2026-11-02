"""Within-subject CV on the real data for every pre-registered candidate (PLAN.md G1, G2, G3, G4, G7.2).

usage: python run_cv.py --task har|social [--seeds 0 1 2] [--only name ...]
Writes results/cv_<task>.json incrementally (one entry per candidate x seed).
"""
import argparse
import json
import os
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
import numpy as np

from harry.cv import folds, run_candidate
from harry.models import CANDIDATES, ABLATIONS

ap = argparse.ArgumentParser()
ap.add_argument("--task", required=True, choices=["har", "social"])
ap.add_argument("--seeds", type=int, nargs="+", default=[0, 1, 2])
ap.add_argument("--only", nargs="*")
ap.add_argument("--ablations", action="store_true")
a = ap.parse_args()

out = Path(f"results/{'ablation' if a.ablations else 'cv'}_{a.task}.json")
res = json.loads(out.read_text()) if out.exists() else {}
fl = folds(a.task)
pool = ABLATIONS[a.task] if a.ablations else CANDIDATES[a.task]
for name, cand in pool.items():
    if a.only and name not in a.only:
        continue
    for seed in a.seeds:
        key = f"{name}|seed={seed}"
        if key in res:
            continue
        r = run_candidate(a.task, cand, seed, fl)
        res[key] = r
        out.write_text(json.dumps(res, indent=1))
        fm = r["fold_mean"]
        extra = (f"static {fm['STATIC_MEAN']:.3f} dynamic {fm['DYNAMIC_MEAN']:.3f}" if a.task == "har"
                 else f"balanced {fm['BALANCED']:.3f} min-class {fm['MIN_CLASS']:.3f}")
        print(f"{key:32s} score {fm['SCORE']:.3f}  {extra}  rot30 {r['rotation_score']['30']:.3f}  "
              f"({r['train_seconds']} s)", flush=True)
