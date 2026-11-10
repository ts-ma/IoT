"""Official-fold evaluation of the recommended models, with the "social only when stationary" gate.

Part 1 – how CW3 marks the models (data/fold_assignments/*.csv, subject-wise 10-fold CV on datasetJan2026)
  For every fold k: train the architecture from scratch on the listed recordings with fold != k and test on
  fold k (Harry's Jan recipe: AdamW cosine, 32 epochs, train step 25; test step 25, as in the pipeline's D).
    har     harry_cnn on daily_activity                        -> graded HAR score
    social  harry_rnn on social_signal                          -> graded social score (no gate)
    gate    harry_cnn again, but without any daily_activity file that is a byte-copy of a social fold-k test
            file (809 static HAR files are copies of social files filed under a different fold, so the
            official HAR model has already seen many social test recordings). It runs on the last 50 samples
            (4 s) of every social test window, exactly what the app's latest HAR result covers.
  Gate rule (professor's feedback): social is only shown while the wearer is stationary.
    static   social enabled when HAR says sittingStanding or one of the lying classes
    sit      social enabled only when HAR says sittingStanding
  A disabled window counts as a miss for its social class ("end-to-end" recall). "When shown" is the recall
  among enabled windows only. "False enable" = dynamic HAR test windows that HAR calls static, i.e. moments
  where the app would wrongly run social while the wearer moves.
  Recordings on disk but not in the fold CSV are left out of training and testing, as in the marking.

Part 2 – the exported .tflite files on a person they never saw (default data/s2952925)
  Streams each recording like the app (result every 12 samples, HAR on the last 50, social on the last 100)
  and applies the same gates. Posture comes from the file name, so sitting/standing can be scored separately.

Results: <out>/report.md, <out>/summary.json, per-fold predictions in <out>/folds/. Re-running resumes.
"""
import argparse
import contextlib
import hashlib
import json
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

from harry.data import (HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC, ACTIVITY_TO_HAR,  # noqa: E402
                        ACTIVITY_TO_POSTURE, SUB_TO_SOCIAL, load_signal, make_windows)

HAR_MODEL, SOC_MODEL = "harry_cnn", "harry_rnn"
W = {"har": 50, "social": 100}
TEST_STEP = 25
APP_STEP = 12
SIT = HAR_CLASSES.index("sittingStanding")
STATIC_IDX = np.array([HAR_CLASSES.index(c) for c in STATIC])
DYN_IDX = np.array([HAR_CLASSES.index(c) for c in DYNAMIC])
TASK_DIR = {"har": "daily_activity", "social": "social_signal"}
FOLD_CSV = {"har": "folds_daily_activity.csv", "social": "folds_social_signal.csv"}
TFLITE = {"har": HERE / "models/recommended/har/harry_cnn.tflite",
          "social": HERE / "models/social/RNN/harry_rnn.tflite"}


# ───────────────────────── data cache (main process)
def build_cache(out, jan_dir, fold_dir, log):
    cache = out / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    for task in ("har", "social"):
        if (cache / f"{task}.npz").exists():
            continue
        classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
        folds = pd.read_csv(fold_dir / FOLD_CSV[task])
        folds = folds[folds.activity.isin(classes)]
        rows, sig = [], []
        for r in folds.itertuples():
            p = jan_dir / TASK_DIR[task] / r.activity / r.file
            rows.append({"activity": r.activity, "file": r.file, "fold": int(r.fold),
                         "y": classes.index(r.activity), "md5": hashlib.md5(p.read_bytes()).hexdigest()})
            sig.append(load_signal(p))
        lens = np.array([len(s) for s in sig])
        np.savez_compressed(cache / f"{task}.npz", data=np.concatenate(sig), offsets=np.r_[0, np.cumsum(lens)])
        pd.DataFrame(rows).to_csv(cache / f"{task}_meta.csv", index=False)
        on_disk = sum(1 for _ in (jan_dir / TASK_DIR[task]).glob("*/*.csv"))
        log(f"cached {task}: {len(rows)} recordings from the fold CSV ({on_disk - len(rows)} on disk not listed -> unused)")


def load_set(cache, task):
    z = np.load(cache / f"{task}.npz")
    meta = pd.read_csv(cache / f"{task}_meta.csv")
    d, o = z["data"], z["offsets"]
    return [d[o[i]:o[i + 1]] for i in range(len(o) - 1)], meta


def windows(sig, idx, window, step):
    X, rid = [], []
    for i in idx:
        w = make_windows(sig[i], window, step)
        if len(w):
            X.append(w); rid += [i] * len(w)
    return np.concatenate(X), np.array(rid)


# ───────────────────────── one training job (worker process)
def init_worker(threads):
    os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
    for k in ("OMP_NUM_THREADS", "TF_NUM_INTRAOP_THREADS"):
        os.environ[k] = str(threads)
    import warnings
    warnings.filterwarnings("ignore")
    import tensorflow as tf
    tf.get_logger().setLevel("ERROR")
    with contextlib.suppress(RuntimeError):
        tf.config.threading.set_intra_op_parallelism_threads(threads)
        tf.config.threading.set_inter_op_parallelism_threads(2)


def run_job(job, out, epochs, subsample, social_power=1.0):
    """job = (kind, fold); kind in har | gate | social. Writes <out>/folds/<kind>_<fold>.npz."""
    kind, k = job
    dst = out / "folds" / f"{kind}_{k}.npz"
    log_path = out / "folds" / f"{kind}_{k}.log"
    t0 = time.time()
    with open(log_path, "w", buffering=1) as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        import keras
        from harry.zoo import build
        from harry.runner import RECIPES, _fit
        from harry import layers as _l, augment as _a  # noqa: F401  (register custom layers)

        task = "social" if kind == "social" else "har"
        model_id = SOC_MODEL if task == "social" else HAR_MODEL
        n = len(SOCIAL_CLASSES if task == "social" else HAR_CLASSES)
        sig, meta = load_set(out / "cache", task)
        train = np.flatnonzero(meta.fold.to_numpy() != k)
        if kind == "gate":                     # drop HAR copies of social fold-k test recordings
            ssig, smeta = load_set(out / "cache", "social")
            test_md5 = set(smeta.md5[smeta.fold == k])
            dropped = int(meta.md5.iloc[train].isin(test_md5).sum())
            train = train[~meta.md5.iloc[train].isin(test_md5).to_numpy()]
            print(f"gate fold {k}: dropped {dropped} HAR training files that are copies of social test files")
        if subsample > 1:
            train = train[::subsample]
        rec = dict(RECIPES[("harry", "jan")])
        if epochs:
            rec["epochs"] = epochs
        if task == "social":
            rec["balance_power"] = social_power
        Xtr, rtr = windows(sig, train, W[task], rec["step"])
        ytr = meta.y.to_numpy()[rtr]
        print(f"[{kind} fold {k}] {model_id}: train {Xtr.shape}, recipe {rec}")
        keras.utils.set_random_seed(1000 + k)
        core = build(model_id, task, n, Xtr)
        hist = _fit(core, Xtr, ytr, n, rec, {}, [], task, {"seed_base": k}, log)

        res = {"seconds_train": time.time() - t0, "n_train_windows": len(ytr), "epochs": rec["epochs"],
               "history": json.dumps(hist)}
        if kind == "gate":                     # HAR on the last 4 s of each social fold-k test window
            ssig, smeta = load_set(out / "cache", "social")
            test = np.flatnonzero(smeta.fold.to_numpy() == k)
            if subsample > 1:
                test = test[::subsample]
            Xs, rid = windows(ssig, test, W["social"], TEST_STEP)
            res["P"] = core.predict(Xs[:, -W["har"]:], batch_size=4096, verbose=0)
            res["rid"] = rid
        else:
            test = np.flatnonzero(meta.fold.to_numpy() == k)
            if subsample > 1:
                test = test[::subsample]
            X, rid = windows(sig, test, W[task], TEST_STEP)
            res["P"] = core.predict(X, batch_size=4096, verbose=0)
            res["rid"], res["y"] = rid, meta.y.to_numpy()[rid]
        res["seconds"] = time.time() - t0
        np.savez_compressed(dst, **res)
        print(f"done in {res['seconds']:.0f}s")
    return kind, k, time.time() - t0


# ───────────────────────── metrics
def recall(y, p, n):
    return np.array([(p[y == c] == c).mean() if (y == c).any() else np.nan for c in range(n)])


def har_summary(r):
    d = dict(zip(HAR_CLASSES, r))
    d["STATIC"] = float(np.nanmean(r[:5])); d["DYNAMIC"] = float(np.nanmean(r[5:]))
    return d


def social_summary(r):
    d = dict(zip(SOCIAL_CLASSES, r))
    d["BALANCED"] = float(np.nanmean(r)); d["MIN"] = float(np.nanmin(r))
    return d


def gated_tables(y, ps, ph):
    """Per social class: recall without gate, end-to-end with each gate, pass rate, recall when shown."""
    n = len(SOCIAL_CLASSES)
    ok = ps == y
    gates = {"static": np.isin(ph, STATIC_IDX), "sit": ph == SIT}
    out = {"ungated": recall(y, ps, n)}
    for g, on in gates.items():
        out[f"{g}_e2e"] = np.array([(ok & on)[y == c].mean() for c in range(n)])
        out[f"{g}_pass"] = np.array([on[y == c].mean() for c in range(n)])
        out[f"{g}_shown"] = np.array([ok[(y == c) & on].mean() if ((y == c) & on).any() else np.nan for c in range(n)])
    return out


# ───────────────────────── Part 1 aggregate
def aggregate(out, folds):
    res = {"folds": [], "har": {}, "social": {}}
    _, hmeta = load_set(out / "cache", "har")
    rows = []
    for k in folds:
        h = np.load(out / "folds" / f"har_{k}.npz")
        s = np.load(out / "folds" / f"social_{k}.npz")
        g = np.load(out / "folds" / f"gate_{k}.npz")
        assert np.array_equal(s["rid"], g["rid"]), "gate and social windows differ"
        hp, sp, gp = h["P"].argmax(1), s["P"].argmax(1), g["P"].argmax(1)
        hr = recall(h["y"], hp, len(HAR_CLASSES))
        gt = gated_tables(s["y"], sp, gp)
        dyn = np.isin(h["y"], DYN_IDX)
        false_static = np.array([np.isin(hp[h["y"] == c], STATIC_IDX).mean() for c in DYN_IDX])
        rows.append({"fold": k, "har": hr, "social": gt, "false_enable": false_static,
                     "false_enable_all": float(np.isin(hp[dyn], STATIC_IDX).mean()),
                     "pooled": (h["y"], hp, s["y"], sp, gp),
                     "seconds": float(h["seconds"] + s["seconds"] + g["seconds"])})
    fm = lambda key: np.nanmean([r[key] for r in rows], 0)                          # noqa: E731
    fms = lambda key: np.nanmean([r["social"][key] for r in rows], 0)                 # noqa: E731
    hy = np.concatenate([r["pooled"][0] for r in rows]); hp = np.concatenate([r["pooled"][1] for r in rows])
    sy = np.concatenate([r["pooled"][2] for r in rows]); sp = np.concatenate([r["pooled"][3] for r in rows])
    gp = np.concatenate([r["pooled"][4] for r in rows])
    res["har"] = {"fold_mean": har_summary(fm("har")), "pooled": har_summary(recall(hy, hp, len(HAR_CLASSES))),
                  "per_fold": [har_summary(r["har"]) for r in rows],
                  "false_enable": dict(zip(DYNAMIC, fm("false_enable"))),
                  "false_enable_all": float(np.mean([r["false_enable_all"] for r in rows]))}
    keys = rows[0]["social"].keys()
    res["social"] = {"fold_mean": {k: social_summary(fms(k)) for k in keys},
                     "pooled": {k: social_summary(v) for k, v in gated_tables(sy, sp, gp).items()},
                     "per_fold": [social_summary(r["social"]["ungated"]) for r in rows]}
    res["folds"] = folds
    res["hours"] = sum(r["seconds"] for r in rows) / 3600
    cm_h = pd.crosstab(pd.Series([HAR_CLASSES[i] for i in hy], name="true"),
                       pd.Series([HAR_CLASSES[i] for i in hp], name="pred")).reindex(index=HAR_CLASSES, columns=HAR_CLASSES, fill_value=0)
    cm_s = pd.crosstab(pd.Series([SOCIAL_CLASSES[i] for i in sy], name="true"),
                       pd.Series([SOCIAL_CLASSES[i] for i in sp], name="pred")).reindex(index=SOCIAL_CLASSES, columns=SOCIAL_CLASSES, fill_value=0)
    return res, cm_h, cm_s


# ───────────────────────── Part 2: exported models on an unseen person
def unseen(person_dir, log):
    import tensorflow as tf
    import re
    it = {}
    for t, p in TFLITE.items():
        i = tf.lite.Interpreter(model_path=str(p)); i.allocate_tensors(); it[t] = i

    def predict(t, X):
        i = it[t]; inp, o = i.get_input_details()[0], i.get_output_details()[0]
        i.resize_tensor_input(inp["index"], list(X.shape)); i.allocate_tensors()
        i.set_tensor(inp["index"], X.astype(np.float32)); i.invoke()
        return i.get_tensor(o["index"])

    pat = re.compile(r"PDIOT_[^_]+_([A-Za-z]+)_([A-Za-z]+)_.*\.csv", re.I)
    H, S = [], []
    for p in sorted(Path(person_dir).glob("*.csv")):
        m = pat.fullmatch(p.name)
        act, sub = m.group(1).lower(), m.group(2).lower()
        x = load_signal(p)
        ends = np.arange(W["har"], len(x) + 1, APP_STEP)
        Xh = np.stack([x[e - W["har"]:e] for e in ends])
        ph = predict("har", Xh).argmax(1)
        hy = HAR_CLASSES.index(ACTIVITY_TO_HAR[act])
        H.append(pd.DataFrame({"y": hy, "p": ph, "file": p.name}))
        if act in ACTIVITY_TO_POSTURE:
            ends = np.arange(W["social"], len(x) + 1, APP_STEP)
            Xs = np.stack([x[e - W["social"]:e] for e in ends])
            S.append(pd.DataFrame({"y": SOCIAL_CLASSES.index(SUB_TO_SOCIAL[sub]), "p": predict("social", Xs).argmax(1),
                                   "gate": predict("har", Xs[:, -W["har"]:]).argmax(1),
                                   "posture": ACTIVITY_TO_POSTURE[act], "file": p.name}))
    H, S = pd.concat(H), pd.concat(S)
    hr = har_summary(recall(H.y.to_numpy(), H.p.to_numpy(), len(HAR_CLASSES)))
    dyn = H[H.y.isin(DYN_IDX)]
    fe = {DYNAMIC[j]: float(np.isin(dyn.p[dyn.y == c], STATIC_IDX).mean()) for j, c in enumerate(DYN_IDX)}
    out = {"person": Path(person_dir).name, "har": hr, "false_enable": fe,
           "false_enable_all": float(np.isin(dyn.p, STATIC_IDX).mean()), "social": {}}
    for name, sub in [("all stationary", S), ("sitting/standing", S[S.posture.isin(["sitting", "standing"])]),
                      ("lying", S[~S.posture.isin(["sitting", "standing"])])]:
        t = gated_tables(sub.y.to_numpy(), sub.p.to_numpy(), sub.gate.to_numpy())
        out["social"][name] = {k: social_summary(v) for k, v in t.items()}
    log(f"part 2 on {out['person']}: {H.file.nunique()} recordings, {len(H)} HAR and {len(S)} social results")
    return out


# ───────────────────────── report
def pct(v):
    return "–" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{100 * v:.1f}"


def social_rows(tbl, label):
    cols = SOCIAL_CLASSES + ["BALANCED", "MIN"]
    lines = []
    names = [("ungated", "no gate (graded number)"),
             ("static_e2e", "gate = not moving, end-to-end"), ("static_pass", "  …share of windows enabled"),
             ("static_shown", "  …recall when shown"),
             ("sit_e2e", "gate = sitting/standing only, end-to-end"), ("sit_pass", "  …share of windows enabled"),
             ("sit_shown", "  …recall when shown")]
    for k, nm in names:
        d = tbl[k]
        lines.append(f"| {label} | {nm} | " + " | ".join(pct(d[c]) for c in cols) + " |")
    return lines


def write_report(out, p1, cm_h, cm_s, p2, social_power=1.0):
    L = ["# Official-fold evaluation: HAR `harry_cnn`, Social `harry_rnn`", "",
         f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `model_harry/eval_official_folds.py`. All numbers are %.",
         "Targets (CW3): static ≥ 90, dynamic ≥ 85, every social class ≥ 75.",
         f"Social class weights: balanced^{social_power:g} (1 = fully balanced).", ""]
    if p1:
        res = p1
        h = res["har"]["fold_mean"]; hp = res["har"]["pooled"]
        L += ["## Part 1 – official 10-fold CV (how the models are marked)", "",
              f"Folds run: {res['folds']} · total compute {res['hours']:.1f} h. Each fold trains the architecture "
              "from scratch on the other folds. *Fold mean* = mean over folds of per-class recall (as Lab 3 B9); "
              "*pooled* = all test windows together.", "",
              "### HAR (harry_cnn)", "",
              "| | " + " | ".join(HAR_CLASSES) + " | STATIC | DYNAMIC |", "|---" * (len(HAR_CLASSES) + 3) + "|",
              "| fold mean | " + " | ".join(pct(h[c]) for c in HAR_CLASSES) + f" | **{pct(h['STATIC'])}** | **{pct(h['DYNAMIC'])}** |",
              "| pooled | " + " | ".join(pct(hp[c]) for c in HAR_CLASSES) + f" | {pct(hp['STATIC'])} | {pct(hp['DYNAMIC'])} |", "",
              "Per fold (static / dynamic): " + ", ".join(f"{k}: {pct(f['STATIC'])}/{pct(f['DYNAMIC'])}"
                                                         for k, f in zip(res["folds"], res["har"]["per_fold"])), "",
              "### Social (harry_rnn) and the stationary gate", "",
              "| | | " + " | ".join(SOCIAL_CLASSES) + " | BALANCED | MIN |", "|---" * (len(SOCIAL_CLASSES) + 4) + "|"]
        L += social_rows(res["social"]["fold_mean"], "fold mean")
        L += ["", "Per fold, no gate (balanced / weakest class): " + ", ".join(
            f"{k}: {pct(f['BALANCED'])}/{pct(f['MIN'])}" for k, f in zip(res["folds"], res["social"]["per_fold"])), "",
              "### Social would wrongly run while moving (HAR calls a dynamic window static)", "",
              "| " + " | ".join(DYNAMIC) + " | all dynamic |", "|---" * (len(DYNAMIC) + 1) + "|",
              "| " + " | ".join(pct(res["har"]["false_enable"][c]) for c in DYNAMIC) +
              f" | {pct(res['har']['false_enable_all'])} |", "",
              "### Confusion matrices (pooled windows)", "", "HAR:", "", "```", cm_h.to_string(), "```", "",
              "Social (no gate):", "", "```", cm_s.to_string(), "```", ""]
    if p2:
        L += [f"## Part 2 – exported models on an unseen person ({p2['person']})", "",
              "The `.tflite` files (trained on all of Jan2026 + Harry's recordings) streamed like the app: a result "
              f"every {APP_STEP} samples, raw (no smoothing).", "",
              "| " + " | ".join(HAR_CLASSES) + " | STATIC | DYNAMIC |", "|---" * (len(HAR_CLASSES) + 2) + "|",
              "| " + " | ".join(pct(p2["har"][c]) for c in HAR_CLASSES) +
              f" | **{pct(p2['har']['STATIC'])}** | **{pct(p2['har']['DYNAMIC'])}** |", "",
              f"Social would wrongly run while moving: {pct(p2['false_enable_all'])} of dynamic results (" +
              ", ".join(f"{c} {pct(v)}" for c, v in p2["false_enable"].items()) + ").", "",
              "| postures | | " + " | ".join(SOCIAL_CLASSES) + " | BALANCED | MIN |", "|---" * (len(SOCIAL_CLASSES) + 4) + "|"]
        for name, tbl in p2["social"].items():
            L += social_rows(tbl, name)
        L += [""]
    L += ["## How to read the gate rows", "",
          "- **no gate**: the social model alone on every social test window. This is what the marking scores.",
          "- **end-to-end**: what the user sees. A window where HAR says *moving* (or, for the strict gate, anything "
          "but sitting/standing) shows no social result and counts as a miss.",
          "- **share enabled**: how often the gate let social run. Social data is all stationary, so ideally 100 "
          "for the *not moving* gate. For the *sitting/standing* gate it is roughly the share of recordings made "
          "sitting or standing.",
          "- **recall when shown**: accuracy of the social results the user actually sees.", ""]
    (out / "report.md").write_text("\n".join(L), encoding="utf-8")


# ───────────────────────── main
def parse_folds(s):
    out = []
    for part in s.split(","):
        a, _, b = part.partition("-")
        out += list(range(int(a), int(b or a) + 1))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--folds", default="0-9", help="e.g. 0-9 or 0,3,5")
    ap.add_argument("--workers", type=int, default=2, help="parallel training processes")
    ap.add_argument("--threads", type=int, default=0, help="TF threads per worker (0 = cores / workers)")
    ap.add_argument("--epochs", type=int, default=0, help="override the 32-epoch recipe (smoke tests only)")
    ap.add_argument("--subsample", type=int, default=1, help="keep every k-th recording (smoke tests only)")
    ap.add_argument("--jan", default=str(ROOT / "data/datasetJan2026"))
    ap.add_argument("--fold-dir", default=str(ROOT / "data/fold_assignments"))
    ap.add_argument("--unseen", default=str(ROOT / "data/s2952925"), help="person folder for part 2 ('' = skip)")
    ap.add_argument("--skip-cv", action="store_true", help="only run part 2 (minutes)")
    ap.add_argument("--out", default=str(HERE / "results/official_folds"))
    ap.add_argument("--social-weight-power", type=float, default=1.0,
                    help="social class weights = balanced**power (1 = fully balanced, 0 = none)")
    ap.add_argument("--reuse", default="", help="earlier run folder: copy its har/gate results (only social retrains)")
    a = ap.parse_args()

    out = Path(a.out)
    (out / "folds").mkdir(parents=True, exist_ok=True)
    log = lambda m: print(time.strftime("%H:%M:%S"), m, flush=True)            # noqa: E731
    folds = parse_folds(a.folds)
    smoke = a.epochs or a.subsample > 1
    if smoke and out.name == "official_folds":
        out = out.with_name("official_folds_smoke"); (out / "folds").mkdir(parents=True, exist_ok=True)
        log(f"smoke settings -> writing to {out}")

    p1 = cm_h = cm_s = None
    if not a.skip_cv:
        if a.reuse:
            import shutil
            src = Path(a.reuse)
            if not (out / "cache").exists():
                shutil.copytree(src / "cache", out / "cache")
            for f in sorted((src / "folds").glob("*_*.*")):
                if f.name.startswith(("har_", "gate_")) and not (out / "folds" / f.name).exists():
                    shutil.copy2(f, out / "folds" / f.name)
            log(f"reused HAR and gate results from {src}")
        build_cache(out, Path(a.jan), Path(a.fold_dir), log)
        jobs = [(kind, k) for k in folds for kind in ("social", "gate", "har")
                if not (out / "folds" / f"{kind}_{k}.npz").exists()]
        threads = a.threads or max(1, (os.cpu_count() or 8) // a.workers)
        log(f"{len(jobs)} training jobs to run ({3 * len(folds) - len(jobs)} already done), "
            f"{a.workers} workers x {threads} threads. Logs: {out / 'folds'}/<job>.log")
        t0 = time.time()
        if jobs:
            with ProcessPoolExecutor(a.workers, initializer=init_worker, initargs=(threads,)) as ex:
                futs = [ex.submit(run_job, j, out, a.epochs, a.subsample, a.social_weight_power) for j in jobs]
                for i, f in enumerate(as_completed(futs), 1):
                    kind, k, sec = f.result()
                    el = time.time() - t0
                    log(f"[{i}/{len(jobs)}] {kind} fold {k} done in {sec / 60:.1f} min · "
                        f"elapsed {el / 60:.0f} min · est. left {el / i * (len(jobs) - i) / 60:.0f} min")
        p1, cm_h, cm_s = aggregate(out, folds)
    p2 = None
    if a.unseen:
        init_worker(os.cpu_count() or 8)
        p2 = unseen(a.unseen, log)
    write_report(out, p1, cm_h, cm_s, p2, a.social_weight_power)
    (out / "summary.json").write_text(json.dumps({"part1": p1, "part2": p2}, indent=1, default=lambda o: o.tolist()
                                                 if hasattr(o, "tolist") else str(o)), encoding="utf-8")
    log(f"report: {out / 'report.md'}")


if __name__ == "__main__":
    main()
