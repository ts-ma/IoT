"""v2: one command for everything the report needs about Harry's models (double-click RUN_EVERYTHING.command).

  0. decisions  group members' folds; the social window (fastest candidate of results/social_window_study with every
                class >= 77 %); frozen in results/decisions.json
  1. data       cached recordings (shared with v1); audit: composition, folds, duplicates, group-data quality
  2. check      activity model with the group members mixed in, 10 folds, seed 0: if its datasetJan2026 dynamic mean
                is < 85 %, activities are trained on datasetJan2026 only (frozen in decisions.json)
  3. jobs       ~170 training/testing jobs in parallel (resumable): Harry's 4 architectures per task on the folds
                (deployed ones x 3 seeds), class-weight sweep, final models + TFLite export, deployment benchmarks
  4. analysis   every metric into results/tables/*.csv (all test windows / as marked / per member)
  5. figures    results/figures/<section>/*.png + .pdf
  6. write-up   results/WRITEUP.md + index.html (figure gallery); exported models in models/ (+ INSTALL.md)
  7. knowledge  KNOWLEDGE.md (start here), tables/README.md (data dictionary), history/, context/, code/, MANIFEST.csv

Options: --smoke (quick end-to-end test in results_smoke/ + models_smoke/), --report-only (redo 4-6), --workers N --threads N, --no-open
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
CANDS = {"w100": (100, False), "w75": (75, False), "w62": (62, False), "w50": (50, False), "w100rec": (100, True)}


def choose_social(C, log, smoke):
    """Fastest candidate whose every class keeps >= C.MIN_CLASS_RULE; waits for the study if it is still running."""
    import pandas as pd
    import shutil
    f = C.STUDY / "summary.csv"
    while True:
        old = C.STUDY_OLD / "summary.csv"
        if not f.exists() and old.exists() and subprocess.run(["pgrep", "-f", "social_window_study.py"], capture_output=True).returncode != 0:
            shutil.copytree(C.STUDY_OLD, C.STUDY, dirs_exist_ok=True)          # first study run wrote outside pipeline_v2/
            log(f"copied the social window study from {C.STUDY_OLD} into {C.STUDY}")
        running = subprocess.run(["pgrep", "-f", "social_window_study.py"], capture_output=True).returncode == 0
        d = pd.read_csv(f, index_col=0) if f.exists() else None
        complete = d is not None and set(CANDS) <= set(d.index) and (d.folds >= 10).all()
        if complete or smoke:
            break
        if not running:
            raise SystemExit(f"The social window study is incomplete ({f}) and not running. Run ./run_social_window_study.sh first.")
        log("waiting for the social window study to finish (checks every 5 min) ...")
        time.sleep(300)
    if d is None or d.empty:
        return {"candidate": "w100", "window": 100, "recency": False, "note": "study not available (smoke test): 8 s window used."}
    ok = d[d.min_class >= C.MIN_CLASS_RULE * 100]
    lat = "lat_med_real" if "lat_med_real" in d else "lat_med_jan"
    if ok.empty:
        best = d.min_class.idxmax()
        note = f"No candidate kept every class ≥ {C.MIN_CLASS_RULE * 100:.0f} %, so the one with the best weakest class was used."
    else:
        best = ok.sort_values([lat, "min_class"], ascending=[True, False]).index[0]
        note = ("Candidates meeting the rule (median s until shown on our recordings): "
                + ", ".join(f"{i} {r[lat]:.1f} s" for i, r in ok.sort_values(lat).iterrows()) + ".")
    w, rec = CANDS[best]
    return {"candidate": best, "window": w, "recency": rec, "note": note,
            "table": d.reset_index().round(3).to_dict(orient="records")}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--smoke", action="store_true", help="tiny end-to-end test (1 epoch, 2 folds, subsampled) in results_smoke/")
    ap.add_argument("--report-only", action="store_true", help="skip training; rebuild tables, figures and write-up")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--threads", type=int, default=0, help="TF threads per worker (0 = cores / workers)")
    ap.add_argument("--no-open", action="store_true")
    a = ap.parse_args()
    if a.smoke:
        os.environ["FULLRUN_OUT"] = str(HERE / "results_smoke")
        os.environ["FULLRUN_MODELS"] = str(HERE / "models_smoke")
    sys.path.insert(0, str(HERE))                      # fullrun2/
    sys.path.insert(1, str(HERE.parent))               # model_harry/: the shared model library harry/
    from fullrun2 import config as C
    C.OUT.mkdir(parents=True, exist_ok=True)
    logf = open(C.OUT / "run.log", "a", buffering=1)

    def log(m):
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {m}"
        print(line, flush=True); logf.write(line + "\n")

    def save_decisions(d):
        C.DECISIONS.write_text(json.dumps(d, indent=1, default=str))
        C.apply_decisions()

    t0 = time.time()
    log(f"===== model pipeline v2 {'(SMOKE TEST) ' if a.smoke else ''}-> {C.OUT}")
    from fullrun2 import data
    data.build_cache(log)
    dec = json.loads(C.DECISIONS.read_text()) if C.DECISIONS.exists() else {}
    if "person_fold" not in dec:
        pf, sizes = data.choose_person_folds()
        dec["person_fold"], dec["fold_sizes"] = pf, sizes
        log(f"decision: group members' folds {pf} (the two smallest official folds)")
    if "social" not in dec:
        dec["social"] = choose_social(C, log, a.smoke)
        log(f"decision: social window {dec['social']['candidate']} ({dec['social']['window'] / C.FS:g} s, recency "
            f"{dec['social']['recency']}). {dec['social']['note']}")
    save_decisions(dec)
    tables = C.OUT / "tables"; tables.mkdir(exist_ok=True)
    log("stage 1: data audit")
    data.audit(tables, log)

    from fullrun2 import jobs
    threads = a.threads or max(1, (os.cpu_count() or 8) // a.workers)
    if "har_check" not in dec and not a.report_only:
        log("stage 2: activity recipe check (group members mixed in, 10 folds, seed 0)")
        chk = jobs.plan(a.smoke, only={"check"})
        jobs.run_all(chk, a.workers, threads, a.smoke, log)
        import numpy as np
        vals = []
        for j in chk:
            f = jobs.JOBS / f"{j['id']}.npz"
            if not f.exists():
                continue
            z = np.load(f)
            m = z["cv__person"] == "jan"
            y, p = z["cv__y"][m], z["cv__P"][m].argmax(1)
            vals.append(np.nanmean([(p[y == c] == c).mean() if (y == c).any() else np.nan for c in range(5, 11)]))
        jd = float(np.mean(vals)) if vals else float("nan")
        dec["har_check"] = {"jan_dynamic": jd, "folds": len(vals)}
        dec["har_recipe"] = "mixed" if (jd >= C.TARGETS["dynamic"] or a.smoke) else "jan"
        save_decisions(dec)
        log(f"decision: activity datasetJan2026 dynamic mean with the members mixed in = {100 * jd:.1f} % -> recipe "
            f"'{dec['har_recipe']}'")
    plan = jobs.plan(a.smoke)
    (C.OUT / "plan.json").write_text(json.dumps(plan, indent=1, default=str))
    if not a.report_only:
        log(f"stage 3: {len(plan)} jobs")
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
    log("stage 4: analysis")
    from fullrun2 import analyze, plots, writeup
    analyze.run(log)
    log("stage 5: figures")
    cat = plots.run(log)
    (C.OUT / "figures" / "catalogue.json").write_text(json.dumps(cat, indent=1))
    log("stage 6: write-up")
    writeup.write(cat, system, log)
    fm = C.MODELS
    if fm.exists():
        rel = "model_harry/pipeline_v2/models"
        (fm / "INSTALL.md").write_text(
            "# Installing the final models in the app (not done automatically)\n\n"
            f"Activity model: same window (4 s) and names as the app expects. Social model: window {C.W['social']} samples "
            f"({C.W['social'] / C.FS:g} s){'; recency-trained' if C.SOCIAL_RECENCY else ''}. "
            + ("The app currently hard-codes a 100-sample social window (`socialWindowSamples` and the metadata check in "
               "`lib/social.dart`), so change those to the new length before copying.\n\n" if C.W['social'] != 100 else
               "No code change is needed.\n\n") +
            f"```bash\ncp {rel}/harry_har_cnn.tflite {rel}/harry_har_cnn_meta.json {rel}/harry_har_cnn_example.json <app>/assets/models/\n"
            f"cp {rel}/harry_social_rnn.tflite {rel}/harry_social_rnn_meta.json {rel}/harry_social_rnn_example.json <app>/assets/models/\n```\n\n"
            "Then rebuild (`flutter run`) and check the `EXAMPLE app:` line in the debug console matches the example file.\n")
    log("stage 7: knowledge base (KNOWLEDGE.md, data dictionary, history, code snapshot, manifest)")
    from fullrun2 import knowledge
    knowledge.run(log)
    log(f"===== done in {(time.time() - t0) / 3600:.2f} h. Start with {C.OUT / 'KNOWLEDGE.md'}; figures: {C.OUT / 'index.html'}")
    if not a.no_open and sys.platform == "darwin":
        subprocess.run(["open", str(C.OUT / "index.html")])
        subprocess.run(["open", "-R", str(C.OUT / "KNOWLEDGE.md")])


if __name__ == "__main__":
    main()
