"""Signal cache, windowing and the data audit.

Sets (one .npz + meta .csv each, built once, read by every worker):
  jan_har / jan_social     datasetJan2026 recordings listed in the official fold CSVs (fold 0-9)
  janx_har / janx_social   recordings on disk but not in the fold CSVs (unknown subjects: never in CV,
                           used only when training on "all Jan2026" for LOPO and the final models)
  real                     every recording of both group members (HAR label; social label if stationary)
"""
import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path

import numpy as np
import pandas as pd

from harry.data import (HAR_CLASSES, SOCIAL_CLASSES, ACTIVITY_TO_HAR, ACTIVITY_TO_POSTURE, SUB_TO_SOCIAL,
                        load_signal, make_windows)
from . import config as C

CACHE = C.OUT / "cache"
TASK_DIR = {"har": "daily_activity", "social": "social_signal"}
FOLD_CSV = {"har": "folds_daily_activity.csv", "social": "folds_social_signal.csv"}
PAT = re.compile(r"PDIOT_([^_]+)_([A-Za-z]+)_([A-Za-z]+)_.*\.csv", re.I)


def _md5(p):
    return hashlib.md5(Path(p).read_bytes()).hexdigest()


def _save(name, sig, meta):
    lens = np.array([len(s) for s in sig])
    np.savez_compressed(CACHE / f"{name}.npz", data=np.concatenate(sig).astype(np.float32), offsets=np.r_[0, np.cumsum(lens)])
    meta.to_csv(CACHE / f"{name}_meta.csv", index=False)


def build_cache(log=print):
    CACHE.mkdir(parents=True, exist_ok=True)
    for task in ("har", "social"):
        if (CACHE / f"jan_{task}.npz").exists():
            continue
        classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
        folds = pd.read_csv(C.FOLD_DIR / FOLD_CSV[task])
        fold_of = dict(zip(zip(folds.activity, folds.file), folds.fold.astype(int)))
        rows = {"jan": [], "janx": []}
        sigs = {"jan": [], "janx": []}
        for y, c in enumerate(classes):
            for p in sorted((C.JAN_DIR / TASK_DIR[task] / c).glob("*.csv"), key=lambda q: q.name):
                k = fold_of.get((c, p.name), -1)
                s = "jan" if k >= 0 else "janx"
                x = load_signal(p)
                rows[s].append({"activity": c, "file": p.name, "fold": k, "y": y, "md5": _md5(p), "n": len(x)})
                sigs[s].append(x)
        for s in ("jan", "janx"):
            _save(f"{s}_{task}", sigs[s], pd.DataFrame(rows[s]))
        log(f"cached {task}: {len(rows['jan'])} listed, {len(rows['janx'])} unlisted recordings")
    if not (CACHE / "real.npz").exists():
        rows, sigs = [], []
        for person in C.PEOPLE:
            for p in sorted((C.ROOT / "data" / person).glob("*.csv")):
                _, act, sub = PAT.fullmatch(p.name).groups()
                act, sub = act.lower(), sub.lower()
                raw = pd.read_csv(p)
                x = load_signal(p)
                st = act in ACTIVITY_TO_POSTURE
                ts = raw["timestamp"].to_numpy() if "timestamp" in raw else None
                dur = (ts[-1] - ts[0]) / 1000 if ts is not None and len(ts) > 1 else np.nan
                rows.append({"person": person, "file": p.name, "activity": act, "sub": sub,
                             "har": ACTIVITY_TO_HAR[act], "har_y": HAR_CLASSES.index(ACTIVITY_TO_HAR[act]),
                             "stationary": st, "posture": ACTIVITY_TO_POSTURE.get(act, ""),
                             "social": SUB_TO_SOCIAL[sub] if st else "",
                             "social_y": SOCIAL_CLASSES.index(SUB_TO_SOCIAL[sub]) if st else -1,
                             "n": len(x), "n_raw": len(raw), "nan_rows": int(raw[["accelX", "accelY", "accelZ"]].isna().any(axis=1).sum()),
                             "duration_s": dur, "fs_est": (len(raw) - 1) / dur if dur and dur > 0 else np.nan,
                             "md5": _md5(p)})
                sigs.append(x)
        _save("real", sigs, pd.DataFrame(rows))
        log(f"cached real data: {len(rows)} recordings from {len(C.PEOPLE)} people")


@lru_cache(maxsize=16)
def load_set(name):
    z = np.load(CACHE / f"{name}.npz")
    meta = pd.read_csv(CACHE / f"{name}_meta.csv", keep_default_na=False)
    d, o = z["data"], z["offsets"]
    return [d[o[i]:o[i + 1]] for i in range(len(o) - 1)], meta


def label_col(set_name, task):
    return ("har_y" if task == "har" else "social_y") if set_name == "real" else "y"


def select(set_name, task, sel):
    """Selector dict -> recording indices. Keys: fold_eq, fold_ne, people, not_people, drop_md5_of_social_fold."""
    _, meta = load_set(set_name)
    idx = np.arange(len(meta))
    if set_name == "real" and task == "social":
        idx = idx[meta.social_y.to_numpy()[idx] >= 0]
    if "fold_eq" in sel:
        idx = idx[meta.fold.to_numpy()[idx] == sel["fold_eq"]]
    if "fold_ne" in sel:
        idx = idx[meta.fold.to_numpy()[idx] != sel["fold_ne"]]
    if "people" in sel:
        idx = idx[meta.person.isin(sel["people"]).to_numpy()[idx]]
    if "drop_md5_of_social_fold" in sel:           # gate model: no copies of the social test recordings
        _, sm = load_set("jan_social")
        bad = set(sm.md5[sm.fold == sel["drop_md5_of_social_fold"]])
        idx = idx[~meta.md5.isin(bad).to_numpy()[idx]]
    if sel.get("subsample", 1) > 1:
        idx = idx[::sel["subsample"]]
    return idx


def windows(parts, task, window):
    """parts: list of (set_name, selector, step[, crop_last]). Returns X, y, src (set id), rid (recording idx)."""
    X, y, src, rid = [], [], [], []
    for part in parts:
        name, sel, step = part[:3]
        crop = part[3] if len(part) > 3 else None
        sig, meta = load_set(name)
        lab = meta[label_col(name, task)].to_numpy()
        for i in select(name, task, sel):
            w = make_windows(sig[i], window, step)
            if not len(w):
                continue
            if crop:
                w = w[:, -crop:]
            X.append(w); y += [int(lab[i])] * len(w); src += [name] * len(w); rid += [int(i)] * len(w)
    if not X:
        return np.empty((0, crop or window, 3), np.float32), np.empty(0, int), np.empty(0, object), np.empty(0, int)
    return np.concatenate(X), np.array(y), np.array(src, dtype=object), np.array(rid)


# ───────────────────────── data audit (tables only; figures are in plots.py)
def audit(tables, log=print):
    """Dataset composition, recording lengths, fold balance, duplicates, real-data quality."""
    out = {}
    rows = []
    for task in ("har", "social"):
        for s in ("jan", "janx"):
            sig, meta = load_set(f"{s}_{task}")
            for c, g in meta.groupby("activity"):
                n = g.n.to_numpy()
                rows.append({"task": task, "set": "listed" if s == "jan" else "unlisted", "class": c, "recordings": len(g),
                             "samples": int(n.sum()), "hours": n.sum() / C.FS / 3600, "len_mean_s": n.mean() / C.FS,
                             "len_min_s": n.min() / C.FS, "len_max_s": n.max() / C.FS,
                             "windows_test_step": int(sum(max(0, (k - C.W[task]) // C.TEST_STEP + 1) for k in n))})
    comp = pd.DataFrame(rows); comp.to_csv(tables / "data_composition.csv", index=False)
    out["composition"] = comp

    fr = []
    for task in ("har", "social"):
        _, meta = load_set(f"jan_{task}")
        fr.append(meta.groupby(["activity", "fold"]).size().rename("recordings").reset_index().assign(task=task))
    folds = pd.concat(fr); folds.to_csv(tables / "fold_composition.csv", index=False)

    # duplicates: static HAR files that are byte-copies of social recordings, and the folds they sit in
    _, h = load_set("jan_har"); _, s = load_set("jan_social")
    first = s.drop_duplicates("md5").set_index("md5")
    d = h[h.md5.isin(first.index)]
    dup = pd.DataFrame({"har_class": d.activity.to_numpy(), "har_file": d.file.to_numpy(), "har_fold": d.fold.to_numpy(),
                        "social_class": first.loc[d.md5, "activity"].to_numpy(),
                        "social_fold": first.loc[d.md5, "fold"].to_numpy()})
    dup.to_csv(tables / "duplicates_har_social.csv", index=False)
    within = {t: int((load_set(f"jan_{t}")[1].md5.value_counts() > 1).sum()) for t in ("har", "social")}
    out["dup"] = {"har_copies_of_social": len(dup), "same_fold": int((dup.har_fold == dup.social_fold).sum()),
                  "by_har_class": dup.har_class.value_counts().to_dict(), "by_social_class": dup.social_class.value_counts().to_dict(),
                  "within_task_duplicate_groups": within}

    # real data quality: lengths, sampling rate, NaNs, flat/clipped runs, gravity agreement with Jan2026
    sig, meta = load_set("real")
    jsig, jmeta = load_set("jan_har")
    jg = {c: np.mean([jsig[i].mean(0) for i in np.flatnonzero(jmeta.activity == c)], 0) for c in HAR_CLASSES}
    q = []
    for i, r in meta.iterrows():
        x = sig[i]
        g = x.mean(0)
        ref = jg[r.har]
        ang = float(np.degrees(np.arccos(np.clip(g @ ref / (np.linalg.norm(g) * np.linalg.norm(ref) + 1e-9), -1, 1))))
        flat = int(np.max(np.diff(np.flatnonzero(np.r_[True, np.any(np.abs(np.diff(x, axis=0)) > 1e-6, 1), True])))) if len(x) > 1 else 0
        q.append({**r.to_dict(), "gx": g[0], "gy": g[1], "gz": g[2], "g_norm": float(np.linalg.norm(g)),
                  "angle_to_jan_class_deg": ang, "dyn_std_g": float((x - g).std()),
                  "longest_flat_run": flat, "clipped": int((np.abs(x) > 7.9).sum())})
    qual = pd.DataFrame(q)
    qual["flag"] = np.where(qual.angle_to_jan_class_deg > 35, "posture differs from Jan2026",
                            np.where(qual.longest_flat_run > 25, "flat run > 2 s",
                                     np.where(qual.nan_rows > 0, "missing values", "")))
    qual.to_csv(tables / "real_data_quality.csv", index=False)
    out["real_quality"] = qual
    jq = []
    for c in HAR_CLASSES:
        for i in np.flatnonzero(jmeta.activity == c):
            g = jsig[i].mean(0); jq.append({"class": c, "gx": g[0], "gy": g[1], "gz": g[2], "dyn_std_g": float((jsig[i] - g).std())})
    pd.DataFrame(jq).to_csv(tables / "jan_gravity.csv", index=False)
    (tables / "data_facts.json").write_text(json.dumps(out["dup"], indent=1, default=int))
    log(f"data audit: {len(comp)} class rows, {len(dup)} HAR copies of social files, "
        f"{int((qual.flag != '').sum())} real recordings flagged")
    return out
