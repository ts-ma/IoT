# Project knowledge base — PDIoT Coursework 3, activity and social-signal models (Harry, s2503795)

_Generated 2026-11-10 03:20 by `run_pipeline_v2.py` (stage 7). Repository commit f62538c (results produced from the working tree; the exact code is in `code/`). Read this file first; every number here comes from the tables in `tables/` (dictionary: `tables/README.md`); `WRITEUP.md` has the long-form report text and all figures; `MANIFEST.csv` lists every file._

## 1. The project in one page

- **Course:** Principles and Design of IoT Systems (PDIoT), University of Edinburgh, Coursework 3 (2026-27). Brief: `context/cw3_instructions.txt`. Group of two: Harry (s2503795, owns the models) and a teammate (s2952925, owns the app UI).
- **Sensor:** RESpeck, a chest-worn tri-axial accelerometer, 12.5 Hz, values in g. It sends 32 samples per Bluetooth packet (one packet every 2.56 s).
- **Task 1 – physical activity (11 classes):** sitting/standing (one class), lying on back / left / right / stomach (static); normal walking, shuffle walking, ascending stairs, descending stairs, running, miscellaneous movements (dynamic).
- **Task 2 – social signals (4 classes), defined only while stationary:** breathing normally, coughing, hyperventilation, other (talking, eating, singing, laughing).
- **Task 3 – app:** a Flutter app classifies both live on the phone (TensorFlow Lite), keeps a daily history, and is marked on responsiveness (results updating within 2 s score higher than within 10 s), features and UI.
- **How the models are marked:** subject-wise 10-fold cross-validation with the official fold files (`folds_daily_activity.csv`, `folds_social_signal.csv`, per activity). Accuracy = per-class recall on the held-out fold, averaged over the 10 folds. Targets: static mean ≥ 90 % (6 marks), dynamic mean ≥ 85 % (9 marks), each social class ≥ 75 % (5 marks each). Missing a target still earns partial marks. The report may present improved offline results.
- **Dates:** demo 18 Nov 2026; report (≤ 4,000 words) 15 Jan 2027; RESpeck devices returned after the demo.

## 2. Headline numbers (this run)

| metric | all test windows % | as marked (Jan2026 windows) % | target % | meets target (marked) |
|---|---|---|---|---|
| activity static mean | 99.4 | 99.4 | 90 | yes |
| activity dynamic mean | 90.7 | 90.6 | 85 | yes |
| social balanced | 81.8 | 81.7 | 75 | yes |
| weakest social class | 77.5 | 77.4 | 75 | yes |

Per class (fold mean over 3 seeds, %):

| task | class | all | jan |
|---|---|---|---|
| har | ascending | 93.8 | 93.8 |
| har | descending | 92.8 | 92.7 |
| har | lyingBack | 99.7 | 99.7 |
| har | lyingLeft | 100.0 | 100.0 |
| har | lyingRight | 100.0 | 100.0 |
| har | lyingStomach | 99.7 | 99.7 |
| har | miscMovement | 82.8 | 82.7 |
| har | normalWalking | 89.8 | 89.7 |
| har | running | 96.9 | 96.9 |
| har | shuffleWalking | 88.0 | 88.0 |
| har | sittingStanding | 97.5 | 97.4 |
| social | breathingNormally | 86.4 | 86.4 |
| social | coughing | 82.3 | 82.1 |
| social | hyperventilation | 80.2 | 80.0 |
| social | other | 78.3 | 78.2 |

Each group member as an unseen test subject (their own fold; balanced accuracy %):

| task | s2503795 | s2952925 |
|---|---|---|
| har | 97.9 | 99.0 |
| social | 93.1 | 93.7 |

## 3. Data — what exists and how every piece is used

**datasetJan2026** (provided; one CSV per recording, columns include accelX/accelY/accelZ in g):

| task | set | recordings | hours |
|---|---|---|---|
| har | listed | 1869 | 15.77 |
| har | unlisted | 50 | 0.45 |
| social | listed | 6440 | 54.24 |
| social | unlisted | 52 | 0.44 |

- *listed* = in the official fold CSV → used in cross-validation (train or test depending on the fold) and in the final models.
- *unlisted* = on disk but not in the fold CSV (unknown subjects) → never in cross-validation (could leak a test subject into training); only in the final models.
- All static daily-activity recordings are byte copies of social *breathing normally* recordings, so datasetJan2026 has no static activity data while coughing / hyperventilating / talking (see `tables/duplicates_har_social.csv`).

**Group recordings** (`IoT/data/s2503795/`, `IoT/data/s2952925/`, 44 CSVs each, recorded 5–6 Oct 2026 with the RESpeck and the app; file name `PDIOT_<uun>_<Activity>_<Sub>_<date>_<time>.csv`). Labels come from the file name:

| file activity | activity class | posture (stationary) |
|---|---|---|
| sitting | sittingStanding | sitting |
| standing | sittingStanding | standing |
| lyingdownback | lyingBack | back |
| lyingdownleft | lyingLeft | left |
| lyingdownright | lyingRight | right |
| lyingdownstomach | lyingStomach | stomach |
| normalwalking | normalWalking | – (moving) |
| shufflewalking | shuffleWalking | – (moving) |
| ascendingstairs | ascending | – (moving) |
| descendingstairs | descending | – (moving) |
| running | running | – (moving) |
| miscellaneousmovements | miscMovement | – (moving) |

| file sub-activity | social class (only if stationary) |
|---|---|
| normal | breathingNormally |
| coughing | coughing |
| hyperventilating | hyperventilation |
| talking | other |
| eating | other |
| singing | other |
| laughing | other |

**How the group recordings are used:** each member is one extra subject in the cross-validation: s2503795 → fold 8, s2952925 → fold 9 (the two smallest official folds). In that fold the member's recordings are test data; in the other nine folds they are training data (windows every 6 samples, mixed with datasetJan2026). Activities use all 44 recordings of a member; social signals only the stationary ones (sitting, standing, lying × 7 sub-activities).

| task | person | fold | recordings | test_windows |
|---|---|---|---|---|
| har | s2503795 | 8 | 44 | 616 |
| har | s2952925 | 9 | 44 | 587 |
| social | s2503795 | 8 | 38 | 494 |
| social | s2952925 | 9 | 38 | 467 |

Training windows per fold (deployed models, seed 0; exact per class in `tables/fold_training_data.csv`, test windows in `tables/fold_test_data.csv`):

| task | fold | datasetJan2026 | group members |
|---|---|---|---|
| har | 0 | 23346 | 4812 |
| har | 1 | 23342 | 4812 |
| har | 2 | 23380 | 4812 |
| har | 3 | 23405 | 4812 |
| har | 4 | 23418 | 4812 |
| har | 5 | 23400 | 4812 |
| har | 6 | 23436 | 4812 |
| har | 7 | 23469 | 4812 |
| har | 8 | 23484 | 2392 |
| har | 9 | 23446 | 2420 |
| social | 0 | 74718 | 3851 |
| social | 1 | 74758 | 3851 |
| social | 2 | 74718 | 3851 |
| social | 3 | 74735 | 3851 |
| social | 4 | 74772 | 3851 |
| social | 5 | 74748 | 3851 |
| social | 6 | 74761 | 3851 |
| social | 7 | 74746 | 3851 |
| social | 8 | 74759 | 1913 |
| social | 9 | 74798 | 1938 |

## 4. Windowing, preprocessing and models

- **Windows:** activity 50 samples (4 s); social 75 samples (6 s). Training windows every 25 samples (datasetJan2026) / 6 (group); test windows every 25 samples (2 s). Windows never cross recordings.
- **Input:** raw x, y, z in g (no preprocessing outside the model); everything below is inside the TensorFlow graph and exported to TFLite with builtin ops only.
- **Gravity** = per-axis mean over the window (posture). **Dynamic channels** (7) = x, y, z minus their means; |a| minus its mean; first differences of x, y, z. **Band power** = log mean power in fixed frequency bands via a Hann-tapered DFT matrix (activity: 0.3–1, 1–1.5, 1.5–2, 2–2.5, 2.5–3.5, 3.5–6.26 Hz; social: 0.1–0.4, 0.4–0.8, 0.8–1.5, 1.5–3, 3–6.26 Hz) of the first 4 dynamic channels, plus log-std of all 7. Each branch is z-normalised with statistics from the fold's training windows only.
- **Architectures** (all four share gravity branch → Dense, spectral branch → Dense 32, and the head Dropout 0.3 → Dense 64 → Dropout 0.3 → softmax): multi-branch **CNN** (4 Conv1D blocks with BatchNorm, dilation, global average + max pooling), **Conv-GRU** (Conv1D stem + GRU 48), **gravity-split MLP** (flattened dynamic channels → Dense 64 → Dense 64), **spectral-feature net** (no sequence branch). Full layer lists: `architectures/*.txt`.

| task | name | window_s | params | tflite_kb | ms_per_window_mac_1thread | deployed |
|---|---|---|---|---|---|---|
| har | Multi-branch CNN | 4.0 | 26112 | 130.8 | 0.0252500030910596 | True |
| har | Spectral-feature net | 4.0 | 5009 | 44.1 | 0.0069590023485943 | False |
| har | Gravity-split MLP | 4.0 | 35744 | 165.5 | 0.0098750024335458 | False |
| har | Conv-GRU | 4.0 | 21152 | 186.3 | 0.0504589988850057 | False |
| social | Multi-branch CNN | 6.0 | 42065 | 205.9 | 0.0740205068723298 | False |
| social | Spectral-feature net | 6.0 | 3874 | 52.0 | 0.008375005563721 | False |
| social | Gravity-split MLP | 6.0 | 45809 | 217.1 | 0.0117079907795414 | False |
| social | Conv-GRU | 6.0 | 20017 | 230.8 | 0.0754170032450929 | True |

## 5. Training

| setting | value | notes |
|---|---|---|
| optimiser | AdamW | keras.optimizers.AdamW |
| learning_rate | 0.002 | initial; CosineDecay to 5 % (alpha 0.05) over all steps |
| weight_decay | 0.0001 | AdamW decoupled weight decay |
| epochs | 32 | fixed; no early stopping, test fold only monitored |
| batch_size | 64 |  |
| loss | categorical cross-entropy | label smoothing 0.1 |
| train_step_jan_samples | 25 | window step on datasetJan2026 training recordings (2 s) |
| train_step_group_samples | 6 | window step on the group members' training recordings (0.48 s; they are few) |
| test_step_samples | 25 | window step of every test set (2 s) |
| class_weights_har | balanced | w_c = N / (K n_c), normalised to mean 1 over training windows |
| class_weights_social | balanced^0.6 | w_c = (N / (K n_c))^0.6, normalised to mean 1 over training windows |
| augmentation | RandomAugment (in-graph, training only) | amplitude ×U(0.8,1.25) of the gravity-free part; roll about sensor Y ±30°; tilt about a random axis ±10° (Rodrigues); Gaussian noise σ = 0.002 g |
| window_har_samples | 50 | 4 s |
| window_social_samples | 75 | 6 s |
| social_recency_training | False | if True: 50 % of training windows get their first W−k samples (k ∈ [38, 75]) replaced by another training window, gravity-aligned; label of the last k samples |
| seeds_deployed | 0,1,2 | deployed architectures; seed = 1000*seed + fold |
| seeds_other | 0 | other architectures and the class-weight sweep |
| har_recipe | mixed | 'mixed' = group members' training-fold recordings added; 'jan' = datasetJan2026 only |
| framework | TensorFlow / Keras 3, CPU | see tables/system.json |

Class weights actually applied (deployed models, mean / min / max over the 10 folds; per fold in `tables/class_weights.csv`):

| task | class | mean | min | max |
|---|---|---|---|---|
| har | ascending | 1.178 | 1.119 | 1.197 |
| har | descending | 1.315 | 1.249 | 1.335 |
| har | lyingBack | 1.001 | 0.989 | 1.039 |
| har | lyingLeft | 1.234 | 1.211 | 1.313 |
| har | lyingRight | 1.268 | 1.242 | 1.358 |
| har | lyingStomach | 0.922 | 0.914 | 0.95 |
| har | miscMovement | 1.178 | 1.12 | 1.2 |
| har | normalWalking | 1.161 | 1.101 | 1.178 |
| har | running | 1.151 | 1.09 | 1.168 |
| har | shuffleWalking | 1.176 | 1.116 | 1.195 |
| har | sittingStanding | 0.44 | 0.434 | 0.462 |
| social | breathingNormally | 1.342 | 1.34 | 1.343 |
| social | coughing | 1.406 | 1.405 | 1.406 |
| social | hyperventilation | 1.368 | 1.367 | 1.368 |
| social | other | 0.666 | 0.666 | 0.666 |

## 6. Cross-validation, testing and evaluation

1. For each fold k = 0…9 a model is trained **from scratch** on: datasetJan2026 listed recordings with fold ≠ k, plus the group member(s) whose assigned fold ≠ k. It is tested on: datasetJan2026 fold k plus the member assigned to fold k. A subject is never in both sets of a fold (official fold files; each member is one subject).
2. Epochs are fixed (32); the test fold is evaluated after every epoch only to draw learning curves — it never stops or tunes training.
3. Every test window gets a prediction (argmax of the softmax). Scores per fold: recall per class; static / dynamic / social means; plus precision, F1, macro AUC, recording-level majority vote, log-loss, calibration.
4. The same predictions are scored in several **scopes**: *all* test windows (headline), *jan* = only datasetJan2026 windows (identical to how CW3 marks), each member's windows (= unseen-person result, from the single fold that member is in).
5. Reported number = mean over the 10 folds (then over 3 seeds for the deployed models). Spread: sd over folds, sd over seeds, 95 % t-interval over folds. Comparisons: paired Wilcoxon signed-rank over the 10 folds.
6. **Final models** (the ones exported for the app) are trained once on everything: all datasetJan2026 recordings (listed + unlisted) + both members. They have no held-out test set of their own; their expected accuracy is the cross-validation result. Their Keras ↔ TFLite agreement is checked on the group recordings.

## 7. Decisions and the evidence behind them

| decision | reason | evidence |
|---|---|---|
| Gravity-split, in-model preprocessing | breathing moves the chest by ~0.007 g while gravity is 1 g; the original normalisation (÷ ~0.5 g) drowned the breathing signal (data audit 2026-11-02) | history §10 |
| Train on datasetJan2026, not only own recordings | models trained only on Harry's recordings generalised poorly to other people (B9 folds: activity dynamic 54.5 %, social balanced 46.1 %) | history/lab3_b9_folds_mine.md |
| Social class weights balanced^0.6 | fully balanced weights left 'other' at 73.0 % (below 75 %); 0.6 gave 87.2/82.3/80.8/80.3 on the official folds | history/official_folds_*_report.md; §6.7 sweep in WRITEUP |
| Group recordings mixed in, never fine-tuned on | fine-tuning social on one person dropped the other member to 70.1 %; fine-tuning activities on both members dropped datasetJan2026 dynamic from 90.7 % to 84.8 % (p = 0.002); mixing kept both | history/v1_lopo_*.csv, v1_stat_tests.csv |
| Group members as two extra fold subjects | Harry's decision (2026-11-09): use all data for training, CV, testing and evaluation; each member is tested once by a model that never saw them | decisions.json |
| Activity recipe 'mixed' | one check: mixed-in activity model, datasetJan2026 dynamic mean 90.5 % vs the 85 % rule | decisions.json (har_check) |
| Social window 6 s (w75) | fastest candidate with every class ≥ 77 % (target ≈ 4–4.5 s on screen = 2 s data transmission + 2 s detection). Candidates meeting the rule (median s until shown on our recordings): w75 5.4 s, w100rec 5.4 s, w100 6.1 s. | context/social_window_study_*, figures/real/social_window_choice |
| Deployed architectures: CNN (activity), Conv-GRU (social) | best of Harry's four on the folds (see WRITEUP §6.5 and tables/stat_tests.csv) | tables/summary_scores.csv (group baseline vs main) |
| Social shown only while not moving (app) | course feedback: social signals are only defined while stationary | app: lib/services/social_sample_processor.dart |
| Only Harry's four architectures in v2 | Harry's decision (2026-11-09) | config.py |

## 8. How the models are used in the app

- App: Flutter project copy at `/Users/harryyang/IoT-ui-enhancement-v2.0-harry` (not a git repository). Models are loaded from `assets/models/` (`harry_har_cnn.tflite`, `harry_social_rnn.tflite` + `_meta.json` + `_example.json`). **This run's models are exported only** (`pipeline_v2/models/`, see `models/INSTALL.md`); the app still ships the models exported on 2026-11-03 (8 s social window, fine-tuned on s2503795).
- Live logic: samples arrive in packets of 32 (2.56 s); both models classify the latest window every 6 samples (0.5 s, Settings: 0.5/1/2 s); the activity shown is the majority of the last 3 results (smoothing, on by default); social results are paused while the shown activity is dynamic; history stores raw results with the interval they stand for; 'times coughed' counts coughing results < 5 s apart as one time and ignores a lone result.
- Measured responsiveness (app replay on the group recordings, `history/app_latency_replay.csv`): activity about 4 s from a change to the screen after the 2026-11-09 smoothing fix (about 6 s before); social 6–7 s with the 8 s window.
- On-phone tools for the report: Tools → Real-time test (per-class accuracy, first-correct and shown latency, CSV) and Latency test (cued changes timed on the phone, CSV); Performance tab (CPU, memory, battery, inference time, log with a conditions file).

## 9. Results — where to find each number

| question | answer in |
|---|---|
| marked accuracy per class / group | §2 here; WRITEUP §1, §6.1; tables/summary_per_class.csv (variant = jan) |
| accuracy including the group members' test windows | tables/summary_per_class.csv (variant = all) |
| per fold, per seed | tables/per_fold_class.csv, fold_scores.csv |
| how good on an unseen real person | tables/person_per_class.csv, person_postures.csv; WRITEUP §6.8 |
| which classes are confused | tables/confusion_long.csv; figures/results/confusion_*; WRITEUP §6.3 |
| how each architecture compares | tables/summary_scores.csv (group baseline); stat_tests.csv; WRITEUP §6.5 |
| what data trained / tested fold k | tables/fold_training_data.csv, fold_test_data.csv; jobs/<id>.json (job.train, job.tests) |
| exact hyper-parameters and class weights | tables/recipes.csv, class_weights.csv; jobs/<id>.json (info.train_recipe) |
| learning curves / over-fitting | tables/epochs.csv; figures/training/ |
| why this social window / speed | context/social_window_study_*; WRITEUP §6.6; figures/real/social_window_choice |
| effect of class weights | WRITEUP §6.7; tables/summary_per_class.csv (group sweep) |
| where are the trained / exported models | pipeline_v2/models/ (app files + INSTALL.md); results/jobs/models/ (per-fold Keras models, seed 0) |
| model size, speed, parity | tables/deploy.csv, architectures.csv; WRITEUP §6.9 |
| data quality of the group recordings | tables/real_data_quality.csv; WRITEUP §2.2 |
| earlier experiments and why choices changed | §10 here; history/ |
| exact code | code/ (README inside) |
| compute, environment | tables/system.json, timing.csv, run.log |

## 10. History (dated; Harry's models only)

- **2026-10-05/06** — both members record the CW2 protocol (44 recordings each).
- **2026-11-02** — data audit: static activity files are copies of social breathing files; datasetJan2026 `N_x` names are recording indices, not subjects; breathing ≈ 0.007 g within a window → gravity-split, in-model preprocessing designed.
- **2026-11-02/03** — first models trained on Harry's own recordings only generalise poorly to datasetJan2026 (Lab 3 B9 folds: activity dynamic 54.5 %, social balanced 46.1 %). Trained on datasetJan2026 instead (B9 folds: activity static 97.2 / dynamic 90.9 %, social balanced 82.0 % on 2 folds) → `history/lab3_b9_folds_mine.md`.
- **2026-11-03** — app models exported: `harry_har_cnn` and `harry_social_rnn` (8 s), datasetJan2026 pre-training + fine-tune on s2503795; app update interval made a setting.
- **2026-11-09 (morning)** — official fold CSVs arrive. Official 10-fold CV, datasetJan2026 only, seed 0: activity CNN static 99.3 / dynamic 90.5 %; social Conv-GRU with balanced weights 90.3 / 85.5 / 82.7 / 73.0 % ('other' fails) → weights balanced^0.6: 87.2 / 82.3 / 80.8 / 80.3 % (all pass) → `history/official_folds_*`.
- **2026-11-09** — tests on the members (models trained on datasetJan2026 only): social 95.1 % (s2503795) / 89.6 % (s2952925) with ^0.6; the shipped social model (fine-tuned on s2503795) only 76.7 % on s2952925 → no fine-tuning on one person. Activity 98.5/98.2 % (s2503795) and 97.0/97.0 % (s2952925) static/dynamic; the datasetJan2026-only activity model calls 5–18 % of coughing/hyperventilation windows 'moving' → `history/real_people_*`.
- **2026-11-09** — v1 report pipeline (`final_run/`): activity datasetJan2026-only 99.3 / 90.7 % vs fine-tuned on the members 99.0 / 84.8 % (dynamic −5.9 points, worse in all 10 folds, p = 0.002); social datasetJan2026 only 82.6 % vs members mixed in 82.7 %; leave-one-person-out with mixing best for both tasks; class-weight sweep confirms 0.6 → `history/v1_*.csv`.
- **2026-11-09** — app analysis: 32-sample packets (2.56 s) set the update floor; a smoothing bug (one result per packet) cost ~2 s; fixed, default step 0.5 s; social paused while moving → `history/app_latency_replay.csv`.
- **2026-11-09** — social window study (4/5/6/8 s, 8 s recency) → chosen w75 → `history/social_window_study_report.md`.
- **2026-11-09 (night)** — v2 (this run): only Harry's four architectures; one data split (members as fold subjects, mixed); export only.

## 11. Caveats an answer should mention

- The group members are two people; their per-person results come from one fold each.
- Hyper-parameters (epochs, learning rate) were fixed from earlier experiments; the class-weight power and the social window were chosen using results on the official folds — the sweep and the window study are shown as sensitivity analyses.
- The headline scope includes the group members' windows (a fold with a member has more test windows); the marked scope excludes them, so the two differ slightly.
- Window-level results are correlated within a recording; statistics are therefore over folds.
- Live accuracy, latency, CPU, memory and battery on the phone must be measured with the app (Tools / Performance tabs); this folder only contains offline results and replays.

## 12. Glossary

- **window**: a fixed-length slice of the signal the model classifies. **step**: samples between consecutive windows. **fold**: one of 10 groups of subjects; *fold k* = trained without them, tested on them. **recall**: share of a class's windows recognised. **balanced accuracy**: mean recall over classes. **scope**: which test windows a score counts. **seed**: random initialisation / augmentation / batch order. **gate / pause**: app rule that hides social results while moving. **recency training**: splicing the start of another window onto a training window so the label follows the most recent seconds.
