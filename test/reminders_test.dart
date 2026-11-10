import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/services/reminders.dart';

class _Notes implements ReminderNotifier {
  final List<(ReminderKind, DateTime, String)> sent = [];
  DateTime now = DateTime(2026);

  @override
  Future<void> notify(ReminderKind kind, String title, String body) async =>
      sent.add((kind, now, body));
}

void main() {
  late _Notes notes;
  late ReminderConfig cfg;
  late ActivityReminders r;
  late DateTime t;

  setUp(() {
    notes = _Notes();
    cfg = const ReminderConfig();
    r = ActivityReminders(notifier: notes, config: () => cfg);
    t = DateTime(2026, 11, 10, 9);
  });

  // One result per second, each standing for 1 s.
  void doFor(String label, Duration d) {
    for (var s = 0; s < d.inSeconds; s++) {
      t = t.add(const Duration(seconds: 1));
      notes.now = t;
      r.onActivity(label, t, const Duration(seconds: 1));
    }
  }

  int moves() => notes.sent.where((n) => n.$1 == ReminderKind.move).length;

  group('move reminder', () {
    test('after 60 min of sitting/standing, again every 30 min', () {
      doFor('sittingStanding', const Duration(minutes: 59, seconds: 58));
      expect(moves(), 0);
      doFor('sittingStanding', const Duration(seconds: 3));
      expect(moves(), 1);
      expect(notes.sent.single.$3, contains('an hour'));
      doFor('sittingStanding', const Duration(minutes: 29));
      expect(moves(), 1);
      doFor('sittingStanding', const Duration(minutes: 2));
      expect(moves(), 2);
    });

    test('5 min of walking restarts the count', () {
      doFor('sittingStanding', const Duration(minutes: 61));
      expect(moves(), 1);
      doFor('normalWalking', const Duration(minutes: 5, seconds: 2));
      doFor('sittingStanding', const Duration(minutes: 59));
      expect(moves(), 1);
      doFor('sittingStanding', const Duration(minutes: 2));
      expect(moves(), 2);
    });

    test('short breaks and misreads do not restart it', () {
      doFor('sittingStanding', const Duration(minutes: 30));
      doFor('normalWalking', const Duration(minutes: 3)); // short break
      doFor('miscMovement', const Duration(seconds: 20)); // misread
      doFor('sittingStanding', const Duration(minutes: 31));
      expect(moves(), 1);
    });

    test('lying down does not count; off means no reminder', () {
      doFor('lyingBack', const Duration(minutes: 90));
      expect(moves(), 0);
      cfg = const ReminderConfig(moveEnabled: false);
      doFor('sittingStanding', const Duration(minutes: 90));
      expect(moves(), 0);
    });

    test('custom duration', () {
      cfg = const ReminderConfig(sitMinutes: 30);
      doFor('sittingStanding', const Duration(minutes: 31));
      expect(moves(), 1);
      expect(notes.sent.single.$3, contains('30 minutes'));
    });
  });

  group('wake-up alarm', () {
    int wakes() => notes.sent.where((n) => n.$1 == ReminderKind.wakeUp).length;

    test('still lying after the alarm: every 5 min until up, then done', () {
      cfg = const ReminderConfig(
          moveEnabled: false, wakeEnabled: true, wakeMinuteOfDay: 8 * 60);
      t = DateTime(2026, 11, 10, 7, 55);
      doFor('lyingLeft', const Duration(minutes: 4, seconds: 59)); // 07:59:59
      expect(wakes(), 0);
      doFor('lyingLeft', const Duration(seconds: 2));
      expect(wakes(), 1);
      expect(notes.sent.last.$3, contains('08:00'));
      doFor('lyingBack', const Duration(minutes: 4, seconds: 50));
      expect(wakes(), 1);
      doFor('lyingBack', const Duration(seconds: 20));
      expect(wakes(), 2);
      doFor('sittingStanding', const Duration(minutes: 2)); // got up
      doFor('lyingBack', const Duration(minutes: 30)); // nap: no alarm
      expect(wakes(), 2);
    });

    test('already up at the alarm time: nothing; next day it works again',
        () {
      cfg = const ReminderConfig(
          moveEnabled: false, wakeEnabled: true, wakeMinuteOfDay: 7 * 60);
      t = DateTime(2026, 11, 10, 6, 58);
      doFor('normalWalking', const Duration(minutes: 5));
      doFor('lyingBack', const Duration(minutes: 20));
      expect(wakes(), 0);
      t = DateTime(2026, 11, 11, 6, 59);
      doFor('lyingRight', const Duration(minutes: 3));
      expect(wakes(), 1);
    });

    test('disabled alarm never fires', () {
      t = DateTime(2026, 11, 10, 7, 55);
      cfg = const ReminderConfig(moveEnabled: false);
      doFor('lyingBack', const Duration(minutes: 30));
      expect(wakes(), 0);
    });
  });
}
