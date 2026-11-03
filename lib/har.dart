import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'services/app_metrics.dart';

// This file runs live human activity recognition (HAR) on the acceleration
// stream from the respeck.
//
// How it works, end to end:
//  1. ble.dart decodes each BLE packet into individual x, y, z samples (in g)
//     and passes every sample to HarClassifier.addSample() below.
//  2. The samples are collected in a sliding window (SampleWindow). The model
//     always looks at the most recent `window_samples` samples (50 for the
//     dummy model, i.e. 4 seconds at 12.5 Hz).
//  3. Every `step_samples` samples (25, i.e. every 2 seconds) the current
//     window is handed to the TFLite model. Consecutive windows therefore
//     overlap by half, which gives a new prediction every 2 seconds while
//     each prediction still sees 4 seconds of movement.
//  4. The model outputs one probability per activity class. The class with
//     the highest probability is returned as a HarPrediction, which ble.dart
//     passes on to the home page to display.
//
// The model contract (window length, step, class names) is read from the
// metadata JSON next to the model rather than hard coded here. A different
// model with the same input layout ([1, window, 3] raw accelerometer values)
// can therefore be dropped in by replacing the two asset files below (and
// listing them in pubspec.yaml), without changing any code.
//
// Normalisation of the input is done inside the model itself, so raw values
// in g are fed in exactly as they arrive from the respeck.

// Paths of the model and its metadata inside the app bundle. These files must
// also be listed under `assets:` in pubspec.yaml, otherwise they are not
// packaged into the app and loading fails at startup.
const String harModelAsset = 'assets/models/har_cnn.tflite';
const String harMetaAsset = 'assets/models/har_cnn_meta.json';

// A fixed length sliding window of [x, y, z] samples.
//
// It keeps only the newest `length` samples: once full, each new sample pushes
// the oldest one out. It also counts how many samples have arrived since the
// window was last classified, and reports that a new window is ready
//  - for the first time as soon as the window is full, and
//  - after that, every `step` new samples.
//
// This class knows nothing about TFLite, so the windowing logic can be unit
// tested on its own (see test/widget_test.dart).
class SampleWindow {
  // Number of samples the model looks at in one go (50 for the dummy model)
  final int length;
  // Number of new samples between two classifications (25 for the dummy model)
  final int step;
  // The buffered samples, oldest first. Each entry is [x, y, z] in g.
  final List<List<double>> _samples = [];
  // Samples added since the last time a window was reported ready
  int _sinceLast = 0;

  SampleWindow(this.length, this.step);

  // Add one sample. Returns true when a new window is ready to classify,
  // in which case the caller should read `batch` straight away.
  bool add(double x, double y, double z) {
    _samples.add([x, y, z]);
    // Drop the oldest sample once the window is over length. Only one sample
    // is added at a time, so removing one is enough to keep it at `length`.
    // (removeAt(0) shifts the list, but at 50 entries that cost is trivial.)
    if (_samples.length > length) {
      _samples.removeAt(0);
    }
    _sinceLast++;
    // Only classify complete windows, and only every `step` samples. Because
    // `_sinceLast` keeps counting while the window fills up, the first window
    // is reported as soon as it is full, regardless of `step`.
    if (_samples.length == length && _sinceLast >= step) {
      _sinceLast = 0;
      return true;
    }
    return false;
  }

  // The current window in the shape the model expects: [1, length, 3], i.e. a
  // batch containing one window, oldest sample first. The samples are copied,
  // so later calls to add() cannot change a window that is being classified.
  List<List<List<double>>> get batch => [List.of(_samples)];

  // Empty the window and restart the step count, so that the next prediction
  // is only made once a full window of fresh samples has arrived
  void clear() {
    _samples.clear();
    _sinceLast = 0;
  }
}

// The result of classifying one window: the most likely activity, and the
// probability the model gave it (0.0 to 1.0)
class HarPrediction {
  // One of the class names from the metadata file, e.g. "normalWalking"
  final String label;
  // The model's probability for `label`. The probabilities of all classes sum
  // to 1, so with 11 classes a value near 0.09 means the model is guessing.
  final double confidence;
  const HarPrediction(this.label, this.confidence);
}

// Wraps the TFLite interpreter together with the sliding window. Feed it
// samples one at a time with addSample(); it decides when to run the model.
class HarClassifier {
  // The TFLite interpreter that holds the loaded model and runs inference
  final Interpreter _interpreter;
  // Activity names, in the same order as the model's output probabilities
  final List<String> classes;
  // The sliding window of recent samples (see SampleWindow above)
  final SampleWindow window;

  // Private constructor: a HarClassifier can only be made through load(),
  // because loading the model and metadata is asynchronous
  HarClassifier._(this._interpreter, this.classes, this.window);

  // Load the metadata and the model from the app's assets. Throws if either
  // file is missing or invalid, which main() catches so that the app still
  // starts (just without live HAR).
  static Future<HarClassifier> load() async {
    // The metadata JSON describes the model: the class names, the window
    // length and the step between windows (see har_dummy_meta.json)
    final meta = jsonDecode(await rootBundle.loadString(harMetaAsset));
    final classes = List<String>.from(meta['output']['classes']);
    // Load the .tflite model into an interpreter, ready to run
    final interpreter = await Interpreter.fromAsset(harModelAsset);
    return HarClassifier._(
      interpreter,
      classes,
      SampleWindow(meta['window_samples'], meta['step_samples']),
    );
  }

  // Add one sample (in g). Returns a prediction when this sample completed a
  // new window and the model was run, otherwise null. Most calls return null:
  // with a step of 25 only one sample in 25 triggers inference.
  HarPrediction? addSample(double x, double y, double z) {
    if (!window.add(x, y, z)) {
      return null;
    }
    // Output buffer in the model's output shape [1, number of classes]. The
    // interpreter fills it with one probability per class.
    final output = [List<double>.filled(classes.length, 0)];
    // Run the model on the current window. This runs on the main (UI)
    // isolate, which is fine for a model as small as the dummy one, but a much
    // bigger model may need to run in a background isolate to keep the UI
    // smooth.
    // The time spent in the model call is recorded for the Performance page
    // (model cost / latency figures for the report).
    final timer = Stopwatch()..start();
    _interpreter.run(window.batch, output);
    timer.stop();
    appMetrics.recordHarInference(timer.elapsed);
    final probs = output[0];
    // Pick the class with the highest probability (argmax)
    int best = 0;
    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > probs[best]) best = i;
    }
    return HarPrediction(classes[best], probs[best]);
  }

  // Forget the buffered samples, e.g. after a disconnect. Otherwise the first
  // window after reconnecting would mix samples from before and after the gap,
  // which does not describe any real movement.
  void reset() => window.clear();
}

// The single classifier used by the app, shared by main.dart (which loads it),
// ble.dart (which feeds it samples) and home.dart (which checks it exists).
// Null until main() has loaded the model, and stays null if loading failed,
// in which case the app works as before without live HAR.
HarClassifier? harClassifier;
