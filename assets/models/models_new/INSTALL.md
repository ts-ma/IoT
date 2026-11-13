# Installing the v3 models in the app (copy by hand)

Made by pipeline_v3 (run_v3.py). Both models are trained on all data (all datasetJan2026 + both group members) and
trained to favour the most recent seconds. Check results/report.md before installing.

Back up the app's current files first:

```bash
mkdir -p ~/IoT/assets/models_v2_backup && cp ~/IoT/assets/models/harry_* ~/IoT/assets/models_v2_backup/
```

## Activity (CNN, 4 s) – no app code change (same 50-sample window)

```bash
cp harry_har_cnn.tflite harry_har_cnn_meta.json harry_har_cnn_example.json ~/IoT/assets/models/
```

## Social (RNN, 8 s) – needs ONE app change first

The app checks the social window length. In `~/IoT/lib/social.dart` change

    const int socialWindowSamples = 75;

to

    const int socialWindowSamples = 100;

(and the comment above it that says 75), then:

```bash
cp harry_social_rnn.tflite harry_social_rnn_meta.json harry_social_rnn_example.json ~/IoT/assets/models/
```

## Check

`flutter run`, then look for the `EXAMPLE app:` line in the debug console: it must match the `_example.json`
file. Run `flutter test` (tests that hard-code the 75-sample social window must be updated with the social change).
