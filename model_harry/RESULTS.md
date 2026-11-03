# Results — teammate's models vs model_harry (2026-11-02)

Full tables: `results/tables.md`. Raw numbers: `results/comparison.json`, `results/cv_*.json`,
`results/ablation_*.json`. Data checks: `results/data_check.md`. Problems and goals: `PLAN.md`.

## How it was measured

- **Real data:** `IoT/data/s2503795`, 44 × 30 s, one subject. Metrics mirror the CW3 marking: per-class
  recall in each fold, then the mean over folds. The test windows are identical for every model (4 s or
  8 s window, 1 s step).
  - **HAR:** 5 folds. Static recordings are held out whole by behaviour (normal / coughing /
    hyperventilating / talking+eating / singing+laughing). Each dynamic recording is cut into 5 time
    blocks.
  - **Social:** 6 folds, leave-one-posture-out (the test posture is never seen in training).
- **Her models** were scored in two ways:
  - **as shipped:** her `.tflite` files from `model/`. She never saw this data, so this is a fair test;
  - **retrained:** her exact architecture and recipe inside the same CV.
- **My models:** 3 seeds each. Seed std ≤ 1 pp everywhere, so the gaps below are not seed noise.
- **Casual check:** her exact held-out `datasetJan2026` test split, reproduced to the window (4034 / 13534
  windows; her `har_cnn` gives 0.9078 and `social_cnn` 0.6665, matching her notebook).

## Headline numbers (per-class recall, %)

### HAR (model chosen: `harry_full@50`, 26 k params, 132 KB TFLite)
| model | static mean | dynamic mean | sittingStanding | miscMovement | rotated 30° |
|---|---|---|---|---|---|
| `har_cnn.tflite`, hers as shipped | 95.2 | 98.9 | 76.1 | 93.3 | 92.3 |
| her architecture + recipe, retrained on real data | 99.1 | 41.9 | 95.5 | 64.4 | 62.2 |
| her architecture + **my recipe** (ablation) | 99.9 | 95.6 | 99.3 | 73.3 | 97.6 |
| **mine (`harry_full@50`)** | **99.9** | **98.9** | **99.3** | 93.3 | **97.9** |

Her shipped model's posture errors come from **sitting/standing while hyperventilating (75 %) or laughing
(82 %)**; posture recall broken down by behaviour is in `tables.md`. This is problem P8: her training
posture classes only ever contained normal breathing. Mine gets ≥99.4 % for every behaviour.

### Social signals (model chosen: `harry_full@100`, 8 s window, 42 k params, 226 KB TFLite)
| model | balanced | breathing | coughing | hyperventilation | other | rotated 30° |
|---|---|---|---|---|---|---|
| `social_cnn.tflite`, hers as shipped | 69.6 | 48.8 | 51.2 | 90.5 | 88.0 | 69.1 |
| `social_mlp.tflite`, hers as shipped | 25.0 | 0 | 0 | 0 | 100 | 25.0 |
| her architecture + recipe, retrained on real data | 23.1 | 11.1 | 27.8 | 5.6 | 47.8 | 23.6 |
| her architecture + **my recipe** (ablation) | 19.3 | 16.7 | 34.3 | 0.0 | 26.2 | 24.2 |
| mine, 4 s window | 79.0 | 84.3 | 75.2 | 80.2 | 76.5 | 75.6 |
| mine, 8 s, no gravity input | 80.5 | 84.3 | 75.4 | 83.6 | 78.7 | 78.8 |
| mine, 8 s, feature-only head | 82.3 | 84.3 | 77.8 | 87.0 | 80.2 | 82.5 |
| **mine (`harry_full@100`)** | **83.5** | **90.3** | **82.4** | **81.4** | **79.8** | **80.5** |

All four of my class means are above the 75 % target. Her shipped CNN misses it for breathing and coughing,
whose windows mostly fall into `other`: 86/168 and 81/168. My remaining error runs the other way, with
`other` → breathing or coughing (112/460 windows). The fold-to-fold spread is large (≈7 pp std); the hardest
posture fold is the worst case (minimum class recall ≈56 %).

### Casual check on datasetJan2026 (her held-out test split, other people)
| model | HAR static / dynamic | social balanced |
|---|---|---|
| hers (`har_cnn`, `social_cnn`) — trained on this dataset's train split | 96.9 / 86.4 | 54.9 |
| mine — trained on one person, 44 files | 92.5 / **57.8** | **47.4** |

## What the evidence says

1. **Social: the input representation was the bug, not the recipe.** Her architecture stays at chance level
   on real data with or without my recipe (23 % and 19 %). With gravity removed in-model, an 8 s window and
   balanced training, the score is 83.5 %. This confirms P1–P4.
2. **HAR: on real data the gain is mostly the training recipe.** Dense windows, fresh augmentation,
   balanced weights and regularisation move her own architecture from 41.9 % to 95.6 % dynamic. My
   multi-branch architecture adds the rest: 98.9 % dynamic and miscMovement 73 → 93 %. Her shipped model
   already transfers well to dynamic activities on my data (98.9 %, a genuine cross-person test). Its real
   weakness is posture under non-normal behaviour (P8).
3. **Robustness to sensor roll** (30° about Y): mine loses 1–3 pp; her shipped models lose 1–5 pp; her
   architecture retrained on real data loses up to 8 pp.
4. **Main limitation: my models are trained on one person.**
   - On other people (the `datasetJan2026` check) they are worse than hers, especially for dynamic
     activities (57.8 % vs 86.4 %).
   - My within-subject CV numbers for dynamic classes are optimistic: test blocks come from the same 30 s
     session.
   - So mine are the better models for Harry's own live demo; hers generalise better to strangers. Neither
     is good on the `datasetJan2026` social split (≤55 % balanced).

## Recommended next steps (not done; need your decision)

- **A. Add the other group members' 44-file folders to `IoT/data/<uun>/`** (the best option). The pipeline
  switches to leave-one-subject-out automatically. This is the only way to measure cross-person accuracy
  on real data, and the demo involves every group member.
- **B. If allowed, pre-train on `datasetJan2026` and fine-tune on real data.** The
  architecture changes carry over, and an earlier numpy probe on that dataset suggested ≈72–74 % balanced
  social against her 54.9 %. This needs your approval because of the data policy.
- **C. App side** (for your teammate; nothing changed here):
  - Copy `models/harry_<task>.{tflite,_meta.json,_example.json}` into `assets/models/` (Lab 4 Part 4).
  - Smooth predictions: average the probabilities of the last 3 predictions.
  - Show the social result only when HAR predicts a static class.
  - Do not ship `model/social_mlp.tflite` (it always predicts `other`) or `model/har_cnn_full_int8.tflite`
    (int8 input, which the template does not support).

## Deliverables in `models/`
| file | window / step | input / output | TFLite vs Keras |
|---|---|---|---|
| `harry_har.tflite` (+ `_meta.json`, `_example.json`, `.keras`) | 50 / 25 (4 s / 2 s) | `[1,50,3]` raw g → 11 softmax | argmax 100 %, max Δp 3.6e-7 |
| `harry_social.tflite` (+ `_meta.json`, `_example.json`, `.keras`) | 100 / 25 (8 s / 2 s) | `[1,100,3]` raw g → 4 softmax | argmax 100 %, max Δp 1.4e-5 |

Both use builtin TFLite ops only (no Flex) and follow the Lab 4 contract, so the app template loads them by
changing the two asset paths. The social model's first prediction arrives after 8 s; after that it updates
every 2 s.

---

## Lab3-B9 subject-wise 10-fold CV on datasetJan2026 (added 2026-11-03, at Harry's request)

This is an explicit exception to the real-data-only policy. B9 needs many subjects, so it has to train on
`datasetJan2026`.

**Folds:** an exact replica of B9 `make_folds()` (seed 0). The per-activity fold table is identical to her
notebook. The official Learn fold CSV is still not available.

**Models:** both are retrained per fold for 32 fixed epochs, with training and test windows at step 25.
- **Hers:** her CNN with her B9 recipe. Per-fold HAR accuracy matches her notebook within ±0.6 pp (fold 0:
  91.1 vs 91.4; fold 9: 92.1 vs 92.1).
- **Mine:** `harry_full` (HAR 4 s, social 8 s) with my recipe, using the same epoch and window budget as hers.

**Social caveat:** in `social_signal` the `N_x` file names are recording indices, not subjects. So B9 folds for
social are recording-wise, not truly subject-wise.

Graded metric, per-class recall (%), mean over folds. Full table: `results/b9_tables.md`.

| task | model | folds | window acc (B9 metric) | static mean | dynamic mean | social balanced | weakest class |
|---|---|---|---|---|---|---|---|
| HAR | hers | 10 | 91.3 ± 1.2 | 97.3 | 86.2 | – | miscMovement 75.9 |
| HAR | **mine** | 10 | **93.6 ± 1.1** | 97.2 | **90.9** | – | miscMovement 83.9 |
| HAR | mine as shipped (trained on IoT/data only) | 10 | 71.6 ± 2.2 | 93.3 | 54.5 | – | ascending 18.5 |
| social | hers | 10 | 66.7 ± 1.3 | – | – | 56.8 | hyperventilation 40.1 |
| social | **mine** | 2 of 10 (run in progress) | 79.8 ± 0.2 | – | – | **82.0** | other 75.8 |
| social | mine as shipped (trained on IoT/data only) | 10 | 60.0 ± 1.2 | – | – | 46.1 | hyperventilation 20.4 |

**Reading it:**
- Under the marking protocol, my architecture and recipe beat hers on both tasks.
- HAR: dynamic +4.7 pp (normalWalking +5.2, shuffleWalking +6.6, miscMovement +8.0). Static is unchanged.
- Social: +25 pp balanced. Her breathing and hyperventilation recalls are 43 % and 40 %; mine are 91 % and 80 %.
- The models trained only on Harry's data do not transfer to other people. To get both, train the improved
  architecture on `datasetJan2026` and fine-tune on real data (option B above).
