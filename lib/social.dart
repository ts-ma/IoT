import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'har.dart' show SampleWindow;

const socialModelAsset = 'assets/models/harry_social_rnn.tflite';
const socialMetaAsset = 'assets/models/harry_social_rnn_meta.json';

/// Contract of the bundled Social model (must match its _meta.json): 100
/// samples = 8 s at 12.5 Hz, long enough to contain whole breaths. The model
/// was trained with a 25-sample (2 s) step; the app applies the update
/// interval chosen in Settings at run time (see [SocialClassifier.step]).
const int socialWindowSamples = 100;
const int socialStepSamples = 25;
const double socialWindowSeconds = socialWindowSamples / 12.5;
const socialLabels = [
  'breathingNormally',
  'coughing',
  'hyperventilation',
  'other',
];

/// One completed inference. Probabilities follow [socialLabels], not truth labels.
class SocialPrediction {
  SocialPrediction._(this.label, this.confidence, List<double> probabilities)
      : probabilities = List.unmodifiable(probabilities);

  final String label;
  final double confidence;
  final List<double> probabilities;
}

/// Small injection boundary for tests without a native TFLite library.
/// Production uses a dedicated interpreter; a runner belongs to one classifier.
abstract interface class SocialModelRunner {
  List<int> get inputShape;
  TensorType get inputType;
  List<int> get outputShape;
  TensorType get outputType;
  List<double> run(List<List<List<double>>> batch);
  void close();
}

class _TfliteSocialRunner implements SocialModelRunner {
  _TfliteSocialRunner(this._interpreter);

  final Interpreter _interpreter;

  static Future<SocialModelRunner> load() async =>
      _TfliteSocialRunner(await Interpreter.fromAsset(socialModelAsset));

  // .single also rejects models with additional inputs or outputs.
  @override
  List<int> get inputShape => _interpreter.getInputTensors().single.shape;
  @override
  TensorType get inputType => _interpreter.getInputTensors().single.type;
  @override
  List<int> get outputShape => _interpreter.getOutputTensors().single.shape;
  @override
  TensorType get outputType => _interpreter.getOutputTensors().single.type;

  @override
  List<double> run(List<List<List<double>>> batch) {
    final output = [List<double>.filled(4, 0)];
    _interpreter.run(batch, output);
    return output.single;
  }

  @override
  void close() => _interpreter.close();
}

/// Independent eight-second window classifier. Feed raw X/Y/Z values in g.
/// Standardization is embedded in the model; no preprocessing is applied here.
class SocialClassifier {
  SocialClassifier._(this._runner);

  final SocialModelRunner _runner;
  final SampleWindow _window =
      SampleWindow(socialWindowSamples, socialStepSamples);
  bool _disposed = false;

  List<String> get classes => socialLabels;

  /// Samples between results (see SampleWindow.step); the window stays 100.
  int get step => _window.step;
  set step(int value) => _window.step = value;

  /// Validates metadata before allocating an interpreter, then validates the
  /// actual tensors. Any runner allocated during a failed load is closed.
  static Future<SocialClassifier> load({
    AssetBundle? metadataBundle,
    Future<SocialModelRunner> Function()? createRunner,
  }) async {
    final text =
        await (metadataBundle ?? rootBundle).loadString(socialMetaAsset);
    _validateMetadata(jsonDecode(text));
    final runner = await (createRunner ?? _TfliteSocialRunner.load)();
    try {
      if (!listEquals(runner.inputShape, [1, socialWindowSamples, 3]) ||
          runner.inputType != TensorType.float32 ||
          !listEquals(runner.outputShape, [1, 4]) ||
          runner.outputType != TensorType.float32) {
        throw const FormatException('Social model tensors must be '
            '[1, $socialWindowSamples, 3] float32 -> [1, 4] float32');
      }
      return SocialClassifier._(runner);
    } catch (_) {
      runner.close();
      rethrow;
    }
  }

  static void _validateMetadata(Object? value) {
    void require(bool condition, String field) {
      if (!condition) throw FormatException('Invalid Social metadata: $field');
    }

    bool matches(Object? actual, List<Object> expected) =>
        actual is List && listEquals(actual, expected);

    if (value is! Map<String, dynamic>) {
      throw const FormatException('Social metadata must be a JSON object');
    }
    final input = value['input'];
    final output = value['output'];
    if (input is! Map<String, dynamic> || output is! Map<String, dynamic>) {
      throw const FormatException('Social metadata must describe input/output');
    }
    require(value['model_file'] == 'harry_social_rnn.tflite', 'model_file');
    require(value['task'] == 'social_signal', 'task');
    require(value['sampling_frequency_hz'] == 12.5, 'sampling_frequency_hz');
    require(
        value['window_samples'] is int &&
            value['window_samples'] == socialWindowSamples,
        'window_samples');
    require(
        value['step_samples'] is int &&
            value['step_samples'] == socialStepSamples,
        'step_samples');
    require(
        matches(input['shape'], [1, socialWindowSamples, 3]), 'input.shape');
    require(input['dtype'] == 'float32', 'input.dtype');
    require(matches(input['channels'], ['accelX', 'accelY', 'accelZ']),
        'input.channels');
    require(input['units'] == 'g (raw accelerometer values)', 'input.units');
    require(matches(output['shape'], [1, 4]), 'output.shape');
    require(output['dtype'] == 'float32', 'output.dtype');
    require(matches(output['classes'], socialLabels), 'output.classes');
    // The supplied JSON encodes a literal backslash-u2013 in this description.
    final normalization = value['normalization'];
    require(
        normalization is String &&
            normalization.replaceAll(r'\u2013', '\u2013') ==
                'inside the model \u2013 feed raw values',
        'normalization');
  }

  /// Returns null until sample 100, then until each further [step] samples
  /// arrive (25 by default).
  /// The model sees the latest complete window, oldest sample first.
  /// With [infer] false the sample is only buffered (social signals are paused
  /// while the wearer moves); the first sample after the pause that has a full
  /// window behind it is classified at once.
  SocialPrediction? addSample(double x, double y, double z,
      {bool infer = true}) {
    _checkOpen();
    if (!x.isFinite || !y.isFinite || !z.isFinite) {
      _window.clear();
      throw ArgumentError('Social acceleration samples must be finite');
    }
    if (!infer) {
      // Paused (the wearer is moving): keep the window current, no inference.
      _window.push(x, y, z);
      return null;
    }
    if (!_window.add(x, y, z)) return null;
    try {
      final probabilities = _runner.run(_window.batch);
      if (probabilities.length != 4 ||
          probabilities.any((p) => !p.isFinite || p < 0 || p > 1) ||
          (probabilities.fold<double>(0, (a, b) => a + b) - 1).abs() > 1e-4) {
        throw StateError('Social model returned invalid softmax probabilities');
      }
      var best = 0;
      for (var i = 1; i < probabilities.length; i++) {
        if (probabilities[i] > probabilities[best]) best = i;
      }
      return SocialPrediction._(
          classes[best], probabilities[best], probabilities);
    } catch (_) {
      // A failed inference emits no prediction. Require a fresh complete window
      // before retrying, just as after an interrupted stream.
      _window.clear();
      rethrow;
    }
  }

  void _checkOpen() {
    if (_disposed) throw StateError('Social classifier has been disposed');
  }

  void reset() {
    _checkOpen();
    _window.clear();
  }

  /// Idempotent: the owned interpreter is closed exactly once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _window.clear();
    _runner.close();
  }
}

/// App-lifetime owner. Repeated/concurrent loads share one attempt, including
/// failures. A disposed session cannot be reopened; create a new owner instead.
class SocialClassifierSession {
  SocialClassifierSession({Future<SocialClassifier> Function()? loader})
      : _loader = loader ?? SocialClassifier.load;

  final Future<SocialClassifier> Function() _loader;
  Future<void>? _loading;
  SocialClassifier? _classifier;
  bool _disposed = false;

  SocialClassifier? get classifier => _classifier;

  Future<void> load() {
    if (_disposed) throw StateError('Social session has been disposed');
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final loaded = await _loader();
    if (_disposed) {
      loaded.dispose();
    } else {
      _classifier = loaded;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final classifier = _classifier;
    _classifier = null;
    classifier?.dispose();
  }
}
