"""Worker side: execute one job (train -> per-epoch monitoring -> evaluation) and write its JSON.

Recipes (fixed before results, PLAN.md G1.6 / G4.2; mirrors Lab 3: fixed epochs in CV, never early-stop
on a test fold — the per-epoch "monitor" curves are for plotting only and drive no decision):
  hers on any data   Adam 1e-3, sparse CE, batch 64, 32 epochs, train step 25            (her B9 recipe)
  mine on real data  AdamW cosine 2e-3, wd 1e-4, label smoothing .1, balanced weights, in-graph
                     augmentation, batch 64, 60 epochs, train step 6 (dense windows for tiny data)
  mine on Jan data   same, but 32 epochs / train step 25 (compute budget matched to hers)
  fine-tune (E)      hers: Adam 1e-4, 15 epochs, step 25 · mine: AdamW cosine 5e-4, 30 epochs, step 6
"""
import contextlib
import io
import json
import os
import pickle
import sys
import time
import traceback
from pathlib import Path

import numpy as np

from . import datasets as ds
from .data import HAR_CLASSES, SOCIAL_CLASSES
from .metrics import per_class_recall, summarise, recording_vote
from .zoo import ZOO

RECIPES = {
    ("teammate", "real"): dict(opt="adam", lr=1e-3, epochs=32, step=25, batch=64),
    ("teammate", "jan"): dict(opt="adam", lr=1e-3, epochs=32, step=25, batch=64),
    ("teammate", "finetune"): dict(opt="adam", lr=1e-4, epochs=15, step=25, batch=64),
    ("harry", "real"): dict(opt="adamw", lr=2e-3, epochs=60, step=6, batch=64, wd=1e-4, smooth=0.1, aug=True, balance=True),
    ("harry", "jan"): dict(opt="adamw", lr=2e-3, epochs=32, step=25, batch=64, wd=1e-4, smooth=0.1, aug=True, balance=True),
    ("harry", "finetune"): dict(opt="adamw", lr=5e-4, epochs=30, step=6, batch=64, wd=1e-4, smooth=0.1, aug=True, balance=True),
    ("sklearn", "real"): dict(step=25), ("sklearn", "jan"): dict(step=25), ("sklearn", "finetune"): dict(step=25),
}
EVAL_STEP = {"real": 12, "jan": 25}
ROT = (15, 30)


def recipe_for(spec, regime, settings):
    if regime == "none":                                   # EXPORT of the Jan-only model: no further training
        return dict(step=25, epochs=0)
    r = dict(RECIPES[(spec.recipe, regime)])
    if "epochs" in r and settings.get("epoch_scale") not in (None, 1):
        r["epochs"] = max(2, int(round(r["epochs"] * settings["epoch_scale"])))
    if "epochs" in r and settings.get("max_epochs"):
        r["epochs"] = min(r["epochs"], settings["max_epochs"])
    return r


def _rot_y(X, deg):
    t = np.deg2rad(deg); c, s = np.cos(t), np.sin(t)
    R = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]], np.float32)
    return (X @ R.T).astype(np.float32)


def _metrics(task, y, prob, rid, n):
    p = prob.argmax(1)
    rec, cm = per_class_recall(y, p, n)
    from sklearn.metrics import f1_score
    out = summarise(task, rec)
    out.update(window_acc=float((p == y).mean()), macro_f1=float(f1_score(y, p, labels=range(n), average="macro", zero_division=0)),
               recording_vote_acc=recording_vote(y, p, rid), n_windows=int(len(y)), confusion=cm.tolist())
    return out


def _score_only(task, y, prob, n):
    return summarise(task, per_class_recall(y, prob.argmax(1), n)[0])["SCORE"]


# ───────────────────────── her B2 feature classifier (sklearn)
def her_features(X):
    mag = np.linalg.norm(X, axis=2, keepdims=True)
    sig = np.concatenate([X, mag], 2)
    f = [sig.mean(1), sig.std(1), sig.min(1), sig.max(1), (sig ** 2).mean(1), np.ptp(sig, 1),
         np.abs(np.diff(sig, axis=1)).mean(1)]
    return np.concatenate(f, 1)


class _SkModel:
    def __init__(self, seed, n):
        self.n = n
        from sklearn.linear_model import LogisticRegression
        from sklearn.pipeline import make_pipeline
        from sklearn.preprocessing import StandardScaler
        self.m = make_pipeline(StandardScaler(), LogisticRegression(max_iter=1000, random_state=seed))

    def fit(self, X, y):
        self.m.fit(her_features(X), y); return self

    def predict(self, X, **_):
        P = np.zeros((len(X), self.n), np.float32)
        P[:, self.m.classes_] = self.m.predict_proba(her_features(X))
        return P


# ───────────────────────── main entry
def execute(job, settings):
    """Run one job in a worker process. Never raises: failures are written into the result JSON."""
    out_dir = Path(settings["out_dir"]) / "jobs"
    out_dir.mkdir(parents=True, exist_ok=True)
    res_path, log_path = out_dir / f"{job['id']}.json", out_dir / f"{job['id']}.log"
    t0 = time.time()
    with open(log_path, "w", buffering=1, encoding="utf-8") as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        try:
            res = _execute(job, settings, log)
            res["status"] = "ok"
        except Exception:                                   # noqa: BLE001
            res = {"status": "failed", "error": traceback.format_exc()}
            print(res["error"])
    res.update({k: job[k] for k in ("id", "scenario", "task", "model", "group", "owner", "fold", "seed", "regime")})
    res["train_on"] = job.get("train_on")
    res["seconds"] = round(time.time() - t0, 1)
    res_path.write_text(json.dumps(res), encoding="utf-8")
    return {k: res.get(k) for k in ("id", "status", "seconds", "scenario", "task", "model", "fold")} | {
        "score": next((v["SCORE"] for k, v in res.get("evals", {}).items() if not k.startswith("monitor")), None)}


def _execute(job, settings, log):
    import keras
    from .zoo import build
    from . import layers as _l, augment as _a                  # noqa: F401  (register custom objects)

    task, spec = job["task"], ZOO[job["model"]]
    classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
    n, W = len(classes), spec.windows[task]
    if job["regime"] == "deploy":
        return _deploy(job, spec, task, n, W, settings)
    rec = recipe_for(spec, job["regime"], settings)
    keras.utils.set_random_seed(int(job["seed_int"]))
    Xtr, ytr, _ = ds.windows(job["train"], W, rec["step"])
    if "also" in job["train"]:                             # sklearn EXPORT: one fit on real + Jan
        Xa, ya, _ = ds.windows(job["train"]["also"], W, rec["step"])
        Xtr, ytr = np.concatenate([Xtr, Xa]), np.concatenate([ytr, ya])
    sets = {}
    for lab, sel in job["evals"].items():
        step = EVAL_STEP["jan" if sel["set"].startswith("jan") else "real"]
        sets[lab] = ds.windows(sel, W, step)
    print(f"[{job['id']}] train windows {Xtr.shape} · " + " · ".join(f"{k}: {v[0].shape[0]}" for k, v in sets.items()))
    print(f"recipe: {rec}")
    history, model = [], None

    if spec.kind == "sklearn":
        t = time.time()
        model = _SkModel(int(job["seed_int"]), n).fit(Xtr, ytr)
        row = {"epoch": 1, "train_acc": float((model.predict(Xtr).argmax(1) == ytr).mean()), "seconds": round(time.time() - t, 2)}
        for lab in job["monitors"]:
            X, y, _ = sets[lab]; P = model.predict(X)
            row[f"{lab}/acc"] = float((P.argmax(1) == y).mean()); row[f"{lab}/score"] = _score_only(task, y, P, n)
        history.append(row)
        params = int(sum(getattr(s, "size", 0) for s in [model.m[-1].coef_, model.m[-1].intercept_]))
    else:
        if job.get("depends"):
            core = keras.models.load_model(Path(settings["out_dir"]) / "models" / f"{job['depends']}.keras", compile=False)
        else:
            core = build(job["model"], task, n, Xtr)
        params = int(core.count_params())
        history = _fit(core, Xtr, ytr, n, rec, sets, job["monitors"], task, settings, log) if rec.get("epochs") else []
        model = core
        if job.get("save_model"):
            mdir = Path(settings["out_dir"]) / "models"; mdir.mkdir(parents=True, exist_ok=True)
            core.save(mdir / f"{job['id']}.keras")

    evals = {}
    for lab, (X, y, rid) in sets.items():
        if not len(y):
            continue
        P = model.predict(X, batch_size=4096, verbose=0)
        evals[lab] = _metrics(task, y, P, rid, n)
        evals[lab]["rotation_score"] = {str(d): _score_only(task, y, model.predict(_rot_y(X, d), batch_size=4096, verbose=0), n)
                                        for d in ROT}
    out = {"history": history, "evals": evals, "params": params, "window": W, "recipe": rec,
           "n_train_windows": int(len(ytr))}
    if job["scenario"] == "EXPORT":
        out["export"] = _export_final(job, spec, task, classes, n, W, model, Xtr, settings)
    if spec.kind != "sklearn":
        keras.backend.clear_session()
    return out


def _fit(core, X, y, n, rec, sets, monitors, task, settings, log):
    import keras
    from .augment import RandomAugment

    class EpochLog(keras.callbacks.Callback):
        def __init__(self):
            super().__init__(); self.rows, self.t = [], time.time()

        def on_epoch_end(self, epoch, logs=None):
            row = {"epoch": epoch + 1, "train_loss": float(logs.get("loss", np.nan)),
                   "train_acc": float(logs.get("accuracy", np.nan))}
            for lab in monitors:
                Xm, ym, _ = sets[lab]
                if not len(ym):
                    continue
                P = core.predict(Xm, batch_size=4096, verbose=0)
                row[f"{lab}/loss"] = float(-np.mean(np.log(np.clip(P[np.arange(len(ym)), ym], 1e-7, 1))))
                row[f"{lab}/acc"] = float((P.argmax(1) == ym).mean())
                row[f"{lab}/score"] = _score_only(task, ym, P, n)
            row["seconds"] = round(time.time() - self.t, 2); self.t = time.time()
            self.rows.append(row)
            print("epoch {:3d} | ".format(row["epoch"]) + " | ".join(
                f"{k} {v:.4f}" for k, v in row.items() if k not in ("epoch", "seconds")) + f" | {row['seconds']}s", flush=True)

    cb = EpochLog()
    steps = int(np.ceil(len(X) / rec["batch"])) * rec["epochs"]
    if rec["opt"] == "adam":
        core.compile(optimizer=keras.optimizers.Adam(rec["lr"]), loss="sparse_categorical_crossentropy", metrics=["accuracy"])
        core.fit(X, y, epochs=rec["epochs"], batch_size=rec["batch"], shuffle=True, verbose=0, callbacks=[cb])
        return cb.rows
    inp = keras.Input(shape=core.input_shape[1:])
    train_model = keras.Model(inp, core(RandomAugment(seed=int(settings.get("seed_base", 0)))(inp)))
    sched = keras.optimizers.schedules.CosineDecay(rec["lr"], decay_steps=max(1, steps), alpha=0.05)
    train_model.compile(optimizer=keras.optimizers.AdamW(sched, weight_decay=rec["wd"]),
                        loss=keras.losses.CategoricalCrossentropy(label_smoothing=rec["smooth"]), metrics=["accuracy"])
    cnt = np.bincount(y, minlength=n).astype(float)
    sw = (len(y) / (n * np.maximum(cnt, 1)))[y].astype(np.float32) if rec.get("balance") else None
    train_model.fit(X, keras.utils.to_categorical(y, n), sample_weight=sw, epochs=rec["epochs"],
                    batch_size=rec["batch"], shuffle=True, verbose=0, callbacks=[cb])
    return cb.rows


def _deploy(job, spec, task, n, W, settings):
    """TFLite deployability: size, builtin-ops-only conversion, batch-1 latency (weights are untrained)."""
    X, y, _ = ds.windows(job["train"], W, 25)
    if spec.kind == "sklearn":
        m = _SkModel(0, n).fit(X, y)
        t = time.perf_counter()
        for w in X[:200]:
            m.predict(w[None])
        return {"evals": {}, "deploy": {"tflite": False, "size_kb": round(len(pickle.dumps(m.m)) / 1024, 1),
                                        "ms_per_window": round((time.perf_counter() - t) / 200 * 1000, 3),
                                        "note": "not TFLite: needs features + classifier re-implemented in Dart (m2cgen)"},
                "params": int(m.m[-1].coef_.size + m.m[-1].intercept_.size), "window": W, "history": []}
    import tensorflow as tf
    from .zoo import build
    from .export import TFLiteRunner
    model = build(job["model"], task, n, X, for_export=True)
    conv = tf.lite.TFLiteConverter.from_keras_model(model)
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
    with contextlib.redirect_stdout(io.StringIO()):
        blob = conv.convert()
    tmp = Path(settings["out_dir"]) / "deploy"; tmp.mkdir(parents=True, exist_ok=True)
    path = tmp / f"{job['task']}_{job['model']}.tflite"; path.write_bytes(blob)
    r = TFLiteRunner(path)
    r.it.resize_tensor_input(r.inp["index"], [1, W, 3]); r.it.allocate_tensors()
    for w in X[:20]:
        r.it.set_tensor(r.inp["index"], w[None]); r.it.invoke()
    t = time.perf_counter()
    for w in X[:300]:
        r.it.set_tensor(r.inp["index"], w[None]); r.it.invoke()
    ms = (time.perf_counter() - t) / min(300, len(X)) * 1000
    pk, pt = model.predict(X[:64], verbose=0), r.predict(X[:64])
    return {"evals": {}, "history": [], "params": int(model.count_params()), "window": W,
            "deploy": {"tflite": True, "builtin_ops_only": True, "size_kb": round(len(blob) / 1024, 1),
                       "ms_per_window": round(ms, 4), "max_abs_dprob_vs_keras": float(np.abs(pk - pt).max())}}


def _export_final(job, spec, task, classes, n, W, model, Xtr, settings):
    """Write the final deployable model to <export_dir>/<task>/: .tflite + _meta.json + _example.json (+ .keras)."""
    from .export import export
    out = Path(settings["export_dir"]) / task / spec.group              # e.g. models/har/CNN/harry_cnn.tflite
    out.mkdir(parents=True, exist_ok=True)
    Xc, yc, _ = ds.windows({"set": f"real_{task}"}, W, 25)           # example/parity windows = real recordings
    trained_on = {"jan+real": "datasetJan2026 (pre-train) + all IoT/data real recordings (fine-tune)",
                  "real": "all IoT/data real recordings", "jan": "all datasetJan2026"}[job["train_on"]]
    meta = {"trained_on": trained_on, "architecture": spec.model_id, "group": spec.group, "owner": spec.owner,
            "notes": spec.notes, "recipe": job["regime"], "exported": time.strftime("%Y-%m-%d %H:%M")}
    if spec.kind == "sklearn":
        (out / f"{spec.model_id}.pkl").write_bytes(pickle.dumps(model.m))
        P = model.predict(Xc[:1])
        (out / f"{spec.model_id}_meta.json").write_text(json.dumps(
            {"model_file": f"{spec.model_id}.pkl", "task": "daily_activity" if task == "har" else "social_signal",
             "window_samples": W, "step_samples": 25, "classes": list(classes), "tflite": False,
             "features": "mean,std,min,max,energy,range,mean|diff| of x,y,z,|a| (28) -> StandardScaler -> LogReg",
             **meta}, indent=2), encoding="utf-8")
        return {"file": f"{spec.model_id}.pkl", "tflite": False, "size_kb": round((out / f"{spec.model_id}.pkl").stat().st_size / 1024, 1),
                "example_class": classes[int(P[0].argmax())]}
    from .zoo import build
    final = model
    if spec.group == "RNN":                                          # unrolled copy -> builtin TFLite ops only
        final = build(spec.model_id, task, n, Xtr[:512], for_export=True)
        final.set_weights(model.get_weights())
    model.save(out / f"{spec.model_id}.keras")
    info = export(final, spec.model_id, out, W, 25, classes, "daily_activity" if task == "har" else "social_signal",
                  Xc, yc, extra_meta=meta)
    acc = float((final.predict(Xc, batch_size=4096, verbose=0).argmax(1) == yc).mean())
    return info | {"tflite": True, "fit_acc_on_real_training_data": acc}
