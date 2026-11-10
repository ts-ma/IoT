"""Self-contained project knowledge base, written after the write-up (stage 7 of run_pipeline_v2.py).

Goal: someone (or an AI) with no prior knowledge of the project can open <out>/ and answer any question about how the
data was used, how the models were built, trained, cross-validated, tested and evaluated, why each choice was made,
and how they perform. Outputs:

  KNOWLEDGE.md              start here: the project, data, method, decisions with reasons, results, dated history,
                            a question -> file map, caveats
  tables/README.md          data dictionary: every CSV, every column
  tables/fold_training_data.csv, fold_test_data.csv, class_weights.csv, recipes.csv, architectures.csv
  architectures/            full layer-by-layer summary (.txt) and layer configs (.json) of every architecture
  history/                  earlier experiments (Harry's models only) with their original reports / tables
  context/                  the CW3 brief (text), the social window study report, frozen decisions
  code/                     snapshot of every script that produced these results
  MANIFEST.csv              every file in the folder with what it is
"""
import json
import shutil
import subprocess
import time
from pathlib import Path

import numpy as np
import pandas as pd

from harry.data import HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC, ACTIVITY_TO_HAR, SUB_TO_SOCIAL, ACTIVITY_TO_POSTURE
from . import config as C

OUT = C.OUT
TAB = OUT / "tables"
V1 = C.LIB / "final_run" / "tables"          # previous pipeline (history only, Harry's models)
RES = C.LIB / "results"                        # earlier experiment reports (history only)
CW3_PDF = Path("/Volumes/Macintosh HD2/Uni Course/Year 4/Semester_1/IoT/Coursework_2_3/Coursework 3 Instructions.pdf")
APP_DIR = Path.home() / "IoT-ui-enhancement-v2.0-harry"


def _read(f):
    f = Path(f)
    return pd.read_csv(f) if f.exists() and f.stat().st_size > 2 else pd.DataFrame()


def _pct(v, d=1):
    return "n/a" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{100 * v:.{d}f}"


def _md(df):
    if df is None or df.empty:
        return "_(not available)_\n"
    cols = list(df.columns)
    out = ["| " + " | ".join(map(str, cols)) + " |", "|" + "---|" * len(cols)]
    out += ["| " + " | ".join(str(v) for v in r) + " |" for r in df.itertuples(index=False)]
    return "\n".join(out) + "\n"


# ───────────────────────── derived tables from the job records
def job_tables(log):
    from .analyze import load_jobs
    jobs = load_jobs()
    if jobs.empty:
        return
    ok = jobs[jobs.status == "ok"]
    tr, te, cw = [], [], []
    for r in ok.itertuples():
        info = r.xinfo or {}
        cls = HAR_CLASSES if r.task == "har" else SOCIAL_CLASSES
        base = {"job": r.id, "group": r.group, "task": r.task, "model": r.model, "seed": r.seed,
                "fold": int(r.fold) if pd.notna(r.fold) else "all", "power": r.power}
        for src, counts in (info.get("train_class_counts_by_source") or {}).items():
            for c, k in zip(cls, counts):
                name = {"real": "group members"}.get(src, "datasetJan2026 (unlisted)" if src.startswith("janx") else "datasetJan2026")
                tr.append({**base, "source": name, "class": c, "windows": int(k)})
        for test, comp in (info.get("test_composition") or {}).items():
            for who, counts in comp.items():
                for c, k in zip(cls, counts):
                    te.append({**base, "test_set": test, "source": "datasetJan2026" if who == "jan" else who, "class": c, "windows": int(k)})
        for c, w in zip(cls, info.get("train_class_weights") or []):
            cw.append({**base, "class": c, "weight": w})
    pd.DataFrame(tr).to_csv(TAB / "fold_training_data.csv", index=False)
    pd.DataFrame(te).to_csv(TAB / "fold_test_data.csv", index=False)
    pd.DataFrame(cw).to_csv(TAB / "class_weights.csv", index=False)
    # architectures
    rows = []
    for r in ok[ok.group == "deploy"].itertuples():
        i = r.xinfo or {}
        stem = f"{r.task}_{r.model}_w{i.get('window')}"
        rows.append({"task": r.task, "model": r.model, "name": C.MODEL_NAMES.get(r.model, r.model), "window_samples": i.get("window"),
                     "window_s": (i.get("window") or 0) / C.FS, "params": i.get("params"), "tflite_kb": round(i.get("size_kb", np.nan), 1),
                     "ms_per_window_mac_1thread": i.get("ms_per_window"), "deployed": r.model == C.FINAL[r.task],
                     "summary_file": f"architectures/{stem}.txt", "layers_file": f"architectures/{stem}.json"})
    pd.DataFrame(rows).to_csv(TAB / "architectures.csv", index=False)
    log("knowledge: job-derived tables written")


def recipes_table():
    from harry.runner import RECIPES
    r = dict(RECIPES[("harry", "jan")])
    rows = [
        ("optimiser", "AdamW", "keras.optimizers.AdamW"), ("learning_rate", r["lr"], "initial; CosineDecay to 5 % (alpha 0.05) over all steps"),
        ("weight_decay", r["wd"], "AdamW decoupled weight decay"), ("epochs", r["epochs"], "fixed; no early stopping, test fold only monitored"),
        ("batch_size", r["batch"], ""), ("loss", "categorical cross-entropy", f"label smoothing {r['smooth']}"),
        ("train_step_jan_samples", r["step"], "window step on datasetJan2026 training recordings (2 s)"),
        ("train_step_group_samples", C.REAL_TRAIN_STEP, "window step on the group members' training recordings (0.48 s; they are few)"),
        ("test_step_samples", C.TEST_STEP, "window step of every test set (2 s)"),
        ("class_weights_har", "balanced", "w_c = N / (K n_c), normalised to mean 1 over training windows"),
        ("class_weights_social", f"balanced^{C.SOCIAL_POWER:g}", "w_c = (N / (K n_c))^0.6, normalised to mean 1 over training windows"),
        ("augmentation", "RandomAugment (in-graph, training only)", "amplitude ×U(0.8,1.25) of the gravity-free part; roll about sensor Y ±30°; "
         "tilt about a random axis ±10° (Rodrigues); Gaussian noise σ = 0.002 g"),
        ("window_har_samples", C.W["har"], f"{C.W['har'] / C.FS:g} s"), ("window_social_samples", C.W["social"], f"{C.W['social'] / C.FS:g} s"),
        ("social_recency_training", C.SOCIAL_RECENCY, "if True: 50 % of training windows get their first W−k samples (k ∈ [38, 75]) "
         "replaced by another training window, gravity-aligned; label of the last k samples"),
        ("seeds_deployed", ",".join(map(str, C.SEEDS)), "deployed architectures; seed = 1000*seed + fold"),
        ("seeds_other", "0", "other architectures and the class-weight sweep"),
        ("har_recipe", C.HAR_RECIPE, "'mixed' = group members' training-fold recordings added; 'jan' = datasetJan2026 only"),
        ("framework", "TensorFlow / Keras 3, CPU", "see tables/system.json"),
    ]
    d = pd.DataFrame(rows, columns=["setting", "value", "notes"])
    d.to_csv(TAB / "recipes.csv", index=False)
    return d


# ───────────────────────── history (Harry's models only)
def history(log):
    h = OUT / "history"; h.mkdir(exist_ok=True)
    copied = []
    mine = lambda d: d[d.model.astype(str).str.startswith("harry")] if "model" in d else d          # noqa: E731
    for name in ["summary_scores", "summary_per_class", "lopo_scores", "lopo_per_class", "lopo_gate", "gate_folds", "gate_leaks",
                 "stream_accuracy", "stream_latency", "trial_simulation", "deploy"]:
        d = _read(V1 / f"{name}.csv")
        if d.empty:
            continue
        if name == "deploy":
            d = d[d.model.astype(str).str.contains("harry")]
        elif "model" in d:
            d = mine(d)
        d.to_csv(h / f"v1_{name}.csv", index=False); copied.append(f"v1_{name}.csv")
    st = _read(V1 / "stat_tests.csv")
    if not st.empty:
        st = st[~st.comparison.str.contains("her_|Lab 3", regex=True)]
        st.to_csv(h / "v1_stat_tests.csv", index=False); copied.append("v1_stat_tests.csv")
    for src, dst in [(RES / "official_folds" / "report.md", "official_folds_balanced_weights_report.md"),
                     (RES / "official_folds_social_w0.6" / "report.md", "official_folds_social_w0.6_report.md"),
                     (RES / "real_people" / "report.md", "real_people_social_report.md"),
                     (RES / "real_people" / "har_report.md", "real_people_har_report.md"),
                     (RES / "app_latency_app.csv", "app_latency_replay.csv"),
                     (C.STUDY / "report.md", "social_window_study_report.md")]:
        if src.exists():
            shutil.copy(src, h / dst); copied.append(dst)
    b9 = RES / "b9_tables.md"
    if b9.exists():                                            # keep only Harry's rows
        lines = [l for l in b9.read_text().splitlines() if not l.startswith("| hers")]
        (h / "lab3_b9_folds_mine.md").write_text("\n".join(lines) + "\n"); copied.append("lab3_b9_folds_mine.md")
    log(f"knowledge: history files {len(copied)}")
    return copied


def context(log):
    cdir = OUT / "context"; cdir.mkdir(exist_ok=True)
    if CW3_PDF.exists():
        try:
            subprocess.run(["pdftotext", "-layout", str(CW3_PDF), str(cdir / "cw3_instructions.txt")], check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            pass
    if C.DECISIONS.exists():
        shutil.copy(C.DECISIONS, cdir / "decisions.json")
    for f in ["summary.csv", "report.md"]:
        if (C.STUDY / f).exists():
            shutil.copy(C.STUDY / f, cdir / f"social_window_study_{f}")
    log("knowledge: context copied")


def code_snapshot(log):
    cdir = OUT / "code"
    if cdir.exists():
        shutil.rmtree(cdir)
    (cdir / "fullrun2").mkdir(parents=True); (cdir / "harry").mkdir()
    for f in (C.HERE / "fullrun2").glob("*.py"):
        shutil.copy(f, cdir / "fullrun2" / f.name)
    for name in ["augment", "layers", "zoo", "runner", "data", "metrics", "export", "datasets"]:
        f = C.LIB / "harry" / f"{name}.py"
        if f.exists():
            shutil.copy(f, cdir / "harry" / f.name)
    for name in ["run_pipeline_v2.py", "social_window_study.py", "app_latency_sim.py", "run.sh", "run_social_window_study.sh",
                 "RUN_PIPELINE_V2.command", "README.md", "../requirements.txt"]:
        f = (C.HERE / name).resolve()
        if f.exists():
            shutil.copy(f, cdir / f.name)
    (cdir / "README.md").write_text(
        "# Code that produced these results (snapshot)\n\n"
        "Folder layout of the original: `model_harry/pipeline_v2/` (this code, `cache/`, `social_window_study/`, `results/`, "
        "`models/`); the model library `harry/` is shared with the previous pipeline in `model_harry/harry/`.\n\n"
        "| file | role |\n|---|---|\n"
        "| `run_pipeline_v2.py` | orchestrator: decisions, activity check, jobs, analysis, figures, write-up, knowledge base |\n"
        "| `fullrun2/config.py` | every constant and frozen decision (windows, folds of the group members, seeds, targets) |\n"
        "| `fullrun2/data.py` | reading recordings, label mapping, fold selection, windowing, data audit |\n"
        "| `fullrun2/jobs.py` | the job plan (which models are trained on what) and the worker that trains / tests / exports |\n"
        "| `fullrun2/analyze.py` | scoring every job (scopes, per-class recall, metrics, statistics) into tables |\n"
        "| `fullrun2/plots.py`, `writeup.py`, `knowledge.py` | figures, WRITEUP.md, this knowledge base |\n"
        "| `harry/zoo.py` | the four architectures (`build`) |\n| `harry/layers.py` | in-model preprocessing layers (gravity, dynamic channels, band power, log-std) |\n"
        "| `harry/augment.py` | training-time augmentation layer |\n| `harry/runner.py` | training recipe (`RECIPES`) and the fit loop (`_fit`, class weights) |\n"
        "| `harry/export.py` | TFLite export + Keras/TFLite parity check + app metadata |\n| `harry/metrics.py` | per-class recall and group scores |\n"
        "| `social_window_study.py` | the study that chose the social window (accuracy vs latency) |\n"
        "| `app_latency_sim.py` | replay of the app's live logic (packets, step, smoothing, social pause) |\n")
    log("knowledge: code snapshot written")


# ───────────────────────── data dictionary
COLS = {
    "id": "job id (see jobs_index.csv)", "job": "job id", "group": "job group: main (deployed architecture, 3 seeds), baseline (other "
    "architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported)",
    "task": "har = physical activity (11 classes), social = social signal (4 classes)", "model": "architecture id (harry_cnn, harry_rnn, "
    "harry_mlp, harry_feat; see architectures.csv)", "variant": "scoring scope: all = every test window of the fold; jan = only its "
    "datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows",
    "seed": "training seed (0, 1, 2)", "fold": "official fold 0–9 (the group members are in folds given by decisions.json)",
    "power": "social class-weight exponent (balanced^power); empty for activities", "class": "class name (model output order)",
    "recall": "share of the class's test windows predicted as that class (the marked accuracy)", "precision": "share of windows predicted "
    "as the class that truly are", "f1": "harmonic mean of precision and recall", "support": "test windows of the class",
    "predicted": "test windows predicted as the class", "static": "mean recall over the 5 static classes", "dynamic": "mean recall over "
    "the 6 dynamic classes", "social": "mean recall over the 4 social classes (balanced accuracy)", "social_min": "lowest of the 4 social "
    "recalls", "balanced_acc": "mean of the per-class recalls", "window_acc": "share of all test windows correct", "macro_f1": "mean F1 "
    "over classes", "macro_auc": "mean one-vs-rest ROC AUC", "recording_vote_acc": "share of test recordings whose majority window "
    "prediction is correct", "log_loss": "mean negative log probability of the true class", "ece": "expected calibration error (15 "
    "bins)", "mean_conf": "mean top probability", "n_test_windows": "test windows scored", "n_test_recordings": "test recordings scored",
    "mean": "mean over seeds of the fold-mean (the reported number)", "seed_std": "sd over seeds of the fold-mean", "fold_std": "sd over "
    "folds (seed 0)", "fold_min": "worst fold (seed 0)", "fold_max": "best fold (seed 0)", "ci95": "half-width of the 95 % t-interval over "
    "folds", "n_seeds": "seeds", "n_folds": "folds", "true": "true class", "pred": "predicted class", "count": "windows",
    "epoch": "epoch (1–32)", "stage": "train", "train_loss": "training loss (with augmentation, label smoothing, class weights)",
    "train_acc": "training accuracy", "test/loss": "held-out-fold loss (monitor only)", "test/acc": "held-out-fold accuracy (monitor "
    "only)", "test/score": "held-out-fold group score (HAR: mean of static and dynamic means; social: balanced)", "seconds": "wall time",
    "source": "datasetJan2026, a group member, or 'group members' (training)", "windows": "number of windows", "weight": "class weight "
    "applied in training (normalised to mean 1 over the training windows)", "test_set": "name of the test set inside the job (cv)",
    "person": "group member id", "postures": "all / lying / sitting/standing", "frac_correct": "share of the recording's windows correct",
    "vote_correct": "majority vote correct", "conf": "mean confidence", "r": "recording key (source:index)", "y": "true class index",
    "n": "windows", "file": "recording file name", "comparison": "A vs B", "scope": "scoring scope (as 'variant')", "metric": "compared "
    "metric", "mean_a": "mean of A over folds", "mean_b": "mean of B over folds", "mean_diff": "mean of A − B", "folds_a_better": "folds "
    "where A > B", "p_wilcoxon": "two-sided Wilcoxon signed-rank p over the paired folds", "params": "trainable + non-trainable "
    "parameters", "size_kb": "TFLite file size", "ms_per_window": "median single-window TFLite inference, 1 thread, development Mac",
    "ms_p90": "90th percentile of the same", "window": "input window (samples)", "parity_argmax_agreement": "share of group-recording "
    "windows where Keras and TFLite agree", "parity_max_abs_dprob": "largest probability difference Keras vs TFLite",
    "recordings": "number of recordings", "hours": "hours of data", "len_mean_s": "mean recording length", "len_min_s": "shortest",
    "len_max_s": "longest", "windows_test_step": "test windows at the 2 s step", "set": "listed (in the fold CSV) / unlisted",
    "activity": "class folder / activity", "candidate": "social window candidate", "cand": "social window candidate (w100 = 8 s, w75 = 6 s, "
    "w62 = 5 s, w50 = 4 s, w100rec = 8 s recency-trained)", "lat_s6": "seconds from a change until the new class is shown and kept 4 s "
    "(app replay, 0.5 s step)", "lat_s12": "same with a 1 s step", "miss_s6": "share of replays where the new class was never shown "
    "steadily", "steady_acc": "accuracy over the last 12 s after the change", "stream": "jan = pairs of fold-k test recordings; real = "
    "same-posture changes in the group members' recordings", "target": "class changed to",
}
TABLE_INFO = {
    "jobs_index": "one row per job: settings, status, time, parameters, training windows",
    "per_fold_class": "per job × scope × class: recall, precision, F1, support (recompute any marked number from here)",
    "fold_scores": "per job × scope: group scores and other metrics for that fold",
    "summary_per_class": "per experiment × scope × class: fold-mean over seeds (reported), spreads, CI",
    "summary_scores": "per experiment × scope: group scores, mean and sd over seeds (columns <metric>_mean / <metric>_std)",
    "confusion_long": "per job × scope (all, jan) × true × predicted: window counts",
    "calibration_bins": "deployed models, seed 0: accuracy and confidence per confidence bin",
    "recording_level": "deployed models, all windows: one row per test recording",
    "epochs": "per job × epoch: training and held-out monitoring curves",
    "stat_tests": "paired Wilcoxon tests over folds", "person_per_class": "each group member's own fold (unseen-person result), per class",
    "person_postures": "group members' social result split by posture (seed 0)", "deploy": "deployment cost per architecture and final models",
    "data_composition": "datasetJan2026 recordings per task, listed/unlisted, class", "fold_composition": "official folds: recordings per class and fold",
    "group_folds": "the group members' recordings / test windows per class and assigned fold",
    "duplicates_har_social": "static activity files that are byte copies of social recordings, with both folds",
    "real_data_quality": "group recordings: sampling rate, gaps, flat runs, clipping, gravity angle vs Jan2026 class mean, flags",
    "jan_gravity": "datasetJan2026 static recordings: mean gravity vector", "tsne": "2-D embedding of fold-0 test windows (deployed models)",
    "timing": "compute per job group", "fold_training_data": "per job × source × class: training windows actually used",
    "fold_test_data": "per job × source × class: test windows", "class_weights": "per job × class: the class weight applied",
    "recipes": "every training / evaluation setting", "architectures": "per architecture: window, parameters, size, speed, layer files",
    "social_window_study_summary": "the window study: per candidate class recalls and latency statistics",
    "social_window_study_streams": "the window study: one row per replayed change", "social_window_study_per_fold_recall": "the window "
    "study: per fold and candidate class recalls",
}


def data_dictionary(log):
    lines = ["# Data dictionary (tables/)\n", "Every CSV in this folder, what one row is, and what every column means. Percentages are "
             "stored as fractions (0–1) unless the column name says otherwise.\n"]
    for f in sorted(TAB.glob("*.csv")):
        d = _read(f)
        lines.append(f"## {f.name}\n\n{TABLE_INFO.get(f.stem, '')} — {len(d)} rows.\n")
        if d.empty:
            continue
        rows = []
        for c in d.columns:
            desc = COLS.get(c)
            if desc is None:
                if c in HAR_CLASSES or c in SOCIAL_CLASSES:
                    desc = f"value for class {c}"
                elif c.endswith("_mean") or c.endswith("_std"):
                    desc = f"{COLS.get(c.rsplit('_', 1)[0], c.rsplit('_', 1)[0])} – {'mean' if c.endswith('_mean') else 'sd'} over seeds"
                elif c.startswith("lat_") or c.startswith("miss_"):
                    desc = "window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream"
                else:
                    desc = ""
            ex = d[c].dropna().iloc[0] if d[c].notna().any() else ""
            rows.append({"column": f"`{c}`", "meaning": desc, "example": str(ex)[:40]})
        lines.append(_md(pd.DataFrame(rows)))
    for f in ["system.json", "data_facts.json"]:
        if (TAB / f).exists():
            lines.append(f"## {f}\n\n```json\n{(TAB / f).read_text()}\n```\n")
    (TAB / "README.md").write_text("\n".join(lines))
    log("knowledge: data dictionary written")


# ───────────────────────── KNOWLEDGE.md
def knowledge_md(log):
    dec = json.loads(C.DECISIONS.read_text()) if C.DECISIONS.exists() else {}
    ss, comp, gf = _read(TAB / "summary_scores.csv"), _read(TAB / "data_composition.csv"), _read(TAB / "group_folds.csv")
    spc, pp, arch = _read(TAB / "summary_per_class.csv"), _read(TAB / "person_per_class.csv"), _read(TAB / "architectures.csv")
    ftr, cw = _read(TAB / "fold_training_data.csv"), _read(TAB / "class_weights.csv")
    system = json.loads((TAB / "system.json").read_text()) if (TAB / "system.json").exists() else {}
    git = subprocess.run(["git", "-C", str(C.ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    L = []
    A = L.append

    def g(task, scope, met):
        d = ss[(ss.group == "main") & (ss.task == task) & (ss.variant == scope)] if not ss.empty else ss
        return d[f"{met}_mean"].iloc[0] if len(d) and f"{met}_mean" in d else np.nan

    A("# Project knowledge base — PDIoT Coursework 3, activity and social-signal models (Harry, s2503795)\n")
    A(f"_Generated {time.strftime('%Y-%m-%d %H:%M')} by `run_pipeline_v2.py` (stage 7). Repository commit {git or 'n/a'} (results "
      "produced from the working tree; the exact code is in `code/`). Read this file first; every number here comes from the tables in "
      "`tables/` (dictionary: `tables/README.md`); `WRITEUP.md` has the long-form report text and all figures; `MANIFEST.csv` lists every "
      "file._\n")

    A("## 1. The project in one page\n")
    A("- **Course:** Principles and Design of IoT Systems (PDIoT), University of Edinburgh, Coursework 3 (2026-27). Brief: "
      "`context/cw3_instructions.txt`. Group of two: Harry (s2503795, owns the models) and a teammate (s2952925, owns the app UI).\n"
      "- **Sensor:** RESpeck, a chest-worn tri-axial accelerometer, 12.5 Hz, values in g. It sends 32 samples per Bluetooth packet "
      "(one packet every 2.56 s).\n"
      "- **Task 1 – physical activity (11 classes):** sitting/standing (one class), lying on back / left / right / stomach (static); "
      "normal walking, shuffle walking, ascending stairs, descending stairs, running, miscellaneous movements (dynamic).\n"
      "- **Task 2 – social signals (4 classes), defined only while stationary:** breathing normally, coughing, hyperventilation, other "
      "(talking, eating, singing, laughing).\n"
      "- **Task 3 – app:** a Flutter app classifies both live on the phone (TensorFlow Lite), keeps a daily history, and is marked on "
      "responsiveness (results updating within 2 s score higher than within 10 s), features and UI.\n"
      "- **How the models are marked:** subject-wise 10-fold cross-validation with the official fold files (`folds_daily_activity.csv`, "
      "`folds_social_signal.csv`, per activity). Accuracy = per-class recall on the held-out fold, averaged over the 10 folds. Targets: "
      "static mean ≥ 90 % (6 marks), dynamic mean ≥ 85 % (9 marks), each social class ≥ 75 % (5 marks each). Missing a target still earns "
      "partial marks. The report may present improved offline results.\n"
      "- **Dates:** demo 18 Nov 2026; report (≤ 4,000 words) 15 Jan 2027; RESpeck devices returned after the demo.\n")

    A("## 2. Headline numbers (this run)\n")
    rows = []
    for task, met, lab, t in [("har", "static", "activity static mean", 0.90), ("har", "dynamic", "activity dynamic mean", 0.85),
                              ("social", "social", "social balanced", 0.75), ("social", "social_min", "weakest social class", 0.75)]:
        a, b = g(task, C.HEADLINE, met), g(task, "jan", met)
        rows.append({"metric": lab, "all test windows %": _pct(a), "as marked (Jan2026 windows) %": _pct(b), "target %": f"{t * 100:.0f}",
                     "meets target (marked)": "" if np.isnan(b) else ("yes" if b >= t else "no")})
    A(_md(pd.DataFrame(rows)))
    if not spc.empty:
        d = spc[(spc.group == "main") & (spc.variant.isin([C.HEADLINE, "jan"]))].pivot_table(index=["task", "class"], columns="variant", values="mean")
        d = (d * 100).round(1).reset_index()
        A("Per class (fold mean over 3 seeds, %):\n\n" + _md(d))
    if not pp.empty:
        d = pp.groupby(["task", "person"]).recall.mean().unstack()
        A("Each group member as an unseen test subject (their own fold; balanced accuracy %):\n\n" + _md((d * 100).round(1).reset_index()))

    A("## 3. Data — what exists and how every piece is used\n")
    if not comp.empty:
        d = comp.groupby(["task", "set"]).agg(recordings=("recordings", "sum"), hours=("hours", "sum")).reset_index().round(2)
        A("**datasetJan2026** (provided; one CSV per recording, columns include accelX/accelY/accelZ in g):\n\n" + _md(d))
    A("- *listed* = in the official fold CSV → used in cross-validation (train or test depending on the fold) and in the final models.\n"
      "- *unlisted* = on disk but not in the fold CSV (unknown subjects) → never in cross-validation (could leak a test subject into "
      "training); only in the final models.\n"
      "- All static daily-activity recordings are byte copies of social *breathing normally* recordings, so datasetJan2026 has no static "
      "activity data while coughing / hyperventilating / talking (see `tables/duplicates_har_social.csv`).\n")
    A("**Group recordings** (`IoT/data/s2503795/`, `IoT/data/s2952925/`, 44 CSVs each, recorded 5–6 Oct 2026 with the RESpeck and the "
      "app; file name `PDIOT_<uun>_<Activity>_<Sub>_<date>_<time>.csv`). Labels come from the file name:\n")
    A(_md(pd.DataFrame([{"file activity": k, "activity class": v, "posture (stationary)": ACTIVITY_TO_POSTURE.get(k, "– (moving)")}
                        for k, v in ACTIVITY_TO_HAR.items()])))
    A(_md(pd.DataFrame([{"file sub-activity": k, "social class (only if stationary)": v} for k, v in SUB_TO_SOCIAL.items()])))
    A(f"**How the group recordings are used:** each member is one extra subject in the cross-validation: "
      + ", ".join(f"{p} → fold {k}" for p, k in C.PERSON_FOLD.items())
      + " (the two smallest official folds). In that fold the member's recordings are test data; in the other nine folds they are "
      f"training data (windows every {C.REAL_TRAIN_STEP} samples, mixed with datasetJan2026"
      + ("" if C.HAR_RECIPE == "mixed" else "; for activities they are only test data because the activity check failed") + "). "
      "Activities use all 44 recordings of a member; social signals only the stationary ones (sitting, standing, lying × 7 "
      "sub-activities).\n")
    if not gf.empty:
        A(_md(gf.groupby(["task", "person", "fold"]).agg(recordings=("recordings", "sum"), test_windows=("windows_test_step", "sum")).reset_index()))
    if not ftr.empty:
        d = ftr[(ftr.group == "main") & (ftr.seed == 0)].groupby(["task", "fold", "source"]).windows.sum().unstack().fillna(0).astype(int)
        A("Training windows per fold (deployed models, seed 0; exact per class in `tables/fold_training_data.csv`, test windows in "
          "`tables/fold_test_data.csv`):\n\n" + _md(d.reset_index()))

    A("## 4. Windowing, preprocessing and models\n")
    A(f"- **Windows:** activity {C.W['har']} samples ({C.W['har'] / C.FS:g} s); social {C.W['social']} samples ({C.W['social'] / C.FS:g} s)"
      f"{' trained with recency splices' if C.SOCIAL_RECENCY else ''}. Training windows every 25 samples (datasetJan2026) / "
      f"{C.REAL_TRAIN_STEP} (group); test windows every 25 samples (2 s). Windows never cross recordings.\n"
      "- **Input:** raw x, y, z in g (no preprocessing outside the model); everything below is inside the TensorFlow graph and exported "
      "to TFLite with builtin ops only.\n"
      "- **Gravity** = per-axis mean over the window (posture). **Dynamic channels** (7) = x, y, z minus their means; |a| minus its mean; "
      "first differences of x, y, z. **Band power** = log mean power in fixed frequency bands via a Hann-tapered DFT matrix (activity: "
      "0.3–1, 1–1.5, 1.5–2, 2–2.5, 2.5–3.5, 3.5–6.26 Hz; social: 0.1–0.4, 0.4–0.8, 0.8–1.5, 1.5–3, 3–6.26 Hz) of the first 4 dynamic "
      "channels, plus log-std of all 7. Each branch is z-normalised with statistics from the fold's training windows only.\n"
      "- **Architectures** (all four share gravity branch → Dense, spectral branch → Dense 32, and the head Dropout 0.3 → Dense 64 → "
      "Dropout 0.3 → softmax): multi-branch **CNN** (4 Conv1D blocks with BatchNorm, dilation, global average + max pooling), "
      "**Conv-GRU** (Conv1D stem + GRU 48), **gravity-split MLP** (flattened dynamic channels → Dense 64 → Dense 64), **spectral-feature "
      "net** (no sequence branch). Full layer lists: `architectures/*.txt`.\n")
    if not arch.empty:
        A(_md(arch[["task", "name", "window_s", "params", "tflite_kb", "ms_per_window_mac_1thread", "deployed"]]))

    A("## 5. Training\n")
    A(_md(recipes_table()))
    if not cw.empty:
        d = cw[(cw.group == "main") & (cw.seed == 0)].groupby(["task", "class"]).weight.agg(["mean", "min", "max"]).round(3).reset_index()
        A("Class weights actually applied (deployed models, mean / min / max over the 10 folds; per fold in `tables/class_weights.csv`):\n\n" + _md(d))

    A("## 6. Cross-validation, testing and evaluation\n")
    A("1. For each fold k = 0…9 a model is trained **from scratch** on: datasetJan2026 listed recordings with fold ≠ k, plus the group "
      "member(s) whose assigned fold ≠ k. It is tested on: datasetJan2026 fold k plus the member assigned to fold k. A subject is never "
      "in both sets of a fold (official fold files; each member is one subject).\n"
      "2. Epochs are fixed (32); the test fold is evaluated after every epoch only to draw learning curves — it never stops or tunes "
      "training.\n"
      "3. Every test window gets a prediction (argmax of the softmax). Scores per fold: recall per class; static / dynamic / social "
      "means; plus precision, F1, macro AUC, recording-level majority vote, log-loss, calibration.\n"
      "4. The same predictions are scored in several **scopes**: *all* test windows (headline), *jan* = only datasetJan2026 windows "
      "(identical to how CW3 marks), each member's windows (= unseen-person result, from the single fold that member is in).\n"
      "5. Reported number = mean over the 10 folds (then over 3 seeds for the deployed models). Spread: sd over folds, sd over seeds, "
      "95 % t-interval over folds. Comparisons: paired Wilcoxon signed-rank over the 10 folds.\n"
      "6. **Final models** (the ones exported for the app) are trained once on everything: all datasetJan2026 recordings (listed + "
      "unlisted) + both members. They have no held-out test set of their own; their expected accuracy is the cross-validation result. "
      "Their Keras ↔ TFLite agreement is checked on the group recordings.\n")

    A("## 7. Decisions and the evidence behind them\n")
    sw = dec.get("social", {})
    hc = dec.get("har_check", {})
    A(_md(pd.DataFrame([
        {"decision": "Gravity-split, in-model preprocessing", "reason": "breathing moves the chest by ~0.007 g while gravity is 1 g; the "
         "original normalisation (÷ ~0.5 g) drowned the breathing signal (data audit 2026-11-02)", "evidence": "history §10"},
        {"decision": "Train on datasetJan2026, not only own recordings", "reason": "models trained only on Harry's recordings generalised "
         "poorly to other people (B9 folds: activity dynamic 54.5 %, social balanced 46.1 %)", "evidence": "history/lab3_b9_folds_mine.md"},
        {"decision": "Social class weights balanced^0.6", "reason": "fully balanced weights left 'other' at 73.0 % (below 75 %); 0.6 gave "
         "87.2/82.3/80.8/80.3 on the official folds", "evidence": "history/official_folds_*_report.md; §6.7 sweep in WRITEUP"},
        {"decision": "Group recordings mixed in, never fine-tuned on", "reason": "fine-tuning social on one person dropped the other member "
         "to 70.1 %; fine-tuning activities on both members dropped datasetJan2026 dynamic from 90.7 % to 84.8 % (p = 0.002); mixing kept "
         "both", "evidence": "history/v1_lopo_*.csv, v1_stat_tests.csv"},
        {"decision": "Group members as two extra fold subjects", "reason": "Harry's decision (2026-11-09): use all data for training, CV, "
         "testing and evaluation; each member is tested once by a model that never saw them", "evidence": "decisions.json"},
        {"decision": f"Activity recipe '{C.HAR_RECIPE}'", "reason": f"one check: mixed-in activity model, datasetJan2026 dynamic mean "
         f"{_pct(hc.get('jan_dynamic'))} % vs the 85 % rule", "evidence": "decisions.json (har_check)"},
        {"decision": f"Social window {C.W['social'] / C.FS:g} s ({sw.get('candidate', C.SOCIAL_CANDIDATE)})", "reason": "fastest candidate "
         f"with every class ≥ {C.MIN_CLASS_RULE * 100:.0f} % (target ≈ 4–4.5 s on screen = 2 s data transmission + 2 s detection). "
         + sw.get("note", ""), "evidence": "context/social_window_study_*, figures/real/social_window_choice"},
        {"decision": "Deployed architectures: CNN (activity), Conv-GRU (social)", "reason": "best of Harry's four on the folds (see "
         "WRITEUP §6.5 and tables/stat_tests.csv)", "evidence": "tables/summary_scores.csv (group baseline vs main)"},
        {"decision": "Social shown only while not moving (app)", "reason": "course feedback: social signals are only defined while "
         "stationary", "evidence": "app: lib/services/social_sample_processor.dart"},
        {"decision": "Only Harry's four architectures in v2", "reason": "Harry's decision (2026-11-09)", "evidence": "config.py"},
    ])))

    A("## 8. How the models are used in the app\n")
    A(f"- App: Flutter project copy at `{APP_DIR}` (not a git repository). Models are loaded from `assets/models/` "
      "(`harry_har_cnn.tflite`, `harry_social_rnn.tflite` + `_meta.json` + `_example.json`). **This run's models are exported only** "
      f"(`pipeline_v2/models/`, see `models/INSTALL.md`); the app still ships the models exported on 2026-11-03 "
      "(8 s social window, fine-tuned on s2503795).\n"
      "- Live logic: samples arrive in packets of 32 (2.56 s); both models classify the latest window every 6 samples (0.5 s, Settings: "
      "0.5/1/2 s); the activity shown is the majority of the last 3 results (smoothing, on by default); social results are paused while "
      "the shown activity is dynamic; history stores raw results with the interval they stand for; 'times coughed' counts coughing "
      "results < 5 s apart as one time and ignores a lone result.\n"
      "- Measured responsiveness (app replay on the group recordings, `history/app_latency_replay.csv`): activity about 4 s from a change "
      "to the screen after the 2026-11-09 smoothing fix (about 6 s before); social 6–7 s with the 8 s window.\n"
      "- On-phone tools for the report: Tools → Real-time test (per-class accuracy, first-correct and shown latency, CSV) and Latency test "
      "(cued changes timed on the phone, CSV); Performance tab (CPU, memory, battery, inference time, log with a conditions file).\n")

    A("## 9. Results — where to find each number\n")
    A(_md(pd.DataFrame([
        {"question": "marked accuracy per class / group", "answer in": "§2 here; WRITEUP §1, §6.1; tables/summary_per_class.csv (variant = jan)"},
        {"question": "accuracy including the group members' test windows", "answer in": "tables/summary_per_class.csv (variant = all)"},
        {"question": "per fold, per seed", "answer in": "tables/per_fold_class.csv, fold_scores.csv"},
        {"question": "how good on an unseen real person", "answer in": "tables/person_per_class.csv, person_postures.csv; WRITEUP §6.8"},
        {"question": "which classes are confused", "answer in": "tables/confusion_long.csv; figures/results/confusion_*; WRITEUP §6.3"},
        {"question": "how each architecture compares", "answer in": "tables/summary_scores.csv (group baseline); stat_tests.csv; WRITEUP §6.5"},
        {"question": "what data trained / tested fold k", "answer in": "tables/fold_training_data.csv, fold_test_data.csv; jobs/<id>.json (job.train, job.tests)"},
        {"question": "exact hyper-parameters and class weights", "answer in": "tables/recipes.csv, class_weights.csv; jobs/<id>.json (info.train_recipe)"},
        {"question": "learning curves / over-fitting", "answer in": "tables/epochs.csv; figures/training/"},
        {"question": "why this social window / speed", "answer in": "context/social_window_study_*; WRITEUP §6.6; figures/real/social_window_choice"},
        {"question": "effect of class weights", "answer in": "WRITEUP §6.7; tables/summary_per_class.csv (group sweep)"},
        {"question": "where are the trained / exported models", "answer in": "pipeline_v2/models/ (app files + INSTALL.md); results/jobs/models/ (per-fold Keras models, seed 0)"},
        {"question": "model size, speed, parity", "answer in": "tables/deploy.csv, architectures.csv; WRITEUP §6.9"},
        {"question": "data quality of the group recordings", "answer in": "tables/real_data_quality.csv; WRITEUP §2.2"},
        {"question": "earlier experiments and why choices changed", "answer in": "§10 here; history/"},
        {"question": "exact code", "answer in": "code/ (README inside)"},
        {"question": "compute, environment", "answer in": "tables/system.json, timing.csv, run.log"},
    ])))

    A("## 10. History (dated; Harry's models only)\n")
    A("- **2026-10-05/06** — both members record the CW2 protocol (44 recordings each).\n"
      "- **2026-11-02** — data audit: static activity files are copies of social breathing files; datasetJan2026 `N_x` names are "
      "recording indices, not subjects; breathing ≈ 0.007 g within a window → gravity-split, in-model preprocessing designed.\n"
      "- **2026-11-02/03** — first models trained on Harry's own recordings only generalise poorly to datasetJan2026 (Lab 3 B9 folds: "
      "activity dynamic 54.5 %, social balanced 46.1 %). Trained on datasetJan2026 instead (B9 folds: activity static 97.2 / dynamic "
      "90.9 %, social balanced 82.0 % on 2 folds) → `history/lab3_b9_folds_mine.md`.\n"
      "- **2026-11-03** — app models exported: `harry_har_cnn` and `harry_social_rnn` (8 s), datasetJan2026 pre-training + fine-tune on "
      "s2503795; app update interval made a setting.\n"
      "- **2026-11-09 (morning)** — official fold CSVs arrive. Official 10-fold CV, datasetJan2026 only, seed 0: activity CNN static 99.3 / "
      "dynamic 90.5 %; social Conv-GRU with balanced weights 90.3 / 85.5 / 82.7 / 73.0 % ('other' fails) → weights balanced^0.6: 87.2 / "
      "82.3 / 80.8 / 80.3 % (all pass) → `history/official_folds_*`.\n"
      "- **2026-11-09** — tests on the members (models trained on datasetJan2026 only): social 95.1 % (s2503795) / 89.6 % (s2952925) with "
      "^0.6; the shipped social model (fine-tuned on s2503795) only 76.7 % on s2952925 → no fine-tuning on one person. Activity "
      "98.5/98.2 % (s2503795) and 97.0/97.0 % (s2952925) static/dynamic; the datasetJan2026-only activity model calls 5–18 % of "
      "coughing/hyperventilation windows 'moving' → `history/real_people_*`.\n"
      "- **2026-11-09** — v1 report pipeline (`final_run/`): activity datasetJan2026-only 99.3 / 90.7 % vs fine-tuned on the members "
      "99.0 / 84.8 % (dynamic −5.9 points, worse in all 10 folds, p = 0.002); social datasetJan2026 only 82.6 % vs members mixed in 82.7 %; "
      "leave-one-person-out with mixing best for both tasks; class-weight sweep confirms 0.6 → `history/v1_*.csv`.\n"
      "- **2026-11-09** — app analysis: 32-sample packets (2.56 s) set the update floor; a smoothing bug (one result per packet) cost "
      "~2 s; fixed, default step 0.5 s; social paused while moving → `history/app_latency_replay.csv`.\n"
      f"- **2026-11-09** — social window study (4/5/6/8 s, 8 s recency) → chosen {sw.get('candidate', C.SOCIAL_CANDIDATE)} → "
      "`history/social_window_study_report.md`.\n"
      "- **2026-11-09 (night)** — v2 (this run): only Harry's four architectures; one data split (members as fold subjects, mixed); "
      "export only.\n")

    A("## 11. Caveats an answer should mention\n")
    A("- The group members are two people; their per-person results come from one fold each.\n"
      "- Hyper-parameters (epochs, learning rate) were fixed from earlier experiments; the class-weight power and the social window were "
      "chosen using results on the official folds — the sweep and the window study are shown as sensitivity analyses.\n"
      "- The headline scope includes the group members' windows (a fold with a member has more test windows); the marked scope excludes "
      "them, so the two differ slightly.\n"
      "- Window-level results are correlated within a recording; statistics are therefore over folds.\n"
      "- Live accuracy, latency, CPU, memory and battery on the phone must be measured with the app (Tools / Performance tabs); this "
      "folder only contains offline results and replays.\n")
    A("## 12. Glossary\n")
    A("- **window**: a fixed-length slice of the signal the model classifies. **step**: samples between consecutive windows. **fold**: "
      "one of 10 groups of subjects; *fold k* = trained without them, tested on them. **recall**: share of a class's windows recognised. "
      "**balanced accuracy**: mean recall over classes. **scope**: which test windows a score counts. **seed**: random initialisation / "
      "augmentation / batch order. **gate / pause**: app rule that hides social results while moving. **recency training**: splicing the "
      "start of another window onto a training window so the label follows the most recent seconds.\n")
    (OUT / "KNOWLEDGE.md").write_text("\n".join(L), encoding="utf-8")
    log(f"knowledge: KNOWLEDGE.md ({sum(len(x.split()) for x in L)} words)")


def manifest(log):
    desc = [("KNOWLEDGE.md", "start here: the whole project explained, decisions, history, question → file map"),
            ("WRITEUP.md", "long-form report text with every number and figure"), ("index.html", "figure gallery with captions"),
            ("run.log", "pipeline log"), ("plan.json", "every job and its data / tests"), ("decisions.json", "frozen decisions"),
            ("tables/README.md", "data dictionary"), ("tables/", "results and data tables (see tables/README.md)"),
            ("figures/", "figures (PNG + PDF); captions in figures/catalogue.json"), ("architectures/", "layer-by-layer model summaries"),
            ("jobs/models/", "trained Keras models (seed 0 of the deployed architectures, final models)"),
            ("jobs/", "per job: <id>.json settings + history + info, <id>.npz test predictions, <id>.log training log"),
            ("../models/", "exported app models (.tflite, _meta.json, _example.json, .keras, INSTALL.md) — outside results/"),
            ("history/", "earlier experiments (Harry's models only)"), ("context/", "CW3 brief text, window study, decisions"),
            ("code/", "the code that produced this folder")]
    rows = []
    for f in sorted(OUT.rglob("*")):
        if f.is_dir():
            continue
        rel = f.relative_to(OUT).as_posix()
        if rel.startswith("jobs/") and not rel.startswith("jobs/models/") and rel.endswith((".npz", ".log")):
            continue                                        # thousands of files; described by the jobs/ row
        what = next((d for p, d in desc if rel == p or (p.endswith("/") and rel.startswith(p))), "")
        rows.append({"file": rel, "bytes": f.stat().st_size, "what": what})
    rows.append({"file": "jobs/<id>.npz, jobs/<id>.log", "bytes": "", "what": "per-job test predictions (cv__P probabilities, cv__y labels, "
                 "cv__rid recording index, cv__src source set, cv__person 'jan' or member id) and training logs"})
    pd.DataFrame(rows).to_csv(OUT / "MANIFEST.csv", index=False)
    log(f"knowledge: MANIFEST.csv ({len(rows)} entries)")


def run(log):
    TAB.mkdir(parents=True, exist_ok=True)
    for fn in (job_tables, history, context, code_snapshot, knowledge_md, data_dictionary, manifest):
        try:
            fn(log)
        except Exception as e:                                      # noqa: BLE001
            import traceback
            log(f"knowledge step {fn.__name__} failed: {e!r}\n{traceback.format_exc()}")
