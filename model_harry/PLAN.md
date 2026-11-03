# model_harry — Problems, Correction Goals and Progress Tracker

Owner: Harry (s2503795) · Started: 2026-11-02 · Scope: models only (the teammate's `model/` folder and
`Lab3_trained.ipynb` are left untouched).

## Data policy (decided by Harry, 2026-11-02)

| Source | Status | How it is used here |
|---|---|---|
| `IoT/data/<uun>/*.csv` | **Real** RESpeck recordings (currently 1 subject, `s2503795`, 44 × 30 s) | All training, all cross-validation |
| `IoT-RESpeck/datasetJan2026` | Suspected generated / not trustworthy | **Only** a final casual check, never for training or model selection |

Known consequences, recorded here so they are not forgotten:

- **One subject, so no subject-wise CV yet.** Within-subject CV schemes are used instead (see G1). As soon as
  teammates drop their 44-file folders into `IoT/data/<uun>/`, the loader picks them up and
  leave-one-subject-out (LOSO) CV is used automatically.
- **Dynamic classes have one 30 s recording each** (about 12 windows at a 4 s window and 2 s step). That is very
  little data, so results for these classes are noisy and optimistic: train and test are different parts of
  the same session.
- The CW3 marking text says the official numbers come from 10-fold CV on the provided dataset with the Learn
  folds. That is a different protocol from this data policy. The report will need the official protocol
  eventually, and the code keeps the data source pluggable so it can be switched.
- Real-data caveat: 4 of the 6 `LyingDownLeft` files (Normal, Talking, Singing, Laughing) were **rotated by
  26–38° during CW2 cleaning** (`Lab2_1` stage 3), so they are not exactly what the sensor measured. Live
  lying-left data on this wearer will look like the un-rotated orientation (X≈−0.65, Z≈−0.82). Rotation
  augmentation (G4) is meant to cover this.

---

## 1. Problems found in the teammate's models (`Lab3_trained.ipynb`, `model/`)

Each problem is tagged with the goal that fixes it.

### Social-signal model (`social_cnn`, `social_mlp`)
- **P1 — Breathing is invisible to the network.** `Normalization` is adapted on raw windows. Its per-axis std
  (≈0.52 / 0.45 / 0.61 g) comes from posture, i.e. where gravity points. Breathing moves ≈0.007 g inside a
  window, so after normalisation the useful signal is ≈0.013 units riding on posture offsets of ±2. The CNN
  ends up learning posture, not respiration. → **G2**
- **P2 — The majority class wins.** There is no class weighting, and `EarlyStopping(monitor="val_accuracy")`
  rewards predicting `other` (53 % of windows). The MLP collapsed to always predicting `other` (recall 0 for
  the other three classes) and was still exported to `model/social_mlp.tflite`. The CNN recalls are
  breathing 35 %, cough 57 %, hyperventilation 41 % and other 87 %, a balanced score of ≈54 %. Marking is
  per class (≥75 % each). → **G2**
- **P3 — The 4 s window is too short for normal breathing.** At ≈0.2–0.3 Hz that is at most one breath per
  window. → **G2**
- **P4 — The architecture throws away burst and frequency information.** It uses only
  GlobalAveragePooling, which averages a 0.5 s cough away, has no spectral branch, and uses `valid` padding
  that shrinks a short window further. → **G2**
- **P5 — No social-signal CV, and the hold-out split is not subject-wise.** In `social_signal` the `N_x`
  names are recording indices, not subjects, so the same person can appear in both train and test. → **G1**

### HAR model (`har_cnn`, `har_mlp`, `har_rnn`, `har_cnn_dynamic`, `har_cnn_full_int8`)
- **P6 — No frequency-domain information.** The B2 feature pipeline dropped the frequency family, which was the
  largest single gain in the Lab 3 template (0.842 → 0.875). The CNN has no explicit cadence features.
  → **G3**
- **P7 — Weak dynamic classes.** Recalls are normalWalking 73 %, miscMovement 83 % and shuffleWalking 84 %.
  The dynamic mean is ≈86 % against an 85 % target, which is marginal. → **G3**
- **P8 — Posture classes only ever saw "breathing normally".** In `datasetJan2026`, every
  `sittingStanding`/`lying*` file is a byte copy of a `breathingNormally` file. In the app the user will be
  talking, coughing or laughing while sitting or lying. The model has never seen that and drifts to
  `miscMovement`; `sittingStanding→miscMovement` was already a top confusion. → **G3**
- **P9 — Weak orientation handling.** Gravity is mixed into the same normalised channels as motion; there is
  no explicit orientation branch. → **G3**

### Robustness / training recipe (both tasks)
- **P10 — Ineffective augmentation.** B8 rotated a fixed 50 % of windows once, before training, so there is no
  new variety per epoch. It used a random axis ±15°, which does not match real variation. Real variation is
  mostly body roll about the sensor Y axis, up to ≈30–40°: see the CW2 lying-left fix and the
  `datasetJan2026` lyingLeft Z IQR of 0.39. There was no amplitude, noise or time-shift augmentation. → **G4**
- **P11 — Visible overfitting with no regularisation recipe.** Train accuracy is 95 % against 90 % on
  validation, and `val_loss` rises from about epoch 9. There is a constant learning rate, no weight decay and
  no label smoothing. → **G4**
- **P12 — Variants rejected on noise.** BatchNorm, kernel 3, class weights and augmentation were judged on a
  single split with differences of 0.3–0.8 pp, while the fold-to-fold std is ≈1.4 pp. → **G1**

### Evaluation / process
- **P13 — Wrong metric.** B9 reports overall window accuracy. Marking uses per-class recall averaged within
  static, dynamic and social groups, then over folds. → **G1**
- **P14 — B9 is incomplete and not reproducible.** It uses self-made folds (no Learn fold CSV was found). The
  summary cells 118–121 were never executed. Fold 2 was "already completed" from a stale state. The notebook
  mutates globals (`TASK`, `CLASSES`, swapping `X_train`), so it cannot be re-run top to bottom. → **G1**
- **P15 — Trained and evaluated only on `datasetJan2026`.** The models were never tested on real recordings
  from our own RESpeck and wearer. → **G1 / G7**
- **P16 — No data hygiene.** There is no de-duplication, and the ~102 orientation outliers that `Lab2_2`
  flagged (including mislabelled files, e.g. an upright `lyingLeft (2).csv`) were left in training.
  → **G5** (applies to the `datasetJan2026` check set)

### Deployment
- **P17 — Exports in `model/` that should not be shipped.**
  - `har_cnn_full_int8.tflite` takes and returns int8, which the Lab 4 template does not support
    (float32 only).
  - `social_mlp.tflite` is degenerate (always predicts `other`).
  - Nothing documents which file the app should use. → **G6**
- **P18 — No temporal smoothing or gating.** The social model would also classify walking or running windows,
  where its classes are meaningless, and predictions are shown raw. App-side change, documented only. → **G6**

---

## 2. Correction goals and step-by-step TODOs

Legend: `[x]` done · `[ ]` open · `[~]` partially / deferred (reason given)

### G1 — Real-data pipeline and honest evaluation protocol (P5, P12, P13, P14, P15)
- [x] G1.1 Loader for `IoT/data/<uun>/PDIOT_<uun>_<Activity>_<Sub>_<date>_<time>.csv`. It parses the activity
      and sub-activity, then derives the HAR label (all stationary files carry their posture label), the
      social label (stationary files only), the posture and the subject.
- [x] G1.2 Fixed class order identical to the teammate's (`HAR_CLASSES`, `SOCIAL_CLASSES`), so outputs stay
      compatible with the app.
- [x] G1.3 CV schemes (all deterministic, no window ever straddles train and test):
  - [x] HAR "grouped-blocked 5-fold" (1 subject):
    - static recordings are held out whole, by behaviour group
      {Normal}, {Coughing}, {Hyperventilating}, {Talking, Eating}, {Singing, Laughing}, which tests the
      posture under an unseen behaviour;
    - dynamic recordings (one per class) are split into 5 contiguous 6 s time blocks; block k is the test
      set and the train windows are cut separately from the segments before and after it.
  - [x] Social "leave-one-posture-out" (LOPO, 6 folds: sitting, standing, back, left, right, stomach). Tests
        respiration under an unseen posture.
  - [~] LOSO automatically when ≥2 subjects are present.
- [x] G1.4 Metrics that mirror the marking: per-class recall per fold → static mean, dynamic mean, and each
      social class → mean ± std over folds. Also pooled confusion matrices, per-recording majority vote and a
      per-behaviour breakdown for the static HAR classes.
- [x] G1.5 Everything runs as scripts (`run_cv.py`, `train_final.py`, `compare.py`) with no hidden global
      state, writing JSON/CSV/Markdown to `results/`.
- [x] G1.6 Candidate list and training recipe fixed **before** looking at CV numbers (`harry/models.py::CANDIDATES`,
      `harry/train.py::RECIPES`). Selection rule: HAR = mean(static mean, dynamic mean); social = balanced recall,
      ties < 0.01 broken by min-class recall; the teammate replica is a control and is never selected. Each candidate uses 3
      seeds; differences smaller than the seed/fold std are not called improvements.

### G2 — Social-signal model that actually sees respiration (P1–P4)
- [x] G2.1 In-model, TFLite-safe front end: per-window gravity g = mean over time; AC = x − g; |x| − mean|x|;
      first difference. Normalisation is adapted on these gravity-free channels only.
- [x] G2.2 Spectral branch: a fixed DFT matrix multiplication (no `tf.signal`) gives log band power in
      respiration bands (0.1–0.4, 0.4–0.8, 0.8–1.5, 1.5–3, 3–6.25 Hz), plus log-std per channel.
- [x] G2.3 CNN branch: `same` padding, BatchNorm, dilations 1/2/4 for a long receptive field, and **GAP ‖ GMP**
      pooling (GMP keeps short cough bursts).
- [x] G2.4 Class-balanced loss (balanced class weights). Model choice uses the balanced / minimum per-class
      recall, never plain accuracy.
- [x] G2.5 Window study: 50 (4 s) vs 100 (8 s) samples, step kept at 25 (the app still updates every 2 s).
- [x] G2.6 Ablation: with vs without the gravity (posture) side input, since LOPO tests posture invariance.

### G3 — HAR model with orientation + dynamics + cadence (P6–P9)
- [x] G3.1 Two branches:
  - orientation branch: gravity vector → Dense;
  - dynamics branch: CNN on AC/|x|/jerk with GAP ‖ GMP.
- [x] G3.2 Spectral cadence branch: log band power 0.3–1, 1–1.5, 1.5–2, 2–2.5, 2.5–3.5 and 3.5–6.25 Hz, plus
      log-std.
- [x] G3.3 Posture classes trained on **all** stationary behaviours: 7 files per sit/stand posture and 6 per
      lying posture, not just normal breathing.
- [x] G3.4 Feature-MLP candidate (spectral + log-std + gravity only, ~2k params), as a hedge for the tiny
      dataset.

### G4 — Robustness recipe (P10, P11)
- [x] G4.1 Fresh augmentation every epoch:
  - rotation about Y ±30° plus any axis ±10°;
  - AC amplitude ×U(0.8, 1.25);
  - Gaussian noise σ = 0.002 g;
  - time shift through dense (step 6) training windows.
- [x] G4.2 AdamW with cosine-decay learning rate, weight decay 1e-4, label smoothing 0.1 and dropout 0.3.
      Fixed epoch budget (no peeking at test folds).
- [x] G4.3 Robustness probe: accuracy on test folds rotated by 15° and 30° about Y, for the teammate's models
      and for mine.
- [~] G4.4 Seed ensemble inside one TFLite. **Not needed:** CV seed std ≤ 1 pp for every candidate.

### G5 — Data hygiene (P16)
- [x] G5.1 Real data: verify there are no duplicates, all files are 375 samples, and orientation sanity
      (dominant axis/sign per posture).
- [x] G5.2 `datasetJan2026` check set: report how many test-split files are duplicates or Lab2_2 outliers.
      Evaluate as-is, since it is only a casual check.

### G6 — Deployment contract (P17, P18)
- [x] G6.1 Export float32 TFLite with input `[1, W, 3]` raw g and softmax output. `_meta.json` and
      `_example.json` use exactly the Lab 4 format.
- [x] G6.2 Verify TFLite against Keras: argmax agreement ≥ 99.9 % and max |Δp| ≤ 1e-4, using only builtin ops
      (the interpreter must load without Flex).
- [x] G6.3 Document for the app (no app code changed): exponential moving average or majority vote over the
      last 3 predictions, and only show the social result when HAR predicts a static class.

### G7 — Comparison with the teammate's models (P15)
- [x] G7.1 Evaluate **her exported TFLite files as-is** on the real data (she never trained on it, so all 44
      files are fair test data), on the same windows and metrics as mine.
- [x] G7.2 Retrain **her architecture + her recipe** on the real data inside the same CV. This separates the
      effect of the data from the effect of the architecture/recipe.
- [x] G7.3 Casual check on `datasetJan2026`: rebuild her exact held-out test split (seed 0, 70/15/15
      stratified). Confirm it by reproducing her 4034 HAR and 13534 social test windows and her 0.908 /
      0.667 accuracy, then score her models and mine on it.
- [x] G7.4 Write `RESULTS.md` with tables, conclusions and limitations.

### G8 — One-click comparison pipeline (requested 2026-11-03)
- [x] G8.1 Model zoo with comparison groups: her 6 architectures + B2 logistic regression (replicas), and my
      MLP / CNN / RNN / feature models (`harry/zoo.py`).
- [x] G8.2 Scenarios A (real CV), B (real→Jan), C (Jan→real), D (Jan B9 CV), E (Jan pretrain + real fine-tune),
      DEPLOY (`harry/jobs.py`). Identical splits, windows and metrics for her and my models.
- [x] G8.3 Per-epoch logging with held-out monitor curves (monitor only, fixed epochs), learning curves,
      per-epoch tables, confusion matrices, leaderboard, best-per-circumstance table (`harry/report.py`).
- [x] G8.4 Parallel execution: CPU process pool plus optional GPU pool (WSL2), resumable jobs, cached
      signals, in-graph augmentation (one `fit` per job), click-to-run bootstrap (`run_pipeline.py`, `.bat`).
- [x] G8.5 Hyperparameter-tuning need evaluated (`TUNING_EVALUATION.md`): not now.
- [x] G8.6 Quick-profile smoke test on the Mac: 198/198 jobs OK in 3m19s.
- [ ] G8.7 Full run on Harry's Windows laptop, then read `runs/full/report.html` and pick the deployment
      models.

### G9 — Readable results + scenario redesign (requested 2026-11-03)
- [x] G9.1 Folds only where train and test share a dataset (A, D). B and C now train on the whole training
      dataset and test once on the whole test dataset (spread from seeds). C's model doubles as E's
      pre-training.
- [x] G9.2 Official Learn fold CSV support (`paths.fold_csv`, tolerant column matching, coverage check, fallback).
- [x] G9.3 Tidy tables (`tables/*.csv`), saved figures (`figures/**.png`), report rebuilt from them, console
      leaderboard, `results_viewer.ipynb` (14 sections, verified: 168 figures / 51 tables / 0 errors on the
      quick run).
- [x] G9.4 CPU-only default (`compute.device: cpu`).

### G10 — Final models auto-exported to `model_harry/models` (requested 2026-11-03)
- [x] G10.1 EXPORT stage: every architecture trained on ALL data (Jan pre-train + real fine-tune) and exported
      as .tflite/_meta/_example/.keras; RNNs unrolled; parity verified (quick run: 20/20 TFLite at 100 %
      argmax agreement).
- [x] G10.2 Model card (`models/README.md`), `manifest.json`, `recommended/<task>/` (best TFLite by mean of
      D + E).
- [x] G10.3 Only the full profile writes to `model_harry/models`; the 2 Nov models are archived in
      `models/2026-11-02_real-data-only/`.

---

## 3. Progress log
(newest last)

- 2026-11-02 — Plan written. Python venv created in `model_harry/.venv` (TF 2.20, git-ignored).
- 2026-11-02 — Code in `harry/` (data, layers, models, train, metrics, cv, export) + scripts `check_data.py`,
  `run_cv.py`, `train_final.py`, `compare.py`.
- 2026-11-02 — G5.1 `check_data.py`: 44 files, 0 duplicates, all 375 samples, all orientation checks pass, every
  CV fold has every class in train and test (`results/data_check.md`). LOSO branch written but untested (needs a 2nd subject).
- 2026-11-02 — G6 smoke test: builtins-only TFLite export, Keras/TFLite argmax agreement 100 %, max |Δp| < 1e-5.
- 2026-11-02 — G7.3 her split reproduced exactly: HAR 288 recs / 4034 windows, her `har_cnn.tflite` 0.9078;
  social 974 recs / 13534 windows, `social_cnn.tflite` 0.6665 (matches her notebook).
- 2026-11-02 — CV launched (3 seeds × all candidates). Her architecture + recipe retrained on real data:
  HAR static 99.1 %, dynamic 38–49 %; social balanced 23 % (min class 0 %).
- 2026-11-02 — CV finished (3 seeds). HAR best = `harry_full@50` (static 99.9, dynamic 98.9). Social best =
  `harry_full@100` (balanced 83.5, every class ≥79.8). Seed std ≤ 1 pp everywhere. G2.5: 8 s beats 4 s by
  4.5 pp. G2.6: removing the gravity input costs 3 pp, so it is kept.
- 2026-11-02 — Post-hoc attribution ablation (her architecture + my recipe): HAR dynamic 95.6 (so the HAR gain is
  mostly the recipe); social 19.3 (so the social gain is entirely the representation/architecture).
- 2026-11-02 — Final models trained on all real data and exported to `models/` (builtin ops only, parity 100 %).
- 2026-11-02 — G5.2: on her datasetJan2026 split, 2 HAR + 1 social test recordings have identical copies in
  train (negligible). Lab2_2 outlier list not available locally (it was produced in Colab), so the outlier part
  is skipped.
- 2026-11-02 — G7 comparison written to `RESULTS.md`. Mine are better on Harry's real data. On other people
  (the datasetJan2026 check) mine are worse, especially dynamic (57.8 vs 86.4), because training data = 1 subject.
  The next step needs a decision (more subjects, or pre-training on datasetJan2026).
- 2026-11-03 — G8 pipeline built: `run_pipeline.py` + `pipeline.yaml` + `harry/{zoo,augment,datasets,jobs,runner,report,worker_init}.py`.
  New models `harry_mlp` and `harry_rnn`; augmentation moved into the graph. Quick profile passes (198 jobs, 0 failures).
- 2026-11-03 — G9: scenario redesign (B, C whole-dataset), fold CSV support, tables/figures/notebook; quick run 194/194 OK.
- 2026-11-03 — Learn fold CSV is not distributed to students (it only describes how marking is done); Harry will ask the organiser. D keeps Lab3 make_folds(seed 0) until then. `run_pipeline.bat` explicitly defaults to the full profile.
- 2026-11-03 — G10 export stage added; quick run exports 22 models (20 TFLite + 2 sklearn), all parity checks pass.
- 2026-11-03 — Pre-flight: fold-CSV path verified with a synthetic CSV (path column, 1-based folds); full profile = 1,089 jobs, ≈ 19 worker-hours → ≈ 3–4 h on 8 workers (RNN/CNN social Jan jobs 7–9 min each).
