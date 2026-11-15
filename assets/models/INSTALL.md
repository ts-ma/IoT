# Models bundled in the app

| Task | Files | Model | Window | From |
|---|---|---|---|---|
| Activity (11 classes) | `harry_har_cnn.tflite` + `_meta.json` + `_example.json` | multi-branch CNN, trained to favour the most recent seconds | 50 samples (4 s) | IoT-Models `model_harry/pipeline_v3/models/` |
| Social signal (4 classes) | `harry_social_cnn.tflite` + `_meta.json` + `_example.json` | multi-branch CNN (`architecture: harry_cnn` in the meta file), trained to favour the most recent seconds | 75 samples (6 s) | IoT-Models `model_harry/pipeline_v4/models/` (candidate `cnn_w75rec`) |

The social files were renamed from `harry_social_rnn` to `harry_social_cnn` on 2026-11-15 to match the model. The model repo (`pipeline_v4/models/`) still exports them as `harry_social_rnn.*`: rename them to `harry_social_cnn.*` when copying, and set `"model_file": "harry_social_cnn.tflite"` in the meta file (the app checks it).

Both were trained on datasetJan2026 and both group members' recordings, mixed. Official 10-fold cross-validation (per-class recall, mean over folds):

- Activity (pipeline v3, mixed, 2 seeds): static 99.4 %, dynamic 89.5 %.
- Social (pipeline v4, trained on datasetJan2026 only, seed 0): breathing 89.3 %, coughing 78.0 %, hyperventilation 79.2 %, other 76.6 % (mean 80.8 %).

The `.keras` files are training copies and are not bundled (`pubspec.yaml` lists only the `.tflite` and `.json` files). `models_new/` holds a different, older social model (an 8 s RNN, `harry_social_rnn.*`) and is not bundled either.

## Installing a new model

1. Copy the three files (`.tflite`, `_meta.json`, `_example.json`) over the ones here, keeping the same names.
2. The app reads the window and classes from the meta file. The social window is also fixed in code (`socialWindowSamples = 75` in `lib/social.dart`); change it there too if the new model uses another length.
3. Run `flutter clean` and rebuild. An incremental build can keep the old model if the copied files have older dates.
4. In a debug build, check that the `EXAMPLE app:` line in the console matches the example file.
