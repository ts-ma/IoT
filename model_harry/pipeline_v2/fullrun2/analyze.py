"""Turn job outputs into tables (long-format CSVs in <out>/tables/) for the figures and the write-up.

Scoring scopes (column 'variant' of the CV tables), from the same test predictions of each fold:
  all        every test window of the fold: datasetJan2026 fold k + the group member(s) assigned to fold k (headline)
  jan        only the datasetJan2026 windows = exactly what the CW3 marking computes
  group      only the group members' windows (folds that contain one)
  <person>   one group member (the single fold that member is tested in = unseen-person result)
Works on partial results: missing jobs are simply absent from the tables.
"""
import json
import shutil
from pathlib import Path

import numpy as np
import pandas as pd

from harry.data import HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC
from . import config as C
from .data import load_set

JOBS = C.OUT / "jobs"


def classes(task):
    return HAR_CLASSES if task == "har" else SOCIAL_CLASSES


def load_jobs():
    rows = []
    for f in sorted(JOBS.glob("*.json")):
        r = json.loads(f.read_text())
        j = r.get("job", {})
        info = r.get("info", {})
        rows.append({**{k: j.get(k) for k in ("id", "group", "task", "model", "variant", "seed", "fold", "power", "person")},
                     "status": r.get("status"), "seconds": r.get("seconds"), "params": info.get("params"),
                     "train_windows": info.get("train_windows"), "train_seconds": info.get("train_seconds"),
                     "predict_seconds": info.get("predict_seconds"), "xinfo": info, "xhist": r.get("history", [])})
    return pd.DataFrame(rows)


def npz(job_id):
    f = JOBS / f"{job_id}.npz"
    return np.load(f) if f.exists() else None


def recall_vec(y, p, n):
    return np.array([(p[y == c] == c).mean() if (y == c).any() else np.nan for c in range(n)])


def group_scores(task, rec):
    if task == "har":
        return {"static": float(np.nanmean(rec[:5])), "dynamic": float(np.nanmean(rec[5:]))}
    return {"social": float(np.nanmean(rec)), "social_min": float(np.nanmin(rec))}


def ece(P, y, bins=15):
    conf, pred = P.max(1), P.argmax(1)
    edges = np.linspace(0, 1, bins + 1)
    e = 0.0
    for a, b in zip(edges[:-1], edges[1:]):
        m = (conf > a) & (conf <= b)
        if m.any():
            e += m.mean() * abs((pred[m] == y[m]).mean() - conf[m].mean())
    return float(e)


def _scopes(person):
    out = {"all": np.ones(len(person), bool), "jan": person == "jan", "group": person != "jan"}
    for p in C.PEOPLE:
        out[p] = person == p
    return {k: m for k, m in out.items() if m.any()}


# ───────────────────────── CV tables (main, baseline, sweep) in every scope
def cv_tables(jobs, tables, log):
    from sklearn.metrics import precision_recall_fscore_support, f1_score, roc_auc_score
    cv = jobs[(jobs.group.isin(["main", "baseline", "sweep"])) & (jobs.status == "ok")]
    real_meta = load_set("real")[1]
    pc, fs, cm, rl, cal, post = [], [], [], [], [], []
    for r in cv.itertuples():
        z = npz(r.id)
        if z is None or "cv__P" not in z:
            continue
        P_all, y_all, rid_all = z["cv__P"], z["cv__y"], z["cv__rid"]
        person_all = z["cv__person"] if "cv__person" in z else np.array(["jan"] * len(y_all))
        n = len(classes(r.task))
        for scope, msk in _scopes(person_all).items():
            P, y, rid, person = P_all[msk], y_all[msk], rid_all[msk], person_all[msk]
            p = P.argmax(1)
            base = {"id": r.id, "group": r.group, "task": r.task, "model": r.model, "variant": scope, "seed": r.seed,
                    "fold": r.fold, "power": r.power}
            rec = recall_vec(y, p, n)
            pr, _, f1, sup = precision_recall_fscore_support(y, p, labels=range(n), zero_division=0)
            for c in range(n):
                pc.append({**base, "class": classes(r.task)[c], "recall": rec[c], "precision": pr[c], "f1": f1[c],
                           "support": int(sup[c]), "predicted": int((p == c).sum())})
            present = np.unique(y)
            try:
                auc = roc_auc_score(np.eye(n)[y][:, present], P[:, present], average="macro") if len(present) > 1 else np.nan
            except ValueError:
                auc = np.nan
            key = np.char.add(person.astype(str), np.char.add(":", rid.astype(str)))      # recording id per source
            df = pd.DataFrame({"r": key, "y": y, "p": p})
            vote = df.groupby("r").agg(y=("y", "first"), p=("p", lambda s: s.mode().iloc[0]))
            nll = float(-np.mean(np.log(np.clip(P[np.arange(len(y)), y], 1e-7, 1))))
            fs.append({**base, **group_scores(r.task, rec), "balanced_acc": float(np.nanmean(rec)), "window_acc": float((p == y).mean()),
                       "macro_f1": float(f1_score(y, p, average="macro", labels=list(present), zero_division=0)),
                       "macro_auc": auc, "recording_vote_acc": float((vote.y == vote.p).mean()), "log_loss": nll,
                       "ece": ece(P, y), "mean_conf": float(P.max(1).mean()), "n_test_windows": int(len(y)),
                       "n_test_recordings": int(df.r.nunique())})
            if scope not in ("all", "jan"):
                continue
            m = pd.crosstab(y, p).reindex(index=range(n), columns=range(n), fill_value=0)
            for a in range(n):
                for b in range(n):
                    cm.append({**base, "true": classes(r.task)[a], "pred": classes(r.task)[b], "count": int(m.iat[a, b])})
            if r.group == "main" and scope == "all":
                g = df.assign(conf=P.max(1), ok=(df.y == df.p)).groupby("r")
                jm = load_set(f"jan_{r.task}")[1]
                rr = g.agg(y=("y", "first"), n=("y", "size"), frac_correct=("ok", "mean"), conf=("conf", "mean")).reset_index()
                rr["vote_correct"] = (vote.y == vote.p).reindex(rr.r).to_numpy()
                src_person = rr.r.str.split(":").str[0]; idx = rr.r.str.split(":").str[1].astype(int)
                rr["source"] = np.where(src_person == "jan", "datasetJan2026", src_person)
                rr["file"] = [jm.file.iat[i] if sp == "jan" else real_meta.file.iat[i] for sp, i in zip(src_person, idx)]
                rr["class"] = [classes(r.task)[i] for i in rr.y]
                rl.append(rr.assign(**base))
                if r.seed == 0:
                    conf, ok = P.max(1), (p == y)
                    for b, (lo, hi) in enumerate(zip(np.linspace(0, 1, 11)[:-1], np.linspace(0, 1, 11)[1:])):
                        mk = (conf > lo) & (conf <= hi)
                        cal.append({**base, "bin": b, "lo": lo, "hi": hi, "n": int(mk.sum()),
                                    "acc": float(ok[mk].mean()) if mk.any() else np.nan,
                                    "conf": float(conf[mk].mean()) if mk.any() else np.nan})
                    if r.task == "social":                  # group members: lying vs sitting/standing
                        isr = person != "jan"
                        if isr.any():
                            postures = real_meta.posture.to_numpy()[rid[isr]]
                            for who in np.unique(person[isr]):
                                for pg, sel in [("all", np.ones(isr.sum(), bool)), ("lying", np.char.startswith(postures.astype(str), "lying")),
                                                ("sitting/standing", ~np.char.startswith(postures.astype(str), "lying"))]:
                                    mm = sel & (person[isr] == who)
                                    if mm.any():
                                        rv = recall_vec(y[isr][mm], p[isr][mm], n)
                                        post.append({"person": who, "fold": r.fold, "postures": pg, "balanced": float(np.nanmean(rv)),
                                                     **{c: rv[i] for i, c in enumerate(SOCIAL_CLASSES)}})
    out = {}
    for name, rows in [("per_fold_class", pc), ("fold_scores", fs), ("confusion_long", cm), ("calibration_bins", cal),
                       ("person_postures", post)]:
        d = pd.DataFrame(rows); d.to_csv(tables / f"{name}.csv", index=False); out[name] = d
    rlt = pd.concat(rl) if rl else pd.DataFrame(); rlt.to_csv(tables / "recording_level.csv", index=False); out["recording_level"] = rlt
    log(f"cv tables: {len(cv)} jobs scored in {len(set(x['variant'] for x in fs))} scopes")
    return out


def summaries(t, tables):
    """Fold mean per class (the marked number), its spread over folds, over seeds, and a 95% CI (per scope)."""
    from scipy import stats
    pc, fs = t["per_fold_class"], t["fold_scores"]
    if pc.empty:
        return {}
    rows = []
    key = ["group", "task", "model", "variant", "power"]
    pc = pc.assign(power=pc.power.fillna(-1))
    for k, g in pc.groupby(key + ["class"], dropna=False):
        per_seed = g.groupby("seed").recall.mean()
        folds = g[g.seed == g.seed.min()].recall
        nf = folds.notna().sum()
        ci = stats.t.ppf(0.975, nf - 1) * folds.std(ddof=1) / np.sqrt(nf) if nf > 1 else np.nan
        rows.append({**dict(zip(key + ["class"], k)), "mean": per_seed.mean(), "seed_std": per_seed.std(ddof=1) if len(per_seed) > 1 else np.nan,
                     "fold_std": folds.std(ddof=1), "fold_min": folds.min(), "fold_max": folds.max(), "ci95": ci,
                     "n_seeds": len(per_seed), "n_folds": int(nf), "precision": g.precision.mean(), "f1": g.f1.mean()})
    s = pd.DataFrame(rows)
    s["power"] = s.power.replace(-1, np.nan)
    s.to_csv(tables / "summary_per_class.csv", index=False)
    fs = fs.assign(power=fs.power.fillna(-1))
    metrics = [c for c in ["static", "dynamic", "social", "social_min", "balanced_acc", "window_acc", "macro_f1", "macro_auc",
                           "recording_vote_acc", "log_loss", "ece", "mean_conf"] if c in fs]
    g = fs.groupby(key + ["seed"], dropna=False)[metrics].mean().reset_index()
    gs = g.groupby(key, dropna=False)[metrics].agg(["mean", "std"]).reset_index()
    gs.columns = ["_".join(c).strip("_") if isinstance(c, tuple) else c for c in gs.columns]
    gs["power"] = gs.power.replace(-1, np.nan)
    gs.to_csv(tables / "summary_scores.csv", index=False)
    return {"per_class": s, "scores": gs}


def stat_tests(t, tables):
    """Paired Wilcoxon signed-rank tests over the 10 folds (seed 0): deployed architecture vs each other one, and
    the chosen class-weight power vs the others, in the headline and the marked scope."""
    from scipy.stats import wilcoxon
    fs = t["fold_scores"]
    if fs.empty:
        return pd.DataFrame()
    rows = []

    def compare(name, scope, a, b, metric):
        m = a.merge(b, on="fold", suffixes=("_a", "_b"))
        if len(m) < 5:
            return
        d = m[f"{metric}_a"] - m[f"{metric}_b"]
        try:
            pv = wilcoxon(m[f"{metric}_a"], m[f"{metric}_b"]).pvalue if (d != 0).any() else 1.0
        except ValueError:
            pv = np.nan
        rows.append({"comparison": name, "scope": scope, "metric": metric, "n_folds": len(m), "mean_a": m[f"{metric}_a"].mean(),
                     "mean_b": m[f"{metric}_b"].mean(), "mean_diff": d.mean(), "folds_a_better": int((d > 0).sum()),
                     "p_wilcoxon": pv})

    for scope in ("all", "jan"):
        f = fs[(fs.variant == scope) & (fs.seed == 0)]
        for task, metrics in [("har", ["static", "dynamic"]), ("social", ["social", "social_min"])]:
            fin = f[(f.group == "main") & (f.task == task)]
            for m in metrics:
                for model, g in f[(f.group == "baseline") & (f.task == task)].groupby("model"):
                    compare(f"{task}: {C.MODEL_NAMES[C.FINAL[task]]} vs {C.MODEL_NAMES.get(model, model)}", scope, fin, g, m)
                if task == "social":
                    for pw, g in f[f.group == "sweep"].groupby("power"):
                        compare(f"social: class-weight power {C.SOCIAL_POWER:g} vs {pw:g}", scope, fin, g, m)
    d = pd.DataFrame(rows); d.to_csv(tables / "stat_tests.csv", index=False)
    return d


def history_table(jobs, tables):
    rows = []
    for r in jobs.itertuples():
        for h in r.xhist or []:
            rows.append({"id": r.id, "group": r.group, "task": r.task, "model": r.model, "variant": r.variant,
                         "seed": r.seed, "fold": r.fold, "power": r.power, **h})
    d = pd.DataFrame(rows)
    d.to_csv(tables / "epochs.csv", index=False)
    return d


def person_table(t, tables):
    """Unseen-person result: each group member's fold (main models, every seed), per class."""
    pc = t["per_fold_class"]
    if pc.empty:
        return pd.DataFrame()
    d = pc[(pc.group == "main") & (pc.variant.isin(list(C.PEOPLE)))]
    out = d.groupby(["task", "variant", "fold", "class"]).agg(recall=("recall", "mean"), recall_seed_sd=("recall", "std"),
                                                               support=("support", "first")).reset_index()
    out = out.rename(columns={"variant": "person"})
    out.to_csv(tables / "person_per_class.csv", index=False)
    return out


def window_study_table(tables, log):
    """Copy the social window study (how the social window was chosen) into this run's tables."""
    rows = []
    for name in ("summary.csv", "streams.csv", "per_fold_recall.csv"):
        f = C.STUDY / name
        if f.exists():
            shutil.copy(f, tables / f"social_window_study_{name}")
            rows.append(name)
    log(f"social window study tables copied: {rows}")


def embeddings(tables, log, n=2500):
    """t-SNE of the penultimate layer (head_dense) for fold 0 of the deployed models (all test windows)."""
    import keras
    from sklearn.manifold import TSNE
    from harry import layers as _l, augment as _a  # noqa: F401
    from .jobs import _cv_test
    from .data import windows
    rows = []
    for task in ("har", "social"):
        cand = sorted((JOBS / "models").glob(f"main_{task}_*_s0_f0.keras"))
        if not cand:
            continue
        t = _cv_test(task, 0)
        X, y, src, _ = windows(t["parts"], task, C.W[task])
        sel = np.random.default_rng(0).permutation(len(y))[:n]
        m = keras.models.load_model(cand[0], compile=False)
        emb = keras.Model(m.input, m.get_layer("head_dense").output).predict(X[sel], batch_size=2048, verbose=0)
        xy = TSNE(2, init="pca", random_state=0, perplexity=35).fit_transform(emb)
        pred = m.predict(X[sel], batch_size=2048, verbose=0).argmax(1)
        rows.append(pd.DataFrame({"task": task, "x": xy[:, 0], "y": xy[:, 1], "true": [classes(task)[i] for i in y[sel]],
                                  "pred": [classes(task)[i] for i in pred], "source": src[sel]}))
    d = pd.concat(rows) if rows else pd.DataFrame()
    d.to_csv(tables / "tsne.csv", index=False)
    log("t-SNE embeddings done")
    return d


def deploy_table(jobs, tables):
    rows = []
    for r in jobs[(jobs.group == "deploy") & (jobs.status == "ok")].itertuples():
        rows.append({"task": r.task, "model": r.model, **{k: v for k, v in r.xinfo.items() if k != "layers"}})
    for r in jobs[(jobs.group == "final") & (jobs.status == "ok")].itertuples():
        e = r.xinfo.get("export", {})
        rows.append({"task": r.task, "model": f"{r.model} (final, trained)", "tflite": True, "size_kb": e.get("size_kb"),
                     "params": r.params, "ms_per_window": e.get("ms_per_window"), "window": C.W[r.task],
                     "parity_argmax_agreement": e.get("argmax_agreement"), "parity_max_abs_dprob": e.get("max_abs_dprob")})
    d = pd.DataFrame(rows); d.to_csv(tables / "deploy.csv", index=False)
    return d


def run(log):
    tables = C.OUT / "tables"; tables.mkdir(parents=True, exist_ok=True)
    jobs = load_jobs()
    if jobs.empty:
        log("no jobs finished yet"); return {}
    jobs.drop(columns=["xinfo", "xhist"]).to_csv(tables / "jobs_index.csv", index=False)
    t = cv_tables(jobs, tables, log)
    out = {"jobs": jobs, **t}
    out.update(summaries(t, tables))
    out["stats"] = stat_tests(t, tables)
    out["epochs"] = history_table(jobs, tables)
    out["person"] = person_table(t, tables)
    out["deploy"] = deploy_table(jobs, tables)
    window_study_table(tables, log)
    try:
        out["tsne"] = embeddings(tables, log)
    except Exception as e:                                          # noqa: BLE001
        log(f"tsne skipped: {e!r}")
    timing = jobs.groupby("group").seconds.agg(["count", "sum", "mean"]).reset_index()
    timing.to_csv(tables / "timing.csv", index=False)
    out["timing"] = timing
    return out
