"""G7: compare the teammate's models with mine and write results/comparison.json + results/tables.md.

1. Her exported .tflite files, as-is, on exactly my real-data CV test folds (she never trained on this data).
2. CV results of every candidate, including her architecture + recipe retrained on the real data.
3. Casual check on datasetJan2026: her exact held-out test split (seed 0), her TFLite vs my final TFLite.
"""
import json
import os
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
import numpy as np

from harry.cv import folds, evaluate_predict_fn
from harry.data import (HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC, list_jan, teammate_split, jan_windows)
from harry.export import TFLiteRunner
from harry.metrics import per_class_recall, summarise, recording_vote

TEAM = {"har": ["har_cnn", "har_cnn_dynamic", "har_cnn_full_int8", "har_mlp", "har_rnn"],
        "social": ["social_cnn", "social_mlp"]}
MODEL_DIR = Path("../model")
out = {}

for task in ["har", "social"]:
    classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
    fl = folds(task)
    o = out[task] = {"teammate_tflite_on_real": {}, "cv": {}, "jan_check": {}}
    # 1 ─ her files, as shipped
    for name in TEAM[task]:
        r = TFLiteRunner(MODEL_DIR / f"{name}.tflite")
        o["teammate_tflite_on_real"][name] = evaluate_predict_fn(task, r.predict, r.window, fl)
    # 2 ─ CV candidates (mean ± std over seeds of the fold-mean metrics)
    res = json.loads(Path(f"results/cv_{task}.json").read_text())
    abl = Path(f"results/ablation_{task}.json")
    if abl.exists():
        res |= json.loads(abl.read_text())
    for cname in dict.fromkeys(k.split("|")[0] for k in res):
        runs = [v for k, v in res.items() if k.split("|")[0] == cname]
        keys = runs[0]["fold_mean"].keys()
        o["cv"][cname] = {
            "mean": {k: float(np.mean([r["fold_mean"][k] for r in runs])) for k in keys},
            "seed_std": {k: float(np.std([r["fold_mean"][k] for r in runs])) for k in keys},
            "fold_std": {k: float(np.mean([r["fold_std"][k] for r in runs])) for k in keys},
            "rotation_score": {d: float(np.mean([r["rotation_score"][d] for r in runs])) for d in ("15", "30")},
            "recording_vote_acc": float(np.mean([r["recording_vote_acc"] for r in runs])),
            "static_recall_by_behaviour": runs[0].get("static_recall_by_behaviour"),
            "confusion_seed0": runs[0]["confusion"], "n_seeds": len(runs),
        }
    # 3 ─ datasetJan2026 casual check on her held-out test split
    recs = list_jan("daily_activity" if task == "har" else "social_signal", classes)
    _, _, te = teammate_split(recs)
    mine = Path(f"models/harry_{task}.tflite")
    for label, path in [(n, MODEL_DIR / f"{n}.tflite") for n in TEAM[task][:1]] + [("harry_final", mine)]:
        if not path.exists():
            continue
        r = TFLiteRunner(path)
        X, y, rid = jan_windows(te, r.window, 25)
        p = r.predict(X).argmax(1)
        rec, cm = per_class_recall(y, p, len(classes))
        o["jan_check"][label] = summarise(task, rec) | {"window_acc": float((p == y).mean()),
                                                        "recording_vote_acc": recording_vote(y, p, rid),
                                                        "n_windows": int(len(y)), "confusion": cm.tolist()}
    print(task, "done", flush=True)

Path("results/comparison.json").write_text(json.dumps(out, indent=1))


# ───────────────────────── markdown tables
def pct(v):
    return "–" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{100 * v:.1f}"


L = []
for task in ["har", "social"]:
    classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
    head = (["STATIC_MEAN", "DYNAMIC_MEAN"] + classes) if task == "har" else (["BALANCED", "MIN_CLASS"] + classes)
    o = out[task]
    L += [f"### {task.upper()} — real data, within-subject CV (fold-mean per-class recall, %)", "",
          "| model | trained on | " + " | ".join(head) + " | rot 15° | rot 30° |",
          "|---|---|" + "---|" * (len(head) + 2)]
    for n, r in o["teammate_tflite_on_real"].items():
        L.append(f"| **{n}.tflite** (hers, as shipped) | datasetJan2026 | " +
                 " | ".join(pct(r["fold_mean"][h]) for h in head) +
                 f" | {pct(r['rotation_score']['15'])} | {pct(r['rotation_score']['30'])} |")
    for n, r in o["cv"].items():
        tag = "her arch + recipe" if n.startswith("teammate") else "mine"
        L.append(f"| {n} ({tag}, {r['n_seeds']} seeds) | real (CV) | " +
                 " | ".join(f"{pct(r['mean'][h])}" for h in head) +
                 f" | {pct(r['rotation_score']['15'])} | {pct(r['rotation_score']['30'])} |")
    L.append("")
    if task == "har":
        L += ["Static-posture recall split by the behaviour performed during the recording (%):", "",
              "| model | " + " | ".join(sorted(o["cv"][next(iter(o["cv"]))]["static_recall_by_behaviour"])) + " |",
              "|---|" + "---|" * len(o["cv"][next(iter(o["cv"]))]["static_recall_by_behaviour"])]
        for n, r in list(o["teammate_tflite_on_real"].items())[:1] + list(o["cv"].items()):
            b = r["static_recall_by_behaviour"]
            L.append(f"| {n} | " + " | ".join(pct(b[k]) for k in sorted(b)) + " |")
        L.append("")
    L += [f"Casual check on datasetJan2026 (her held-out test split, {task}):", "",
          "| model | " + " | ".join(head) + " | window acc | recording vote |", "|---|" + "---|" * (len(head) + 2)]
    for n, r in o["jan_check"].items():
        L.append(f"| {n} | " + " | ".join(pct(r[h]) for h in head) +
                 f" | {pct(r['window_acc'])} | {pct(r['recording_vote_acc'])} |")
    L.append("")
Path("results/tables.md").write_text("\n".join(L))
print("\n".join(L))
