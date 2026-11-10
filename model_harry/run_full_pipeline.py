"""One command for everything the report needs about the models (double-click RUN_EVERYTHING.command).

  1. data      cache every recording; audit: composition, folds, duplicates, group-data quality
  2. jobs      ~350 training/testing jobs in parallel (resumable; finished jobs are skipped):
               official 10-fold CV of the final recipes (2 data variants x 3 seeds), social gate, 7 baseline
               architectures per task, class-weight sweep, leave-one-person-out, final models + TFLite export,
               deployment benchmarks
  3. analysis  every metric into final_run/tables/*.csv, statistics, real-time simulation, t-SNE
  4. figures   final_run/figures/<section>/*.png + .pdf
  5. write-up  final_run/WRITEUP.md + final_run/index.html (figure gallery), final_models/INSTALL.md

Options: --smoke (quick end-to-end test in final_run_smoke/), --report-only (redo 3-5 from finished jobs),
         --workers N --threads N, --no-open
"""
import argparse
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--smoke", action="store_true", help="tiny end-to-end test (1 epoch, 2 folds, subsampled) in final_run_smoke/")
    ap.add_argument("--report-only", action="store_true", help="skip training; rebuild tables, figures and write-up")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--threads", type=int, default=0, help="TF threads per worker (0 = cores / workers)")
    ap.add_argument("--no-open", action="store_true")
    a = ap.parse_args()
    if a.smoke:
        os.environ["FULLRUN_OUT"] = str(HERE / "final_run_smoke")
    sys.path.insert(0, str(HERE))
    from fullrun import config as C
    C.OUT.mkdir(parents=True, exist_ok=True)
    logf = open(C.OUT / "run.log", "a", buffering=1)

    def log(m):
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {m}"
        print(line, flush=True); logf.write(line + "\n")

    t0 = time.time()
    log(f"===== full model pipeline {'(SMOKE TEST) ' if a.smoke else ''}-> {C.OUT}")
    from fullrun import data
    tables = C.OUT / "tables"; tables.mkdir(exist_ok=True)
    log("stage 1/5: data cache and audit")
    data.build_cache(log)
    data.audit(tables, log)

    from fullrun import jobs
    plan = jobs.plan(a.smoke)
    (C.OUT / "plan.json").write_text(json.dumps(plan, indent=1, default=str))
    if not a.report_only:
        threads = a.threads or max(1, (os.cpu_count() or 8) // a.workers)
        log(f"stage 2/5: {len(plan)} jobs")
        jobs.run_all(plan, a.workers, threads, a.smoke, log)
    jobs.init_worker(os.cpu_count() or 8)
    import tensorflow as tf, keras, sklearn, numpy  # noqa: E401
    try:
        chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    except OSError:
        chip = platform.processor()
    system = {"machine": chip or platform.machine(), "cpus": os.cpu_count(), "os": platform.platform(), "python": platform.python_version(),
              "tensorflow": tf.__version__, "keras": keras.__version__, "sklearn": sklearn.__version__, "numpy": numpy.__version__,
              "date": time.strftime("%Y-%m-%d %H:%M")}
    (tables / "system.json").write_text(json.dumps(system, indent=1))

    log("stage 3/5: analysis")
    from fullrun import analyze, plots, writeup
    analyze.run(log)
    log("stage 4/5: figures")
    cat = plots.run(log)
    (C.OUT / "figures" / "catalogue.json").write_text(json.dumps(cat, indent=1))
    log("stage 5/5: write-up")
    writeup.write(cat, system, log)
    fm = C.OUT / "final_models"
    if fm.exists():
        (fm / "INSTALL.md").write_text(
            "# Installing the final models in the app\n\nThese files keep the app's names and metadata contract, so no code change is needed:\n\n"
            "```bash\ncd <IoT repo, on the app branch>\ncp model_harry/final_run/final_models/harry_har_cnn.tflite "
            "model_harry/final_run/final_models/harry_har_cnn_meta.json model_harry/final_run/final_models/harry_har_cnn_example.json assets/models/\n"
            "cp model_harry/final_run/final_models/harry_social_rnn.tflite model_harry/final_run/final_models/harry_social_rnn_meta.json "
            "model_harry/final_run/final_models/harry_social_rnn_example.json assets/models/\n```\n\n"
            "Then do a full rebuild (`flutter run`), and check the `EXAMPLE app:` line in the debug console matches the example file. "
            "The `.keras` files are for further training only.\n")
    log(f"===== done in {(time.time() - t0) / 3600:.2f} h. Open {C.OUT / 'index.html'} and {C.OUT / 'WRITEUP.md'}")
    if not a.no_open and sys.platform == "darwin":
        subprocess.run(["open", str(C.OUT / "index.html")])
        subprocess.run(["open", "-R", str(C.OUT / "WRITEUP.md")])


if __name__ == "__main__":
    main()
