#!/usr/bin/env python3
"""One-click pipeline: train, test and cross-validate her and my models in every scenario, then build a report.

    Double-click this file (Windows), or:  python run_pipeline.py [--profile quick|full] [--fresh] [--config FILE]

First run creates a private virtual environment next to this file and installs the requirements
(TensorFlow is ~600 MB), then re-launches itself inside it. Re-running resumes: finished jobs are skipped.
Output: runs/<profile>/report.html (open in a browser), summary.md, results.csv, jobs/*.json|*.log
"""
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
NEEDED = ["numpy", "pandas", "tensorflow", "sklearn", "yaml", "matplotlib", "scipy"]


def _pause():
    if os.name == "nt" and sys.stdin and sys.stdin.isatty():
        try:
            input("\nPress Enter to close this window...")
        except EOFError:
            pass


# ───────────────────────── 1. bootstrap a venv (stdlib only above this line)
def _missing():
    import importlib.util
    return [m for m in NEEDED if importlib.util.find_spec(m) is None]


def bootstrap():
    if os.environ.get("HARRY_PIPELINE_CHILD") or not _missing():
        return
    if sys.version_info >= (3, 14) or sys.version_info < (3, 10):
        sys.exit(f"Python {sys.version.split()[0]} found; TensorFlow 2.20 needs Python 3.10-3.13. "
                 "Install Python 3.12 from python.org and run this file with it.")
    venv = HERE / (".venv" if sys.platform == "darwin" else f".venv-{'win' if os.name == 'nt' else 'linux'}")
    py = venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if not py.exists():
        print(f"Creating virtual environment {venv} ...", flush=True)
        subprocess.check_call([sys.executable, "-m", "venv", str(venv)])
    reqs = (HERE / "requirements.txt").read_text(encoding="utf-8").split()
    gpu_linux = sys.platform.startswith("linux") and subprocess.call(
        "nvidia-smi", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
    if gpu_linux:
        reqs = [r.replace("tensorflow==", "tensorflow[and-cuda]==") for r in reqs]
    chk = subprocess.call([str(py), "-c", "import " + ",".join(NEEDED)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if chk != 0:
        print("Installing requirements (first run only, several minutes) ...", flush=True)
        subprocess.check_call([str(py), "-m", "pip", "install", "--upgrade", "pip"])
        subprocess.check_call([str(py), "-m", "pip", "install", *reqs])
    env = dict(os.environ, HARRY_PIPELINE_CHILD="1")
    code = subprocess.call([str(py), str(Path(__file__).resolve()), *sys.argv[1:]], env=env)
    sys.exit(code)


# ───────────────────────── 2. config, data, hardware
def load_config(path, profile=None):
    import yaml
    cfg = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    cfg["profile"] = profile or cfg["profile"]
    p = dict(cfg["profiles"][cfg["profile"]])
    cfg["profile_settings"] = p
    if "seeds" in p:
        cfg["seeds"] = p["seeds"]
    from harry.zoo import ZOO
    models = list(ZOO) if cfg["models"] == "all" else list(cfg["models"])
    cfg["model_list"] = [m for m in models if ZOO[m].group in cfg["groups"]]
    return cfg


def resolve_jan(cfg):
    for c in cfg["paths"]["jan_dir"] or []:
        p = (HERE / c).resolve() if not Path(c).is_absolute() else Path(c)
        if (p / "daily_activity").is_dir() and (p / "social_signal").is_dir():
            return p
    if sys.stdin and sys.stdin.isatty():
        while True:
            ans = input("\ndatasetJan2026 not found. Paste the path to the datasetJan2026 folder "
                        "(the one containing daily_activity/ and social_signal/), or press Enter to skip "
                        "the Jan2026 scenarios: ").strip().strip('"')
            if not ans:
                return None
            p = Path(ans).expanduser()
            if (p / "daily_activity").is_dir() and (p / "social_signal").is_dir():
                return p
            print("  -> that folder does not contain daily_activity/ and social_signal/")
    return None


def detect_gpu(py=sys.executable):
    code = "import os;os.environ['TF_CPP_MIN_LOG_LEVEL']='3';import tensorflow as tf;print(len(tf.config.list_physical_devices('GPU')))"
    try:
        out = subprocess.run([py, "-c", code], capture_output=True, text=True, timeout=300).stdout.strip().splitlines()
        return int(out[-1]) if out else 0
    except Exception:                                         # noqa: BLE001
        return 0


def compute_plan(cfg):
    c = cfg["compute"]
    logical = os.cpu_count() or 4
    n_gpu = 0 if c["device"] == "cpu" else detect_gpu()
    if c["device"] in ("gpu", "auto") and n_gpu == 0 and c["device"] == "gpu":
        print("WARNING: device=gpu requested but TensorFlow sees no GPU -> using CPU only.")
    tpw = 4 if c["threads_per_worker"] == "auto" else int(c["threads_per_worker"])
    gw = int(c["gpu_workers"]) if n_gpu else 0
    cw = max(1, (logical - 2 * gw) // tpw) if c["cpu_workers"] == "auto" else int(c["cpu_workers"])
    big_on = c["big_jobs_on"] if c["big_jobs_on"] != "auto" else ("gpu" if gw else "cpu")
    if big_on == "gpu" and not gw:
        big_on = "cpu"
    return dict(logical=logical, n_gpu=n_gpu, cpu_workers=cw, threads=tpw, gpu_workers=gw, big_on=big_on,
                gpu_mem_mb=(7000 // gw) if gw else 0, steal=bool(c["allow_steal"]))


# ───────────────────────── 3. scheduler
def fmt_t(s):
    s = int(s); return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def run(cfg, fresh=False):
    import json
    import multiprocessing as mp
    import numpy as np
    import shutil
    from concurrent.futures import ProcessPoolExecutor, wait, FIRST_COMPLETED

    from harry import datasets as ds, report, tables, model_card
    from harry.jobs import plan
    from harry.runner import execute
    from harry.worker_init import init_worker

    out_dir = (HERE / cfg["paths"]["out_dir"] / cfg["profile"]).resolve()
    if fresh and out_dir.exists():
        shutil.rmtree(out_dir)
    (out_dir / "jobs").mkdir(parents=True, exist_ok=True)
    cache = HERE / cfg["paths"]["out_dir"] / "cache"
    ds.configure(cache)

    jan = resolve_jan(cfg) if any(s in cfg["scenarios"] for s in ("B", "C", "D", "E")) else None
    print(f"real data : {(HERE / cfg['paths']['real_dir']).resolve()}")
    print(f"Jan2026   : {jan or 'not used (scenarios B, C, D, E skipped)'}")
    ds.build_cache((HERE / cfg["paths"]["real_dir"]).resolve(), jan)
    fc = cfg["paths"].get("fold_csv")
    fc = ((HERE / fc).resolve() if fc and not Path(fc).is_absolute() else fc)
    if fc and not Path(fc).exists():
        print(f"WARNING: fold_csv {fc} not found -> using Lab3 make_folds(seed 0)"); fc = None
    if jan:
        ds.assign_jan_folds(fc)
    jobs = plan(cfg, have_jan=jan is not None and ds.available("jan_har"))
    hw = compute_plan(cfg)
    print(f"hardware  : {hw['logical']} logical CPUs, {hw['n_gpu']} GPU(s) visible to TensorFlow")
    print(f"workers   : {hw['cpu_workers']} CPU x {hw['threads']} threads"
          + (f" + {hw['gpu_workers']} GPU ({hw['gpu_mem_mb']} MB each)" if hw["gpu_workers"] else "")
          + f"; big (Jan-sized) jobs on {hw['big_on'].upper()}")

    done, skipped = {}, 0
    for j in jobs:
        p = out_dir / "jobs" / f"{j['id']}.json"
        if p.exists():
            r = json.loads(p.read_text(encoding="utf-8"))
            if r.get("status") == "ok" or not cfg["retry_failed"]:
                done[j["id"]] = r.get("status"); skipped += 1
    todo = [j for j in jobs if j["id"] not in done]
    print(f"jobs      : {len(jobs)} total, {skipped} already finished, {len(todo)} to run  ->  {out_dir}\n", flush=True)
    (out_dir / "plan.json").write_text(json.dumps([{k: j[k] for k in ("id", "scenario", "task", "model", "group", "size")}
                                                   for j in jobs], indent=0))

    exp = cfg.get("export", {})
    # only the full profile may overwrite model_harry/models; smoke tests export inside their own run folder
    export_dir = ((HERE / exp.get("dir", "models")).resolve() if cfg["profile"] == "full"
                  else out_dir / "exported_models")
    settings = {"out_dir": str(out_dir), "max_epochs": cfg["profile_settings"].get("max_epochs"),
                "export_dir": str(export_dir)}
    if exp.get("enabled", True):
        print(f"export    : final models -> {export_dir}\n")
    ctx = mp.get_context("spawn")
    mtpc = {"max_tasks_per_child": cfg["compute"]["max_tasks_per_child"]} if sys.version_info >= (3, 11) else {}
    pools = {"cpu": ProcessPoolExecutor(hw["cpu_workers"], mp_context=ctx, initializer=init_worker,
                                        initargs=("cpu", hw["threads"], 0, str(cache)), **mtpc)}
    cap = {"cpu": hw["cpu_workers"]}
    if hw["gpu_workers"]:
        pools["gpu"] = ProcessPoolExecutor(hw["gpu_workers"], mp_context=ctx, initializer=init_worker,
                                           initargs=("gpu", 2, hw["gpu_mem_mb"], str(cache)), **mtpc)
        cap["gpu"] = hw["gpu_workers"]
    home = lambda j: hw["big_on"] if j["size"] == "big" else "cpu"
    running, t0, last_report = {}, time.time(), time.time()
    dur = {"big": [], "small": []}
    queue = list(todo)
    n_total, n_done = len(todo), 0
    cfg_text = (HERE / "pipeline.yaml").read_text(encoding="utf-8") if (HERE / "pipeline.yaml").exists() else ""

    def ready(j):
        d = j.get("depends")
        return d is None or done.get(d) == "ok"

    def blocked(j):
        d = j.get("depends")
        return d is not None and d in done and done[d] != "ok"

    try:
        while queue or running:
            for j in [j for j in queue if blocked(j)]:                  # dependency failed -> skip
                queue.remove(j); done[j["id"]] = "skipped"; n_done += 1
                print(f"  skipped {j['id']} (pre-training job failed)")
            for pool in pools:
                while sum(1 for v in running.values() if v[1] == pool) < cap[pool]:
                    pick = next((j for j in queue if ready(j) and home(j) == pool), None)
                    if pick is None and hw["steal"]:
                        pick = next((j for j in queue if ready(j)), None)
                    if pick is None:
                        break
                    queue.remove(pick)
                    running[pools[pool].submit(execute, pick, settings)] = (pick, pool, time.time())
            if not running:
                break
            fin, _ = wait(list(running), timeout=60, return_when=FIRST_COMPLETED)
            for f in fin:
                j, pool, ts = running.pop(f)
                try:
                    r = f.result()
                except Exception as e:                                   # noqa: BLE001  (worker crashed)
                    r = {"status": "failed", "seconds": time.time() - ts, "score": None}
                    print(f"  worker crash on {j['id']}: {e}")
                done[j["id"]] = r["status"]; n_done += 1
                dur[j["size"]].append(r["seconds"] or 0)
                el = time.time() - t0
                rem_big = sum(1 for q in queue + [v[0] for v in running.values()] if q["size"] == "big")
                rem_small = len(queue) + len(running) - rem_big
                mb = np.mean(dur["big"]) if dur["big"] else (np.mean(dur["small"]) * 8 if dur["small"] else 0)
                ms = np.mean(dur["small"]) if dur["small"] else mb / 8
                eta = (rem_big * mb + rem_small * ms) / max(1, sum(cap.values()))
                sc = f"score {100 * r['score']:.1f}" if r.get("score") is not None else r["status"].upper()
                print(f"[{n_done:4d}/{n_total}] {fmt_t(el)} elapsed · ETA ~{fmt_t(eta)} | {pool.upper()} | "
                      f"{j['group']:7s} {j['scenario']:5s} {j['task']:6s} {j['model']:14s} {str(j['fold'])[:22]:22s} "
                      f"s{j['seed']} -> {sc} ({r['seconds']:.0f}s)", flush=True)
            if time.time() - last_report > 60 * cfg["report_every_minutes"]:
                report.build(out_dir, cfg_text); last_report = time.time()
                print(tables.console_summary(tables.from_jobs(out_dir)))
                print(f"  (report updated: {out_dir / 'report.html'} · tables in {out_dir / 'tables'})", flush=True)
    finally:
        for p in pools.values():
            p.shutdown(wait=True, cancel_futures=True)
    path = report.build(out_dir, cfg_text)
    print(tables.console_summary(tables.from_jobs(out_dir)))
    card = model_card.write(out_dir, export_dir, tuple(exp.get("recommend_by", ["D", "E"])))
    if card:
        print(f"\nFinal models written to {export_dir} — see {card}")
        txt = card.read_text(encoding="utf-8").split("## Using a model")[0]
        print("\n".join(l for l in txt.splitlines() if l.startswith(("## ", "| ★", "|   |", "| |")) or l.startswith("| ★")))
    print(f"\nDone in {fmt_t(time.time() - t0)}.\n  report   : {path}\n  tables   : {out_dir / 'tables'}"
          f"\n  figures  : {out_dir / 'figures'}\n  notebook : {HERE / 'results_viewer.ipynb'} (set RUN = '{out_dir.name}')")
    return path


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(HERE / "pipeline.yaml"))
    ap.add_argument("--profile", choices=["quick", "full"])
    ap.add_argument("--fresh", action="store_true", help="delete previous results for this profile first")
    ap.add_argument("--report-only", action="store_true", help="just rebuild report.html from finished jobs")
    a = ap.parse_args()
    sys.path.insert(0, str(HERE))
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    cfg = load_config(a.config, a.profile)
    if a.report_only:
        from harry import report
        print(report.build((HERE / cfg["paths"]["out_dir"] / cfg["profile"]).resolve()))
        return
    path = run(cfg, fresh=a.fresh)
    if os.name == "nt":
        try:
            os.startfile(path)                                  # open the report in the default browser
        except OSError:
            pass


if __name__ == "__main__":
    try:
        bootstrap()
        main()
    except SystemExit:
        raise
    except Exception:                                           # noqa: BLE001
        import traceback
        traceback.print_exc()
        _pause()
        sys.exit(1)
    _pause()
