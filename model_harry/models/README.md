# Final models (`model_harry/models`)

Exported 2026-11-03 07:15 by `run_pipeline.py` from `full`. Every architecture, hers and
mine, was trained the same final way on all available data. The scores below come from the
pipeline's tests (folds × seeds), and every score is in %. Full details are in
`full/report.html` and `results_viewer.ipynb`.

| scenario | what the score means |
|---|---|
| A | trained and tested on Harry's real recordings (within-subject CV) |
| B | trained on the real data, tested on Jan2026 (other people) |
| C | trained on Jan2026, tested on the real data |
| D | Jan2026 10-fold CV, i.e. other people, Lab3 B9 / CW3 marking protocol |
| E | Jan2026 pre-training + real fine-tuning, tested on the real data |

**Recommended** = the best TFLite model by mean of scenarios D + E. Its copy is in
`recommended/<task>/`.

## HAR — recommended: **harry_cnn**

| | model | owner | group | file | KB | params | window | A | B | C | D | E | rank (D+E) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ★ | harry_cnn | mine | CNN | `har/CNN/harry_cnn.tflite` | 131.6 | 26112 | 50 | 99.5 | 74.8 | 96.7 | 93.9 | 99.6 | 96.7 |
|  | harry_rnn | mine | RNN | `har/RNN/harry_rnn.tflite` | 189.3 | 21152 | 50 | 97.9 | 73.2 | 94.4 | 93.8 | 98.8 | 96.3 |
|  | her_cnn_bn | hers | CNN | `har/CNN/her_cnn_bn.tflite` | 51.2 | 11826 | 50 | 60.0 | 58.6 | 95.1 | 91.8 | 97.3 | 94.6 |
|  | her_cnn | hers | CNN | `har/CNN/her_cnn.tflite` | 50.5 | 11538 | 50 | 69.6 | 54.9 | 94.6 | 91.7 | 97.0 | 94.4 |
|  | her_cnn_3conv | hers | CNN | `har/CNN/her_cnn_3conv.tflite` | 100.0 | 23890 | 50 | 89.9 | 60.2 | 92.6 | 91.7 | 97.0 | 94.4 |
|  | her_cnn_k3 | hers | CNN | `har/CNN/her_cnn_k3.tflite` | 33.9 | 7250 | 50 | 67.7 | 54.5 | 94.7 | 91.0 | 97.1 | 94.0 |
|  | harry_mlp | mine | MLP | `har/MLP/harry_mlp.tflite` | 166.6 | 35744 | 50 | 94.7 | 67.8 | 83.4 | 90.1 | 97.3 | 93.7 |
|  | harry_feat | mine | FEATURE | `har/FEATURE/harry_feat.tflite` | 44.6 | 5009 | 50 | 96.9 | 67.5 | 84.1 | 88.9 | 97.6 | 93.3 |
|  | her_lstm | hers | RNN | `har/RNN/her_lstm.tflite` | 153.5 | 4978 | 50 | 58.4 | 48.0 | 90.2 | 86.4 | 94.2 | 90.3 |
|  | her_mlp | hers | MLP | `har/MLP/her_mlp.tflite` | 50.8 | 12114 | 50 | 59.6 | 48.7 | 83.6 | 86.1 | 89.4 | 87.8 |
|  | her_logreg | hers | FEATURE | `har/FEATURE/her_logreg.pkl` | 3.1 | 319 | 50 | 100.0 | 62.2 | 74.0 | 85.1 | – | 85.1 |

## SOCIAL — recommended: **harry_cnn**

| | model | owner | group | file | KB | params | window | A | B | C | D | E | rank (D+E) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ★ | harry_cnn | mine | CNN | `social/CNN/harry_cnn.tflite` | 225.6 | 42065 | 100 | 80.4 | 45.7 | 94.6 | 82.3 | 92.1 | 87.2 |
|  | harry_rnn | mine | RNN | `social/RNN/harry_rnn.tflite` | 292.9 | 20017 | 100 | 79.1 | 50.8 | 94.5 | 82.3 | 90.9 | 86.6 |
|  | harry_feat | mine | FEATURE | `social/FEATURE/harry_feat.tflite` | 70.2 | 3874 | 100 | 81.6 | 47.9 | 80.9 | 75.1 | 87.4 | 81.2 |
|  | harry_mlp | mine | MLP | `social/MLP/harry_mlp.tflite` | 279.7 | 57009 | 100 | 81.5 | 47.0 | 80.9 | 75.5 | 86.6 | 81.0 |
|  | her_cnn_3conv | hers | CNN | `social/CNN/her_cnn_3conv.tflite` | 98.2 | 23435 | 50 | 23.2 | 26.4 | 77.4 | 62.1 | 76.8 | 69.5 |
|  | her_cnn | hers | CNN | `social/CNN/her_cnn.tflite` | 48.8 | 11083 | 50 | 26.2 | 26.3 | 76.2 | 56.9 | 72.3 | 64.6 |
|  | her_cnn_bn | hers | CNN | `social/CNN/her_cnn_bn.tflite` | 49.4 | 11371 | 50 | 25.0 | 26.6 | 74.8 | 58.6 | 70.0 | 64.3 |
|  | her_cnn_k3 | hers | CNN | `social/CNN/her_cnn_k3.tflite` | 32.1 | 6795 | 50 | 23.4 | 26.2 | 72.4 | 52.6 | 65.5 | 59.0 |
|  | her_logreg | hers | FEATURE | `social/FEATURE/her_logreg.pkl` | 2.2 | 116 | 50 | 48.4 | 44.8 | 56.9 | 46.9 | – | 46.9 |
|  | her_lstm | hers | RNN | `social/RNN/her_lstm.tflite` | 152.6 | 4747 | 50 | 23.6 | 25.5 | 25.1 | 26.4 | 25.9 | 26.2 |
|  | her_mlp | hers | MLP | `social/MLP/her_mlp.tflite` | 49.9 | 11883 | 50 | 23.1 | 25.5 | 25.0 | 25.0 | 25.0 | 25.0 |

## Using a model in the app (Lab 4)
1. Copy `<task>/<GROUP>/<model>.tflite`, `<model>_meta.json` and `<model>_example.json` into the app's
   `assets/models/`.
2. List them in `pubspec.yaml`, and point the two path constants in `har.dart` / `social.dart` at
   them.
3. Input is `[1, window, 3]` raw g (float32), and the output is softmax. Normalisation and features
   are inside the model. `window_samples` / `step_samples` are in the meta file (my social models
   use 100 samples = 8 s).
4. Run the Lab 4 Step 5.1 check with the `_example.json`.

Two cautions:
- The teammate's current `social.dart` rejects any model whose meta does not say `social_cnn.tflite`
  with a 50-sample window, so it needs a small change for 8 s models.
- `her_logreg.pkl` is not TFLite: it would need its features and classifier re-implemented in Dart.
