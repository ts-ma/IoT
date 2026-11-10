import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/services/app_metrics.dart';
import 'package:pdiot/services/change_latency.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/user_session.dart';

/// Feeds [seconds] of 12.5 Hz samples from [f] (time in s -> xyz), starting
/// at [start]; returns the time after the last sample.
DateTime feed(void Function(double, double, double, DateTime) add,
    DateTime start, double seconds, List<double> Function(double t) f) {
  final n = (seconds * 12.5).round();
  for (var i = 0; i < n; i++) {
    final t = i / 12.5;
    final v = f(t);
    add(v[0], v[1], v[2], start.add(Duration(milliseconds: i * 80)));
  }
  return start.add(Duration(milliseconds: n * 80));
}

void main() {
  final t0 = DateTime(2026, 11, 10, 12);
  final rng = Random(4);
  double noise(double s) => (rng.nextDouble() - 0.5) * 2 * s;
  List<double> sitting(double t) =>
      [noise(0.004), -1 + noise(0.004), 0.05 + noise(0.004)];
  List<double> walking(double t) => [
        0.25 * sin(2 * pi * 1.8 * t) + noise(0.03),
        -1 + 0.4 * sin(2 * pi * 1.8 * t + 1) + noise(0.03),
        0.1 * sin(2 * pi * 0.9 * t) + noise(0.03),
      ];

  test('sitting -> walking: change found where the motion started', () {
    final est = ChangeLatencyEstimator();
    final change = feed(est.addSample, t0, 9, sitting);
    final shown = feed(est.addSample, change, 4, walking);
    final e = est.estimate(
        task: ChangeTask.activity,
        from: 'sittingStanding',
        to: 'normalWalking',
        shownAt: shown);
    expect(e, isNotNull);
    expect(e!.signal, 'motion');
    expect(e.changedAt.difference(change).inMilliseconds.abs(),
        lessThanOrEqualTo(240));
    expect(e.latency.inMilliseconds, closeTo(4000, 300));
  });

  test('lying back -> lying left: a tilt with no change in motion', () {
    final est = ChangeLatencyEstimator();
    final change = feed(est.addSample, t0, 8,
        (t) => [0.02 + noise(0.004), noise(0.004), 1 + noise(0.004)]);
    final shown = feed(est.addSample, change, 5,
        (t) => [1 + noise(0.004), noise(0.004), 0.02 + noise(0.004)]);
    final e = est.estimate(
        task: ChangeTask.activity,
        from: 'lyingBack',
        to: 'lyingLeft',
        shownAt: shown);
    expect(e, isNotNull);
    // The instant tilt is also one big jerk, so either signal may find it.
    expect(e!.signal, anyOf('motion', 'posture'));
    expect(e.latency.inMilliseconds, closeTo(5000, 300));
  });

  test('no change in the signal, too little data or a gap: unclear', () {
    final est = ChangeLatencyEstimator();
    var end = feed(est.addSample, t0, 13, sitting);
    expect(
        est.estimate(
            task: ChangeTask.activity, from: 'a', to: 'b', shownAt: end),
        isNull);
    est.clear();
    end = feed(est.addSample, t0, 6, sitting);
    expect(
        est.estimate(
            task: ChangeTask.activity, from: 'a', to: 'b', shownAt: end),
        isNull);
    est.clear();
    final a = feed(est.addSample, t0, 5, sitting);
    end = feed(est.addSample, a.add(const Duration(seconds: 4)), 6, walking);
    expect(
        est.estimate(
            task: ChangeTask.activity, from: 'a', to: 'b', shownAt: end),
        isNull);
  });

  test('metrics keep last/min/mean/max, unclear counts and recent changes', () {
    final m = AppMetrics();
    final change = feed(m.recordSample, t0, 9, sitting);
    final shown = feed(m.recordSample, change, 4, walking);
    final e = m.recordShownChange(
        ChangeTask.activity, 'sittingStanding', 'normalWalking', shown);
    expect(e, isNotNull);
    expect(m.activityChange.count, 1);
    expect(m.recentChanges.single.to, 'normalWalking');
    // Right after, the stretch is mostly walking: a flicker is unclear.
    final later = feed(m.recordSample, shown, 12, walking);
    expect(
        m.recordShownChange(
            ChangeTask.activity, 'normalWalking', 'shuffleWalking', later),
        isNull);
    expect(m.activityUnclear, 1);
    expect(m.activityChange.count, 1);
    m.endStream(); // a reconnect starts with no samples
    expect(m.changeEstimator.length, 0);
    m.reset();
    expect(m.recentChanges, isEmpty);
    expect(m.activityUnclear, 0);
  });

  test('a switch of the shown activity is timed; the first result is not', () {
    final m = AppMetrics();
    final sensor = SensorController(
        session: UserSession(rememberLastUser: false), metrics: m);
    addTearDown(sensor.dispose);
    final change = feed(m.recordSample,
        DateTime.now().subtract(const Duration(seconds: 13)), 9, sitting);
    feed(m.recordSample, change, 4, walking);
    sensor.addHarResult(const HarPrediction('sittingStanding', 0.9));
    expect(m.activityChange.count + m.activityUnclear, 0);
    sensor.addHarResult(const HarPrediction('normalWalking', 0.9));
    sensor.addHarResult(const HarPrediction('normalWalking', 0.9));
    sensor.addHarResult(const HarPrediction('normalWalking', 0.9));
    expect(sensor.harShown!.label, 'normalWalking');
    expect(m.activityChange.count, 1);
    expect(m.activityChange.last.inMilliseconds, closeTo(4000, 600));
  });
}
