# model_harry

Harry's rework of the HAR and social-signal models. It is trained on the **real** recordings in `IoT/data/`.
The teammate's `model/` folder and `Lab3_trained.ipynb` are not modified.

- `PLAN.md`: every problem found in the original models, the correction goals, the TODO checklist and the
  progress log.
- `RESULTS.md`: comparison against the original models, with conclusions and limitations.

## Layout
```
harry/data.py      real-data loader, labels, CV fold schemes, datasetJan2026 check-set loader
harry/layers.py    TFLite-safe in-model preprocessing (gravity split, |x|, jerk, fixed-DFT band power)
harry/models.py    teammate CNN replica (control) + multi-branch models; CANDIDATES list
harry/train.py     training recipes (teammate vs harry) + per-epoch augmentation
harry/metrics.py   per-class recall, static/dynamic/social group means (mirrors the CW3 marking)
harry/cv.py        CV runner, rotation-robustness probe
harry/export.py    TFLite export in the Lab 4 contract (+ _meta.json, _example.json), TFLite runner
check_data.py      data and fold sanity checks          -> results/data_check.md
run_cv.py          CV for every candidate x 3 seeds     -> results/cv_<task>.json
train_final.py     select best candidate, train on all real data, export -> models/harry_<task>.tflite
compare.py         her .tflite vs mine on the real CV folds + datasetJan2026 casual check -> results/tables.md
```

## Reproduce
```bash
cd model_harry
python3.13 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python check_data.py
.venv/bin/python run_cv.py --task har
.venv/bin/python run_cv.py --task social
.venv/bin/python train_final.py
.venv/bin/python compare.py
```
To add more people, drop their cleaned 44-file folder into `IoT/data/<uun>/`. CV then switches to
leave-one-subject-out automatically. Delete `results/cv_*.json` first so old runs are not mixed in.

## Using the exported models in the app
Copy `models/harry_<task>.tflite`, `_meta.json` and `_example.json` into `assets/models/`, exactly as
`Lab4_Guide` Part 4 describes. Input is `[1, W, 3]` raw g (float32) and the output is softmax. Normalisation
and features are inside the model. `window_samples` is read from the meta file, so an 8 s social window needs
no code change.

---

## One-click pipeline (`run_pipeline.py`): her vs my models, every scenario

Trains, tests and cross-validates **her architectures and mine under identical data, windows and metrics**,
group by group (MLP → CNN → RNN → FEATURE).

| scenario | train on → test on | folds? |
|---|---|---|
| A | real (`IoT/data`) → real | **yes**, same dataset. 1 subject: behaviour/time-block (HAR), leave-one-posture-out (social); ≥2 subjects: leave-one-subject-out |
| B | **all** real → **all** Jan2026 | no, different datasets. Spread comes from 3 seeds |
| C | **all** Jan2026 → **all** real | no. 3 seeds. This model is also E's pre-trained model |
| D | Jan2026 → Jan2026 | **yes**, Lab3-B9 10-fold (or the official Learn folds, see below) |
| E | C's model fine-tuned on each real training fold → real | yes, A's folds, so A vs E shows what pre-training adds |
| DEPLOY | – | TFLite size, builtin-op check, ms/window |

**Why folds only in A and D:**
- Cross-validation is a testing method for when train and test must come from the *same* dataset. Every
  recording gets tested once, by a model that never saw it (or its subject).
- When train and test are different datasets (B, C), folds add nothing. Splitting the test set only
  re-cuts the same predictions, and splitting the training set only throws data away.
- After CV has told you how good a recipe is, the model you actually deploy is trained on all the data.

| group | hers (replicas of `Lab3_trained.ipynb`) | mine |
|---|---|---|
| MLP | `her_mlp` | `harry_mlp` |
| CNN | `her_cnn` (shipped), `her_cnn_bn`, `her_cnn_k3`, `her_cnn_3conv` | `harry_cnn` |
| RNN | `her_lstm` (shipped as `har_rnn`) | `harry_rnn` |
| FEATURE | `her_logreg` (her B2 best, sklearn) | `harry_feat` |

### Run it on Windows (CPU)
1. Install **Python 3.12** from python.org (tick "Add python.exe to PATH"). TensorFlow does not support
   3.14 yet.
2. `datasetJan2026` is found automatically at `IoT/data/datasetJan2026` or `IoT/datasetJan2026`;
   otherwise you are asked for its path.
3. **Double-click `run_pipeline.bat`.**
   - The first run creates `.venv-win` and installs the requirements (a few minutes).
   - All 32 threads are used (8 parallel workers × 4 threads).
   - The report opens in your browser at the end.
   - Double-clicking always runs the **full** profile. For an optional smoke test (≈ 5–15 min), run
     `run_pipeline.bat --profile quick` from a terminal.
4. Closing the window stops the run; double-clicking again **resumes**, because finished jobs are skipped.

Full profile: 1,089 jobs, **roughly 3–4 h on the i9**. The slowest are my CNN/RNN on Jan2026 social signals (≈ 7–9 min each per worker). The terminal prints one line per finished job,
and every 5 min a leaderboard of the numbers so far.

### Where the results are (`runs/<profile>/`)
| what | file |
|---|---|
| **Interactive viewer** | `results_viewer.ipynb` (in `model_harry/`; set `RUN = "full"`, then Run All): progress, leaderboard heatmap, best per circumstance, CW3 targets, group-by-group bars + learning curves, per-epoch tables, per-class recall, fold spread, confusion matrices, rotation robustness, accuracy vs phone cost, training time, previous (2 Nov) experiments |
| Report | `report.html` (open in a browser, rebuilt every 5 min while running) and `summary.md` |
| Figures | `figures/<task>/...png` (every chart from the report, browsable in Explorer) |
| Numbers | `tables/runs.csv`, `per_class.csv`, `epochs.csv`, `confusion.csv`, `deploy.csv`, `status.csv`, `leaderboard_<task>.csv`, `best_<task>.csv` (open in Excel) |
| Per-run training log | `jobs/<id>.log`: one line per epoch (train loss/acc, held-out loss/acc/score) |
| **Final models** | **`model_harry/models/`** (full profile only), described below |

### Final models in `model_harry/models/` (updated automatically by every full run)
After the experiments, every architecture (hers and mine, all groups) is trained once more on **all
available data**:
- **Keras models:** pre-train on all of Jan2026, then fine-tune on all of your real recordings.
- **Sklearn model (`her_logreg`):** one fit on both datasets.

| path | content |
|---|---|
| `models/<task>/<GROUP>/<model>.tflite` + `_meta.json` + `_example.json` | Lab 4 format, ready for the app (RNNs exported unrolled, builtin ops only; Keras/TFLite parity is checked) |
| `models/<task>/<GROUP>/<model>.keras` | the same model in Keras, for further training |
| `models/README.md` | **model card**: every model's size, params, window and score in scenarios A–E, plus the recommended one ★ |
| `models/recommended/<task>/` | copy of the best TFLite model per task (by mean of D + E, set in `pipeline.yaml → export`) |
| `models/manifest.json` | the same as the card, machine-readable |
| `models/2026-11-02_real-data-only/` | the earlier models (trained on the real data only), kept for reference |

Layout (11 architectures × 2 tasks; GROUP = MLP | CNN | RNN | FEATURE):
```
models/
  har/    MLP/ her_mlp.*  harry_mlp.*      CNN/ her_cnn.*  her_cnn_bn.*  her_cnn_k3.*  her_cnn_3conv.*  harry_cnn.*
          RNN/ her_lstm.* harry_rnn.*      FEATURE/ her_logreg.pkl  harry_feat.*
  social/ (same)
  recommended/har/   recommended/social/   README.md   manifest.json   2026-11-02_real-data-only/
```
Quick runs never touch `model_harry/models`; they export to `runs/quick/exported_models/`.

The `jobs/*.json` files are only the pipeline's raw store for resuming; you never need to open them. To
open the notebook, double-click nothing: run `.venv-win\Scripts\jupyter lab` in `model_harry/`, or open
the `.ipynb` in VS Code and pick the `.venv-win` interpreter.

### Official Learn folds (optional; not available to students as of 2026-11-03, organiser to be asked)
- **What it is:** the CW3 instructions say the marked accuracy uses "subject-wise 10-fold cross-validation
  … fold assignments provided on Learn". It is a CSV that assigns each `datasetJan2026` recording to fold
  0–9.
- **Where to get it:** download it from the PDIoT course page on Learn (Coursework 3 / Lab 3 materials).
- **How to use it:**
  1. Save it as, e.g., `IoT/folds/pdiot_folds.csv`.
  2. Set `paths.fold_csv: ../folds/pdiot_folds.csv` in `pipeline.yaml`.
  3. Re-run with `--fresh`, or delete `runs/full/jobs/D*`, so D is retrained on the official folds.
- **Accepted layouts:** `activity, file, fold` as in Lab 3 B9, plus common variants (a file path instead
  of a name, 1-based folds).
- **Coverage check:** the pipeline prints how many recordings it matched. If the CSV doesn't cover a task,
  that task falls back to Lab 3 `make_folds(seed 0)`, the same folds your teammate used.

### Recipes (fixed in advance; Lab 3 rules: fixed epochs in CV, never early-stop on a test fold)
- **Hers:** Adam 1e-3, 32 epochs, train step 25 (her B9).
- **Mine:**
  - AdamW with cosine-decay learning rate, label smoothing 0.1, balanced class weights, and in-graph
    augmentation (rotation, amplitude, noise);
  - 60 epochs / step 6 on real data, 32 epochs / step 25 on Jan2026 (same budget as hers).
- **Fine-tune (E):** hers Adam 1e-4 × 15 epochs; mine AdamW 5e-4 × 30 epochs.

### GPU (optional, not needed)
- TensorFlow ≥ 2.11 cannot use the GPU on native Windows.
- To use the RTX 4060, run the same command inside WSL2 Ubuntu and set `compute.device: auto` in
  `pipeline.yaml`. The bootstrap installs `tensorflow[and-cuda]` there.

### Hyperparameter tuning
See `TUNING_EVALUATION.md`. The verdict is that it isn't needed yet; it includes a design for doing it
without biasing the reported numbers.
