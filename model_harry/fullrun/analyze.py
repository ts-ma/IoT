"""Turn job outputs into tables (long-format CSVs in final_run/tables/) and a facts dict for the write-up.

Every number in the write-up and every figure is computed from these tables, so you can re-plot anything.
Works on partial results: missing jobs are simply absent from the tables.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd

from harry.data import HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC
from . import config as C
from .data import load_set

JOBS = C.OUT / "jobs"
STATIC_IDX = [HAR_CLASSES.index(c) for c in STATIC]
SIT = HAR_CLASSES.index("sittingStanding")


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
                     "train_windows": info.get("train_windows"), "finetune_windows": info.get("finetune_windows"),
                     "train_seconds": info.get("train_seconds"), "finetune_seconds": info.get("finetune_seconds"),
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


# ───────────────────────── official-fold tables (main, baseline, sweep)
def cv_tables(jobs, tables, log):
    from sklearn.metrics import precision_recall_fscore_support, f1_score, roc_auc_score
    cv = jobs[(jobs.group.isin(["main", "baseline", "sweep"])) & (jobs.status == "ok")]
    pc, fs, cm, rl, cal = [], [], [], [], []
    for r in cv.itertuples():
        z = npz(r.id)
        if z is None or "cv__P" not in z:
            continue
        P, y, rid = z["cv__P"], z["cv__y"], z["cv__rid"]
        n = len(classes(r.task)); p = P.argmax(1)
        base = {"id": r.id, "group": r.group, "task": r.task, "model": r.model, "variant": r.variant, "seed": r.seed,
                "fold": r.fold, "power": r.power}
        rec = recall_vec(y, p, n)
        pr, _, f1, sup = precision_recall_fscore_support(y, p, labels=range(n), zero_division=0)
        for c in range(n):
            pc.append({**base, "class": classes(r.task)[c], "recall": rec[c], "precision": pr[c], "f1": f1[c],
                       "support": int(sup[c]), "predicted": int((p == c).sum())})
        try:
            auc = roc_auc_score(np.eye(n)[y], P, average="macro")
        except ValueError:
            auc = np.nan
        df = pd.DataFrame({"r": rid, "y": y, "p": p})
        vote = df.groupby("r").agg(y=("y", "first"), p=("p", lambda s: s.mode().iloc[0]))
        nll = float(-np.mean(np.log(np.clip(P[np.arange(len(y)), y], 1e-7, 1))))
        fs.append({**base, **group_scores(r.task, rec), "balanced_acc": float(np.nanmean(rec)), "window_acc": float((p == y).mean()),
                   "macro_f1": float(f1_score(y, p, average="macro", labels=range(n), zero_division=0)),
                   "macro_auc": auc, "recording_vote_acc": float((vote.y == vote.p).mean()), "log_loss": nll,
                   "ece": ece(P, y), "mean_conf": float(P.max(1).mean()), "n_test_windows": int(len(y)),
                   "n_test_recordings": int(df.r.nunique())})
        m = pd.crosstab(y, p).reindex(index=range(n), columns=range(n), fill_value=0)
        for a in range(n):
            for b in range(n):
                cm.append({**base, "true": classes(r.task)[a], "pred": classes(r.task)[b], "count": int(m.iat[a, b])})
        if r.group == "main":
            g = df.assign(conf=P.max(1), ok=(df.y == df.p)).groupby("r")
            meta = load_set(f"jan_{r.task}")[1]
            rr = g.agg(y=("y", "first"), n=("y", "size"), frac_correct=("ok", "mean"), conf=("conf", "mean")).reset_index()
            rr["vote_correct"] = (vote.y == vote.p).reindex(rr.r).to_numpy()
            rr["file"] = meta.file.to_numpy()[rr.r]; rr["class"] = [classes(r.task)[i] for i in rr.y]
            rl.append(rr.assign(**base))
            if r.seed == 0:
                conf, ok = P.max(1), (p == y)
                for b, (lo, hi) in enumerate(zip(np.linspace(0, 1, 11)[:-1], np.linspace(0, 1, 11)[1:])):
                    msk = (conf > lo) & (conf <= hi)
                    cal.append({**base, "bin": b, "lo": lo, "hi": hi, "n": int(msk.sum()),
                                "acc": float(ok[msk].mean()) if msk.any() else np.nan,
                                "conf": float(conf[msk].mean()) if msk.any() else np.nan})
    out = {}
    for name, rows in [("per_fold_class", pc), ("fold_scores", fs), ("confusion_long", cm), ("calibration_bins", cal)]:
        d = pd.DataFrame(rows); d.to_csv(tables / f"{name}.csv", index=False); out[name] = d
    rlt = pd.concat(rl) if rl else pd.DataFrame(); rlt.to_csv(tables / "recording_level.csv", index=False); out["recording_level"] = rlt
    log(f"cv tables: {len(fs)} jobs scored")
    return out


def summaries(t, tables):
    """Fold mean per class (the marked number), its spread over folds, over seeds, and a 95% CI."""
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
    """Paired Wilcoxon signed-rank tests over the 10 folds (seed 0)."""
    from scipy.stats import wilcoxon
    fs = t["fold_scores"]
    if fs.empty:
        return pd.DataFrame()
    rows = []

    def compare(name, a, b, metric):
        m = a.merge(b, on="fold", suffixes=("_a", "_b"))
        if len(m) < 5:
            return
        d = m[f"{metric}_a"] - m[f"{metric}_b"]
        try:
            pv = wilcoxon(m[f"{metric}_a"], m[f"{metric}_b"]).pvalue if (d != 0).any() else 1.0
        except ValueError:
            pv = np.nan
        rows.append({"comparison": name, "metric": metric, "n_folds": len(m), "mean_a": m[f"{metric}_a"].mean(),
                     "mean_b": m[f"{metric}_b"].mean(), "mean_diff": d.mean(), "folds_a_better": int((d > 0).sum()),
                     "p_wilcoxon": pv})

    for task, metrics in [("har", ["static", "dynamic"]), ("social", ["social", "social_min"])]:
        fin = fs[(fs.group == "main") & (fs.task == task) & (fs.variant == "jan") & (fs.seed == 0)]
        for m in metrics:
            for model, g in fs[(fs.group == "baseline") & (fs.task == task)].groupby("model"):
                compare(f"{task}: {C.FINAL[task]} vs {model} (Jan2026 only)", fin, g, m)
            jr = fs[(fs.group == "main") & (fs.task == task) & (fs.variant == "jan+real") & (fs.seed == 0)]
            compare(f"{task}: Jan2026 + real data vs Jan2026 only", jr, fin, m)
        if task == "social":
            for pw, g in fs[fs.group == "sweep"].groupby("power"):
                for m in ["social", "social_min"]:
                    compare(f"social: class-weight power {C.SOCIAL_POWER:g} vs {pw:g}", fin, g, m)
    d = pd.DataFrame(rows); d.to_csv(tables / "stat_tests.csv", index=False)
    return d


def history_table(jobs, tables):
    rows = []
    for r in jobs.itertuples():
        for h in r.xhist or []:
            rows.append({"id": r.id, "group": r.group, "task": r.task, "model": r.model, "variant": r.variant,
                         "seed": r.seed, "fold": r.fold, "power": r.power, "person": r.person, **h})
    d = pd.DataFrame(rows)
    d.to_csv(tables / "epochs.csv", index=False)
    return d


# ───────────────────────── gate (social only while not moving) on the official folds
def gate_table(jobs, tables):
    rows, leaks = [], []
    for v in C.VARIANTS:
        for k in C.FOLDS:
            vs = v.replace("+", "_")
            g, s = npz(f"gate_{vs}_f{k}"), npz(f"main_social_{vs}_s0_f{k}")
            if g is None or s is None or "gate__P" not in g:
                continue
            assert np.array_equal(g["gate__rid"], s["cv__rid"])
            y, ps, ph = s["cv__y"], s["cv__P"].argmax(1), g["gate__P"].argmax(1)
            for name, on in [("not_moving", np.isin(ph, STATIC_IDX)), ("sitting_standing", ph == SIT)]:
                for c in range(4):
                    m = y == c
                    rows.append({"variant": v, "fold": k, "gate": name, "class": SOCIAL_CLASSES[c],
                                 "enabled": float(on[m].mean()), "recall_no_gate": float((ps[m] == c).mean()),
                                 "recall_end_to_end": float(((ps == c) & on)[m].mean()),
                                 "recall_when_shown": float((ps[m & on] == c).mean()) if (m & on).any() else np.nan,
                                 "hidden_as": pd.Series([HAR_CLASSES[i] for i in ph[m & ~on]]).value_counts().head(3).to_dict()})
            h = npz(f"main_har_{vs}_s0_f{k}")
            if h is not None:
                yh, phh = h["cv__y"], h["cv__P"].argmax(1)
                for c in DYNAMIC:
                    ci = HAR_CLASSES.index(c)
                    leaks.append({"variant": v, "fold": k, "class": c, "called_static": float(np.isin(phh[yh == ci], STATIC_IDX).mean())})
    d, l = pd.DataFrame(rows), pd.DataFrame(leaks)
    d.to_csv(tables / "gate_folds.csv", index=False); l.to_csv(tables / "gate_leaks.csv", index=False)
    return d, l


# ───────────────────────── leave-one-person-out
def lopo_table(jobs, tables):
    rows, gates = [], []
    meta = load_set("real")[1]
    for r in jobs[(jobs.group == "lopo") & (jobs.status == "ok")].itertuples():
        z = npz(r.id)
        if z is None:
            continue
        for key in z.files:
            if not key.endswith("__P"):
                continue
            name = key[:-3]
            person = name.split("_", 1)[1]
            P, y, rid = z[key], z[f"{name}__y"], z[f"{name}__rid"]
            p = P.argmax(1)
            if name.startswith("person_"):
                rec = recall_vec(y, p, len(classes(r.task)))
                post = meta.posture.to_numpy()[rid]
                for grp, m in [("all", np.ones(len(y), bool)), ("sitting/standing", np.isin(post, ["sitting", "standing"])),
                               ("lying", np.isin(post, ["back", "left", "right", "stomach"]))]:
                    if r.task == "har" and grp != "all":
                        continue
                    rg = recall_vec(y[m], p[m], len(classes(r.task)))
                    for c, v in zip(classes(r.task), rg):
                        rows.append({"task": r.task, "variant": r.variant, "trained_without": person, "person": person,
                                     "postures": grp, "class": c, "recall": v, "id": r.id})
            elif name.startswith("gate_"):
                gates.append({"variant": r.variant, "person": person, "id": r.id,
                              **{f"hidden_{SOCIAL_CLASSES[c]}": float((~np.isin(p[y == c], STATIC_IDX)).mean()) for c in range(4)}})
    d = pd.DataFrame(rows)
    d = d[d.person.isin(C.PEOPLE)] if not d.empty else d
    # A was trained without both people: keep it once per person
    d.to_csv(tables / "lopo_per_class.csv", index=False)
    g = pd.DataFrame(gates); g.to_csv(tables / "lopo_gate.csv", index=False)
    if not d.empty:
        s = d.groupby(["task", "variant", "person", "postures"]).recall.mean().rename("balanced").reset_index()
        s.to_csv(tables / "lopo_scores.csv", index=False)
    return d, g


# ───────────────────────── real-time simulation (app behaviour on unseen people)
def _mode3(p):
    out = p.copy()
    for i in range(2, len(p)):
        v, c = np.unique(p[i - 2:i + 1], return_counts=True)
        out[i] = v[c.argmax()] if c.max() > 1 else p[i]
    return out


def simulate(tables, log, sessions=5):
    """Stream each person's recordings back to back (random order, 5 orders) through the leave-that-person-out
    models with the final strategies, at every update interval the app offers. Measures accuracy of what the app
    shows (raw and smoothed), latency after each change of activity, and the social gate."""
    import keras
    from harry import layers as _l, augment as _a  # noqa: F401
    sig, meta = load_set("real")
    strat = {"har": "C" if C.REAL_STRATEGY["har"] == "finetune" else "B", "social": "C" if C.REAL_STRATEGY["social"] == "finetune" else "B"}
    res, lat, trial, tl = [], [], [], []
    for person in C.PEOPLE:
        paths = {t: JOBS / "models" / f"lopo_{t}_{strat[t]}_{person}.keras" for t in ("har", "social")}
        if not all(p.exists() for p in paths.values()):
            continue
        mh = keras.models.load_model(paths["har"], compile=False)
        ms = keras.models.load_model(paths["social"], compile=False)
        idx = np.flatnonzero(meta.person == person)
        for task in ("har", "social"):
            ids = idx if task == "har" else idx[meta.social_y.to_numpy()[idx] >= 0]
            for s in range(sessions):
                order = np.random.default_rng(s).permutation(ids)
                x = np.concatenate([sig[i] for i in order])
                lab = np.concatenate([np.full(len(sig[i]), meta[("har_y" if task == "har" else "social_y")][i]) for i in order])
                bounds = np.cumsum([len(sig[i]) for i in order])[:-1]
                for step in C.APP_STEPS:
                    W = C.W[task]
                    ends = np.arange(W, len(x) + 1, step)
                    Xw = np.stack([x[e - W:e] for e in ends])
                    pr = (mh if task == "har" else ms).predict(Xw, batch_size=4096, verbose=0).argmax(1)
                    true = lab[ends - 1]
                    variants = {"raw": pr}
                    if task == "har":
                        variants["smoothed"] = _mode3(pr)
                    else:
                        gate = np.isin(mh.predict(Xw[:, -C.W["har"]:], batch_size=4096, verbose=0).argmax(1), STATIC_IDX)
                        variants["gated"] = np.where(gate, pr, -1)
                    for vname, pv in variants.items():
                        for c in np.unique(true):
                            m = true == c
                            res.append({"person": person, "task": task, "session": s, "step": step, "output": vname,
                                        "class": classes(task)[c], "n": int(m.sum()), "accuracy": float((pv[m] == c).mean())})
                        for b in bounds:
                            new = lab[b]
                            if new == lab[b - 1]:          # two recordings of the same class: no change to detect
                                continue
                            after = np.flatnonzero(ends > b)
                            okk = pv[after] == new
                            first = after[okk.argmax()] if okk.any() else None
                            stable = None
                            for j in range(len(after) - 2):
                                if okk[j] and okk[j + 1] and okk[j + 2]:
                                    stable = after[j]; break
                            nxt = [q for q in bounds if q > b]
                            limit = nxt[0] if nxt else len(x)
                            lat.append({"person": person, "task": task, "session": s, "step": step, "output": vname,
                                        "to": classes(task)[new], "from": classes(task)[lab[b - 1]],
                                        "first_correct_s": (ends[first] - b) / C.FS if first is not None and ends[first] <= limit else np.nan,
                                        "stable_s": (ends[stable] - b) / C.FS if stable is not None and ends[stable] <= limit else np.nan})
                    if s == 0 and step == C.APP_DEFAULT_STEP:
                        out_v = variants["smoothed" if task == "har" else "gated"]
                        tl.append(pd.DataFrame({"person": person, "task": task, "t_s": ends / C.FS, "true": [classes(task)[i] for i in true],
                                                "pred": [classes(task)[i] for i in pr],
                                                "shown": [classes(task)[i] if i >= 0 else "hidden" for i in out_v]}))
            # trial-style (like the app's real-time test): each recording from a cold start
            for i in ids:
                W = C.W[task]
                ends = np.arange(W, len(sig[i]) + 1, C.APP_DEFAULT_STEP)
                Xw = np.stack([sig[i][e - W:e] for e in ends])
                pr = (mh if task == "har" else ms).predict(Xw, batch_size=4096, verbose=0).argmax(1)
                c = int(meta[("har_y" if task == "har" else "social_y")][i])
                ok = pr == c
                trial.append({"person": person, "task": task, "file": meta.file[i], "class": classes(task)[c],
                              "results": len(pr), "accuracy": float(ok.mean()), "majority_correct": bool(np.bincount(pr).argmax() == c),
                              "first_correct_s": ends[ok.argmax()] / C.FS if ok.any() else np.nan})
        log(f"simulated the app for {person}")
    out = {}
    for name, rows in [("stream_accuracy", res), ("stream_latency", lat), ("trial_simulation", trial)]:
        d = pd.DataFrame(rows); d.to_csv(tables / f"{name}.csv", index=False); out[name] = d
    tlt = pd.concat(tl) if tl else pd.DataFrame(); tlt.to_csv(tables / "stream_timeline.csv", index=False); out["timeline"] = tlt
    return out


def embeddings(tables, log, n=2500):
    """t-SNE of the penultimate layer (head_dense) for fold 0 of the headline models."""
    import keras
    from sklearn.manifold import TSNE
    from harry import layers as _l, augment as _a  # noqa: F401
    rows = []
    for task in ("har", "social"):
        jid = f"main_{task}_{C.HEADLINE.replace('+', '_')}_s0_f0"
        mp, z = JOBS / "models" / f"{jid}.keras", npz(jid)
        if not mp.exists() or z is None:
            continue
        from .data import windows
        X, y, _, _ = windows([(f"jan_{task}", {"fold_eq": 0}, C.TEST_STEP)], task, C.W[task])
        sel = np.random.default_rng(0).permutation(len(y))[:n]
        m = keras.models.load_model(mp, compile=False)
        emb = keras.Model(m.input, m.get_layer("head_dense").output).predict(X[sel], batch_size=2048, verbose=0)
        xy = TSNE(2, init="pca", random_state=0, perplexity=35).fit_transform(emb)
        pred = m.predict(X[sel], batch_size=2048, verbose=0).argmax(1)
        rows.append(pd.DataFrame({"task": task, "x": xy[:, 0], "y": xy[:, 1], "true": [classes(task)[i] for i in y[sel]],
                                  "pred": [classes(task)[i] for i in pred]}))
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
    out["gate"], out["leaks"] = gate_table(jobs, tables)
    out["lopo"], out["lopo_gate"] = lopo_table(jobs, tables)
    out["deploy"] = deploy_table(jobs, tables)
    for name, fn in [("sim", simulate), ("tsne", embeddings)]:
        try:
            out[name] = fn(tables, log)
        except Exception as e:                                      # noqa: BLE001
            log(f"{name} skipped: {e!r}")
    timing = jobs.groupby("group").seconds.agg(["count", "sum", "mean"]).reset_index()
    timing.to_csv(tables / "timing.csv", index=False)
    out["timing"] = timing
    return out
