"""The experiment plan (one job = train one model, test it, save everything) and the parallel job runner.

Job groups
  deploy    untrained build of every architecture -> TFLite size, builtin-ops check, ms per window
  main      final recipes on the official folds: 2 data variants x 3 seeds x 10 folds x {HAR, social}
  gate      HAR model per fold without the HAR copies of that fold's social test recordings, run on the last
            4 s of every social test window (app rule: social only while not moving)
  baseline  7 other architectures per task on the official folds (Jan2026 only, seed 0)
  sweep     social class-weight power sweep (Jan2026 only, seed 0)
  lopo      leave-one-person-out on the two group members: A = all Jan2026 only, B = + other person mixed in,
            C = A fine-tuned on the other person
  final     the deployable models trained on everything, exported for the app

Every job writes jobs/<id>.json (settings, history, timing, status), jobs/<id>.npz (test probabilities, labels,
recording ids) and jobs/<id>.log; models it keeps go to jobs/models/<id>.keras. Finished jobs are skipped.
"""
import contextlib
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
def _cv_test(task, k):
    return {"task": task, "window": C.W[task], "parts": [(f"jan_{task}", {"fold_eq": k}, C.TEST_STEP)]}


def _person_test(task, person, window=None, crop=None):
    part = ("real", {"people": [person]}, C.TEST_STEP) + ((crop,) if crop else ())
    return {"task": task, "window": window or C.W[task], "parts": [part]}


def plan(smoke=False):
    sub = {"subsample": 25} if smoke else {}
    seeds = [0] if smoke else C.SEEDS
    folds = [0, 1] if smoke else C.FOLDS
    people = list(C.PEOPLE)
    jobs = []

    def J(**kw):
        kw.setdefault("seed", 0); kw.setdefault("fold", None); kw.setdefault("power", None)
        kw.setdefault("finetune", None); kw.setdefault("init_from", None); kw.setdefault("monitor", None)
        kw.setdefault("save_model", False); kw.setdefault("depends", []); kw.setdefault("person", None)
        kw.setdefault("export", False)
        jobs.append(kw)

    def jan_train(task, k=None, extra=None):
        sel = dict(sub, **({"fold_ne": k} if k is not None else {}), **(extra or {}))
        parts = [(f"jan_{task}", sel, None)]
        if k is None:                                   # "all Jan2026" = listed + unlisted recordings
            parts.append((f"janx_{task}", dict(sub), None))
        return parts

    def real(people_):
        return [("real", dict(sub, people=people_), C.REAL_TRAIN_STEP)]

    def power(task, model):
        return C.SOCIAL_POWER if task == "social" and model.startswith("harry") else None

    # deploy benchmarks (cheap, first)
    for task in ("har", "social"):
        for m in [C.FINAL[task]] + C.BASELINES[task]:
            J(id=f"deploy_{task}_{m}", group="deploy", task=task, model=m, prio=0)

    # main: final recipes on the official folds
    for seed in seeds:
        for v in C.VARIANTS:
            for k in folds:
                for task in ("har", "social"):
                    m = C.FINAL[task]
                    train = jan_train(task, k)
                    ft = None
                    if v == "jan+real":
                        if C.REAL_STRATEGY[task] == "mix":
                            train = train + real(people)
                        else:
                            ft = real(people)
                    J(id=f"main_{task}_{v.replace('+', '_')}_s{seed}_f{k}", group="main", task=task, model=m,
                      variant=v, seed=seed, fold=k, power=power(task, m), train=train, finetune=ft,
                      tests={"cv": _cv_test(task, k)}, monitor="cv", save_model=(seed == 0),
                      prio=1 if seed == 0 else 6)
    # gate: HAR without copies of social test recordings, evaluated on social test windows (last 4 s)
    for v in C.VARIANTS:
        for k in folds:
            train = jan_train("har", k, {"drop_md5_of_social_fold": k})
            J(id=f"gate_{v.replace('+', '_')}_f{k}", group="gate", task="har", model=C.FINAL["har"], variant=v, fold=k,
              train=train, finetune=real(people) if v == "jan+real" else None,
              tests={"gate": {"task": "social", "window": C.W["social"],
                              "parts": [("jan_social", {"fold_eq": k}, C.TEST_STEP, C.W["har"])]}},
              prio=5)
    # leave-one-person-out
    for task in ("har", "social"):
        m = C.FINAL[task]
        tests = {f"person_{p}": _person_test(task, p) for p in people}
        if task == "har":
            tests.update({f"gate_{p}": _person_test("social", p, C.W["social"], C.W["har"]) for p in people})
        a = f"lopo_{task}_A"
        J(id=a, group="lopo", task=task, model=m, variant="A", power=power(task, m), train=jan_train(task),
          tests=tests, save_model=True, prio=2)
        for p in people:
            other = [q for q in people if q != p]
            t = {f"person_{p}": _person_test(task, p)}
            if task == "har":
                t[f"gate_{p}"] = _person_test("social", p, C.W["social"], C.W["har"])
            J(id=f"lopo_{task}_B_{p}", group="lopo", task=task, model=m, variant="B", person=p, power=power(task, m),
              train=jan_train(task) + real(other), tests=t, save_model=True, prio=4)
            J(id=f"lopo_{task}_C_{p}", group="lopo", task=task, model=m, variant="C", person=p, power=power(task, m),
              init_from=a, depends=[a], finetune=real(other), tests=t, save_model=True, prio=4)
    # final deployable models
    for task in ("har", "social"):
        m = C.FINAL[task]
        if C.REAL_STRATEGY[task] == "finetune":
            J(id=f"final_{task}", group="final", task=task, model=m, power=power(task, m), init_from=f"lopo_{task}_A",
              depends=[f"lopo_{task}_A"], finetune=real(people), tests={}, save_model=True, export=True, prio=3)
        else:
            J(id=f"final_{task}", group="final", task=task, model=m, power=power(task, m),
              train=jan_train(task) + real(people), tests={}, save_model=True, export=True, prio=3)
    # architecture comparison and class-weight sweep (Jan2026 only, seed 0)
    for task in ("har", "social"):
        for m in C.BASELINES[task]:
            for k in folds:
                J(id=f"base_{task}_{m}_f{k}", group="baseline", task=task, model=m, variant="jan", fold=k,
                  power=power(task, m), train=jan_train(task, k), tests={"cv": _cv_test(task, k)}, monitor="cv", prio=7)
    for pw in C.POWER_SWEEP:
        for k in folds:
            J(id=f"sweep_p{pw:g}_f{k}", group="sweep", task="social", model=C.FINAL["social"], variant="jan", fold=k,
              power=pw, train=jan_train("social", k), tests={"cv": _cv_test("social", k)}, monitor="cv", prio=8)
    if smoke:
        keep = {"har": ["her_cnn", "her_logreg"], "social": ["her_cnn"]}
        jobs = [j for j in jobs if j["group"] != "baseline" or j["model"] in keep[j["task"]]]
        jobs = [j for j in jobs if j["group"] != "sweep" or j["power"] in (0.0,)]
        jobs = [j for j in jobs if j["group"] != "deploy" or j["model"] in (C.FINAL[j["task"]], "her_logreg")]
    for j in jobs:
        j.setdefault("variant", None)
        j.setdefault("train", None)
    return sorted(jobs, key=lambda j: j["prio"])


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
    res = {"id": job["id"], "job": {k: v for k, v in job.items() if k not in ("train", "finetune", "tests")}}
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
    from harry.zoo import ZOO, build
    from harry.runner import _fit, _SkModel
    from harry.data import HAR_CLASSES, SOCIAL_CLASSES
    from harry import layers as _l, augment as _a  # noqa: F401
    from .data import windows

    task, spec = job["task"], ZOO[job["model"]]
    n = len(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
    Wm = spec.windows[task]
    ep = 1 if smoke else None
    if job["group"] == "deploy":
        return _deploy(job, spec, task, n, Wm)

    tests = {}
    for name, t in job["tests"].items():
        X, y, src, rid = windows(t["parts"], t["task"], t["window"])
        if t["window"] != Wm and X.shape[1] != Wm:              # baselines with 50-sample windows on a 100 set
            X = X[:, -Wm:]
        tests[name] = (X, y, rid, src)
    print(f"[{job['id']}] tests: " + ", ".join(f"{k}: {v[0].shape}" for k, v in tests.items()))
    seed = 1000 * job["seed"] + (job["fold"] if job["fold"] is not None else 99)
    keras.utils.set_random_seed(seed)
    history, info = [], {}

    def run_fit(model, parts, regime, stage):
        rec = _recipe(spec, regime, job["power"], ep)
        X, y, src, _ = windows(_resolve(parts, rec.get("step", 25)), task, Wm)
        print(f"stage {stage}: {regime} {X.shape} recipe {rec}")
        info[f"{stage}_windows"] = int(len(y)); info[f"{stage}_recipe"] = rec
        info[f"{stage}_windows_by_source"] = {str(s): int((src == s).sum()) for s in np.unique(src)}
        info[f"{stage}_class_counts"] = np.bincount(y, minlength=n).tolist()
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
    out = C.OUT / "final_models"
    out.mkdir(parents=True, exist_ok=True)
    Xc, yc, _, _ = windows([("real", {}, 25)], task, Wm)
    final = model
    if spec.group == "RNN":                         # unrolled copy -> builtin TFLite ops only
        final = build(job["model"], task, n, Xc[:256], for_export=True)
        final.set_weights(model.get_weights())
    name = C.APP_FILES[task]
    model.save(out / f"{name}.keras")
    trained = ("datasetJan2026 (all, incl. recordings not in the fold CSVs) pre-train, fine-tuned on both group members"
               if job["init_from"] else "datasetJan2026 (all) + both group members' recordings, mixed")
    info = export(final, name, out, Wm, 25, classes, "daily_activity" if task == "har" else "social_signal", Xc, yc,
                  extra_meta={"trained_on": trained, "architecture": job["model"], "class_weights":
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
                             initargs=(threads,), max_tasks_per_child=8) as ex:
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
        log(f"{len(failed)} job(s) failed: {', '.join(failed[:10])} – see final_run/jobs/<id>.log; re-run to retry")
