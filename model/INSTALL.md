# Installing the final models in the app (not done automatically)

Activity model: same window (4 s) and names as the app expects. Social model: window 75 samples (6 s). The app currently hard-codes a 100-sample social window (`socialWindowSamples` and the metadata check in `lib/social.dart`), so change those to the new length before copying.

```bash
cp model_harry/pipeline_v2/models/harry_har_cnn.tflite model_harry/pipeline_v2/models/harry_har_cnn_meta.json model_harry/pipeline_v2/models/harry_har_cnn_example.json <app>/assets/models/
cp model_harry/pipeline_v2/models/harry_social_rnn.tflite model_harry/pipeline_v2/models/harry_social_rnn_meta.json model_harry/pipeline_v2/models/harry_social_rnn_example.json <app>/assets/models/
```

Then rebuild (`flutter run`) and check the `EXAMPLE app:` line in the debug console matches the example file.
