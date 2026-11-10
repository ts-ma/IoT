"""Write <out>/WRITEUP.md (the detailed model write-up, every number filled in from the tables) and
<out>/index.html (a gallery of every figure with captions, to pick the ones for the report)."""
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
    comp, qual, gf = read("data_composition"), read("real_data_quality"), read("group_folds")
    st, dep, pp, po = read("stat_tests"), read("deploy"), read("person_per_class"), read("person_postures")
    ws, wst = read("social_window_study_summary"), read("social_window_study_streams")
    cm, jobs, timing = read("confusion_long"), read("jobs_index"), read("timing")
    facts = json.loads((TAB / "data_facts.json").read_text()) if (TAB / "data_facts.json").exists() else {}
    dec = json.loads(C.DECISIONS.read_text()) if C.DECISIONS.exists() else {}
    L = []
    A = L.append
    hv, jv = C.HEADLINE, "jan"
    Ws = C.W["social"] / C.FS
    pf = C.PERSON_FOLD

    def main_cls(task, v, c):
        r = s[(s.group == "main") & (s.task == task) & (s.variant == v) & (s["class"] == c)] if not s.empty else s
        return r.iloc[0] if len(r) else None

    def group_val(task, v, met):
        d = fs[(fs.group == "main") & (fs.task == task) & (fs.variant == v)] if not fs.empty else fs
        if d.empty:
            return np.nan, np.nan, np.nan
        per_seed = d.groupby("seed")[met].mean()
        return per_seed.mean(), d[d.seed == d.seed.min()][met].std(), per_seed.std() if len(per_seed) > 1 else np.nan

    def ok(v, t):
        return "" if v is None or np.isnan(v) else ("✓" if v >= t else "✗")

    A("# Activity and social-signal models: data, method and results (v2)\n")
    A(f"_Generated {time.strftime('%Y-%m-%d %H:%M')} by `model_harry/run_pipeline_v2.py` from the tables in `{C.OUT.name}/tables/`. "
      f"Every number below is computed, not typed; re-running the pipeline regenerates this file. Figures: `{C.OUT.name}/figures/` "
      f"(PNG to view, PDF for the report); all of them with captions: `{C.OUT.name}/index.html`. For the whole project in one place "
      f"(data use, decisions and their reasons, history, a question → file map) start with `{C.OUT.name}/KNOWLEDGE.md`._\n")
    A("> **How to use this document.** It is longer than the 4,000-word report allows. Each section maps to a part of the report "
      "(Methodology → activity recognition / social signals / testing; Results and Discussion → model accuracy / critical analysis). "
      "Sections marked **[fill in]** need results only the live test on the phone can give.\n")

    # ── decisions
    A("## 0. Design decisions in this run\n")
    A(f"- **Models:** only our four architectures are trained – {', '.join(C.MODEL_NAMES[m] for m in C.ARCHS['har'])}. Deployed: "
      f"**{C.MODEL_NAMES[C.FINAL['har']]}** for activities, **{C.MODEL_NAMES[C.FINAL['social']]}** for social signals.\n"
      f"- **Data:** one way of using it. datasetJan2026 and both group members' recordings are mixed in training, and the two "
      f"members take part in the folds as two extra subjects ({', '.join(f'{C.PEOPLE[q]} → fold {k}' for q, k in pf.items())}): "
      f"a member is in the test set of exactly one fold and in the training set of the other nine. Activities: "
      f"{'mixed as well' if C.HAR_RECIPE == 'mixed' else 'trained on datasetJan2026 only (the one check failed, see below); the members are still test subjects'}.\n"
      f"- **Scoring:** every fold is scored on all its test windows (**headline**) and on its datasetJan2026 windows only, which is "
      f"exactly the number the CW3 marking computes with the official fold files.\n"
      f"- **Social window:** {Ws:g} s{' with recency training' if C.SOCIAL_RECENCY else ''} (candidate `{C.SOCIAL_CANDIDATE}`): the "
      f"fastest of the measured candidates whose every class keeps ≥ {C.MIN_CLASS_RULE * 100:.0f} % (§6.6).\n")
    if "har_check" in dec:
        hc = dec["har_check"]
        A(f"- **Activity check:** with the group members mixed into training, the datasetJan2026 dynamic mean was "
          f"{p(hc.get('jan_dynamic'))} % (rule: ≥ 85 %) → **{C.HAR_RECIPE}**.\n")

    # ── headline
    A("## 1. Headline results (subject-wise 10-fold cross-validation)\n")
    A(f"Recall of each class on the held-out fold, averaged over the 10 folds; group means as in the CW3 brief. Values: mean over "
      f"{len(C.SEEDS)} training seeds; ± = standard deviation over the 10 folds (seed 0). **All test windows** includes the group member "
      "assigned to a fold; **as marked** uses only that fold's datasetJan2026 windows.\n")
    rows = []
    for task in ("har", "social"):
        for c in (HAR_CLASSES if task == "har" else SOCIAL_CLASSES):
            a, b = main_cls(task, hv, c), main_cls(task, jv, c)
            tgt = "≥ 75 %" if task == "social" else ("(static ≥ 90 % mean)" if c in STATIC else "(dynamic ≥ 85 % mean)")
            rows.append({"task": "activity" if task == "har" else "social", "class": NICE[c],
                         "all test windows": f"{p(a['mean'])} ± {p(a['fold_std'])}" if a is not None else "n/a",
                         "as marked (Jan2026 windows)": f"{p(b['mean'])} ± {p(b['fold_std'])}" if b is not None else "n/a",
                         "target": tgt, "pass (marked)": ok(b["mean"], 0.75) if task == "social" and b is not None else ""})
    for task, met, lab, t in [("har", "static", "**static mean (5 classes)**", 0.90), ("har", "dynamic", "**dynamic mean (6 classes)**", 0.85),
                              ("social", "social", "**social balanced (4 classes)**", 0.75), ("social", "social_min", "**weakest social class**", 0.75)]:
        a, b = group_val(task, hv, met), group_val(task, jv, met)
        rows.append({"task": "activity" if task == "har" else "social", "class": lab, "all test windows": f"**{p(a[0])}** ± {p(a[1])}",
                     "as marked (Jan2026 windows)": f"**{p(b[0])}** ± {p(b[1])}", "target": f"≥ {t * 100:.0f} %", "pass (marked)": ok(b[0], t)})
    A(md_table(pd.DataFrame(rows)))
    A(f"\nSeed-to-seed standard deviation of the group scores (all windows): static {p(group_val('har', hv, 'static')[2], 2)}, dynamic "
      f"{p(group_val('har', hv, 'dynamic')[2], 2)}, social {p(group_val('social', hv, 'social')[2], 2)} percentage points – differences "
      "smaller than about twice these are run-to-run noise.\n")
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
        t = comp[comp.set == "listed"][["task", "class", "recordings", "len_mean_s", "len_min_s"]].copy()
        t["class"] = t["class"].map(NICE); t["len_mean_s"] = t.len_mean_s.round(1); t["len_min_s"] = t.len_min_s.round(1)
        t.columns = ["task", "class", "recordings", "mean length (s)", "shortest (s)"]
        A(md_table(t))
    A("\nSitting and standing are one class (as required); talking, eating, singing and laughing form the single social class *other*. "
      "Classes are imbalanced: *other* holds about half of the social data, which drives the class-weighting choice (§4.2).\n")
    A("**Official folds.** `folds_daily_activity.csv` and `folds_social_signal.csv` assign every listed recording to one of 10 folds, "
      "per activity (subject IDs are not shared across activities). Every fold contains every class.\n")
    A(f"**Unlisted recordings.** {comp[comp.set == 'unlisted'].recordings.sum() if not comp.empty else 'n/a'} recordings on disk are not "
      "in the fold files and are not copies of listed files, so their subjects' folds are unknown. Putting them in any fold could place a "
      "test subject in training, so they are **left out of cross-validation** and used only to train the final deployed models.\n")
    if facts:
        A(f"**Duplicated recordings across the two tasks.** {facts.get('har_copies_of_social')} static daily-activity recordings are "
          f"byte-for-byte copies of social-signal recordings (the static activity data *is* the normal-breathing social data). Each task is "
          "cross-validated on its own, so this does not affect the scores, but it means datasetJan2026 has **no static activity data recorded "
          "while coughing, hyperventilating or talking** – the group recordings add exactly that.\n")
    A(fig_ref(catalogue, "recordings_per_class_har") + fig_ref(catalogue, "recordings_per_class_social"))
    A("### 2.2 Group recordings\n")
    if not qual.empty:
        n = qual.groupby("person").size()
        flagged = qual[qual.flag.fillna("") != ""]
        A("Both group members recorded the full CW2 protocol with the RESpeck and the app: "
          + ", ".join(f"{C.PEOPLE[k]} {v} recordings" for k, v in n.items()) +
          ". Per person: sitting, standing and the four lying postures, each while breathing normally, coughing, hyperventilating, "
          "talking, eating (sitting/standing only), singing and laughing, plus the six dynamic activities.\n")
        A(f"**Quality checks** (`tables/real_data_quality.csv`): sampling rate {num(qual.fs_est.median(), 2)} Hz median "
          f"(range {num(qual.fs_est.min(), 2)}–{num(qual.fs_est.max(), 2)}); missing values in {int((qual.nan_rows > 0).sum())} recordings; "
          f"longest flat run {int(qual.longest_flat_run.max())} samples; clipped samples {int(qual.clipped.sum())}. Placement: median angle "
          f"between each recording's gravity direction and the datasetJan2026 mean of its class {num(qual.angle_to_jan_class_deg.median())}°, "
          f"{len(flagged)} recording(s) flagged (> 35° or another issue).\n")
    A("**Use:** each member is one extra subject in the folds – all of a member's recordings (every activity) are in the test set of one "
      "fold and in the training set of the other nine; the two members are in different folds. Activity labels come from the posture or "
      "activity in the file name (a recording of sitting while coughing is *sitting/standing* for activities and *coughing* for social "
      "signals); only stationary recordings have a social label.\n")
    if not gf.empty:
        d = gf.groupby(["task", "person", "fold"]).agg(recordings=("recordings", "sum"), test_windows=("windows_test_step", "sum")).reset_index()
        A(md_table(d))
    A(fig_ref(catalogue, "gravity_orientation") + fig_ref(catalogue, "real_data_quality"))

    # ── preprocessing & models
    A("## 3. Pre-processing, features and models\n")
    A("### 3.1 Windowing\n")
    A(f"Both models classify fixed windows of raw acceleration: **4 s (50 samples) for activities** and **{Ws:g} s ({C.W['social']} samples) "
      f"for social signals**{', trained with recency splices (§4.1)' if C.SOCIAL_RECENCY else ''}. Activities are periodic at 1–3 Hz, so 4 s "
      "holds several gait cycles. The social window is a trade-off between holding whole breaths (2–5 s each) and reacting quickly "
      "in the app; it was chosen by measuring both (§6.6). Training windows overlap (step 25 samples = 2 s on datasetJan2026, step "
      f"{C.REAL_TRAIN_STEP} on the much smaller group data); test windows use a 2 s step. In the app a new result is computed every 0.5 s "
      "(overlapping windows), so the display is never older than the latest data.\n")
    A(fig_ref(catalogue, "example_signals_har") + fig_ref(catalogue, "spectra_social"))
    A("### 3.2 Pre-processing inside the model\n")
    A("All pre-processing is part of the TensorFlow graph, so the phone feeds raw g values and the same computation runs in training and "
      "in the app. Every operation lowers to a TFLite builtin op (checked at export).\n\n"
      "1. **Gravity split.** Gravity (= posture) is the mean of each axis over the window; the dynamic part is the window minus that mean, so "
      "posture and motion are separate inputs – important because breathing moves the chest by ~0.007 g while gravity is 1 g.\n"
      "2. **Dynamic channels** (7): gravity-free x, y, z; magnitude |a| minus its mean (orientation-free); first difference of x, y, z (jerk).\n"
      f"3. **Spectral features**: log mean power in fixed frequency bands (Hann-tapered DFT as a matrix multiply). Activity bands {HAR_BANDS} "
      f"Hz; social bands {SOCIAL_BANDS} Hz (breathing, fast breathing, coughs/voice); plus log standard deviation of every dynamic channel.\n"
      "4. **Normalisation**: per-branch z-scoring fitted on the training windows of each fold only.\n"
      "5. **Augmentation (training only)**: random rotation about the body axis (±30°), small tilt (±10°), amplitude scaling (0.8–1.25) and "
      "Gaussian noise (0.002 g), applied on the fly.\n")
    A("### 3.3 Architectures (all ours)\n")
    A("All four share the gravity and spectral branches and the head (Dropout 0.3 → Dense 64 → Dropout 0.3 → softmax); they differ in "
      "how the dynamic channels are read:\n\n"
      "- **Multi-branch CNN** (deployed for activities): four Conv1D blocks (32 k5, 32 k5 dilation 2, max-pool, 64 k3; Conv → BatchNorm → "
      "ReLU) → global average **and** max pooling.\n"
      "- **Conv-GRU** (deployed for social signals): Conv1D stem (32 k5, BatchNorm, ReLU, max-pool 2) → GRU with 48 units, which models "
      "the order of events (inhale/exhale rhythm, a burst followed by recovery). Exported with an unrolled copy (builtin ops only).\n"
      "- **Gravity-split MLP**: the dynamic channels flattened → Dense 64 → Dense 64.\n"
      "- **Spectral-feature net**: no sequence branch at all – only gravity + band powers.\n")
    if not dep.empty:
        d = dep[dep.model.str.contains("final")]
        A(md_table(d[[c for c in ["task", "model", "params", "size_kb", "ms_per_window", "parity_argmax_agreement"] if c in d]].round(3)))

    # ── training
    A("## 4. Training\n")
    A("### 4.1 Recipe\n")
    A("| setting | value |\n|---|---|\n| optimiser | AdamW, weight decay 1e-4 |\n| learning rate | 2e-3 with cosine decay to 5 % |\n"
      "| epochs | 32, fixed in advance (no early stopping on test folds) |\n| batch | 64 |\n| loss | categorical cross-entropy, label smoothing 0.1 |\n"
      f"| class weights | activities: balanced; social: balanced^{C.SOCIAL_POWER:g} (§4.2) |\n| augmentation | §3.2 |\n"
      f"| training data of fold k | datasetJan2026 folds ≠ k (windows every 25 samples) + the group member(s) not in fold k (every "
      f"{C.REAL_TRAIN_STEP} samples), mixed{'' if C.HAR_RECIPE == 'mixed' else ' (activities: datasetJan2026 only)'} |\n"
      + (f"| recency splices (social) | half of the training windows get their first 25–62 samples replaced by another window "
         f"(gravity-aligned), keeping the label of the last 3–6 s, so the model answers from the most recent seconds |\n" if C.SOCIAL_RECENCY else "")
      + f"| seeds | {', '.join(map(str, C.SEEDS))} (deployed architectures); 0 (others) |\n"
      "| final models | the same recipe on everything: all datasetJan2026 recordings (incl. unlisted) + both members |\n")
    A("### 4.2 Class weighting for social signals\n")
    A("With fully balanced weights each class contributes equally to the loss, so the majority class *other* (~53 % of windows) is "
      f"under-predicted. Weights are softened to w_c = (N / (K·n_c))^{C.SOCIAL_POWER:g}: with balanced weights the effective prior of *other* "
      f"is divided by ~3.3; a power of {C.SOCIAL_POWER:g} leaves a factor of 3.3^{1 - C.SOCIAL_POWER:.1f} ≈ 1.6. The sweep in §6.7 shows the "
      "whole trade-off curve.\n")
    if system:
        A("### 4.3 Compute\n")
        tot = jobs.seconds.sum() / 3600 if not jobs.empty else np.nan
        A(f"{system.get('machine')}, {system.get('cpus')} CPU cores, {system.get('os')}; Python {system.get('python')}, TensorFlow "
          f"{system.get('tensorflow')}, Keras {system.get('keras')}, scikit-learn {system.get('sklearn')}. CPU only. "
          f"{len(jobs)} jobs, {num(tot)} CPU-job hours.\n")
        A(md_table(timing.rename(columns={"group": "job group", "count": "jobs", "sum": "seconds total", "mean": "seconds per job"}).round(0)))
    A(fig_ref(catalogue, "learning_curves_har_all") + fig_ref(catalogue, "learning_curves_social_all"))

    # ── evaluation protocol
    A("## 5. Evaluation protocol\n")
    A("### 5.1 Cross-validation\n")
    A("For each fold k = 0…9 a new model is trained from scratch on everything not in fold k and tested on fold k: the official "
      "datasetJan2026 fold k plus the group member assigned to fold k. Within each activity a subject is never in both sets (official fold "
      "files; each member is one subject). A test sample is a window (every 2 s). For each class, accuracy = share of its test windows "
      "classified correctly (recall), averaged over the 10 folds; group scores average the per-class values (static 5 classes, dynamic 6, "
      "each social class against 75 %).\n")
    A("### 5.2 Two scorings of the same predictions\n- **All test windows** (headline): every window of the fold.\n- **As marked**: only "
      "the datasetJan2026 windows of the fold – the CW3 marking's number. The models are the same; only which test windows are counted "
      "differs.\n- **Per member**: the member's own fold, i.e. a model that never saw that person (§6.8).\n")
    A("### 5.3 Other metrics and statistics\nPrecision, F1, macro ROC-AUC, recording-level majority vote, log-loss, expected calibration "
      "error, spread over folds and seeds, 95 % confidence intervals over folds, and paired Wilcoxon signed-rank tests over the 10 folds "
      "(with 10 folds the smallest two-sided p is 0.002).\n")

    # ── results
    A("## 6. Results\n")
    A("### 6.1 Group scores and per-class accuracy\n")
    A(fig_ref(catalogue, "group_scores_har") + fig_ref(catalogue, "group_scores_social"))
    if not s.empty:
        for task in ("har", "social"):
            for v in (hv, jv):
                d = s[(s.group == "main") & (s.task == task) & (s.variant == v)].set_index("class").reindex(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
                t = pd.DataFrame({"class": [NICE[c] for c in d.index], "recall": [p(x) for x in d["mean"]], "fold sd": [p(x) for x in d.fold_std],
                                  "seed sd": [p(x, 2) for x in d.seed_std], "95 % CI ±": [p(x) for x in d.ci95],
                                  "worst fold": [p(x) for x in d.fold_min], "best fold": [p(x) for x in d.fold_max],
                                  "precision": [p(x) for x in d.precision], "F1": [p(x) for x in d.f1]})
                A(f"**{'Activities' if task == 'har' else 'Social signals'} – {C.SCOPE_LABEL[v]}**\n\n" + md_table(t))
    A(fig_ref(catalogue, "fold_heatmap_har_all") + fig_ref(catalogue, "fold_heatmap_social_all") + fig_ref(catalogue, "seed_variation_social"))
    A("### 6.2 Other metrics\n")
    if not fs.empty:
        d = fs[(fs.group == "main") & fs.variant.isin([hv, jv])].groupby(["task", "variant"])[["window_acc", "macro_f1", "macro_auc", "recording_vote_acc", "ece", "log_loss"]].mean().reset_index()
        for col in ["window_acc", "macro_f1", "macro_auc", "recording_vote_acc", "ece"]:
            d[col] = d[col].map(lambda v: p(v))
        d["log_loss"] = d.log_loss.round(3); d["variant"] = d.variant.map(C.SCOPE_LABEL)
        d.columns = ["task", "scored on", "window accuracy %", "macro F1 %", "macro AUC %", "recording vote %", "ECE %", "log-loss"]
        A(md_table(d))
        A("Recording vote = the majority class over all windows of a test recording. ECE = expected calibration error (gap between "
          "confidence and accuracy).\n")
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
    A(fig_ref(catalogue, "confusion_har_all_pct") + fig_ref(catalogue, "confusion_social_all_pct") + fig_ref(catalogue, "tsne_social"))
    A("### 6.4 Per-recording behaviour\n")
    rl = read("recording_level")
    if not rl.empty:
        d = rl[(rl.variant == hv) & (rl.seed == 0)]
        worst = d.sort_values("frac_correct").head(8)[["task", "class", "source", "file", "fold", "n", "frac_correct"]]
        worst["frac_correct"] = worst.frac_correct.map(p)
        A("Errors concentrate in a minority of recordings (whole people / sessions). The worst test recordings (seed 0):\n\n" + md_table(worst))
    A(fig_ref(catalogue, "recording_accuracy_social"))
    A("### 6.5 Architecture comparison (our four models)\n")
    if not fs.empty:
        rows = []
        for task in ("har", "social"):
            d = fs[(fs.task == task) & (fs.seed == 0) & fs.group.isin(["main", "baseline"])]
            for m, g in d.groupby("model"):
                dd = dep[(dep.task == task) & (dep.model == m)] if not dep.empty else dep
                r = {"task": task, "model": ("★ " if m == C.FINAL[task] else "") + C.MODEL_NAMES.get(m, m)}
                for v in (hv, jv):
                    q = g[g.variant == v]
                    if task == "har":
                        r[f"dynamic % ({'all' if v == hv else 'marked'})"] = p(q.dynamic.mean())
                    else:
                        r[f"balanced % ({'all' if v == hv else 'marked'})"] = p(q.social.mean())
                        r[f"weakest % ({'all' if v == hv else 'marked'})"] = p(q.social_min.mean())
                if task == "har":
                    r["static % (all)"] = p(g[g.variant == hv].static.mean())
                r.update({"params": int(dd.params.iloc[0]) if len(dd) and pd.notna(dd.params.iloc[0]) else "",
                          "KB": num(dd.size_kb.iloc[0]) if len(dd) else "", "ms/window": num(dd.ms_per_window.iloc[0], 3) if len(dd) else ""})
                rows.append(r)
        A(md_table(pd.DataFrame(rows).fillna("")))
    if not st.empty:
        d = st[~st.comparison.str.contains("power")].copy()
        d["mean_diff"] = (d.mean_diff * 100).round(2); d["p_wilcoxon"] = d.p_wilcoxon.round(4)
        A("Paired tests (deployed architecture minus the other one, percentage points, over the 10 folds, seed 0):\n\n" +
          md_table(d[["comparison", "scope", "metric", "mean_diff", "folds_a_better", "p_wilcoxon"]]))
    A(fig_ref(catalogue, "architectures_har") + fig_ref(catalogue, "architectures_social") + fig_ref(catalogue, "accuracy_vs_cost_social"))
    A("### 6.6 Choosing the social window (speed vs accuracy)\n")
    A("In the app a social result changes only once about half of the window holds the new signal, plus the wait for the RESpeck's "
      "next data packet (32 samples = 2.56 s, 1.3 s on average). The target was ≈ 4–4.5 s from a change to the screen (≈ 2 s of data "
      "transmission + ≈ 2 s detection), like activities. Candidates were measured on the official folds (datasetJan2026 training, seed "
      "0) and with a replay of the app (32-sample packets, a result every 0.5 s) on same-posture changes in both members' recordings, "
      "which those models never saw (`results/social_window_study/`).\n")
    if not ws.empty:
        d = ws.copy(); key = d.columns[0]
        cols = [key] + SOCIAL_CLASSES + [c for c in ["mean", "min_class", "lat_med_real", "lat_mean_real", "lat_p90_real", "lat_med_jan", "miss_real"] if c in d]
        d = d[cols].copy()
        if "miss_real" in d:
            d["miss_real"] = d.miss_real * 100
        d = d.round(1)
        d.columns = ["candidate"] + [NICE[c] for c in SOCIAL_CLASSES] + [{"mean": "balanced", "min_class": "weakest", "lat_med_real": "median s (ours)",
                     "lat_mean_real": "mean s (ours)", "lat_p90_real": "p90 s (ours)", "lat_med_jan": "median s (Jan pairs)",
                     "miss_real": "never shown % (ours)"}[c] for c in cols[5:]]
        A(md_table(d))
        A(f"Rule (decided before the results): the fastest candidate whose every class is ≥ {C.MIN_CLASS_RULE * 100:.0f} % (2 points above the "
          f"mark). Chosen: **{C.SOCIAL_CANDIDATE}** ({Ws:g} s{', recency-trained' if C.SOCIAL_RECENCY else ''}). "
          + (dec.get("social", {}).get("note", "")) + "\n")
    A(fig_ref(catalogue, "social_window_choice") + fig_ref(catalogue, "social_latency"))
    A("### 6.7 Class-weight sweep (social)\n")
    if not s.empty:
        d = s[(s.task == "social") & s.group.isin(["sweep", "main"]) & (s.variant == hv)]
        if d.power.nunique() > 1:
            t = d.pivot_table(index="power", columns="class", values="mean").reindex(columns=SOCIAL_CLASSES)
            t["weakest"] = t.min(1); t["balanced"] = t[SOCIAL_CLASSES].mean(1)
            t = (t * 100).round(1).reset_index().rename(columns={c: NICE.get(c, c) for c in t.columns})
            A(md_table(t))
            A(f"Power 0 = no class weights, 1 = fully balanced. Raising the power moves accuracy from *other* to the three smaller classes. "
              "The sweep was examined after the choice of 0.6, so report it as a sensitivity analysis.\n")
    A(fig_ref(catalogue, "class_weight_sweep"))
    A("### 6.8 The group members as unseen test subjects\n")
    if not pp.empty:
        d = pp.groupby(["task", "person", "fold"]).recall.mean().reset_index()
        d["balanced accuracy %"] = d.recall.map(p); d["person"] = d.person.map(C.PEOPLE)
        A("Each member's fold is a model that never saw that person (mean of the per-class recalls, 3 seeds):\n\n" +
          md_table(d[["task", "person", "fold", "balanced accuracy %"]]))
        w = pp.pivot_table(index=["task", "class"], columns="person", values="recall")
        w = (w * 100).round(1).reset_index(); w["class"] = w["class"].map(NICE)
        A("Per class (%):\n\n" + md_table(w.rename(columns=C.PEOPLE)))
    if not po.empty:
        d = po.groupby(["person", "postures"]).balanced.mean().unstack()
        A("Social by posture (balanced %, seed 0):\n\n" + md_table((d * 100).round(1).reset_index().replace(C.PEOPLE)))
    A(fig_ref(catalogue, "person_har") + fig_ref(catalogue, "person_social"))
    A("**[fill in] Live real-time test.** Use the app's *Tools → Real-time test* and *Latency test* with every group member and every "
      "class; report the table of trials, the percentage correct and the time until shown, and compare with §1, §6.6 and §6.8.\n")
    A("### 6.9 Deployment cost\n")
    if not dep.empty:
        d = dep.copy(); d["model"] = d.model.map(lambda m: C.MODEL_NAMES.get(m.split(" ")[0], m) + (" – final" if "final" in m else ""))
        A(md_table(d[[c for c in ["task", "model", "window", "params", "size_kb", "ms_per_window", "ms_p90", "parity_argmax_agreement", "parity_max_abs_dprob"] if c in d]].round(4).fillna("")))
        A("Single-thread TFLite on the development Mac; a phone is slower but still far below the 0.5 s update interval. Parity = agreement "
          "between the Keras model and the exported TFLite file on the group recordings.\n")
    A(fig_ref(catalogue, "inference_time") + fig_ref(catalogue, "model_size"))

    # ── critical analysis
    A("## 7. Critical analysis (material for Results and Discussion)\n")
    A("### 7.1 Why some methods performed better\n")
    if not fs.empty:
        for task, met, lab in [("har", "dynamic", "Activities (dynamic mean)"), ("social", "social", "Social (balanced)")]:
            g = fs[(fs.task == task) & (fs.seed == 0) & (fs.variant == hv) & fs.group.isin(["main", "baseline"])].groupby("model")[met].mean().sort_values(ascending=False)
            if len(g):
                A(f"- **{lab}, all test windows:** " + ", ".join(f"{C.MODEL_NAMES.get(m, m)} {p(v)}" for m, v in g.items()) + ".\n")
    A("- **Separating gravity from motion**: breathing moves the chest by a few milli-g while posture changes gravity by up to 1 g; feeding "
      "them as separate, individually normalised inputs lets the small signal be seen.\n"
      "- **Sequence models beat summaries**: the spectral-feature net and the MLP only see summaries / fixed positions; the CNN and GRU "
      "learn local shapes (steps, coughs) wherever they occur in the window.\n"
      "- **Frequency bands** encode breathing rate and gait cadence directly and stabilise all models.\n"
      "- **Recipe**: augmentation (sensor rotation), label smoothing and class weighting matter as much as the architecture for unseen "
      "subjects.\n")
    A("### 7.2 Most confused classes and why\n")
    for task in ("har", "social"):
        A("\n".join(conf_text.get(task, [])) + "\n")
    A("### 7.3 Cross-validation vs real time\n")
    A("Expected differences, to discuss against the live test: (1) CV scores single windows from settled recordings, whereas live use "
      "includes changes, where the first seconds after a change are necessarily wrong (latency, §6.6); (2) live users wear the sensor "
      "slightly differently (§2.2, §6.8); (3) the app smooths activity results and shows social results only while still, which raises "
      "displayed accuracy for steady activities but delays changes; (4) live trials are few, so their percentages have wide confidence "
      "intervals.\n")
    A("### 7.4 Limitations\n")
    A("- Fold-level spread shows that some groups of subjects are much harder than others (§6.1 heatmaps).\n"
      "- Only two group members provide real-world data, so the unseen-person result rests on two people.\n"
      "- Hyper-parameters (epochs, learning rate) were fixed from earlier experiments; the class-weight power and the social window were "
      "chosen from results on the official folds (sensitivity analyses provided).\n"
      "- Windows from one recording are correlated, so fold-level, not window-level, statistics are used.\n"
      "- Accelerometer only at 12.5 Hz: voice is not observable; talking and singing are recognised through breathing-pattern changes.\n")
    A("### 7.5 Improvements / future work\n")
    A("- More real users recorded with the deployed app.\n- Ensembling the CNN and GRU social models, or averaging over consecutive "
      "overlapping windows.\n- Nested cross-validation for hyper-parameters; per-user calibration (a short personal fine-tune in the app).\n"
      "- Quantisation (int8) to cut model size and power further.\n")

    # ── testing
    A("## 8. Testing and verification of the models\n")
    A("- **Keras ↔ TFLite parity**: every exported model is run on all group recordings in both forms (§6.9).\n- **App parity check**: each "
      "model ships with an `_example.json` (one input window and the expected probabilities) that a debug build of the app runs at start-up."
      "\n- **Data checks**: duplicate detection, fold coverage, sampling-rate and placement checks (§2).\n- **Leakage controls**: per-fold "
      "normalisation fitted on training windows only; fixed epochs; a group member is never in the training and test set of the same fold; "
      "unlisted recordings kept out of CV.\n- **Reproducibility**: fixed seeds; every job's settings and per-epoch history stored; frozen "
      "decisions in `decisions.json`; the pipeline resumes and regenerates every table, figure and this document.\n")

    # ── files
    A("## 9. Where everything is\n")
    A(f"| what | where |\n|---|---|\n| deployable models | `pipeline_v2/models/` (see INSTALL.md there; not copied into the app) |\n"
      f"| every figure (PNG + PDF) | `{C.OUT.name}/figures/<section>/` and the gallery `{C.OUT.name}/index.html` |\n"
      f"| every number | `{C.OUT.name}/tables/*.csv` (below) |\n| decisions | `{C.OUT.name}/decisions.json` |\n"
      f"| per-job raw outputs | `{C.OUT.name}/jobs/<id>.json`, `<id>.npz` (test probabilities, labels, recording ids, source and person of "
      f"every window), `<id>.log`, `jobs/models/*.keras` |\n| run log | `{C.OUT.name}/run.log` |\n")
    A(md_table(pd.DataFrame(TABLE_DOCS, columns=["table", "one row per", "use it for"])))
    A("## 10. Figure catalogue\n")
    for sec in dict.fromkeys(c["section"] for c in catalogue):
        A(f"**{sec}**\n\n" + "\n".join(f"- `{c['png']}` – {c['title']}: {c['caption']}" for c in catalogue if c["section"] == sec) + "\n")
    A("## 11. References (check details before citing)\n")
    A("\n".join(f"{i + 1}. {r}" for i, r in enumerate(REFS)) + "\n")
    (C.OUT / "WRITEUP.md").write_text("\n".join(L), encoding="utf-8")
    log(f"write-up: {C.OUT / 'WRITEUP.md'} ({sum(len(x.split()) for x in L)} words)")
    gallery(catalogue)


TABLE_DOCS = [
    ("jobs_index.csv", "job", "what ran, settings, time, parameters"),
    ("per_fold_class.csv", "job × scope × class", "recall/precision/F1 per fold; scope ('variant') = all / jan (as marked) / group / person"),
    ("fold_scores.csv", "job × scope", "group scores and other metrics per fold"),
    ("summary_per_class.csv", "experiment × scope × class", "fold mean (marked), fold/seed sd, CI, min/max"),
    ("summary_scores.csv", "experiment × scope", "group scores mean and sd over seeds"),
    ("confusion_long.csv", "job × scope × true × predicted", "any confusion matrix (sum over folds / seeds)"),
    ("epochs.csv", "job × epoch", "learning curves (train and held-out loss/accuracy/score)"),
    ("recording_level.csv", "test recording", "per-recording accuracy, vote, confidence, source"),
    ("calibration_bins.csv", "job × confidence bin", "reliability diagrams"),
    ("stat_tests.csv", "comparison × scope", "paired Wilcoxon tests"),
    ("person_per_class.csv / person_postures.csv", "member × class", "unseen-person results (each member's own fold)"),
    ("social_window_study_*.csv", "candidate / fold / change", "how the social window was chosen (accuracy and latency)"),
    ("deploy.csv", "architecture", "size, parameters, latency, parity"),
    ("data_composition.csv / fold_composition.csv / group_folds.csv / duplicates_har_social.csv / real_data_quality.csv / jan_gravity.csv",
     "class / recording", "data section"),
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
