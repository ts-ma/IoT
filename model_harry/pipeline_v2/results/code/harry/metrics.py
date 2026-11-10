"""Metrics that mirror the CW3 marking (PLAN.md G1.4): per-class recall, group means, per-recording vote."""
import numpy as np
import pandas as pd
from sklearn.metrics import confusion_matrix

from .data import HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC


def per_class_recall(y, p, n):
    cm = confusion_matrix(y, p, labels=range(n))
    tot = cm.sum(1)
    return np.where(tot > 0, np.diag(cm) / np.maximum(tot, 1), np.nan), cm


def summarise(task, recall):
    classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
    d = {c: float(r) for c, r in zip(classes, recall)}
    if task == "har":
        d["STATIC_MEAN"] = float(np.nanmean([d[c] for c in STATIC]))
        d["DYNAMIC_MEAN"] = float(np.nanmean([d[c] for c in DYNAMIC]))
        d["SCORE"] = (d["STATIC_MEAN"] + d["DYNAMIC_MEAN"]) / 2
    else:
        vals = [d[c] for c in SOCIAL_CLASSES]
        d["BALANCED"] = float(np.nanmean(vals))
        d["MIN_CLASS"] = float(np.nanmin(vals))
        d["SCORE"] = d["BALANCED"]
    return d


def recording_vote(y, p, rec_ids):
    df = pd.DataFrame({"r": rec_ids, "y": y, "p": p})
    v = df.groupby("r").agg(y=("y", "first"), p=("p", lambda s: s.mode().iloc[0]))
    return float((v.y == v.p).mean())
