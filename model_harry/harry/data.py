"""Data loading, labels, windowing and CV fold schemes (PLAN.md G1, G5).

Real data  : IoT/data/<uun>/PDIOT_<uun>_<Activity>_<Sub>_<dd-mm-yyyy>_<HH-MM-SS>.csv  (training + CV)
Check data : IoT-RESpeck/datasetJan2026                                        (casual final check only)
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]                     # .../IoT
REAL_DIR = ROOT / "data"
JAN_DIR = Path(os.environ.get("HARRY_JAN_DIR", "") or "/Volumes/Macintosh HD2/Uni Course/Year 4/Semester_1/IoT/Coursework_2_3/IoT-RESpeck/datasetJan2026")

FS = 12.5
AXES = ["accelX", "accelY", "accelZ"]

# Class order is identical to the teammate's models / the Lab 4 app contract.
HAR_CLASSES = ["sittingStanding", "lyingBack", "lyingLeft", "lyingRight", "lyingStomach",
               "normalWalking", "shuffleWalking", "ascending", "descending", "running", "miscMovement"]
SOCIAL_CLASSES = ["breathingNormally", "coughing", "hyperventilation", "other"]
STATIC = HAR_CLASSES[:5]
DYNAMIC = HAR_CLASSES[5:]

ACTIVITY_TO_HAR = {
    "sitting": "sittingStanding", "standing": "sittingStanding",
    "lyingdownback": "lyingBack", "lyingdownleft": "lyingLeft",
    "lyingdownright": "lyingRight", "lyingdownstomach": "lyingStomach",
    "normalwalking": "normalWalking", "shufflewalking": "shuffleWalking",
    "ascendingstairs": "ascending", "descendingstairs": "descending",
    "running": "running", "miscellaneousmovements": "miscMovement",
}
ACTIVITY_TO_POSTURE = {
    "sitting": "sitting", "standing": "standing", "lyingdownback": "back",
    "lyingdownleft": "left", "lyingdownright": "right", "lyingdownstomach": "stomach",
}
SUB_TO_SOCIAL = {
    "normal": "breathingNormally", "coughing": "coughing", "hyperventilating": "hyperventilation",
    "talking": "other", "eating": "other", "singing": "other", "laughing": "other",
}
# HAR 1-subject CV: static recordings are held out whole, grouped by behaviour (G1.3)
SUB_TO_HAR_FOLD = {"normal": 0, "coughing": 1, "hyperventilating": 2,
                   "talking": 3, "eating": 3, "singing": 4, "laughing": 4}
POSTURES = ["sitting", "standing", "back", "left", "right", "stomach"]

_NAME = re.compile(r"PDIOT_([^_]+)_([A-Za-z]+)_([A-Za-z]+)_.*\.csv", re.IGNORECASE)


def load_signal(path) -> np.ndarray:
    return pd.read_csv(path, usecols=AXES)[AXES].dropna().to_numpy(np.float32)


def list_real(root: Path = REAL_DIR) -> pd.DataFrame:
    """One row per real recording with every label we can derive from the file name."""
    rows = []
    for p in sorted(root.glob("*/*.csv")):
        m = _NAME.fullmatch(p.name)
        if not m:
            raise ValueError(f"unexpected file name {p}")
        uun, act, sub = m.group(1), m.group(2).lower(), m.group(3).lower()
        if act not in ACTIVITY_TO_HAR or sub not in SUB_TO_SOCIAL:
            raise ValueError(f"unknown activity/sub-activity in {p.name}")
        stationary = act in ACTIVITY_TO_POSTURE
        rows.append(dict(path=p, subject=p.parent.name, activity=act, sub=sub,
                         har=ACTIVITY_TO_HAR[act], har_y=HAR_CLASSES.index(ACTIVITY_TO_HAR[act]),
                         stationary=stationary, posture=ACTIVITY_TO_POSTURE.get(act),
                         social=SUB_TO_SOCIAL[sub] if stationary else None,
                         social_y=SOCIAL_CLASSES.index(SUB_TO_SOCIAL[sub]) if stationary else -1))
    df = pd.DataFrame(rows)
    df["rec_id"] = np.arange(len(df))
    return df


def make_windows(sig: np.ndarray, window: int, step: int) -> np.ndarray:
    if len(sig) < window:
        return np.empty((0, window, 3), np.float32)
    return np.stack([sig[s:s + window] for s in range(0, len(sig) - window + 1, step)]).astype(np.float32)


# ---------------------------------------------------------------- pieces & folds
@dataclass
class Piece:
    """A contiguous chunk of one recording that belongs wholly to train or test."""
    x: np.ndarray
    rec_id: int
    har_y: int
    social_y: int
    sub: str
    posture: str | None
    subject: str


def _piece(r, x) -> Piece:
    posture = r.posture if isinstance(r.posture, str) else None        # pandas>=3 stores None as NaN
    return Piece(x, int(r.rec_id), int(r.har_y), int(r.social_y), r.sub, posture, r.subject)


def har_folds(recs: pd.DataFrame, n_blocks: int = 5):
    """Yield (fold_name, train_pieces, test_pieces) for HAR.

    >=2 subjects: leave-one-subject-out.
    1 subject   : static recordings held out whole by behaviour group (SUB_TO_HAR_FOLD);
                  dynamic recordings split into n_blocks contiguous time blocks, block k is test and the
                  remaining samples are kept as separate before/after pieces so no window straddles the split.
    """
    sigs = {r.rec_id: load_signal(r.path) for r in recs.itertuples()}
    subjects = sorted(recs.subject.unique())
    if len(subjects) >= 2:
        for s in subjects:
            tr = [_piece(r, sigs[r.rec_id]) for r in recs.itertuples() if r.subject != s]
            te = [_piece(r, sigs[r.rec_id]) for r in recs.itertuples() if r.subject == s]
            yield f"subject={s}", tr, te
        return
    for k in range(n_blocks):
        tr, te = [], []
        for r in recs.itertuples():
            x = sigs[r.rec_id]
            if r.stationary:
                (te if SUB_TO_HAR_FOLD[r.sub] == k else tr).append(_piece(r, x))
            else:
                edges = np.linspace(0, len(x), n_blocks + 1).astype(int)
                a, b = edges[k], edges[k + 1]
                te.append(_piece(r, x[a:b]))
                for seg in (x[:a], x[b:]):
                    if len(seg):
                        tr.append(_piece(r, seg))
        yield f"block/behaviour={k}", tr, te


def social_folds(recs: pd.DataFrame):
    """Leave-one-posture-out on stationary recordings (or LOSO with >=2 subjects)."""
    st = recs[recs.stationary]
    sigs = {r.rec_id: load_signal(r.path) for r in st.itertuples()}
    subjects = sorted(st.subject.unique())
    key, values = ("subject", subjects) if len(subjects) >= 2 else ("posture", POSTURES)
    for v in values:
        tr = [_piece(r, sigs[r.rec_id]) for r in st.itertuples() if getattr(r, key) != v]
        te = [_piece(r, sigs[r.rec_id]) for r in st.itertuples() if getattr(r, key) == v]
        yield f"{key}={v}", tr, te


def windows_from_pieces(pieces, window: int, step: int, task: str):
    X, y, meta = [], [], []
    for p in pieces:
        w = make_windows(p.x, window, step)
        if not len(w):
            continue
        X.append(w)
        lab = p.har_y if task == "har" else p.social_y
        y += [lab] * len(w)
        meta += [(p.rec_id, p.sub, p.posture, p.subject)] * len(w)
    meta = pd.DataFrame(meta, columns=["rec_id", "sub", "posture", "subject"])
    return np.concatenate(X), np.array(y, dtype=np.int64), meta


def all_pieces(recs: pd.DataFrame, task: str):
    rr = recs if task == "har" else recs[recs.stationary]
    return [_piece(r, load_signal(r.path)) for r in rr.itertuples()]


# ---------------------------------------------------------------- datasetJan2026 (casual check only)
def list_jan(task: str, classes, root: Path | None = None) -> pd.DataFrame:
    """Exactly the teammate's list_recordings(): class order, then sorted glob."""
    root = Path(root) if root is not None else JAN_DIR
    rows = [{"path": p, "label": c, "y": i}
            for i, c in enumerate(classes) for p in sorted((root / task / c).glob("*.csv"))]
    return pd.DataFrame(rows)


def teammate_split(recs: pd.DataFrame, val_frac=0.15, test_frac=0.15, seed=0):
    """Re-creates split_recordings() from Lab3_trained.ipynb (stratified, seed 0)."""
    from sklearn.model_selection import train_test_split
    train_val, test = train_test_split(recs, test_size=test_frac, stratify=recs.y, random_state=seed)
    train, val = train_test_split(train_val, test_size=val_frac / (1 - test_frac),
                                  stratify=train_val.y, random_state=seed)
    return train, val, test


def jan_windows(recs: pd.DataFrame, window: int, step: int):
    X, y, rid = [], [], []
    for i, r in recs.iterrows():
        w = make_windows(load_signal(r.path), window, step)
        X.append(w); y += [r.y] * len(w); rid += [i] * len(w)
    return np.concatenate(X), np.array(y), np.array(rid)
