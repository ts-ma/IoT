# Lab3-B9 subject-wise 10-fold CV on datasetJan2026

Folds = exact replica of B9 `make_folds()` (seed 0); identical per-activity fold table to her notebook. Test windows: step 25. Graded metric = per-class recall per fold, averaged within the group, mean over 10 folds.

## HAR

| model | folds | window acc (B9 metric) | STATIC_MEAN | DYNAMIC_MEAN | sittingStanding | lyingBack | lyingLeft | lyingRight | lyingStomach | normalWalking | shuffleWalking | ascending | descending | running | miscMovement | recording vote |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| mine — harry_full + my recipe (retrained per fold) | 10 | 93.6 ± 1.1 | 97.2 | 90.9 | 94.4 | 97.5 | 96.8 | 98.0 | 99.2 | 90.2 | 88.0 | 93.8 | 93.0 | 96.4 | 83.9 | 95.8 |
| mine as shipped — trained on IoT/data only, no datasetJan2026 training | 10 | 71.6 ± 2.2 | 93.3 | 54.5 | 77.3 | 96.9 | 95.0 | 98.1 | 99.1 | 28.8 | 37.3 | 18.5 | 76.6 | 96.1 | 69.6 | 73.7 |

## SOCIAL

| model | folds | window acc (B9 metric) | BALANCED | MIN_CLASS | breathingNormally | coughing | hyperventilation | other | recording vote |
|---|---|---|---|---|---|---|---|---|---|
| mine — harry_full + my recipe (retrained per fold) | 2 | 79.8 ± 0.2 | 82.0 | 75.8 | 90.6 | 81.6 | 79.8 | 75.8 | 84.0 |
| mine as shipped — trained on IoT/data only, no datasetJan2026 training | 10 | 60.0 ± 1.2 | 46.1 | 19.0 | 24.6 | 55.0 | 20.4 | 84.4 | 61.6 |
