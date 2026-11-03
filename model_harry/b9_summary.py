"""Summarise results/b9/*.json -> results/b9_tables.md (her B9 metric and the CW3 graded metric)."""
import json
from pathlib import Path

import numpy as np

from harry.data import HAR_CLASSES, SOCIAL_CLASSES

LABEL = {"her": "hers — teammate CNN + her B9 recipe (retrained per fold)",
         "mine": "mine — harry_full + my recipe (retrained per fold)",
         "mine_shipped_real": "mine as shipped — trained on IoT/data only, no datasetJan2026 training"}
L = ["# Lab3-B9 subject-wise 10-fold CV on datasetJan2026", "",
     "Folds = exact replica of B9 `make_folds()` (seed 0); identical per-activity fold table to her notebook. "
     "Test windows: step 25. Graded metric = per-class recall per fold, averaged within the group, mean over 10 folds.", ""]
for task in ["har", "social"]:
    classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
    groups = ["STATIC_MEAN", "DYNAMIC_MEAN"] if task == "har" else ["BALANCED", "MIN_CLASS"]
    L += [f"## {task.upper()}", "",
          "| model | folds | window acc (B9 metric) | " + " | ".join(groups + classes) + " | recording vote |",
          "|---|---|---|" + "---|" * (len(groups) + len(classes) + 1)]
    for m in ["her", "mine", "mine_shipped_real"]:
        p = Path(f"results/b9/{task}_{m}.json")
        if not p.exists():
            continue
        F = list(json.loads(p.read_text())["folds"].values())
        mean = lambda k: 100 * np.nanmean([f[k] for f in F])
        std = lambda k: 100 * np.nanstd([f[k] for f in F])
        L.append(f"| {LABEL[m]} | {len(F)} | {mean('window_acc'):.1f} ± {std('window_acc'):.1f} | " +
                 " | ".join(f"{mean(k):.1f}" for k in groups + classes) + f" | {mean('recording_vote_acc'):.1f} |")
    L.append("")
Path("results/b9_tables.md").write_text("\n".join(L))
print("\n".join(L))
