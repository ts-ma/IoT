"""Signal cache + fold definitions + selectors for the pipeline.

Sets (one .npz each, built once by the main process, read by every worker):
  real_har    all 44 real recordings, HAR labels          (IoT/data)
  real_social 38 stationary real recordings, social labels
  jan_har     datasetJan2026/daily_activity, teammate class order, B9 folds (seed 0)
  jan_social  datasetJan2026/social_signal, B9-style folds (N_x = recording index, so recording-wise)

A selector says which part of a set a job uses, e.g. {"set": "jan_har", "fold_ne": 3} or
{"set": "real_har", "segments": [[rec, start, end], ...]}. Jobs stay tiny to pickle.
"""
import re
from functools import lru_cache
from pathlib import Path

import numpy as np
import pandas as pd

from .data import (HAR_CLASSES, SOCIAL_CLASSES, POSTURES, SUB_TO_HAR_FOLD, load_signal, make_windows,
                   list_real, list_jan)

N_JAN_FOLDS = 10
CACHE_DIR = None          # set by configure()


def configure(cache_dir):
    global CACHE_DIR
    CACHE_DIR = Path(cache_dir)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)


# ───────────────────────── B9 folds (verbatim Lab 3 logic)
def subject_id(name: str) -> str:
    m = re.fullmatch(r"N_(\d+)\.csv", name)
    return m.group(1) if m else Path(name).stem


def make_folds(labels, names, n_folds=N_JAN_FOLDS, seed=0):
    recs = pd.DataFrame({"label": labels, "path": names})
    rng = np.random.default_rng(seed)
    out = pd.Series(-1, index=recs.index)
    for _, idx in recs.groupby("label").groups.items():
        subjects = recs.loc[idx, "path"].map(subject_id)
        unique = rng.permutation(subjects.unique())
        fold_of = {s: k % n_folds for k, s in enumerate(unique)}
        out.loc[idx] = subjects.map(fold_of)
    return out.to_numpy()


# ───────────────────────── cache build
def _save(name, signals, meta: pd.DataFrame):
    lens = np.array([len(s) for s in signals])
    np.savez_compressed(CACHE_DIR / f"{name}.npz", data=np.concatenate(signals).astype(np.float32),
                        offsets=np.r_[0, np.cumsum(lens)])
    meta.to_csv(CACHE_DIR / f"{name}_meta.csv", index=False)


def build_cache(real_dir, jan_dir, log=print):
    real_dir = Path(real_dir)
    if not (CACHE_DIR / "real_har.npz").exists():
        recs = list_real(real_dir)
        sig = [load_signal(p) for p in recs.path]
        meta = pd.DataFrame({"name": recs.path.map(lambda p: p.name), "subject": recs.subject, "sub": recs["sub"],
                             "posture": recs.posture.fillna(""), "stationary": recs.stationary})
        _save("real_har", sig, meta.assign(y=recs.har_y.to_numpy()))
        st = recs.stationary.to_numpy()
        _save("real_social", [s for s, k in zip(sig, st) if k],
              meta[st].reset_index(drop=True).assign(y=recs.social_y[st].to_numpy()))
        log(f"cached real data: {len(recs)} recordings ({recs.subject.nunique()} subject(s))")
    if jan_dir is None:
        return
    for name, folder, classes in [("jan_har", "daily_activity", HAR_CLASSES), ("jan_social", "social_signal", SOCIAL_CLASSES)]:
        if (CACHE_DIR / f"{name}.npz").exists():
            continue
        recs = list_jan(folder, classes, root=Path(jan_dir))
        sig = [load_signal(p) for p in recs.path]
        names = recs.path.map(lambda p: p.name).to_numpy()
        meta = pd.DataFrame({"name": names, "label": recs.label, "y": recs.y,
                             "fold": make_folds(recs.label.to_numpy(), names)})
        _save(name, sig, meta)
        log(f"cached {name}: {len(recs)} recordings")


# ───────────────────────── official (Learn) fold CSV
def _col(df, *names):
    low = {c.lower().strip().replace(" ", "_"): c for c in df.columns}
    return next((low[n] for n in names if n in low), None)


def read_fold_csv(path, task_folder, labels, names, log=print):
    """Map each Jan recording to its official fold. Accepts the Lab 3 layout (activity, file, fold) and common
    variants: file may be a bare name ('N_12.csv') or a path ('daily_activity/running/N_12.csv'); folds may be
    0- or 1-based. Returns an int array (fold per recording) or None if the CSV does not cover this task."""
    df = pd.read_csv(path)
    fcol = _col(df, "fold", "fold_id", "fold_number", "k")
    file_col = _col(df, "file", "filename", "file_name", "path", "recording", "csv")
    act_col = _col(df, "activity", "label", "class", "activity_type", "folder", "category")
    if fcol is None or file_col is None:
        raise ValueError(f"{path}: need a fold column and a file column, found {list(df.columns)}")
    files = df[file_col].astype(str).str.replace("\\", "/", regex=False)
    base = files.str.split("/").str[-1]
    act = (df[act_col].astype(str) if act_col else files.str.split("/").str[-2]).str.split("/").str[-1]
    folds = df[fcol].astype(int)
    if folds.min() == 1 and folds.max() == N_JAN_FOLDS:
        folds = folds - 1
    lut = dict(zip(zip(act, base), folds))
    out = np.array([lut.get((l, n), -1) for l, n in zip(labels, names)])
    hit = (out >= 0).mean()
    if hit < 0.95:
        log(f"  fold CSV covers only {hit:.0%} of {task_folder} recordings -> using Lab3 make_folds(seed 0) for it")
        return None
    if hit < 1:
        log(f"  fold CSV: {int((out < 0).sum())} {task_folder} recordings not listed -> excluded from D's test folds")
    return out


def assign_jan_folds(fold_csv=None, log=print):
    """(Re)write the fold column of the Jan caches: official CSV if given and it covers the task, else B9 folds."""
    for name, folder in [("jan_har", "daily_activity"), ("jan_social", "social_signal")]:
        mp = CACHE_DIR / f"{name}_meta.csv"
        if not mp.exists():
            continue
        meta = pd.read_csv(mp, keep_default_na=False)
        folds, src = None, "Lab3 make_folds(seed 0)"
        if fold_csv:
            folds = read_fold_csv(fold_csv, folder, meta.label.to_numpy(), meta.name.to_numpy(), log)
            src = f"official fold CSV ({Path(fold_csv).name})" if folds is not None else src
        meta["fold"] = folds if folds is not None else make_folds(meta.label.to_numpy(), meta.name.to_numpy())
        meta.to_csv(mp, index=False)
        load_set.cache_clear()
        log(f"folds for {name}: {src}")


# ───────────────────────── loading + windowing (workers)
@lru_cache(maxsize=8)
def load_set(name):
    z = np.load(CACHE_DIR / f"{name}.npz")
    meta = pd.read_csv(CACHE_DIR / f"{name}_meta.csv", keep_default_na=False)
    data, off = z["data"], z["offsets"]
    return [data[off[i]:off[i + 1]] for i in range(len(off) - 1)], meta


def available(name):
    return CACHE_DIR is not None and (CACHE_DIR / f"{name}.npz").exists()


def resolve(sel):
    """Selector -> list of (rec, start, end) segments."""
    sig, meta = load_set(sel["set"])
    if "segments" in sel:
        return [tuple(s) for s in sel["segments"]]
    idx = np.arange(len(sig))
    if "fold_eq" in sel:
        idx = idx[meta.fold.to_numpy() == sel["fold_eq"]]
    if "fold_ne" in sel:
        idx = idx[meta.fold.to_numpy() != sel["fold_ne"]]
    if "every_nth" in sel:
        idx = idx[::sel["every_nth"]]
    if "subsample" in sel:                       # quick profile: keep every k-th recording
        idx = idx[::sel["subsample"]]
    return [(int(i), 0, len(sig[i])) for i in idx]


def windows(sel, window, step):
    sig, meta = load_set(sel["set"])
    X, y, rid = [], [], []
    for r, a, b in resolve(sel):
        w = make_windows(sig[r][a:b], window, step)
        if len(w):
            X.append(w); y += [int(meta.y[r])] * len(w); rid += [r] * len(w)
    if not X:
        return np.empty((0, window, 3), np.float32), np.empty(0, np.int64), np.empty(0, np.int64)
    return np.concatenate(X), np.array(y, np.int64), np.array(rid, np.int64)


def meta_of(set_name):
    return load_set(set_name)[1]


# ───────────────────────── real-data folds (1 subject: behaviour/time-block & leave-one-posture-out;
#                            >=2 subjects: leave-one-subject-out)
def real_folds(task, n_blocks=5):
    sig, meta = load_set(f"real_{task}")
    lens = [len(s) for s in sig]
    subjects = sorted(meta.subject.unique())
    folds = []
    if len(subjects) >= 2:
        for s in subjects:
            folds.append((f"subject={s}", [(i, 0, lens[i]) for i in range(len(sig)) if meta.subject[i] != s],
                          [(i, 0, lens[i]) for i in range(len(sig)) if meta.subject[i] == s]))
        return folds
    if task == "social":
        for p in POSTURES:
            folds.append((f"posture={p}", [(i, 0, lens[i]) for i in range(len(sig)) if meta.posture[i] != p],
                          [(i, 0, lens[i]) for i in range(len(sig)) if meta.posture[i] == p]))
        return folds
    for k in range(n_blocks):
        tr, te = [], []
        for i in range(len(sig)):
            if str(meta.stationary[i]) == "True":
                (te if SUB_TO_HAR_FOLD[meta["sub"][i]] == k else tr).append((i, 0, lens[i]))
            else:
                e = np.linspace(0, lens[i], n_blocks + 1).astype(int)
                te.append((i, int(e[k]), int(e[k + 1])))
                tr += [(i, 0, int(e[k]))] if e[k] > 0 else []
                tr += [(i, int(e[k + 1]), lens[i])] if e[k + 1] < lens[i] else []
        folds.append((f"block/behaviour={k}", tr, te))
    return folds
