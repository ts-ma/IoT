"""Social recipe check on real people: train harry_rnn on ALL listed datasetJan2026 social recordings (the
same recipe the official-fold CV scores) with different class-weight settings, then test on each person's
stationary recordings. Nobody in data/<uun>/ is in Jan2026, so every person is unseen.

  balanced^1.0  the original recipe        balanced^0.6  softened weights (more "other")

Recordings are streamed like the app: a social result every 12 samples from the last 100 (8 s). The
"not moving" gate uses the app's exported HAR model (models/recommended/har/harry_cnn.tflite). Note that
this HAR model was fine-tuned on s2503795, so the gate is optimistic for that person only.

Usage: python eval_real_people.py [--powers 1.0 0.6] [--people ../data/s2503795 ../data/s2952925]
Output: results/real_people/report.md, summary.json, models/social_jan_w<power>.keras (kept for reuse)
"""
import argparse
import contextlib
import json
import os
import re
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from eval_official_folds import (W, APP_STEP, TFLITE, init_worker, load_set, windows, gated_tables,  # noqa: E402
                                 social_summary, pct)
from harry.data import SOCIAL_CLASSES, ACTIVITY_TO_POSTURE, SUB_TO_SOCIAL, load_signal  # noqa: E402

CACHE = HERE / "results/official_folds/cache"
PAT = re.compile(r"PDIOT_[^_]+_([A-Za-z]+)_([A-Za-z]+)_.*\.csv", re.I)


def train(power, out):
    dst = out / "models" / f"social_jan_w{power:g}.keras"
    if dst.exists():
        return str(dst)
    with open(out / f"train_w{power:g}.log", "w", buffering=1) as log, contextlib.redirect_stdout(log), \
            contextlib.redirect_stderr(log):
        import keras
        from harry.zoo import build
        from harry.runner import RECIPES, _fit
        from harry import layers as _l, augment as _a  # noqa: F401
        sig, meta = load_set(CACHE, "social")
        rec = dict(RECIPES[("harry", "jan")], balance_power=power)
        X, rid = windows(sig, np.arange(len(sig)), W["social"], rec["step"])
        y = meta.y.to_numpy()[rid]
        print(f"harry_rnn on all {len(sig)} listed Jan2026 social recordings: {X.shape}, recipe {rec}")
        keras.utils.set_random_seed(0)
        core = build("harry_rnn", "social", len(SOCIAL_CLASSES), X)
        _fit(core, X, y, len(SOCIAL_CLASSES), rec, {}, [], "social", {"seed_base": 0}, log)
        dst.parent.mkdir(parents=True, exist_ok=True)
        core.save(dst)
    return str(dst)


def person_windows(folder):
    X, y, posture = [], [], []
    for p in sorted(Path(folder).glob("*.csv")):
        act, sub = (s.lower() for s in PAT.fullmatch(p.name).groups())
        if act not in ACTIVITY_TO_POSTURE:
            continue                                   # moving recordings have no social label
        x = load_signal(p)
        ends = np.arange(W["social"], len(x) + 1, APP_STEP)
        X.append(np.stack([x[e - W["social"]:e] for e in ends]))
        y += [SOCIAL_CLASSES.index(SUB_TO_SOCIAL[sub])] * len(ends)
        posture += [ACTIVITY_TO_POSTURE[act]] * len(ends)
    return np.concatenate(X), np.array(y), np.array(posture)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--powers", type=float, nargs="+", default=[1.0, 0.6])
    ap.add_argument("--people", nargs="+", default=[str(HERE.parent / "data/s2503795"), str(HERE.parent / "data/s2952925")])
    ap.add_argument("--out", default=str(HERE / "results/real_people"))
    a = ap.parse_args()
    out = Path(a.out); (out / "models").mkdir(parents=True, exist_ok=True)
    log = lambda m: print(time.strftime("%H:%M:%S"), m, flush=True)            # noqa: E731
    if not (CACHE / "social.npz").exists():
        sys.exit(f"missing {CACHE}: run eval_official_folds.py first (it builds the Jan2026 cache)")

    threads = max(1, (os.cpu_count() or 8) // len(a.powers))
    log(f"training {len(a.powers)} model(s) on all Jan2026, {threads} threads each (~12-15 min)")
    with ProcessPoolExecutor(len(a.powers), initializer=init_worker, initargs=(threads,)) as ex:
        paths = dict(zip(a.powers, ex.map(train, a.powers, [out] * len(a.powers))))
    log("trained; testing on " + ", ".join(Path(p).name for p in a.people))

    init_worker(os.cpu_count() or 8)
    import keras
    import tensorflow as tf
    from harry import layers as _l, augment as _a  # noqa: F401
    har = tf.lite.Interpreter(model_path=str(TFLITE["har"]))

    def har_predict(X):
        i, o = har.get_input_details()[0], har.get_output_details()[0]
        har.resize_tensor_input(i["index"], list(X.shape)); har.allocate_tensors()
        har.set_tensor(i["index"], X.astype(np.float32)); har.invoke()
        return har.get_tensor(o["index"]).argmax(1)

    models = {p: keras.models.load_model(path, compile=False) for p, path in paths.items()}
    res, L = {}, []
    L += ["# Social recipe on real people (unseen by training)", "",
          f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `model_harry/eval_real_people.py`. All numbers are %.",
          "Each model: harry_rnn trained on **all listed datasetJan2026 social recordings** (Jan recipe, 32 epochs), "
          "class weights balanced^power. Test: each person's stationary recordings, a result every 12 samples "
          "(as the app), no smoothing. Gate = social only when the app's HAR model says not moving "
          "(that HAR model was fine-tuned on s2503795, so the gate is optimistic for s2503795).", "",
          "| person | postures | weights | " + " | ".join(SOCIAL_CLASSES) + " | BALANCED | MIN | gated BALANCED |",
          "|---" * (len(SOCIAL_CLASSES) + 6) + "|"]
    for folder in a.people:
        name = Path(folder).name
        X, y, posture = person_windows(folder)
        gate = har_predict(X[:, -W["har"]:])
        for pw, m in models.items():
            pred = m.predict(X, batch_size=4096, verbose=0).argmax(1)
            for group, mask in [("all stationary", np.ones(len(y), bool)),
                                ("sitting/standing", np.isin(posture, ["sitting", "standing"])),
                                ("lying", ~np.isin(posture, ["sitting", "standing"]))]:
                t = gated_tables(y[mask], pred[mask], gate[mask])
                s, g = social_summary(t["ungated"]), social_summary(t["static_e2e"])
                res[f"{name}|{group}|{pw:g}"] = {"ungated": s, "gated_not_moving": g}
                L.append(f"| {name} | {group} | balanced^{pw:g} | " + " | ".join(pct(s[c]) for c in SOCIAL_CLASSES)
                         + f" | **{pct(s['BALANCED'])}** | {pct(s['MIN'])} | {pct(g['BALANCED'])} |")
        log(f"{name}: {len(y)} social windows")
    (out / "report.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    (out / "summary.json").write_text(json.dumps(res, indent=1, default=float), encoding="utf-8")
    log(f"report: {out / 'report.md'}")


if __name__ == "__main__":
    main()
