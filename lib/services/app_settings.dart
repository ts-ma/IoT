import 'package:flutter/foundation.dart';

import '../globals.dart' show asyncPrefs;

/// RESpeck sampling rate. Every window and step is counted in samples.
const double sensorHz = 12.5;

/// Update intervals offered in Settings, as samples between two results:
/// 25 = 2 s (the step the models were trained with), 12 ≈ 1 s, 6 ≈ 0.5 s.
/// Only how often a window is classified changes; the window length (HAR 4 s,
/// Social 8 s) and the models stay the same, so per-window accuracy does too.
const List<int> stepChoices = [25, 12, 6];
const int defaultStepSamples = 12;

/// "2 s", "1 s", "0.5 s" (12 samples are 0.96 s, shown rounded).
String stepLabel(int samples) {
  final s = samples / sensorHz;
  return s >= 0.75 ? '${s.round()} s' : '${s.toStringAsFixed(1)} s';
}

/// User-adjustable app settings, persisted in shared preferences. Screens and
/// the classifiers listen to the notifiers, so a change applies at once.
class AppSettings {
  /// Samples between two results, for both models.
  final ValueNotifier<int> stepSamples = ValueNotifier(defaultStepSamples);

  /// Display only: show the majority of the last 3 activity results.
  final ValueNotifier<bool> smoothHar = ValueNotifier(true);

  double get resultIntervalSeconds => stepSamples.value / sensorHz;

  Duration get resultInterval =>
      Duration(microseconds: (stepSamples.value * 1e6 / sensorHz).round());

  /// Milliseconds of activity one new result stands for (stored with it).
  int get resultIntervalMs => resultInterval.inMilliseconds;

  Future<void> load() async {
    try {
      final step = await asyncPrefs.getInt('step_samples');
      if (step != null && stepChoices.contains(step)) stepSamples.value = step;
      smoothHar.value = await asyncPrefs.getBool('smooth_har') ?? true;
    } catch (e) {
      debugPrint('Could not read settings: $e');
    }
  }

  Future<void> setStepSamples(int samples) async {
    if (!stepChoices.contains(samples)) {
      throw ArgumentError.value(samples, 'samples', 'Not an offered step');
    }
    stepSamples.value = samples;
    try {
      await asyncPrefs.setInt('step_samples', samples);
    } catch (e) {
      debugPrint('Could not save the update interval: $e');
    }
  }

  Future<void> setSmoothHar(bool value) async {
    smoothHar.value = value;
    try {
      await asyncPrefs.setBool('smooth_har', value);
    } catch (e) {
      debugPrint('Could not save smoothing preference: $e');
    }
  }
}

final AppSettings appSettings = AppSettings();
