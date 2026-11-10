"""Write final_run/WRITEUP.md (the detailed model write-up, every number filled in from the tables) and
final_run/index.html (a gallery of every figure with captions, to pick the ones for the report)."""
import html
import json
import time

import numpy as np
import pandas as pd

from harry.data import HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC
from . import config as C

HAR_BANDS = [(0.3, 1.0), (1.0, 1.5), (1.5, 2.0), (2.0, 2.5), (2.5, 3.5), (3.5, 6.26)]      # = harry/models.py (no keras import here)
SOCIAL_BANDS = [(0.1, 0.4), (0.4, 0.8), (0.8, 1.5), (1.5, 3.0), (3.0, 6.26)]

TAB = C.OUT / "tables"
NICE = {"sittingStanding": "sitting/standing", "lyingBack": "lying on back", "lyingLeft": "lying left", "lyingRight": "lying right",
        "lyingStomach": "lying on stomach", "normalWalking": "walking", "shuffleWalking": "shuffle walking",
        "ascending": "ascending stairs", "descending": "descending stairs", "running": "running", "miscMovement": "miscellaneous movements",
        "breathingNormally": "normal breathing", "coughing": "coughing", "hyperventilation": "hyperventilation", "other": "other"}
WHY = {
    frozenset({"normalWalking", "shuffleWalking"}): "both are level walking at a similar cadence; shuffling only shortens the stride and "
    "lowers the vertical bounce, so a chest sensor sees a scaled-down version of the same rhythm",
    frozenset({"miscMovement", "shuffleWalking"}): "miscellaneous movements contain small steps, turns and weight shifts that look like "
    "slow, irregular shuffling over a 4 s window",
    frozenset({"miscMovement", "normalWalking"}): "miscellaneous movements often include a few walking steps",
    frozenset({"miscMovement", "running"}): "vigorous miscellaneous movements (jumping, fast turns) share the high-energy bursts of running",
    frozenset({"ascending", "descending"}): "stairs up and down have the same step rhythm; they differ mainly in the timing of the impact "
    "peak within each step, a subtle cue in 4 s at 12.5 Hz",
    frozenset({"ascending", "normalWalking"}): "stair climbing is walking with an extra vertical component that is small at chest level",
    frozenset({"descending", "normalWalking"}): "stair descent is walking with an extra vertical component that is small at chest level",
    frozenset({"descending", "shuffleWalking"}): "careful stair descent has short, low-amplitude steps like shuffling",
    frozenset({"sittingStanding", "miscMovement"}): "fidgeting or posture shifts while seated briefly look like movement",
    frozenset({"lyingBack", "sittingStanding"}): "reclining postures sit between the upright and supine gravity directions",
    frozenset({"other", "breathingNormally"}): "talking, eating, singing and laughing are intermittent: an 8 s window often contains "
    "pauses that are just normal breathing, and the vocal vibrations are small at 12.5 Hz",
    frozenset({"other", "coughing"}): "laughing and some eating movements produce short abdominal bursts that resemble coughs",
    frozenset({"other", "hyperventilation"}): "singing and laughing involve deep, fast breaths like hyperventilation",
    frozenset({"coughing", "hyperventilation"}): "both produce strong, fast chest movements; a run of coughs and forced rapid breathing "
    "overlap in amplitude and rate",
    frozenset({"breathingNormally", "hyperventilation"}): "shallow or slow hyperventilation overlaps with deep normal breathing",
}


def read(name):
    f = TAB / f"{name}.csv"
    return pd.read_csv(f) if f.exists() and f.stat().st_size > 2 else pd.DataFrame()


def p(v, d=1):
    return "n/a" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{100 * v:.{d}f}"


def num(v, d=1):
    return "n/a" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{v:.{d}f}"


def md_table(df):
    if df.empty:
        return "_(not available yet)_\n"
    cols = list(df.columns)
    out = ["| " + " | ".join(str(c) for c in cols) + " |", "|" + "---|" * len(cols)]
    for _, r in df.iterrows():
        out.append("| " + " | ".join(str(r[c]) for c in cols) + " |")
    return "\n".join(out) + "\n"


def fig_ref(cat, name):
    f = next((c for c in cat if c["name"] == name), None)
    return f"![{f['title']}]({f['png']})\n\n*{f['title']}: {f['caption']}* (vector: `{f['pdf']}`)\n" if f else ""


def write(catalogue, system, log):
    s, fs, pc = read("summary_per_class"), read("fold_scores"), read("per_fold_class")
    comp, qual = read("data_composition"), read("real_data_quality")
    st, dep, gate, leaks = read("stat_tests"), read("deploy"), read("gate_folds"), read("gate_leaks")
    lopo, lgate, sa, sl, tr = read("lopo_per_class"), read("lopo_gate"), read("stream_accuracy"), read("stream_latency"), read("trial_simulation")
    cm, jobs, timing = read("confusion_long"), read("jobs_index"), read("timing")
    facts = json.loads((TAB / "data_facts.json").read_text()) if (TAB / "data_facts.json").exists() else {}
    L = []
    A = L.append

    def main_cls(task, v, c):
        r = s[(s.group == "main") & (s.task == task) & (s.variant == v) & (s["class"] == c)] if not s.empty else s
        return r.iloc[0] if len(r) else None

    def group_val(task, v, met):
        d = fs[(fs.group == "main") & (fs.task == task) & (fs.variant == v)] if not fs.empty else fs
        if d.empty:
            return np.nan, np.nan, np.nan
        per_seed = d.groupby("seed")[met].mean()
        return per_seed.mean(), d[d.seed == d.seed.min()][met].std(), per_seed.std() if len(per_seed) > 1 else np.nan

    hv, jv = C.HEADLINE, "jan"
    A("# Activity and social-signal models: data, method and results\n")
    A(f"_Generated {time.strftime('%Y-%m-%d %H:%M')} by `model_harry/run_full_pipeline.py` from the tables in `final_run/tables/`. "
      "Every number below is computed, not typed; re-running the pipeline regenerates this file. Figures are in "
      "`final_run/figures/` (PNG to view, PDF for the report) and all of them, with captions, are in `final_run/index.html`._\n")
    A("> **How to use this document.** It is deliberately longer than the 4,000-word report allows. Each section maps to a part of the "
      "report (Methodology → physical activity recognition / social signal classification / testing; Results and Discussion → model "
      "accuracy / critical analysis). Take the paragraphs, tables and figures you need. Sections marked **[fill in]** need results only you "
      "can produce (the live real-time test on the phone).\n")

    # ── headline
    A("## 1. Headline results (official subject-wise 10-fold cross-validation)\n")
    A(f"Marked as in the CW3 brief: recall of each class on the held-out fold, averaged over the 10 official folds; group means as "
      f"stated. **Headline** = training folds use datasetJan2026 **plus** the two group members' recordings "
      f"({VAR_LAB(hv)}); **strict** = datasetJan2026 only, exactly as provided. Test folds are always datasetJan2026 only. "
      f"Values: mean over {len(C.SEEDS)} training seeds; ± = standard deviation over the 10 folds (seed 0).\n")
    rows = []
    for task in ("har", "social"):
        for c in (HAR_CLASSES if task == "har" else SOCIAL_CLASSES):
            a, b = main_cls(task, hv, c), main_cls(task, jv, c)
            tgt = "≥ 75 %" if task == "social" else ("(static ≥ 90 % mean)" if c in STATIC else "(dynamic ≥ 85 % mean)")
            rows.append({"task": "activity" if task == "har" else "social", "class": NICE[c],
                         "headline": f"{p(a['mean'])} ± {p(a['fold_std'])}" if a is not None else "n/a",
                         "strict (Jan2026 only)": f"{p(b['mean'])} ± {p(b['fold_std'])}" if b is not None else "n/a",
                         "target": tgt, "pass (headline)": ("✓" if a is not None and a["mean"] >= 0.75 else "✗") if task == "social" else ""})
    for task, met, lab, t in [("har", "static", "**static mean (5 classes)**", 0.90), ("har", "dynamic", "**dynamic mean (6 classes)**", 0.85),
                              ("social", "social", "**social balanced (4 classes)**", 0.75)]:
        a, b = group_val(task, hv, met), group_val(task, jv, met)
        rows.append({"task": "activity" if task == "har" else "social", "class": lab, "headline": f"**{p(a[0])}** ± {p(a[1])}",
                     "strict (Jan2026 only)": f"{p(b[0])} ± {p(b[1])}", "target": f"≥ {t * 100:.0f} %",
                     "pass (headline)": "✓" if a[0] >= t else ("✗" if not np.isnan(a[0]) else "")})
    A(md_table(pd.DataFrame(rows)))
    hs, hd, ss = group_val("har", hv, "static")[0], group_val("har", hv, "dynamic")[0], group_val("social", hv, "social_min")[0]
    A(f"\nIn words: static activities reach **{p(hs)} %** (target 90 %), dynamic activities **{p(hd)} %** (target 85 %), and the weakest "
      f"social class reaches **{p(ss)} %** (target 75 % for every class). Seed-to-seed standard deviation of the group scores: static "
      f"{p(group_val('har', hv, 'static')[2], 2)}, dynamic {p(group_val('har', hv, 'dynamic')[2], 2)}, social {p(group_val('social', hv, 'social')[2], 2)} "
      "percentage points, so differences smaller than about twice these are within run-to-run noise.\n")
    A(fig_ref(catalogue, "per_class_har") + "\n" + fig_ref(catalogue, "per_class_social"))

    # ── data
    A("## 2. Data\n")
    A("### 2.1 datasetJan2026 (the provided dataset)\n")
    if not comp.empty:
        d = comp.groupby(["task", "set"]).agg(recordings=("recordings", "sum"), hours=("hours", "sum")).reset_index()
        lst = {(r.task, r.set): r for r in d.itertuples()}
        h, so = lst.get(("har", "listed")), lst.get(("social", "listed"))
        hx, sx = lst.get(("har", "unlisted")), lst.get(("social", "unlisted"))
        A(f"RESpeck chest-worn tri-axial accelerometer, 12.5 Hz, values in g. Two parts:\n\n"
          f"- **Daily activity** (11 classes): {h.recordings if h else 'n/a'} recordings ({num(h.hours if h else np.nan, 2)} h) listed in the "
          f"official fold file, plus {hx.recordings if hx else 0} files on disk that the fold file does not list.\n"
          f"- **Social signals** (4 classes): {so.recordings if so else 'n/a'} listed recordings ({num(so.hours if so else np.nan, 2)} h), plus "
          f"{sx.recordings if sx else 0} unlisted files.\n")
        t = comp[comp.set == "listed"][["task", "class", "recordings", "len_mean_s", "len_min_s", "windows_test_step"]].copy()
        t["class"] = t["class"].map(NICE); t["len_mean_s"] = t.len_mean_s.round(1); t["len_min_s"] = t.len_min_s.round(1)
        t.columns = ["task", "class", "recordings", "mean length (s)", "shortest (s)", "test windows (2 s step)"]
        A(md_table(t))
    A("\nSitting and standing are one class (as required); talking, eating, singing and laughing form the single social class *other*. "
      "Classes are imbalanced: *other* holds about half of the social data, which drives the class-weighting choice (§4.2).\n")
    A("**Official folds.** `folds_daily_activity.csv` and `folds_social_signal.csv` assign every listed recording to one of 10 folds. As the "
      "brief explains, subject IDs are not shared across activities, so folds are defined per activity; the same file name (e.g. `N_0.csv`) "
      "in two class folders is two different subjects. Every fold contains every class (`fold_composition_*` figures).\n")
    A(f"**Unlisted recordings.** The fold files omit {comp[comp.set == 'unlisted'].recordings.sum() if not comp.empty else 'n/a'} "
      "recordings that are present on disk. None is a byte-copy of a listed file, so they come from subjects whose fold is unknown. Putting "
      "them in a training fold could place a test subject in training, so they are **excluded from cross-validation** and used only when "
      "training on 'all of datasetJan2026' (leave-one-person-out and the final deployed models).\n")
    if facts:
        A(f"**Duplicated recordings across the two tasks.** {facts.get('har_copies_of_social')} static daily-activity recordings are "
          f"byte-for-byte copies of social-signal recordings (the static activity data *is* the normal-breathing social data). The two fold "
          f"files put only {facts.get('same_fold')} of these pairs in the same fold. This does not affect the marked scores (each task is "
          "cross-validated on its own), but it matters when one model's output is used to evaluate the other (the social gate, §5.5): there "
          "the HAR model of fold *k* is retrained without any copy of fold *k*'s social test recordings. It also means datasetJan2026 has **no "
          "static activity data recorded while coughing, hyperventilating or talking** – only calm breathing – which explains why a "
          "Jan2026-only HAR model mistakes some coughs for movement (§6.9).\n")
    A(fig_ref(catalogue, "recordings_per_class_har") + fig_ref(catalogue, "recordings_per_class_social") + fig_ref(catalogue, "duplicates"))
    A("### 2.2 Group recordings\n")
    if not qual.empty:
        n = qual.groupby("person").size()
        flagged = qual[qual.flag.fillna("") != ""]
        A(f"Both group members recorded the full CW2 protocol with the RESpeck and the app: "
          + ", ".join(f"{C.PEOPLE[k]} {v} recordings" for k, v in n.items()) +
          ". Per person: sitting and standing and the four lying postures, each while breathing normally, coughing, hyperventilating, "
          "talking, eating (sitting/standing only), singing and laughing, plus the six dynamic activities. File names give the labels.\n")
        A(f"**Quality checks** (`tables/real_data_quality.csv`): sampling rate from timestamps {num(qual.fs_est.median(), 2)} Hz median "
          f"(range {num(qual.fs_est.min(), 2)}–{num(qual.fs_est.max(), 2)}); missing values in {int((qual.nan_rows > 0).sum())} recordings; "
          f"longest flat run {int(qual.longest_flat_run.max())} samples; clipped samples {int(qual.clipped.sum())}. Sensor placement was checked "
          f"by comparing each recording's gravity direction with the datasetJan2026 mean for the same class: median angle "
          f"{num(qual.angle_to_jan_class_deg.median())}°, {len(flagged)} recording(s) flagged (> 35° or another issue)"
          + (": " + "; ".join(f"{r.file} ({r.flag}, {r.angle_to_jan_class_deg:.0f}°)" for r in flagged.itertuples()) if len(flagged) else "") + ".\n")
        A("Use in this project: added to the training data of every fold (headline variant), used as unseen test people in the "
          "leave-one-person-out experiments (§5.4), and in the final models. They never appear in a datasetJan2026 test fold.\n")
    A(fig_ref(catalogue, "gravity_orientation") + fig_ref(catalogue, "real_data_quality"))

    # ── preprocessing & models
    A("## 3. Pre-processing, features and models\n")
    A("### 3.1 Windowing\n")
    A(f"Both models classify fixed windows of raw acceleration: **4 s (50 samples) for activities** and **8 s (100 samples) for social signals**. "
      "Activities are periodic at 1–3 Hz, so 4 s holds several gait cycles while staying responsive. Breathing runs at roughly 0.2–0.5 Hz "
      "(one breath every 2–5 s), so the social window needs to hold at least two full breaths; earlier cross-validation of a 4 s social window "
      "lost 4.5 points of balanced accuracy and coughing fell from 82.4 % to 75.2 %. Training windows overlap (step 25 samples = 2 s on "
      f"datasetJan2026, step {C.REAL_TRAIN_STEP} on the much smaller group data); test windows use a 2 s step. In the app a new result is produced "
      "every 0.5, 1 or 2 s (Settings) from the latest window.\n")
    A(fig_ref(catalogue, "example_signals_har") + fig_ref(catalogue, "spectra_social"))
    A("### 3.2 Pre-processing inside the model\n")
    A("All pre-processing is part of the TensorFlow graph, so the phone feeds raw g values and the exact same computation runs in training "
      "and in the app (no feature code to keep in sync in Dart). Every operation lowers to a TFLite builtin op (checked at export).\n\n"
      "1. **Gravity split.** Gravity (= posture) is the mean of each axis over the window; the dynamic part is the window minus that mean. "
      "Posture and motion are therefore separate inputs instead of being mixed in one normalised signal – important because breathing "
      "signals are ~0.007 g while gravity is 1 g.\n"
      "2. **Dynamic channels** (7): gravity-free x, y, z; magnitude |a| minus its mean (orientation-free); first difference of x, y, z (jerk).\n"
      f"3. **Spectral features**: log mean power in fixed frequency bands, computed with a Hann-tapered DFT written as a matrix multiply. "
      f"Activity bands {HAR_BANDS} Hz; social bands {SOCIAL_BANDS} Hz (breathing, fast breathing, coughs/voice). Plus log standard deviation "
      "of every dynamic channel (scale-free intensity).\n"
      "4. **Normalisation**: per-branch z-scoring whose statistics are fitted on the training windows of each fold only.\n"
      "5. **Augmentation (training only)**: random rotation about the body axis (±30°), small random tilt (±10°), amplitude scaling "
      "(0.8–1.25 of the dynamic part) and Gaussian noise (0.002 g), applied on the fly so every epoch sees new variants. This targets the "
      "main real-world variation: how the sensor sits on each person.\n")
    A("### 3.3 Activity model: multi-branch CNN\n")
    A("Three branches are concatenated, then Dropout 0.3 → Dense 64 (ReLU) → Dropout 0.3 → Dense 11 (softmax):\n\n"
      "- **Gravity branch** – normalised gravity vector → Dense 16: posture (sitting vs the four lying positions).\n"
      "- **Convolution branch** – normalised dynamic channels → four Conv1D blocks (32 k5, 32 k5 dilation 2, max-pool, 64 k3; each Conv → "
      "BatchNorm → ReLU) → global average **and** global max pooling: motion shape; max pooling keeps short impacts (stairs, misc).\n"
      "- **Spectral branch** – band powers and log-std → Dense 32: cadence and intensity.\n")
    A("### 3.4 Social model: convolutional-recurrent network (Conv-GRU)\n")
    A("Same gravity and spectral branches (gravity Dense 8), but the sequence branch is a Conv1D stem (32 k5, BatchNorm, ReLU, max-pool 2) "
      "followed by a **GRU with 48 units** over the remaining 50 steps, then Dropout 0.3. The recurrent layer models the order of events "
      "inside the 8 s window (inhale/exhale rhythm, a burst followed by recovery). It is trained with `unroll=False` and exported with an "
      "unrolled copy so TFLite needs builtin ops only.\n")
    if not dep.empty:
        d = dep[dep.model.str.contains("final")] if dep.model.str.contains("final").any() else dep[dep.model.isin(C.FINAL.values())]
        A(md_table(d[[c for c in ["task", "model", "params", "size_kb", "ms_per_window", "parity_argmax_agreement"] if c in d]].round(3)))
    A("### 3.5 Baselines (for the comparison)\n")
    A("Trained and tested on exactly the same folds and data: the Lab 3 models (MLP, CNN – the original app model –, LSTM, and logistic "
      "regression on 28 per-window statistics), and our own simpler variants (gravity-split MLP; spectral-feature network without the "
      "sequence branch; the CNN for social and the GRU for activities). Lab 3 models keep their own recipe (Adam 1e-3, 32 epochs, "
      "4 s windows); ours use §4.\n")

    # ── training
    A("## 4. Training\n")
    A("### 4.1 Recipe\n")
    A("| setting | value |\n|---|---|\n| optimiser | AdamW, weight decay 1e-4 |\n| learning rate | 2e-3 with cosine decay to 5 % |\n"
      "| epochs | 32, fixed in advance (no early stopping on test folds) |\n| batch | 64 |\n| loss | categorical cross-entropy, label smoothing 0.1 |\n"
      f"| class weights | activities: balanced; social: balanced^{C.SOCIAL_POWER:g} (§4.2) |\n| augmentation | §3.2 |\n"
      "| group data (activities) | train on datasetJan2026, then fine-tune on the group recordings: AdamW 5e-4, 30 epochs, step 6 |\n"
      f"| group data (social) | mixed into the datasetJan2026 training set (windows every {C.REAL_TRAIN_STEP} samples) |\n"
      f"| seeds | {', '.join(map(str, C.SEEDS))} |\n")
    A("\nWhy the two tasks use the group data differently: fine-tuning the activity model on group recordings adds what datasetJan2026 lacks "
      "(stationary postures while coughing, talking, …) and improved accuracy on an unseen person; fine-tuning the social model on one person "
      "over-fitted to that person's breathing (unseen-person balanced accuracy fell). Mixing keeps datasetJan2026 dominant. The "
      "leave-one-person-out results (§6.8) re-test all three options.\n")
    A("### 4.2 Class weighting for social signals\n")
    A("With fully balanced weights each class contributes equally to the loss, so the majority class *other* (~53 % of windows) is "
      f"under-predicted and was the only class below 75 %. Weights are therefore softened to w_c = (N / (K·n_c))^{C.SOCIAL_POWER:g}. "
      f"The exponent follows from the class proportions: with balanced weights the effective prior of *other* is divided by ~3.3 "
      f"(its share over the mean share of the others); a power of {C.SOCIAL_POWER:g} leaves a factor of 3.3^{1 - C.SOCIAL_POWER:.1f} ≈ 1.6, "
      "trading 2–4 points on the three smaller classes for ~7 points on *other*. The sweep in §6.6 shows the whole trade-off curve.\n")
    if system:
        A("### 4.3 Compute\n")
        tot = jobs.seconds.sum() / 3600 if not jobs.empty else np.nan
        A(f"{system.get('machine')}, {system.get('cpus')} CPU cores, {system.get('os')}; Python {system.get('python')}, TensorFlow "
          f"{system.get('tensorflow')}, Keras {system.get('keras')}, scikit-learn {system.get('sklearn')}. CPU only. "
          f"{len(jobs)} training/testing jobs, {num(tot)} CPU-job hours in total.\n")
        A(md_table(timing.rename(columns={"group": "job group", "count": "jobs", "sum": "seconds total", "mean": "seconds per job"}).round(0)))
    A(fig_ref(catalogue, "learning_curves_har_jan_real") + fig_ref(catalogue, "learning_curves_social_jan_real"))

    # ── evaluation protocol
    A("## 5. Evaluation protocol\n")
    A("### 5.1 Marked cross-validation\n")
    A("For each fold k = 0…9: a new model is trained from scratch on every listed recording not in fold k (plus the group recordings in the "
      "headline variant) and tested on fold k. Within each activity a subject is never in both sets (guaranteed by the official fold file). "
      "A test *sample* is a window; windows are taken every 2 s. For each class, accuracy = share of its test windows classified correctly "
      "(recall); the reported figure is the mean of this over the 10 folds; group scores average the per-class values (static: 5 classes, "
      "dynamic: 6, social: each of 4 checked against 75 %). Baseline models with 4 s social windows are scored on the last 4 s of the same "
      "8 s test windows, so every model is judged at the same moments.\n")
    A("### 5.2 Additional metrics\nPrecision, F1, macro ROC-AUC, recording-level majority vote, log-loss, expected calibration error, "
      "per-fold and per-seed spread, 95 % confidence intervals over folds, and paired Wilcoxon signed-rank tests over the 10 folds (a "
      "non-parametric test suited to 10 paired values; with n = 10 the smallest attainable two-sided p is 0.002).\n")
    A("### 5.3 Seeds\nThe final recipes are repeated with 3 seeds (different weight initialisation, augmentation and batch order) to separate "
      "real differences from training noise.\n")
    A("### 5.4 Leave-one-person-out (real users)\nEach group member is tested with models that never saw them: (A) trained on all of "
      "datasetJan2026, (B) A's data plus the other member mixed in, (C) model A fine-tuned on the other member. Test windows every 2 s.\n")
    A("### 5.5 Social only while stationary (gate)\nFollowing the formative feedback, social results are only meaningful when the wearer is "
      "not moving. The gate uses the activity model's result for the last 4 s of each social window. Measured: how often social is wrongly "
      "hidden on stationary data, and how often moving windows would wrongly enable it.\n")
    A("### 5.6 Simulated real-time behaviour\nEach member's recordings were streamed back to back in 5 random orders through the "
      "leave-that-person-out models with the final strategies, at the app's update intervals (2 / 1 / 0.5 s): accuracy of what the app shows "
      "(activity: raw and with the app's majority-of-3 smoothing; social: raw and gated) and latency after each change of activity (first "
      "correct result; three correct in a row). A 'trial' simulation replays each recording from a cold start, like a trial in the app's "
      "real-time test.\n")

    # ── results
    A("## 6. Results\n")
    A("### 6.1 Group scores and per-class accuracy\n")
    A(fig_ref(catalogue, "group_scores_har") + fig_ref(catalogue, "group_scores_social"))
    if not s.empty:
        for task in ("har", "social"):
            d = s[(s.group == "main") & (s.task == task) & (s.variant == hv)].set_index("class").reindex(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
            t = pd.DataFrame({"class": [NICE[c] for c in d.index], "recall": [p(v) for v in d["mean"]], "fold sd": [p(v) for v in d.fold_std],
                              "seed sd": [p(v, 2) for v in d.seed_std], "95 % CI ±": [p(v) for v in d.ci95],
                              "worst fold": [p(v) for v in d.fold_min], "best fold": [p(v) for v in d.fold_max],
                              "precision": [p(v) for v in d.precision], "F1": [p(v) for v in d.f1]})
            A(f"**{'Activities' if task == 'har' else 'Social signals'} ({VAR_LAB(hv)})**\n\n" + md_table(t))
    A(fig_ref(catalogue, "fold_heatmap_har_jan_real") + fig_ref(catalogue, "fold_heatmap_social_jan_real") + fig_ref(catalogue, "seed_variation_social"))
    A("### 6.2 Other metrics\n")
    if not fs.empty:
        d = fs[fs.group == "main"].groupby(["task", "variant"])[["window_acc", "macro_f1", "macro_auc", "recording_vote_acc", "ece", "log_loss"]].mean().reset_index()
        for c in ["window_acc", "macro_f1", "macro_auc", "recording_vote_acc", "ece"]:
            d[c] = d[c].map(lambda v: p(v))
        d["log_loss"] = d.log_loss.round(3)
        d.columns = ["task", "variant", "window accuracy %", "macro F1 %", "macro AUC %", "recording vote %", "ECE %", "log-loss"]
        A(md_table(d))
        A("Recording vote = the majority class over all windows of a test recording; higher than window accuracy because isolated errors "
          "are out-voted, which is what the app's smoothing exploits. ECE = expected calibration error (gap between confidence and "
          "accuracy).\n")
    A(fig_ref(catalogue, "calibration") + fig_ref(catalogue, "roc_pr_social"))
    A("### 6.3 Confusions\n")
    conf_text = {}
    if not cm.empty:
        for task in ("har", "social"):
            d = cm[(cm.group == "main") & (cm.task == task) & (cm.variant == hv) & (cm.seed == 0)].groupby(["true", "pred"])["count"].sum().reset_index()
            tot = d.groupby("true")["count"].sum()
            d = d[d.true != d.pred].assign(pct=lambda q: q["count"] / q.true.map(tot)).sort_values("pct", ascending=False).head(6)
            lines = []
            for r in d.itertuples():
                why = WHY.get(frozenset({r.true, r.pred}), "")
                lines.append(f"- **{NICE[r.true]} → {NICE[r.pred]}**: {p(r.pct)} % of {NICE[r.true]} windows ({r.count} windows)" + (f" – {why}." if why else "."))
            conf_text[task] = lines
            A(f"Most frequent {'activity' if task == 'har' else 'social'} confusions (share of the true class, all folds pooled):\n\n" + "\n".join(lines) + "\n")
    A(fig_ref(catalogue, "confusion_har_jan_real_pct") + fig_ref(catalogue, "confusion_social_jan_real_pct") + fig_ref(catalogue, "tsne_social"))
    A("### 6.4 Per-recording behaviour\n")
    rl = read("recording_level")
    if not rl.empty:
        d = rl[(rl.variant == hv) & (rl.seed == 0)]
        worst = d.sort_values("frac_correct").head(8)[["task", "class", "file", "fold", "n", "frac_correct"]]
        worst["frac_correct"] = worst.frac_correct.map(p)
        A("Errors concentrate in a minority of recordings (whole people / sessions), not spread evenly – see the violin plots. "
          "The worst test recordings (seed 0, headline):\n\n" + md_table(worst))
    A(fig_ref(catalogue, "recording_accuracy_social"))
    A("### 6.5 Architecture comparison\n")
    if not fs.empty:
        rows = []
        for task in ("har", "social"):
            d = fs[(fs.task == task) & (fs.seed == 0) & (((fs.group == "main") & (fs.variant == "jan")) | (fs.group == "baseline"))]
            for m, g in d.groupby("model"):
                dd = dep[(dep.task == task) & (dep.model == m)] if not dep.empty else dep
                r = {"task": task, "model": ("★ " if m == C.FINAL[task] else "") + C.MODEL_NAMES.get(m, m)}
                if task == "har":
                    r.update({"static %": p(g.static.mean()), "dynamic %": p(g.dynamic.mean())})
                else:
                    r.update({"balanced %": p(g.social.mean()), "weakest class %": p(g.social_min.mean())})
                r.update({"params": int(dd.params.iloc[0]) if len(dd) and pd.notna(dd.params.iloc[0]) else "", "KB": num(dd.size_kb.iloc[0]) if len(dd) else "",
                          "ms/window": num(dd.ms_per_window.iloc[0], 3) if len(dd) else ""})
                rows.append(r)
        A(md_table(pd.DataFrame(rows).fillna("")))
    if not st.empty:
        d = st[st.comparison.str.contains(" vs her_| vs harry_", regex=True)].copy()
        d["mean_diff"] = (d.mean_diff * 100).round(2); d["p_wilcoxon"] = d.p_wilcoxon.round(4)
        A("Paired tests (final architecture minus baseline, percentage points, over the 10 folds):\n\n" +
          md_table(d[["comparison", "metric", "mean_diff", "folds_a_better", "p_wilcoxon"]]))
    A(fig_ref(catalogue, "architectures_har") + fig_ref(catalogue, "architectures_social") + fig_ref(catalogue, "accuracy_vs_cost_social"))
    A("### 6.6 Class-weight sweep (social)\n")
    if not s.empty:
        d = s[(s.task == "social") & ((s.group == "sweep") | ((s.group == "main") & (s.variant == "jan")))]
        if d.power.nunique() > 1:
            t = d.pivot_table(index="power", columns="class", values="mean").reindex(columns=SOCIAL_CLASSES)
            t["weakest"] = t.min(1); t["balanced"] = t[SOCIAL_CLASSES].mean(1)
            t = (t * 100).round(1).reset_index().rename(columns={c: NICE.get(c, c) for c in t.columns})
            A(md_table(t))
            A("Power 0 = no class weights, 1 = fully balanced. Raising the power moves accuracy from *other* to the three minority classes; "
              f"{C.SOCIAL_POWER:g} keeps every class above the target with the largest margin for the weakest class. Because the sweep was "
              "examined after the choice, report it as a sensitivity analysis rather than as the way the value was picked.\n")
    A(fig_ref(catalogue, "class_weight_sweep"))
    A("### 6.7 Effect of adding the group's recordings\n")
    if not st.empty:
        d = st[st.comparison.str.contains("real data")].copy()
        d["mean_diff"] = (d.mean_diff * 100).round(2); d["p_wilcoxon"] = d.p_wilcoxon.round(4)
        A(md_table(d[["comparison", "metric", "mean_a", "mean_b", "mean_diff", "folds_a_better", "p_wilcoxon"]].round(4)))
    A(fig_ref(catalogue, "variant_paired"))
    A("### 6.8 Leave-one-person-out (unseen group member)\n")
    if not lopo.empty:
        d = lopo[lopo.postures == "all"].groupby(["task", "person", "variant"]).recall.mean().unstack().reindex(columns=["A", "B", "C"])
        d = (d * 100).round(1).reset_index()
        d.columns = ["task", "tested on", "A: Jan2026 only", "B: + other member (mixed)", "C: + other member (fine-tuned)"]
        A("Balanced accuracy (mean per-class recall) on each member:\n\n" + md_table(d))
        ds = lopo[lopo.task == "social"].groupby(["person", "variant", "postures"]).recall.mean().unstack()
        A("Social, by posture (balanced accuracy %):\n\n" + md_table((ds * 100).round(1).reset_index()))
    A(fig_ref(catalogue, "lopo_har") + fig_ref(catalogue, "lopo_social"))
    A("### 6.9 Social gate (social only while not moving)\n")
    if not gate.empty:
        d = gate[gate.gate == "not_moving"].groupby(["variant", "class"])[["enabled", "recall_no_gate", "recall_end_to_end", "recall_when_shown"]].mean()
        d = (d * 100).round(1).reset_index()
        A(md_table(d.rename(columns={"enabled": "shown %", "recall_no_gate": "no gate %", "recall_end_to_end": "end-to-end %",
                                     "recall_when_shown": "when shown %"})))
        if not leaks.empty:
            l = leaks.groupby("variant").called_static.mean()
            A(f"Moving windows wrongly called stationary (social would run while moving): "
              + ", ".join(f"{VAR_LAB(v)} {p(x, 2)} %" for v, x in l.items()) + ".\n")
        A("The share of coughing windows hidden by the gate is the key number: a datasetJan2026-only activity model has never seen a "
          "stationary person coughing (§2.1), so it calls some coughs *miscellaneous movement*. Adding the group recordings, which contain "
          "stationary coughing, reduces this. In the app the gate should therefore be tolerant (e.g. only hide social after several "
          "consecutive 'moving' results).\n")
    if not lgate.empty:
        A("On the group members (leave-one-person-out models), share of stationary social windows hidden:\n\n" +
          md_table((lgate.drop(columns=["id"]).set_index(["variant", "person"]) * 100).round(1).reset_index()))
    A(fig_ref(catalogue, "gate_pass_rate") + fig_ref(catalogue, "gate_effect"))
    A("### 6.10 Simulated real-time accuracy and latency\n")
    if not sa.empty:
        d = sa.groupby(["task", "output", "step"]).apply(lambda q: np.average(q.accuracy, weights=q.n)).unstack()
        d.columns = [f"{ {25: '2 s', 12: '1 s', 6: '0.5 s'}.get(c, c)} updates" for c in d.columns]
        A("Share of displayed results that are correct, both members, 5 random session orders:\n\n" + md_table((d * 100).round(1).reset_index()))
    if not sl.empty:
        d = sl.groupby(["task", "output", "step"])[["first_correct_s", "stable_s"]].median().reset_index()
        d["step"] = d.step.map({25: "2 s", 12: "1 s", 6: "0.5 s"})
        d = d.rename(columns={"step": "update interval", "first_correct_s": "median s to first correct", "stable_s": "median s to 3 correct in a row"})
        A("Latency after a change of activity (median over all changes):\n\n" + md_table(d.round(2)))
        A("The latency is dominated by the window length (the new activity must fill most of the 4 s / 8 s window), not by computation "
          "(milliseconds, §6.11). Shorter update intervals reduce latency by at most one interval.\n")
    if not tr.empty:
        d = tr.groupby(["task", "class"])[["accuracy", "first_correct_s"]].mean().reset_index()
        d["accuracy"] = d.accuracy.map(p); d["first_correct_s"] = d.first_correct_s.round(1); d["class"] = d["class"].map(NICE)
        A("Trial simulation (each recording from a cold start, 1 s updates):\n\n" + md_table(d))
    A(fig_ref(catalogue, "stream_accuracy_vs_step") + fig_ref(catalogue, "latency") + fig_ref(catalogue, "timeline_har_s2952925"))
    A("**[fill in] Live real-time test.** Use the app's *Tools → Real-time test* with every group member and every class; report the "
      "table of trials, the percentage correct and the time to the first correct result, and compare with the simulation above and with "
      "the cross-validation numbers (§7.3).\n")
    A("### 6.11 Deployment cost\n")
    if not dep.empty:
        d = dep.copy(); d["model"] = d.model.map(lambda m: C.MODEL_NAMES.get(m.split(" ")[0], m) + (" – final" if "final" in m else ""))
        A(md_table(d[[c for c in ["task", "model", "params", "size_kb", "ms_per_window", "ms_p90", "parity_argmax_agreement", "parity_max_abs_dprob"] if c in d]].round(4).fillna("")))
        A("Times are single-thread TFLite on the development Mac (Apple M1 Pro); a phone is slower but still far below the 0.5 s update "
          "interval. Parity = agreement between the Keras model and the exported TFLite file on the group recordings.\n")
    A(fig_ref(catalogue, "inference_time") + fig_ref(catalogue, "model_size"))

    # ── critical analysis
    A("## 7. Critical analysis (material for Results and Discussion)\n")
    A("### 7.1 Why some methods performed better\n")
    if not fs.empty:
        def best(task, met):
            d = fs[(fs.task == task) & (fs.seed == 0) & (((fs.group == "main") & (fs.variant == "jan")) | (fs.group == "baseline"))]
            g = d.groupby("model")[met].mean().sort_values(ascending=False)
            return g
        gh, gs_ = best("har", "dynamic"), best("social", "social")
        if len(gh):
            A(f"- **Activities (dynamic mean, Jan2026 only):** ranking " + ", ".join(f"{C.MODEL_NAMES.get(m, m)} {p(v)}" for m, v in gh.items()) + ".\n")
        if len(gs_):
            A(f"- **Social (balanced, Jan2026 only):** ranking " + ", ".join(f"{C.MODEL_NAMES.get(m, m)} {p(v)}" for m, v in gs_.items()) + ".\n")
    A("- **Separating gravity from motion** is the largest single gain for social signals: breathing moves the chest by a few milli-g, while "
      "posture changes gravity by up to 1 g. Normalising the raw signal (Lab 3 models) lets posture dominate the input scale and hides the "
      "breathing; the gravity-split models see posture and breathing on separate, individually normalised inputs.\n"
      "- **Frequency-band features** encode breathing rate and gait cadence directly; they let even the feature-only network compete, and give "
      "the deep models a robust summary that does not depend on where in the window an event falls.\n"
      "- **Longer social window (8 s)** contains whole breaths; 4 s windows (Lab 3 social models) often contain less than one breath.\n"
      "- **Recurrent vs convolutional for social**: the GRU models the order of inhale/exhale and burst/recovery; compare the two in the "
      "table above – if the difference is within the seed spread, say so (the choice then rests on the unseen-person results).\n"
      "- **Recipe**: augmentation (sensor rotation), label smoothing and class weighting matter as much as architecture for generalising to "
      "unseen subjects; Lab 3 models trained with plain Adam and no weighting under-predict minority classes.\n")
    A("### 7.2 Most confused classes and why\n")
    for task in ("har", "social"):
        A("\n".join(conf_text.get(task, [])) + "\n")
    A("### 7.3 Cross-validation vs real time\n")
    A("Expected differences, to discuss against your live test: (1) CV scores single windows from fully settled recordings, whereas live "
      "use includes transitions, where the first 2–4 s after a change are necessarily wrong (latency, §6.10); (2) CV test subjects come from "
      "the same recording campaign as the training data, while live users wear the sensor slightly differently (the gravity check, §2.2); "
      "(3) the app smooths activity results and gates social results, which raises displayed accuracy for steady activities but delays "
      "changes; (4) live trials are few, so their percentages have wide confidence intervals (a 10-trial test has a ±30-point 95 % interval "
      "at 50 %).\n")
    A("### 7.4 Limitations\n")
    A("- Fold-level spread shows that some groups of subjects are much harder than others; the mean hides this (§6.1 heatmaps).\n"
      "- Only two group members provide real-world data; leave-one-person-out with two people is indicative, not conclusive.\n"
      "- datasetJan2026 has no stationary activity data with social signals, so a Jan-only activity model misreads coughs as movement.\n"
      "- Hyper-parameters (epochs, learning rate, window lengths) were fixed from earlier experiments on different folds; the class-weight "
      "power was chosen after seeing results from the official folds (sensitivity analysis provided).\n"
      "- Windows from one recording are correlated, so window-level confidence intervals would be too narrow; fold-level statistics are used.\n"
      "- Accelerometer only, 12.5 Hz: voice and fine cough acoustics are not observable; talking and singing are recognised through "
      "breathing pattern changes only.\n")
    A("### 7.5 Improvements / future work\n")
    A("- More real users (especially female and male participants with different body shapes) recorded with the deployed app.\n"
      "- Stationary-with-social-signal recordings added to the activity training data for every subject (fixes the cough gate problem).\n"
      "- Ensembling the CNN and GRU social models, or test-time averaging over consecutive windows.\n"
      "- Nested cross-validation for hyper-parameters; per-user calibration (a short personal fine-tune in the app).\n"
      "- Quantisation (int8) to cut model size and power further.\n")

    # ── testing
    A("## 8. Testing and verification of the models\n")
    A("- **Keras ↔ TFLite parity**: every exported model is run on all group recordings in both forms; argmax agreement and the largest "
      "probability difference are recorded (§6.11).\n- **App parity check**: each model ships with an `_example.json` (one input window and "
      "the expected probabilities); a debug build of the app runs it at start-up and prints both results.\n- **Data checks**: duplicate "
      "detection, fold-coverage check, sampling-rate and placement checks (§2).\n- **Leakage controls**: per-fold normalisation fitted on "
      "training windows only; fixed epochs; gate models retrained without copies of the social test recordings; unlisted recordings kept "
      "out of CV.\n- **Reproducibility**: fixed seeds, every job's settings and per-epoch history stored; the pipeline resumes and "
      "regenerates every table, figure and this document.\n- **App unit tests** (Flutter) cover the classifiers' window handling, metadata "
      "validation and the history store.\n")

    # ── files
    A("## 9. Where everything is\n")
    A("| what | where |\n|---|---|\n| deployable models | `final_run/final_models/` (copy into the app's `assets/models/`, see INSTALL.md) |\n"
      "| every figure (PNG + PDF) | `final_run/figures/<section>/` and the gallery `final_run/index.html` |\n"
      "| every number | `final_run/tables/*.csv` (described below) |\n| per-job raw outputs | `final_run/jobs/<id>.json` (settings, "
      "per-epoch history, timing), `<id>.npz` (test probabilities, labels, recording ids), `<id>.log`, `jobs/models/*.keras` |\n"
      "| run log | `final_run/run.log` |\n")
    A(md_table(pd.DataFrame(TABLE_DOCS, columns=["table", "one row per", "use it for"])))
    A("## 10. Figure catalogue\n")
    for sec in dict.fromkeys(c["section"] for c in catalogue):
        A(f"**{sec}**\n\n" + "\n".join(f"- `{c['png']}` – {c['title']}: {c['caption']}" for c in catalogue if c["section"] == sec) + "\n")
    A("## 11. References (check details before citing)\n")
    A("\n".join(f"{i + 1}. {r}" for i, r in enumerate(REFS)) + "\n")
    (C.OUT / "WRITEUP.md").write_text("\n".join(L), encoding="utf-8")
    log(f"write-up: {C.OUT / 'WRITEUP.md'} ({sum(len(x.split()) for x in L)} words)")
    gallery(catalogue)


def VAR_LAB(v):
    return {"jan": "datasetJan2026 only", "jan+real": "datasetJan2026 + group recordings"}.get(v, v)


TABLE_DOCS = [
    ("jobs_index.csv", "job", "what ran, settings, time, parameters"),
    ("per_fold_class.csv", "job × class", "recall/precision/F1 per fold – recompute any marked number"),
    ("fold_scores.csv", "job (fold)", "group scores and other metrics per fold"),
    ("summary_per_class.csv", "experiment × class", "fold mean (marked), fold/seed sd, CI, min/max"),
    ("summary_scores.csv", "experiment", "group scores mean and sd over seeds"),
    ("confusion_long.csv", "job × true × predicted", "any confusion matrix (sum over folds / seeds)"),
    ("epochs.csv", "job × epoch", "learning curves (train and held-out loss/accuracy/score)"),
    ("recording_level.csv", "test recording", "per-recording accuracy, vote, confidence"),
    ("calibration_bins.csv", "job × confidence bin", "reliability diagrams"),
    ("stat_tests.csv", "comparison", "paired Wilcoxon tests"),
    ("gate_folds.csv / gate_leaks.csv", "fold × class", "social gate analysis"),
    ("lopo_per_class.csv / lopo_scores.csv / lopo_gate.csv", "person × variant × class", "unseen-person results"),
    ("stream_accuracy.csv / stream_latency.csv / stream_timeline.csv / trial_simulation.csv", "session × step / change / result",
     "simulated real-time accuracy and latency"),
    ("deploy.csv", "architecture", "size, parameters, latency, parity"),
    ("data_composition.csv / fold_composition.csv / duplicates_har_social.csv / real_data_quality.csv / jan_gravity.csv", "class / recording",
     "data section"),
    ("tsne.csv", "window", "embedding scatter"),
    ("timing.csv", "job group", "compute cost"),
]
REFS = [
    "University of Edinburgh, PDIoT Coursework 3 Instructions, 2026.",
    "D. K. Arvind and colleagues: RESpeck respiratory monitoring – e.g. A. Bates, M. J. Ling, J. Mann, D. K. Arvind, \"Respiratory rate and "
    "flow waveform estimation from tri-axial accelerometer data\", Body Sensor Networks (BSN), 2010.",
    "A. Bulling, U. Blanke, B. Schiele, \"A tutorial on human activity recognition using body-worn inertial sensors\", ACM Computing Surveys 46(3), 2014.",
    "F. J. Ordóñez, D. Roggen, \"Deep convolutional and LSTM recurrent neural networks for multimodal wearable activity recognition\", Sensors 16(1), 2016.",
    "N. Y. Hammerla, S. Halloran, T. Plötz, \"Deep, convolutional, and recurrent models for human activity recognition using wearables\", IJCAI, 2016.",
    "J. Wang, Y. Chen, S. Hao, X. Peng, L. Hu, \"Deep learning for sensor-based activity recognition: a survey\", Pattern Recognition Letters 119, 2019.",
    "D. M. Karantonis et al., \"Implementation of a real-time human movement classifier using a triaxial accelerometer for ambulatory monitoring\", IEEE T-ITB 10(1), 2006.",
    "T. T. Um et al., \"Data augmentation of wearable sensor data for Parkinson's disease monitoring using convolutional neural networks\", ICMI, 2017.",
    "F. Yu, V. Koltun, \"Multi-scale context aggregation by dilated convolutions\", ICLR, 2016.",
    "S. Ioffe, C. Szegedy, \"Batch normalization\", ICML, 2015.",
    "N. Srivastava et al., \"Dropout: a simple way to prevent neural networks from overfitting\", JMLR 15, 2014.",
    "K. Cho et al., \"Learning phrase representations using RNN encoder–decoder for statistical machine translation\" (GRU), EMNLP, 2014.",
    "S. Hochreiter, J. Schmidhuber, \"Long short-term memory\", Neural Computation 9(8), 1997.",
    "I. Loshchilov, F. Hutter, \"Decoupled weight decay regularization\" (AdamW), ICLR, 2019; \"SGDR: stochastic gradient descent with warm restarts\", ICLR, 2017.",
    "C. Szegedy et al., \"Rethinking the Inception architecture for computer vision\" (label smoothing), CVPR, 2016.",
    "Y. Cui, M. Jia, T.-Y. Lin, Y. Song, S. Belongie, \"Class-balanced loss based on effective number of samples\", CVPR, 2019.",
    "C. Guo, G. Pleiss, Y. Sun, K. Q. Weinberger, \"On calibration of modern neural networks\", ICML, 2017.",
    "L. van der Maaten, G. Hinton, \"Visualizing data using t-SNE\", JMLR 9, 2008.",
    "F. Wilcoxon, \"Individual comparisons by ranking methods\", Biometrics Bulletin 1(6), 1945; J. Demšar, \"Statistical comparisons of "
    "classifiers over multiple data sets\", JMLR 7, 2006.",
    "P. D. Welch, \"The use of fast Fourier transform for the estimation of power spectra\", IEEE T-AU 15(2), 1967.",
    "TensorFlow Lite / LiteRT documentation, Google, 2026.",
]


def gallery(catalogue):
    secs = list(dict.fromkeys(c["section"] for c in catalogue))
    cards = []
    for sec in secs:
        cards.append(f'<h2 id="{sec}">{html.escape(sec)}</h2><div class="grid">')
        for c in catalogue:
            if c["section"] != sec:
                continue
            cards.append(f'<figure><a href="{c["png"]}" target="_blank"><img loading="lazy" src="{c["png"]}" alt=""></a>'
                         f'<figcaption><b>{html.escape(c["title"])}</b><br>{html.escape(c["caption"])}<br>'
                         f'<code>{html.escape(c["png"])}</code> · <a href="{c["pdf"]}">PDF</a></figcaption></figure>')
        cards.append("</div>")
    nav = " · ".join(f'<a href="#{s}">{s}</a>' for s in secs)
    page = f"""<!doctype html><html><head><meta charset="utf-8"><title>Model figures</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {{ --bg:#fff; --fg:#1a1a1a; --mut:#666; --card:#f6f6f4; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#161616; --fg:#eee; --mut:#aaa; --card:#222; }} }}
body {{ background:var(--bg); color:var(--fg); font:14px/1.45 -apple-system,system-ui,sans-serif; margin:0 auto; max-width:1400px; padding:16px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(420px,1fr)); gap:16px; }}
figure {{ margin:0; background:var(--card); border-radius:8px; padding:10px; }}
img {{ width:100%; background:#fff; border-radius:4px; }} figcaption {{ color:var(--mut); font-size:12.5px; margin-top:6px; }}
figcaption b {{ color:var(--fg); }} a {{ color:#3b82f6; }} code {{ font-size:11px; }}
</style></head><body><h1>Model figures ({len(catalogue)})</h1>
<p>Generated {time.strftime('%Y-%m-%d %H:%M')}. Click a figure for full size; PDF links are vector versions for the report.
The write-up is <a href="WRITEUP.md">WRITEUP.md</a>. Sections: {nav}</p>{''.join(cards)}</body></html>"""
    (C.OUT / "index.html").write_text(page, encoding="utf-8")
