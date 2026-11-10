import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../activity_catalog.dart';

/// Shows a notification (production: AppNotifications; tests: a fake).
abstract interface class ReminderNotifier {
  Future<void> notify(ReminderKind kind, String title, String body);
}

enum ReminderKind { move, wakeUp }

/// Reminder settings (kept in AppSettings, passed in so this stays testable).
class ReminderConfig {
  const ReminderConfig({
    this.moveEnabled = true,
    this.sitMinutes = 60,
    this.wakeEnabled = false,
    this.wakeMinuteOfDay = 8 * 60,
  });

  final bool moveEnabled;

  /// Sitting/standing needed within the last [sitMinutes] + 10 min.
  final int sitMinutes;
  final bool wakeEnabled;

  /// Local alarm time, minutes after midnight (e.g. 480 = 08:00).
  final int wakeMinuteOfDay;
}

/// Turns the shown activity stream into two reminders:
///
/// * **Move**: sitting/standing adds up to [ReminderConfig.sitMinutes] within
///   the last sitMinutes + 10 min, so a few misread or short breaks do not
///   restart the count. Lying is not counted (resting or sleeping). After a
///   reminder it repeats every 30 min until you move; 5 min of movement
///   (within 10 min) starts the count again from zero.
/// * **Wake-up alarm**: after the alarm time, if you are still lying down
///   (lying for most of the last 2 min) it notifies, and again every 5 min,
///   until you have been up (not lying) for most of 2 min. Once up, or 6 h
///   after the alarm time, it is done for the day.
///
/// Fed with every shown activity result and the time it stands for, so it
/// only works while the app is open with the sensor connected.
class ActivityReminders {
  ActivityReminders({
    required this.notifier,
    required ReminderConfig Function() config,
  }) : _config = config;

  final ReminderNotifier notifier;
  final ReminderConfig Function() _config;

  static const _extraWindow = Duration(minutes: 10);
  static const moveNeeded = Duration(minutes: 5);
  static const _moveWindow = Duration(minutes: 10);
  static const remindAgainAfter = Duration(minutes: 30);
  static const _wakeLook = Duration(minutes: 2);
  static const _wakeMostly = Duration(seconds: 90);
  static const wakeRepeat = Duration(minutes: 5);
  static const _wakeGiveUp = Duration(hours: 6);

  final Queue<({DateTime at, String label, Duration span})> _recent = Queue();
  DateTime? _countFrom; // sitting before this does not count
  DateTime? _lastMoveReminder;
  DateTime? _lastWakeReminder;
  DateTime? _wakeDoneFor; // local date the alarm is finished for

  /// Sitting/standing time counted towards the move reminder now.
  Duration get sitTime => _sum((l) => l == 'sittingStanding',
      _recent.isEmpty ? null : _recent.last.at, _sitWindow, from: _countFrom);

  Duration get _sitWindow =>
      Duration(minutes: _config().sitMinutes) + _extraWindow;

  /// One shown activity [label] at [at], standing for [span] of time.
  void onActivity(String label, DateTime at, Duration span) {
    final cfg = _config();
    _recent.addLast((at: at, label: label, span: span));
    final keep = _sitWindow > _wakeLook ? _sitWindow : _wakeLook;
    while (_recent.isNotEmpty && at.difference(_recent.first.at) > keep) {
      _recent.removeFirst();
    }
    if (cfg.moveEnabled) _move(at, cfg);
    if (cfg.wakeEnabled) _wake(at, cfg);
  }

  void _move(DateTime at, ReminderConfig cfg) {
    final moved = _sum(_isMoving, at, _moveWindow, from: _countFrom);
    if (moved >= moveNeeded) {
      // A proper break: start counting again.
      _countFrom = at;
      _lastMoveReminder = null;
      return;
    }
    if (sitTime < Duration(minutes: cfg.sitMinutes)) return;
    final last = _lastMoveReminder;
    if (last != null && at.difference(last) < remindAgainAfter) return;
    _lastMoveReminder = at;
    _send(
        ReminderKind.move,
        'Time to move',
        'You have been sitting or standing for ${_fmt(cfg.sitMinutes)}. '
            'Walk for ${moveNeeded.inMinutes} minutes.');
  }

  void _wake(DateTime at, ReminderConfig cfg) {
    final local = at.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    if (_wakeDoneFor == today) return;
    final alarm = today.add(Duration(minutes: cfg.wakeMinuteOfDay));
    if (local.isBefore(alarm)) return;
    if (local.difference(alarm) > _wakeGiveUp) {
      _wakeDoneFor = today;
      return;
    }
    final lying = _sum(_isLying, at, _wakeLook);
    final up = _sum((l) => !_isLying(l), at, _wakeLook);
    if (up >= _wakeMostly) {
      _wakeDoneFor = today; // already up
      _lastWakeReminder = null;
      return;
    }
    if (lying < _wakeMostly) return;
    final last = _lastWakeReminder;
    if (last != null && at.difference(last) < wakeRepeat) return;
    _lastWakeReminder = at;
    final hh = (cfg.wakeMinuteOfDay ~/ 60).toString().padLeft(2, '0');
    final mm = (cfg.wakeMinuteOfDay % 60).toString().padLeft(2, '0');
    _send(ReminderKind.wakeUp, 'Time to get up',
        'It is past $hh:$mm and you are still lying down.');
  }

  void _send(ReminderKind kind, String title, String body) {
    notifier.notify(kind, title, body).catchError((Object e) {
      debugPrint('Reminder could not be shown: $e');
    });
  }

  Duration _sum(bool Function(String) test, DateTime? now, Duration window,
      {DateTime? from}) {
    if (now == null) return Duration.zero;
    var total = Duration.zero;
    for (final r in _recent) {
      if (now.difference(r.at) > window) continue;
      if (from != null && !r.at.isAfter(from)) continue;
      if (test(r.label)) total += r.span;
    }
    return total;
  }

  static bool _isMoving(String l) =>
      labelInfo(l).group == LabelGroup.dynamicActivity;
  static bool _isLying(String l) => l.startsWith('lying');

  static String _fmt(int minutes) => minutes % 60 == 0
      ? (minutes == 60 ? 'an hour' : '${minutes ~/ 60} hours')
      : '$minutes minutes';

  /// Forget everything (log out, settings change).
  void reset() {
    _recent.clear();
    _countFrom = null;
    _lastMoveReminder = null;
    _lastWakeReminder = null;
    _wakeDoneFor = null;
  }
}
