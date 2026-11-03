"""Turn raw job JSONs into tidy tables (CSV) that are easy to read, sort, filter and plot.

runs/<profile>/tables/
  runs.csv        one row per trained model x test set: score, group means, accuracy, F1, vote, rotation, time
  per_class.csv   one row per run x class: recall
  epochs.csv      one row per run x epoch: train loss/acc + held-out loss/acc/score
  confusion.csv   one row per run x (true, pred): count
  deploy.csv      one row per task x architecture: params, TFLite KB, ms/window
  status.csv      one row per job: ok / failed / pending, seconds
  leaderboard_<task>.csv, best_<task>.csv
Also ingests the Nov-2 experiments in results/ (prev_runs.csv, prev_per_class.csv) for the notebook.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd

from .data import HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC
from .zoo import ZOO, GROUPS

VIEWS = ["A", "B", "C", "D", "E"]
VIEW_EVAL = {"A": "real_test", "B": "jan_all", "C": "real_all", "D": "jan_test", "E": "real_test"}
VIEW_TITLES = {
    "A": "A: real→real (CV)", "B": "B: real→Jan", "C": "C: Jan→real", "D": "D: Jan CV (B9)", "E": "E: Jan pre-train + real fine-tune",
}
GOALS = {"har": {"STATIC_MEAN": 0.90, "DYNAMIC_MEAN": 0.85}, "social": {c: 0.75 for c in SOCIAL_CLASSES}}


def classes_of(task):
    return HAR_CLASSES if task == "har" else SOCIAL_CLASSES


def model_order():
    return sorted(ZOO, key=lambda m: (GROUPS.index(ZOO[m].group), ZOO[m].owner != "hers", m))


def _jobs(out_dir):
    for p in sorted((Path(out_dir) / "jobs").glob("*.json")):
        try:
            yield json.loads(p.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue


def from_jobs(out_dir):
    runs, pcls, eps, conf, dep, status, exports = [], [], [], [], [], [], []
    for j in _jobs(out_dir):
        key = dict(task=j["task"], scenario=j["scenario"], model=j["model"], group=j["group"], owner=j["owner"],
                   fold=str(j["fold"]), seed=j["seed"])
        status.append(key | {"id": j["id"], "status": j.get("status"), "seconds": j.get("seconds")})
        if j.get("status") != "ok":
            continue
        if j["scenario"] == "EXPORT":
            dep_ex = j.get("export", {})
            exports.append(key | {"params": j.get("params"), "window": j.get("window"), "train_on": j.get("train_on"),
                                  "n_train_windows": j.get("n_train_windows"), **dep_ex})
            continue
        if j["scenario"] == "DEPLOY":
            dep.append(key | {"params": j.get("params"), "window": j.get("window"), **j.get("deploy", {})})
            continue
        for lab, e in j.get("evals", {}).items():
            if lab.startswith("monitor"):
                continue
            r = key | {"eval_set": lab, "params": j.get("params"), "window": j.get("window"),
                       "train_seconds": j.get("seconds"), "n_train_windows": j.get("n_train_windows"),
                       "epochs": (j.get("recipe") or {}).get("epochs"),
                       "rot15": e["rotation_score"]["15"], "rot30": e["rotation_score"]["30"]}
            r |= {k: v for k, v in e.items() if k not in ("confusion", "rotation_score") and k not in classes_of(j["task"])}
            runs.append(r)
            for c in classes_of(j["task"]):
                pcls.append(key | {"eval_set": lab, "class": c, "recall": e.get(c)})
            cm = np.array(e["confusion"])
            cl = classes_of(j["task"])
            for a in range(len(cl)):
                for b in range(len(cl)):
                    if cm[a, b]:
                        conf.append(key | {"eval_set": lab, "true": cl[a], "pred": cl[b], "count": int(cm[a, b])})
        for row in j.get("history", []):
            mons = {k.split("/")[0] for k in row if "/" in k}
            for mon in mons or {""}:
                eps.append(key | {"epoch": row["epoch"], "train_loss": row.get("train_loss"),
                                  "train_acc": row.get("train_acc"), "heldout_set": mon,
                                  "heldout_loss": row.get(f"{mon}/loss"), "heldout_acc": row.get(f"{mon}/acc"),
                                  "heldout_score": row.get(f"{mon}/score"), "epoch_seconds": row.get("seconds")})
    T = {"runs": pd.DataFrame(runs), "per_class": pd.DataFrame(pcls), "epochs": pd.DataFrame(eps),
         "confusion": pd.DataFrame(conf), "deploy": pd.DataFrame(dep), "status": pd.DataFrame(status),
         "exports": pd.DataFrame(exports)}
    plan = Path(out_dir) / "plan.json"
    if plan.exists() and not T["status"].empty:
        planned = pd.DataFrame(json.loads(plan.read_text(encoding="utf-8")))
        seen = set(T["status"].id)
        pend = planned[~planned.id.isin(seen)].assign(status="pending")
        T["status"] = pd.concat([T["status"], pend[["id", "scenario", "task", "model", "group", "status"]]], ignore_index=True)
    return T


def leaderboard(runs, task, stat="SCORE"):
    """model x scenario: mean, std, n."""
    d = runs[runs.task == task]
    if d.empty:
        return pd.DataFrame(), pd.DataFrame()
    g = d.groupby(["model", "scenario"])[stat].agg(["mean", "std", "count"]).reset_index()
    mean = g.pivot(index="model", columns="scenario", values="mean")
    std = g.pivot(index="model", columns="scenario", values="std")
    order = [m for m in model_order() if m in mean.index]
    cols = [v for v in VIEWS if v in mean.columns]
    out = mean.loc[order, cols]
    out.insert(0, "owner", [ZOO[m].owner for m in order]); out.insert(0, "group", [ZOO[m].group for m in order])
    return out, std.loc[order, cols]


def best_per_circumstance(runs, task):
    d = runs[runs.task == task]
    rows = []
    for v in VIEWS:
        dv = d[d.scenario == v]
        if dv.empty:
            continue
        g = dv.groupby("model").SCORE.mean()
        row = {"scenario": VIEW_TITLES[v], "best overall": g.idxmax(), "score": round(100 * g.max(), 1)}
        for grp in GROUPS:
            gg = g[[m for m in g.index if ZOO[m].group == grp]]
            h = gg[[m for m in gg.index if ZOO[m].owner == "hers"]]
            mi = gg[[m for m in gg.index if ZOO[m].owner == "mine"]]
            if len(h) and len(mi):
                row[f"{grp}: hers→mine"] = f"{100 * h.max():.1f} → {100 * mi.max():.1f} ({100 * (mi.max() - h.max()):+.1f})"
        rows.append(row)
    return pd.DataFrame(rows)


def group_table(runs, per_class, task, scenario, models):
    """Readable numbers for one group x scenario: mean ± std of the headline metrics and per-class recall."""
    d = runs[(runs.task == task) & (runs.scenario == scenario) & runs.model.isin(models)]
    if d.empty:
        return pd.DataFrame()
    heads = ["SCORE"] + (["STATIC_MEAN", "DYNAMIC_MEAN"] if task == "har" else ["BALANCED", "MIN_CLASS"])
    rows = []
    for m in [m for m in model_order() if m in set(d.model)]:
        x = d[d.model == m]
        r = {"model": m, "owner": ZOO[m].owner, "runs": len(x)}
        for h in heads:
            r[h] = f"{100 * x[h].mean():.1f} ± {100 * x[h].std(ddof=0):.1f}"
        pc = per_class[(per_class.task == task) & (per_class.scenario == scenario) & (per_class.model == m)]
        for c in classes_of(task):
            r[c] = round(100 * pc[pc["class"] == c].recall.mean(), 1)
        r |= {"window acc": round(100 * x.window_acc.mean(), 1), "macro F1": round(100 * x.macro_f1.mean(), 1),
              "rot 30°": round(100 * x.rot30.mean(), 1), "params": int(x.params.iloc[0]),
              "train s": round(x.train_seconds.mean(), 0)}
        rows.append(r)
    return pd.DataFrame(rows)


def write(out_dir):
    out_dir = Path(out_dir)
    T = from_jobs(out_dir)
    tdir = out_dir / "tables"; tdir.mkdir(parents=True, exist_ok=True)
    for k, df in T.items():
        df.to_csv(tdir / f"{k}.csv", index=False)
    if not T["runs"].empty:
        for task in sorted(T["runs"].task.unique()):
            lb, sd = leaderboard(T["runs"], task)
            (lb.round(4)).to_csv(tdir / f"leaderboard_{task}.csv")
            best_per_circumstance(T["runs"], task).to_csv(tdir / f"best_{task}.csv", index=False)
    return T


def console_summary(T):
    if T["runs"].empty:
        return "(no finished runs yet)"
    out = []
    for task in sorted(T["runs"].task.unique()):
        lb, sd = leaderboard(T["runs"], task)
        txt = lb.copy()
        for v in [c for c in VIEWS if c in txt.columns]:
            txt[v] = [("   –  " if np.isnan(a) else f"{100 * a:5.1f}") + ("" if np.isnan(b) else f"±{100 * b:3.1f}")
                      for a, b in zip(lb[v], sd[v])]
        out += [f"\n{task.upper()} — score (%) per scenario, mean±std over folds×seeds", txt.to_string()]
    return "\n".join(out)


# ───────────────────────── previous experiments (Nov 2, results/*.json) for the notebook
def legacy(results_dir):
    rd = Path(results_dir)
    rows, pcls = [], []

    def owner(name):
        return "hers" if name.startswith(("teammate", "her")) or "shipped" in name else "mine"

    def add(task, view, model, fold, seed, d):
        r = {"task": task, "scenario": view, "model": model, "owner": owner(model), "fold": str(fold), "seed": seed}
        r |= {k: d.get(k) for k in ("SCORE", "STATIC_MEAN", "DYNAMIC_MEAN", "BALANCED", "MIN_CLASS", "window_acc")}
        rows.append(r)
        for c in classes_of(task):
            if c in d:
                pcls.append({**{k: r[k] for k in ("task", "scenario", "model", "owner", "fold", "seed")}, "class": c, "recall": d[c]})

    for task in ("har", "social"):
        for fn, view in ((f"cv_{task}.json", "prev A: real CV"), (f"ablation_{task}.json", "prev A: real CV")):
            p = rd / fn
            if p.exists():
                for key, v in json.loads(p.read_text(encoding="utf-8")).items():
                    name, seed = key.split("|seed=")
                    for f in v["per_fold"]:
                        add(task, view, name, f["fold"], int(seed), f)
        p = rd / "comparison.json"
        if p.exists():
            c = json.loads(p.read_text(encoding="utf-8")).get(task, {})
            for name, v in c.get("teammate_tflite_on_real", {}).items():
                for f in v["per_fold"]:
                    add(task, "prev A: real CV", f"{name}.tflite (shipped)", f["fold"], 0, f)
        for who, view, name in (("her", "prev D: B9 CV", "teammate_cnn@50"), ("mine", "prev D: B9 CV", "harry_full"),
                                ("mine_shipped_real", "prev B: real-trained → Jan folds", "harry_full (real-trained)")):
            p = rd / "b9" / f"{task}_{who}.json"
            if p.exists():
                for k, f in json.loads(p.read_text(encoding="utf-8"))["folds"].items():
                    add(task, view, name, k, 0, f)
    return pd.DataFrame(rows), pd.DataFrame(pcls)
