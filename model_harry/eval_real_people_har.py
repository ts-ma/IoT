"""HAR check on real people: train harry_cnn on ALL listed datasetJan2026 daily_activity recordings (the same
recipe the official-fold CV scores), then test on each person's 44 recordings. No real data is used for training.

For comparison, the app's shipped HAR model (models/recommended/har/harry_cnn.tflite: Jan2026 pre-train +
fine-tune on s2503795) is tested the same way; it has seen s2503795, so only its s2952925 numbers are fair.

Recordings are streamed like the app: a HAR result every 12 samples from the last 50 (4 s), no smoothing.
Also reported, for the "social only when stationary" rule:
  social hidden  share of stationary recordings (sitting/standing/lying, any breathing or social signal)
                 that HAR calls moving, per social signal: these would hide the social result
  social leaks   share of moving recordings that HAR calls stationary: social would wrongly run

Usage: python eval_real_people_har.py [--people ../data/s2503795 ../data/s2952925]
Output: results/real_people/har_report.md, har_summary.json, models/har_jan.keras
"""
import argparse
import contextlib
import json
import os
import re
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from eval_official_folds import W, APP_STEP, TFLITE, STATIC_IDX, init_worker, load_set, windows, recall, har_summary, pct  # noqa: E402
from harry.data import HAR_CLASSES, STATIC, DYNAMIC, SOCIAL_CLASSES, ACTIVITY_TO_HAR, ACTIVITY_TO_POSTURE, SUB_TO_SOCIAL, load_signal  # noqa: E402

CACHE = HERE / "results/official_folds/cache"
PAT = re.compile(r"PDIOT_[^_]+_([A-Za-z]+)_([A-Za-z]+)_.*\.csv", re.I)


def train(out):
    dst = out / "models" / "har_jan.keras"
    if dst.exists():
        return dst
    import keras
    from harry.zoo import build
    from harry.runner import RECIPES, _fit
    from harry import layers as _l, augment as _a  # noqa: F401
    with open(out / "train_har.log", "w", buffering=1) as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        sig, meta = load_set(CACHE, "har")
        rec = dict(RECIPES[("harry", "jan")])
        X, rid = windows(sig, np.arange(len(sig)), W["har"], rec["step"])
        y = meta.y.to_numpy()[rid]
        print(f"harry_cnn on all {len(sig)} listed Jan2026 daily_activity recordings: {X.shape}, recipe {rec}")
        keras.utils.set_random_seed(0)
        core = build("harry_cnn", "har", len(HAR_CLASSES), X)
        _fit(core, X, y, len(HAR_CLASSES), rec, {}, [], "har", {"seed_base": 0}, log)
        dst.parent.mkdir(parents=True, exist_ok=True)
        core.save(dst)
    return dst


def person(folder):
    X, rows = [], []
    for p in sorted(Path(folder).glob("*.csv")):
        act, sub = (s.lower() for s in PAT.fullmatch(p.name).groups())
        x = load_signal(p)
        ends = np.arange(W["har"], len(x) + 1, APP_STEP)
        X.append(np.stack([x[e - W["har"]:e] for e in ends]))
        social = SUB_TO_SOCIAL[sub] if act in ACTIVITY_TO_POSTURE else ""
        rows += [(HAR_CLASSES.index(ACTIVITY_TO_HAR[act]), social, p.name)] * len(ends)
    return np.concatenate(X), pd.DataFrame(rows, columns=["y", "social", "file"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--people", nargs="+", default=[str(HERE.parent / "data/s2503795"), str(HERE.parent / "data/s2952925")])
    ap.add_argument("--out", default=str(HERE / "results/real_people"))
    a = ap.parse_args()
    out = Path(a.out); (out / "models").mkdir(parents=True, exist_ok=True)
    log = lambda m: print(time.strftime("%H:%M:%S"), m, flush=True)            # noqa: E731
    init_worker(os.cpu_count() or 8)
    log("training harry_cnn on all Jan2026 daily_activity (~2-3 min)")
    path = train(out)
    import keras
    import tensorflow as tf
    from harry import layers as _l, augment as _a  # noqa: F401
    jan = keras.models.load_model(path, compile=False)
    it = tf.lite.Interpreter(model_path=str(TFLITE["har"]))

    def shipped(X):
        i, o = it.get_input_details()[0], it.get_output_details()[0]
        it.resize_tensor_input(i["index"], list(X.shape)); it.allocate_tensors()
        it.set_tensor(i["index"], X.astype(np.float32)); it.invoke()
        return it.get_tensor(o["index"])

    models = {"Jan2026 only (new)": lambda X: jan.predict(X, batch_size=4096, verbose=0),
              "shipped (Jan + s2503795 fine-tune)": shipped}
    res = {}
    L = ["# HAR on real people", "",
         f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `model_harry/eval_real_people_har.py`. All numbers are %.",
         "**Jan2026 only**: harry_cnn trained on all listed datasetJan2026 daily_activity recordings (Jan recipe, "
         "32 epochs); no real data in training, so both people are unseen. **Shipped**: the app's model, fine-tuned "
         "on s2503795 (its s2503795 numbers are not a fair test). A result every 12 samples from the last 4 s, "
         "no smoothing.", "",
         "| person | model | " + " | ".join(HAR_CLASSES) + " | STATIC | DYNAMIC |", "|---" * (len(HAR_CLASSES) + 4) + "|"]
    gate = ["", "## The \"social only when stationary\" rule", "",
            "*Social hidden*: stationary windows that HAR calls moving (the social result would be hidden), by "
            "what the person was doing. *Social leaks*: moving windows that HAR calls stationary.", "",
            "| person | model | " + " | ".join(f"hidden: {c}" for c in SOCIAL_CLASSES) + " | leaks: moving |",
            "|---" * (len(SOCIAL_CLASSES) + 3) + "|"]
    confusions = []
    for folder in a.people:
        name = Path(folder).name
        X, meta = person(folder)
        y = meta.y.to_numpy()
        for mname, f in models.items():
            p = f(X).argmax(1)
            s = har_summary(recall(y, p, len(HAR_CLASSES)))
            moving = ~np.isin(p, STATIC_IDX)
            hidden = {c: float(moving[meta.social.to_numpy() == c].mean()) for c in SOCIAL_CLASSES}
            leaks = float((~moving[np.isin(y, [HAR_CLASSES.index(c) for c in DYNAMIC])]).mean())
            res[f"{name}|{mname}"] = {"har": s, "social_hidden": hidden, "social_leaks": leaks}
            L.append(f"| {name} | {mname} | " + " | ".join(pct(s[c]) for c in HAR_CLASSES)
                     + f" | **{pct(s['STATIC'])}** | **{pct(s['DYNAMIC'])}** |")
            gate.append(f"| {name} | {mname} | " + " | ".join(pct(hidden[c]) for c in SOCIAL_CLASSES) + f" | {pct(leaks)} |")
            wrong = pd.DataFrame({"true": [HAR_CLASSES[i] for i in y], "pred": [HAR_CLASSES[i] for i in p]})
            wrong = wrong[wrong.true != wrong.pred].value_counts().head(5)
            confusions.append(f"- {name}, {mname}: " + (", ".join(f"{t} → {q} ({n})" for (t, q), n in wrong.items()) or "none"))
        log(f"{name}: {len(y)} HAR windows from {meta.file.nunique()} recordings")
    L += gate + ["", "## Most common mistakes (windows)", ""] + confusions
    (out / "har_report.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    (out / "har_summary.json").write_text(json.dumps(res, indent=1, default=float), encoding="utf-8")
    log(f"report: {out / 'har_report.md'}")


if __name__ == "__main__":
    main()
