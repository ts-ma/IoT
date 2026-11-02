### HAR — real data, within-subject CV (fold-mean per-class recall, %)

| model | trained on | STATIC_MEAN | DYNAMIC_MEAN | sittingStanding | lyingBack | lyingLeft | lyingRight | lyingStomach | normalWalking | shuffleWalking | ascending | descending | running | miscMovement | rot 15° | rot 30° |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **har_cnn.tflite** (hers, as shipped) | datasetJan2026 | 95.2 | 98.9 | 76.1 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 93.3 | 95.0 | 92.3 |
| **har_cnn_dynamic.tflite** (hers, as shipped) | datasetJan2026 | 95.2 | 98.9 | 75.9 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 93.3 | 95.6 | 92.3 |
| **har_cnn_full_int8.tflite** (hers, as shipped) | datasetJan2026 | 93.4 | 98.9 | 67.5 | 99.6 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 93.3 | 92.2 | 89.0 |
| **har_mlp.tflite** (hers, as shipped) | datasetJan2026 | 94.7 | 62.2 | 73.4 | 100.0 | 100.0 | 100.0 | 100.0 | 40.0 | 26.7 | 100.0 | 6.7 | 100.0 | 100.0 | 79.0 | 79.8 |
| **har_rnn.tflite** (hers, as shipped) | datasetJan2026 | 97.5 | 80.0 | 87.5 | 100.0 | 100.0 | 100.0 | 100.0 | 93.3 | 66.7 | 100.0 | 20.0 | 100.0 | 100.0 | 86.0 | 84.4 |
| teammate_cnn@50 (her arch + recipe, 3 seeds) | real (CV) | 99.1 | 41.9 | 95.5 | 100.0 | 100.0 | 100.0 | 100.0 | 0.0 | 24.4 | 53.3 | 8.9 | 100.0 | 64.4 | 69.5 | 62.2 |
| harry_full@50 (mine, 3 seeds) | real (CV) | 99.9 | 98.9 | 99.3 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 93.3 | 99.2 | 97.9 |
| harry_feat@50 (mine, 3 seeds) | real (CV) | 98.1 | 95.2 | 91.4 | 100.0 | 99.5 | 100.0 | 99.5 | 100.0 | 97.8 | 100.0 | 88.9 | 100.0 | 84.4 | 95.9 | 95.1 |
| teammate_cnn+harry_recipe@50 (her arch + recipe, 3 seeds) | real (CV) | 99.9 | 95.6 | 99.3 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 73.3 | 97.6 | 97.6 |

Static-posture recall split by the behaviour performed during the recording (%):

| model | coughing | eating | hyperventilating | laughing | normal | singing | talking |
|---|---|---|---|---|---|---|---|
| har_cnn | 94.0 | 100.0 | 75.0 | 82.1 | 100.0 | 100.0 | 100.0 |
| teammate_cnn@50 | 100.0 | 53.6 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 |
| harry_full@50 | 100.0 | 100.0 | 99.4 | 100.0 | 100.0 | 100.0 | 100.0 |
| harry_feat@50 | 99.4 | 100.0 | 86.3 | 100.0 | 100.0 | 100.0 | 100.0 |
| teammate_cnn+harry_recipe@50 | 100.0 | 94.6 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 |

Casual check on datasetJan2026 (her held-out test split, har):

| model | STATIC_MEAN | DYNAMIC_MEAN | sittingStanding | lyingBack | lyingLeft | lyingRight | lyingStomach | normalWalking | shuffleWalking | ascending | descending | running | miscMovement | window acc | recording vote |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| har_cnn | 96.9 | 86.4 | 90.1 | 100.0 | 94.3 | 100.0 | 100.0 | 73.4 | 84.1 | 89.9 | 90.5 | 97.5 | 82.9 | 90.8 | 91.7 |
| harry_final | 92.5 | 57.8 | 73.4 | 100.0 | 89.0 | 100.0 | 100.0 | 26.9 | 42.8 | 22.3 | 85.2 | 96.4 | 73.6 | 72.5 | 74.7 |

### SOCIAL — real data, within-subject CV (fold-mean per-class recall, %)

| model | trained on | BALANCED | MIN_CLASS | breathingNormally | coughing | hyperventilation | other | rot 15° | rot 30° |
|---|---|---|---|---|---|---|---|---|---|
| **social_cnn.tflite** (hers, as shipped) | datasetJan2026 | 69.6 | 35.1 | 48.8 | 51.2 | 90.5 | 88.0 | 68.1 | 69.1 |
| **social_mlp.tflite** (hers, as shipped) | datasetJan2026 | 25.0 | 0.0 | 0.0 | 0.0 | 0.0 | 100.0 | 25.0 | 25.0 |
| teammate_cnn@50 (her arch + recipe, 3 seeds) | real (CV) | 23.1 | 0.0 | 11.1 | 27.8 | 5.6 | 47.8 | 23.0 | 23.6 |
| harry_full@50 (mine, 3 seeds) | real (CV) | 79.0 | 54.4 | 84.3 | 75.2 | 80.2 | 76.5 | 76.2 | 75.6 |
| harry_full@100 (mine, 3 seeds) | real (CV) | 83.5 | 56.3 | 90.3 | 82.4 | 81.4 | 79.8 | 81.2 | 80.5 |
| harry_nograv@100 (mine, 3 seeds) | real (CV) | 80.5 | 51.9 | 84.3 | 75.4 | 83.6 | 78.7 | 78.9 | 78.8 |
| harry_feat@100 (mine, 3 seeds) | real (CV) | 82.3 | 58.1 | 84.3 | 77.8 | 87.0 | 80.2 | 78.7 | 82.5 |
| teammate_cnn+harry_recipe@50 (her arch + recipe, 3 seeds) | real (CV) | 19.3 | 0.0 | 16.7 | 34.3 | 0.0 | 26.2 | 20.3 | 24.2 |

Casual check on datasetJan2026 (her held-out test split, social):

| model | BALANCED | MIN_CLASS | breathingNormally | coughing | hyperventilation | other | window acc | recording vote |
|---|---|---|---|---|---|---|---|---|
| social_cnn | 54.9 | 34.9 | 34.9 | 56.6 | 40.9 | 87.1 | 66.7 | 70.3 |
| harry_final | 47.4 | 18.7 | 27.6 | 58.4 | 18.7 | 85.1 | 61.1 | 63.2 |
