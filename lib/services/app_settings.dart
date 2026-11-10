import 'package:flutter/foundation.dart';

import '../globals.dart' show asyncPrefs;

/// RESpeck sampling rate. Every window and step is counted in samples.
const double sensorHz = 12.5;

/// Update intervals offered in Settings, as samples between two results:
/// 25 = 2 s (the step the models were trained with), 12 ≈ 1 s, 6 ≈ 0.5 s.
/// Only how often a window is classified changes; the window length (HAR 4 s,
/// Social 8 s) and the models stay the same, so per-window accuracy does too.
/// The RESpeck sends 32 samples (2.56 s) per packet, so results already come
/// in bursts; the 0.5 s default makes the newest result in each burst as
/// fresh as possible (activity changes show ~0.5 s sooner than with 1 s) for
/// about 2 + 2 model runs per second, a few ms of CPU.
const List<int> stepChoices = [25, 12, 6];
const int defaultStepSamples = 6;

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

  /// Reminders (services/reminders.dart): move after sitting/standing for
  /// [sitMinutes]; wake-up alarm at [wakeMinuteOfDay] if still lying down.
  final ValueNotifier<bool> moveReminder = ValueNotifier(true);
  final ValueNotifier<int> sitMinutes = ValueNotifier(60);
  final ValueNotifier<bool> wakeAlarm = ValueNotifier(false);
  final ValueNotifier<int> wakeMinuteOfDay = ValueNotifier(8 * 60);

  /// Every reminder setting, for listeners.
  Listenable get reminders =>
      Listenable.merge([moveReminder, sitMinutes, wakeAlarm, wakeMinuteOfDay]);

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
      moveReminder.value = await asyncPrefs.getBool('move_reminder') ?? true;
      final sit = await asyncPrefs.getInt('sit_minutes');
      if (sit != null && sitMinuteChoices.contains(sit)) sitMinutes.value = sit;
      wakeAlarm.value = await asyncPrefs.getBool('wake_alarm') ?? false;
      final wake = await asyncPrefs.getInt('wake_minute');
      if (wake != null && wake >= 0 && wake < 24 * 60) {
        wakeMinuteOfDay.value = wake;
      }
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

  Future<void> setMoveReminder(bool value) =>
      _save(moveReminder, value, () => asyncPrefs.setBool('move_reminder', value));

  Future<void> setSitMinutes(int value) {
    if (!sitMinuteChoices.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Not an offered duration');
    }
    return _save(sitMinutes, value, () => asyncPrefs.setInt('sit_minutes', value));
  }

  Future<void> setWakeAlarm(bool value) =>
      _save(wakeAlarm, value, () => asyncPrefs.setBool('wake_alarm', value));

  Future<void> setWakeMinuteOfDay(int value) {
    if (value < 0 || value >= 24 * 60) throw RangeError.value(value);
    return _save(
        wakeMinuteOfDay, value, () => asyncPrefs.setInt('wake_minute', value));
  }

  Future<void> _save<T>(
      ValueNotifier<T> n, T value, Future<void> Function() write) async {
    n.value = value;
    try {
      await write();
    } catch (e) {
      debugPrint('Could not save a setting: $e');
    }
  }
}

/// Sitting/standing time before a move reminder, in minutes.
const List<int> sitMinuteChoices = [30, 45, 60, 90];

final AppSettings appSettings = AppSettings();
