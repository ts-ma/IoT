# Installing the final models in the app

These files keep the app's names and metadata contract, so no code change is needed:

```bash
cd <IoT repo, on the app branch>
cp model_harry/final_run/final_models/harry_har_cnn.tflite model_harry/final_run/final_models/harry_har_cnn_meta.json model_harry/final_run/final_models/harry_har_cnn_example.json assets/models/
cp model_harry/final_run/final_models/harry_social_rnn.tflite model_harry/final_run/final_models/harry_social_rnn_meta.json model_harry/final_run/final_models/harry_social_rnn_example.json assets/models/
```

Then do a full rebuild (`flutter run`), and check the `EXAMPLE app:` line in the debug console matches the example file. The `.keras` files are for further training only.
