"""The v2 experiment plan (one job = train one model, test it, save everything) and the parallel job runner.

One way of using the data (see config.py): every fold k trains on datasetJan2026 folds != k plus the group members
whose fold is not k (mixed in; activities fall back to datasetJan2026-only training if the one check fails), and tests
on datasetJan2026 fold k plus the group member(s) assigned to fold k.

Job groups
  deploy    untrained build of each of Harry's architectures -> TFLite size, builtin-ops check, ms per window
  main      the deployed architecture per task: 3 seeds x 10 folds
  baseline  Harry's other three architectures per task: 1 seed x 10 folds (architecture comparison)
  sweep     social class-weight power sweep (deployed social architecture, 1 seed x 10 folds)
  final     the deployable models trained on everything (all datasetJan2026 + both members), exported

Every job writes jobs/<id>.json (settings, history, timing, status), jobs/<id>.npz (test probabilities, labels,
recording ids, source set and person of every test window) and jobs/<id>.log; kept models go to jobs/models/.
"""
import contextlib
import dataclasses
import json
import os
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, wait, FIRST_COMPLETED
from pathlib import Path

import numpy as np

from . import config as C

JOBS = C.OUT / "jobs"


# ───────────────────────── plan
def _cv_test(task, k, sub=None):
    sub = sub or {}
    return {"task": task, "window": C.W[task], "parts": [(f"jan_{task}", dict(sub, fold_eq=k), C.TEST_STEP),
                                                         ("real", {"fold_eq": k}, C.TEST_STEP)]}


def plan(smoke=False, only=None):
    """only: optional set of groups/tasks to plan, e.g. {"check"} = HAR main seed 0 (the one recipe check)."""
    sub = {"subsample": 25} if smoke else {}
    seeds = [0] if smoke else C.SEEDS
    folds = sorted({0, *C.PERSON_FOLD.values()}) if smoke else C.FOLDS      # smoke: include the members' folds
    jobs = []

    def J(**kw):
        kw.setdefault("seed", 0); kw.setdefault("fold", None); kw.setdefault("power", None)
        kw.setdefault("finetune", None); kw.setdefault("init_from", None); kw.setdefault("monitor", None)
        kw.setdefault("save_model", False); kw.setdefault("depends", []); kw.setdefault("person", None)
        kw.setdefault("export", False); kw.setdefault("variant", "all")
        jobs.append(kw)

    def train(task, k=None):
        if k is None:                                   # everything: all Jan2026 (listed + unlisted) + both members
            parts = [(f"jan_{task}", dict(sub), None), (f"janx_{task}", dict(sub), None)]
            return parts + [("real", {}, C.REAL_TRAIN_STEP)]
        parts = [(f"jan_{task}", dict(sub, fold_ne=k), None)]
        if C.recipe(task) == "mixed":
            parts.append(("real", {"fold_ne": k}, C.REAL_TRAIN_STEP))
        return parts

    def power(task):
        return C.SOCIAL_POWER if task == "social" else None

    def tag(task):
        return C.recipe(task) if task == "har" else f"{C.SOCIAL_CANDIDATE}"

    if only == {"check"}:
        for k in folds:
            J(id=f"main_har_{tag('har')}_s0_f{k}", group="main", task="har", model=C.FINAL["har"], fold=k,
              train=train("har", k), tests={"cv": _cv_test("har", k, sub)}, monitor="cv", save_model=True, prio=1)
        return _finish(jobs)

    for task in ("har", "social"):
        for m in C.ARCHS[task]:
            J(id=f"deploy_{task}_{m}_w{C.W[task]}", group="deploy", task=task, model=m, prio=0)
    for seed in seeds:
        for k in folds:
            for task in ("har", "social"):
                J(id=f"main_{task}_{tag(task)}_s{seed}_f{k}", group="main", task=task, model=C.FINAL[task], seed=seed,
                  fold=k, power=power(task), train=train(task, k), tests={"cv": _cv_test(task, k, sub)}, monitor="cv",
                  save_model=(seed == 0), prio=1 if seed == 0 else 5)
    for task in ("har", "social"):
        J(id=f"final_{task}_{tag(task)}", group="final", task=task, model=C.FINAL[task], power=power(task),
          train=train(task), tests={}, save_model=True, export=True, prio=3)
    for task in ("har", "social"):
        for m in C.ARCHS[task][1:]:
            for k in folds:
                J(id=f"base_{task}_{m}_{tag(task)}_f{k}", group="baseline", task=task, model=m, fold=k, power=power(task),
                  train=train(task, k), tests={"cv": _cv_test(task, k, sub)}, monitor="cv", prio=6)
    for pw in C.POWER_SWEEP:
        for k in folds:
            J(id=f"sweep_p{pw:g}_{tag('social')}_f{k}", group="sweep", task="social", model=C.FINAL["social"], fold=k,
              power=pw, train=train("social", k), tests={"cv": _cv_test("social", k, sub)}, monitor="cv", prio=7)
    if smoke:
        jobs = [j for j in jobs if j["group"] != "sweep" or j["power"] == 0.0]
        jobs = [j for j in jobs if j["group"] != "baseline" or j["model"] in ("harry_feat",)]
    return _finish(jobs)


def _finish(jobs):
    for j in jobs:
        j.setdefault("train", None)
    return sorted(jobs, key=lambda j: j["prio"])


def _recency(X, rng, p=0.5, kmin=38, kmax=75):
    """Recency training (social_window_study 'rec'): half of the windows get their first W-k samples replaced by
    another training window (gravity-aligned); the label stays that of the last k samples."""
    X = X.copy()
    W = X.shape[1]
    kmax = min(kmax, W - 5)
    for i in np.flatnonzero(rng.random(len(X)) < p):
        k = int(rng.integers(kmin, kmax + 1))
        j = int(rng.integers(len(X)))
        pre = X[j, :W - k] - X[j, :W - k].mean(0) + X[i, W - k:].mean(0)
        X[i] = np.concatenate([pre, X[i, W - k:]])
    return X


# ───────────────────────── worker
def init_worker(threads):
    os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
    os.environ["CUDA_VISIBLE_DEVICES"] = "-1"
    for k in ("OMP_NUM_THREADS", "TF_NUM_INTRAOP_THREADS"):
        os.environ[k] = str(threads)
    import warnings
    warnings.filterwarnings("ignore")
    import tensorflow as tf
    tf.get_logger().setLevel("ERROR")
    with contextlib.suppress(RuntimeError):
        tf.config.threading.set_intra_op_parallelism_threads(threads)
        tf.config.threading.set_inter_op_parallelism_threads(2)


def _recipe(spec, regime, power, epochs_override):
    from harry.runner import RECIPES
    r = dict(RECIPES[(spec.recipe, regime)])
    if power is not None and spec.recipe == "harry":
        r["balance_power"] = power
    if epochs_override and "epochs" in r:
        r["epochs"] = epochs_override
    return r


def _resolve(parts, rec_step):
    return [(p[0], p[1], p[2] or rec_step) + tuple(p[3:]) for p in parts]


def done(job_id):
    f = JOBS / f"{job_id}.json"
    return f.exists() and json.loads(f.read_text()).get("status") == "ok"


def execute(job, smoke):
    JOBS.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    res = {"id": job["id"], "job": job}             # the full spec: data parts, tests, recipe settings
    with open(JOBS / f"{job['id']}.log", "w", buffering=1) as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        try:
            res.update(_execute(job, smoke, log))
            res["status"] = "ok"
        except Exception:                                          # noqa: BLE001
            res["status"] = "failed"; res["error"] = traceback.format_exc(); print(res["error"])
    res["seconds"] = round(time.time() - t0, 1)
    (JOBS / f"{job['id']}.json").write_text(json.dumps(res, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o)))
    return job["id"], res["status"], res["seconds"]


def _execute(job, smoke, log):
    import keras
    import harry.zoo as zoo
    from harry.zoo import ZOO, build
    from harry.runner import _fit, _SkModel
    from harry.data import HAR_CLASSES, SOCIAL_CLASSES
    from harry import layers as _l, augment as _a  # noqa: F401
    from .data import windows, load_set
    real_meta = load_set("real")[1]

    task = job["task"]
    spec = dataclasses.replace(ZOO[job["model"]], windows={**ZOO[job["model"]].windows, task: C.W[task]})
    zoo.ZOO[job["model"]] = spec                      # build() reads the window from the zoo
    n = len(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
    Wm = spec.windows[task]
    ep = 1 if smoke else None
    if job["group"] == "deploy":
        return _deploy(job, spec, task, n, Wm)

    tests = {}
    for name, t in job["tests"].items():
        X, y, src, rid = windows(t["parts"], t["task"], t["window"])
        tests[name] = (X, y, rid, src)
    print(f"[{job['id']}] tests: " + ", ".join(f"{k}: {v[0].shape}" for k, v in tests.items()))
    seed = 1000 * job["seed"] + (job["fold"] if job["fold"] is not None else 99)
    keras.utils.set_random_seed(seed)
    history, info = [], {}

    def run_fit(model, parts, regime, stage):
        rec = _recipe(spec, regime, job["power"], ep)
        X, y, src, _ = windows(_resolve(parts, rec.get("step", 25)), task, Wm)
        if task == "social" and C.SOCIAL_RECENCY and stage == "train":
            X = _recency(X, np.random.default_rng(seed))
            rec = {**rec, "recency": True}
        print(f"stage {stage}: {regime} {X.shape} recipe {rec}")
        info[f"{stage}_windows"] = int(len(y)); info[f"{stage}_recipe"] = rec
        info[f"{stage}_windows_by_source"] = {str(s): int((src == s).sum()) for s in np.unique(src)}
        info[f"{stage}_class_counts"] = np.bincount(y, minlength=n).tolist()
        info[f"{stage}_class_counts_by_source"] = {str(s_): np.bincount(y[src == s_], minlength=n).tolist() for s_ in np.unique(src)}
        if rec.get("balance"):                         # the exact per-class weights _fit applies
            cnt = np.bincount(y, minlength=n).astype(float)
            w = (len(y) / (n * np.maximum(cnt, 1))) ** rec.get("balance_power", 1.0)
            info[f"{stage}_class_weights"] = (w / w[y].mean()).round(6).tolist()
        if model is None:
            model = _SkModel(job["seed"], n).fit(X, y) if spec.kind == "sklearn" else build(job["model"], task, n, X)
            if spec.kind == "sklearn":
                return model, []
        mon = {}
        if job["monitor"] and job["monitor"] in tests:
            Xm, ym, rm, _ = tests[job["monitor"]]
            mon = {"test": (Xm, ym, rm)}
        t = time.time()
        h = _fit(model, X, y, n, rec, mon, list(mon), task, {"seed_base": seed}, log)
        info[f"{stage}_seconds"] = time.time() - t
        for r in h:
            r["stage"] = stage
        return model, h

    model = None
    if job["init_from"]:
        model = keras.models.load_model(JOBS / "models" / f"{job['init_from']}.keras", compile=False)
    elif job["train"]:
        model, h = run_fit(None, job["train"], "jan", "train"); history += h
    if job["finetune"]:
        model, h = run_fit(model, job["finetune"], "finetune", "finetune"); history += h
    info["params"] = int(model.count_params()) if spec.kind != "sklearn" else int(model.m[-1].coef_.size + model.m[-1].intercept_.size)

    arrays = {}
    t = time.time()
    for name, (X, y, rid, src) in tests.items():
        if not len(y):
            continue
        P = model.predict(X, batch_size=4096, verbose=0) if spec.kind != "sklearn" else model.predict(X)
        arrays[f"{name}__P"] = P.astype(np.float32); arrays[f"{name}__y"] = y; arrays[f"{name}__rid"] = rid
        person = np.array(["jan"] * len(y), dtype="<U16")
        isreal = src == "real"
        if isreal.any():
            person[isreal] = real_meta.person.to_numpy()[rid[isreal]]
        arrays[f"{name}__src"] = src.astype("<U16"); arrays[f"{name}__person"] = person
        info.setdefault("test_composition", {})[name] = {str(w): np.bincount(y[person == w], minlength=n).tolist()
                                                         for w in np.unique(person)}
    info["predict_seconds"] = time.time() - t
    np.savez_compressed(JOBS / f"{job['id']}.npz", **arrays)
    if job["save_model"] and spec.kind != "sklearn":
        (JOBS / "models").mkdir(exist_ok=True)
        model.save(JOBS / "models" / f"{job['id']}.keras")
    if job["export"]:
        info["export"] = _export(job, spec, task, n, Wm, model)
    if spec.kind != "sklearn":
        keras.backend.clear_session()
    return {"history": history, "info": info}


def _deploy(job, spec, task, n, Wm):
    """Untrained build -> TFLite: size, builtin-ops-only conversion, batch-1 latency on this Mac."""
    import io
    import pickle
    import tensorflow as tf
    from harry.zoo import build
    from harry.runner import _SkModel
    from .data import windows
    X, y, _, _ = windows([("jan_" + task, {"subsample": 20}, 25)], task, Wm)
    if spec.kind == "sklearn":
        m = _SkModel(0, n).fit(X, y)
        t = time.perf_counter()
        for w in X[:300]:
            m.predict(w[None])
        return {"info": {"tflite": False, "size_kb": len(pickle.dumps(m.m)) / 1024, "params": int(m.m[-1].coef_.size + m.m[-1].intercept_.size),
                         "ms_per_window": (time.perf_counter() - t) / 300 * 1000, "window": Wm}, "history": []}
    model = build(job["model"], task, n, X, for_export=True)
    lines = []
    model.summary(print_fn=lambda line, **kw: lines.append(line), line_length=120)
    layer_rows = []
    for layer in model.layers:
        try:
            shape = str(layer.output.shape)
        except Exception:                                  # noqa: BLE001
            shape = ""
        layer_rows.append({"name": layer.name, "type": type(layer).__name__, "output_shape": shape,
                           "params": int(layer.count_params()), "config": {k: v for k, v in layer.get_config().items()
                                                                           if k not in ("name", "trainable", "dtype")}})
    adir = C.OUT / "architectures"; adir.mkdir(parents=True, exist_ok=True)
    stem = f"{task}_{job['model']}_w{Wm}"
    (adir / f"{stem}.txt").write_text("\n".join(lines))
    (adir / f"{stem}.json").write_text(json.dumps(layer_rows, indent=1, default=str))
    conv = tf.lite.TFLiteConverter.from_keras_model(model)
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
    with contextlib.redirect_stdout(io.StringIO()):
        blob = conv.convert()
    it = tf.lite.Interpreter(model_content=blob, num_threads=1)
    i = it.get_input_details()[0]
    it.resize_tensor_input(i["index"], [1, Wm, 3]); it.allocate_tensors()
    for w in X[:30]:
        it.set_tensor(i["index"], w[None]); it.invoke()
    ts = []
    for w in X[:500]:
        t = time.perf_counter(); it.set_tensor(i["index"], w[None]); it.invoke(); ts.append(time.perf_counter() - t)
    return {"info": {"tflite": True, "builtin_ops_only": True, "size_kb": len(blob) / 1024, "params": int(model.count_params()),
                     "ms_per_window": float(np.median(ts) * 1000), "ms_p90": float(np.percentile(ts, 90) * 1000), "window": Wm,
                     "layers": len(model.layers)}, "history": []}


def _export(job, spec, task, n, Wm, model):
    """Write the app files (Lab 4 contract) for a final model: .tflite + _meta.json + _example.json + .keras."""
    import tensorflow as tf
    from harry.zoo import build
    from harry.export import export
    from harry.data import HAR_CLASSES, SOCIAL_CLASSES
    from .data import windows
    classes = HAR_CLASSES if task == "har" else SOCIAL_CLASSES
    out = C.MODELS
    out.mkdir(parents=True, exist_ok=True)
    Xc, yc, _, _ = windows([("real", {}, 25)], task, Wm)
    final = model
    if spec.group == "RNN":                         # unrolled copy -> builtin TFLite ops only
        final = build(job["model"], task, n, Xc[:256], for_export=True)
        final.set_weights(model.get_weights())
    name = C.APP_FILES[task]
    model.save(out / f"{name}.keras")
    trained = "datasetJan2026 (all, incl. recordings not in the fold CSVs) + both group members' recordings, mixed"
    info = export(final, name, out, Wm, 25, classes, "daily_activity" if task == "har" else "social_signal", Xc, yc,
                  extra_meta={"trained_on": trained, "architecture": job["model"], "window_seconds": Wm / C.FS,
                              "recency_training": bool(task == "social" and C.SOCIAL_RECENCY), "class_weights":
                              f"balanced^{job['power']:g}" if job["power"] is not None else "balanced",
                              "exported": time.strftime("%Y-%m-%d %H:%M")})
    it = tf.lite.Interpreter(model_path=str(out / f"{name}.tflite"), num_threads=1)
    i = it.get_input_details()[0]; it.resize_tensor_input(i["index"], [1, Wm, 3]); it.allocate_tensors()
    ts = []
    for w in Xc[:500]:
        t = time.perf_counter(); it.set_tensor(i["index"], w[None]); it.invoke(); ts.append(time.perf_counter() - t)
    info["ms_per_window"] = float(np.median(ts) * 1000)
    info["fit_acc_on_real"] = float((final.predict(Xc, batch_size=4096, verbose=0).argmax(1) == yc).mean())
    return info


# ───────────────────────── scheduler
def run_all(jobs, workers, threads, smoke, log):
    todo = [j for j in jobs if not done(j["id"])]
    ids_done = {j["id"] for j in jobs if done(j["id"])}
    log(f"{len(jobs)} jobs in the plan, {len(ids_done)} already finished, {len(todo)} to run "
        f"({workers} workers x {threads} threads)")
    if not todo:
        return
    t0, finished, failed = time.time(), 0, []
    pending = {}
    import multiprocessing as mp
    with ProcessPoolExecutor(workers, mp_context=mp.get_context("spawn"), initializer=init_worker,
                             initargs=(threads,)) as ex:
        while todo or pending:
            ready = [j for j in todo if all(d in ids_done for d in j["depends"])]
            blocked_dead = [j for j in todo if any(d in failed for d in j["depends"])]
            for j in blocked_dead:
                todo.remove(j); failed.append(j["id"]); log(f"skip {j['id']}: dependency failed")
            while ready and len(pending) < workers:
                j = ready.pop(0); todo.remove(j)
                pending[ex.submit(execute, j, smoke)] = j
            if not pending:
                break
            fin, _ = wait(list(pending), return_when=FIRST_COMPLETED)
            for f in fin:
                j = pending.pop(f)
                jid, status, sec = f.result()
                finished += 1
                if status == "ok":
                    ids_done.add(jid)
                else:
                    failed.append(jid)
                el = time.time() - t0
                left = len(todo) + len(pending)
                log(f"[{finished}/{finished + left}] {jid} {status} in {sec / 60:.1f} min · elapsed {el / 3600:.1f} h"
                    f" · est. left {el / finished * left / 3600:.1f} h")
    if failed:
        log(f"{len(failed)} job(s) failed: {', '.join(failed[:10])} – see <out>/jobs/<id>.log; re-run to retry")
