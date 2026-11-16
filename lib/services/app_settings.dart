import 'package:flutter/foundation.dart';

import '../globals.dart' show asyncPrefs;

/// RESpeck sampling rate. Every window and step is counted in samples.
const double sensorHz = 12.5;

/// Samples between two results, for both models: 6 samples = 0.48 s
/// ("0.5 s"). Fixed; it is not a setting. The window each result looks at
/// (activity 4 s, social 6 s) does not depend on it. The RESpeck sends 32
/// samples (2.56 s) per packet and all of a packet's results are made when
/// it arrives, so the screen changes once per packet; a small step makes the
/// last result of each packet as fresh as possible (its window ends at most
/// 0.4 s before the newest sample, instead of up to 1.9 s with 2 s), for
/// about 2 + 2 model runs per second (a few ms of CPU).
const int updateStepSamples = 6;

/// The time one result stands for: [updateStepSamples] at 12.5 Hz (0.48 s).
/// Stored with every saved result, so history durations add up.
const Duration updateInterval = Duration(milliseconds: 480);

/// "0.5 s", for display.
const String updateIntervalLabel = '0.5 s';

/// User-adjustable settings (the reminders), persisted in shared preferences.
/// The reminders and the Settings page listen to the notifiers, so a change
/// applies at once.
class AppSettings {
  /// Reminders (services/reminders.dart): move after sitting/standing for
  /// [sitMinutes]; wake-up alarm at [wakeMinuteOfDay] if still lying down.
  final ValueNotifier<bool> moveReminder = ValueNotifier(true);
  final ValueNotifier<int> sitMinutes = ValueNotifier(60);
  final ValueNotifier<bool> wakeAlarm = ValueNotifier(false);
  final ValueNotifier<int> wakeMinuteOfDay = ValueNotifier(8 * 60);

  /// Every reminder setting, for listeners.
  Listenable get reminders =>
      Listenable.merge([moveReminder, sitMinutes, wakeAlarm, wakeMinuteOfDay]);

  Future<void> load() async {
    try {
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

  Future<void> setMoveReminder(bool value) => _save(
      moveReminder, value, () => asyncPrefs.setBool('move_reminder', value));

  Future<void> setSitMinutes(int value) {
    if (!sitMinuteChoices.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Not an offered duration');
    }
    return _save(
        sitMinutes, value, () => asyncPrefs.setInt('sit_minutes', value));
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
