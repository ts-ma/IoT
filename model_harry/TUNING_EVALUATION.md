# Do we need automatic hyperparameter tuning? — evaluation (2026-11-03)

**Proposal under evaluation:** a YAML file lists the candidate values for each hyperparameter, separated by
semicolons, and a runner iterates over the combinations to find the best one.

## Verdict: not now. It is worth doing later, on a small search space, with a protocol that does not
## reuse the reporting folds.

### 1. What the evidence says about where the accuracy comes from
| change | measured effect | source |
|---|---|---|
| Gravity-free input + spectral branch (social) | **+25 pp** balanced, B9 (56.8 → 82.0) | `results/b9_tables.md` |
| Training recipe (dense windows, augmentation, balanced weights) on her CNN, real data | **+54 pp** dynamic (41.9 → 95.6) | `RESULTS.md` ablation |
| Multi-branch HAR architecture vs hers, B9 | **+4.7 pp** dynamic (86.2 → 90.9) | `results/b9_tables.md` |
| Social window 4 s → 8 s (real data) | **+4.5 pp** balanced | `results/cv_social.json` |
| Her B3 variants (BN, kernel 3, 3 conv layers) | **±0.8 pp** (≈ noise) | her notebook |
| Seed-to-seed variation | **≤ 1 pp** | `results/cv_*.json` |
| Fold-to-fold std | 1.1–1.3 pp (B9) · 7 pp (real social) | both |

Representation, architecture and recipe moved results by 5–50 pp. The classic tunables (learning rate,
dropout, filter counts, kernel size) moved them by about 1 pp, roughly the size of the noise. Typical
tuning gains on problems like this are 1–3 pp.

### 2. Where tuning could still pay off
These are the only places within 1–10 pp of a CW3 threshold:
- **Social minimum class** (`other` 75.8 % against the 75 % target, B9 run partial): window length,
  class-weight strength, augmentation amplitude.
- **HAR `miscMovement`** (83.9 %) and the **dynamic mean** (90.9 % against 85 %): already passes, so there is
  low priority.
- **Window length**, the single biggest knob left (+4.5 pp measured). It is cheap to test as a few named
  candidates in `zoo.py`, with no tuner needed.

### 3. Why not run it right now
- **Selection bias.** If we pick the best of N combinations on the same 10 folds we report, the reported
  number is inflated. With fold std ≈ 1.2 pp and N ≈ 50, the expected optimism of the maximum is about
  2.5 × 1.2 ≈ 3 pp, the same size as the hoped-for gain. A fair tuner needs nested CV or a held-out
  confirmation set.
- **Cost of a full grid.** 4 windows × 3 lr × 3 dropout × 3 augmentation × 2 class-weight = 216 combinations.
  At ≈ 6 min per social B9 fold × 10 folds, that is about 216 worker-hours (≈ 27 h with 8 workers on the
  i9) for one task. A grid with semicolon lists grows multiplicatively, so random search or successive
  halving is the right search method, not a full grid.
- **The data is about to change.** The official Learn folds and the teammates' real recordings are still
  missing. Tuning before they arrive would have to be redone.

### 4. If and when we do it (proposed design, not implemented)
- **Search space:** `tuning.yaml` with semicolon-separated choices, kept small:
  ```yaml
  task: social
  model: harry_cnn
  window: "75; 100; 125"
  lr: "1e-3; 2e-3; 4e-3"
  dropout: "0.2; 0.3; 0.4"
  aug_roll_deg: "15; 30"
  class_weight_power: "0.5; 1.0"      # 1.0 = fully balanced
  budget: {trials: 30, method: random+halving}
  ```
- **Protocol (no peeking):**
  1. Tune on B9 folds 0–7, using inner CV over 3 folds with the halving rule.
  2. Confirm the top 3 on folds 8–9 and on the real data (scenario C).
  3. Report the final pick on all 10 folds, and state that it was tuned.
- **Runner:** reuse `run_pipeline.py`'s worker pool. A trial is just a job with overridden kwargs, so
  parallelism and resumability come for free.
- **Cost:** about 30 trials × 3 inner folds × 6 min ≈ 9 worker-hours, i.e. **≈ 1–1.5 h on the i9 with
  8 workers per task**, less with halving.

**Recommendation:**
1. Run the full pipeline first.
2. Add 2–3 window-length candidates by hand.
3. Build the tuner only if the social minimum class is still below 75 % on the official folds.
