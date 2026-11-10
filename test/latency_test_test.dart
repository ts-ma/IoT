import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/latency_page.dart';
import 'package:pdiot/services/latency_test.dart';
import 'package:pdiot/services/live_feed.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/social_sample_processor.dart';
import 'package:pdiot/services/user_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime.utc(2026, 11, 10, 9);

  group('LatencyRun', () {
    late StreamController<LiveHarEvent> har;
    late StreamController<SocialPredictionEvent> social;
    late DateTime now;
    setUp(() {
      har = StreamController.broadcast(sync: true);
      social = StreamController.broadcast(sync: true);
      now = t0;
    });

    void send(String raw, String shown, double s) => har.add(LiveHarEvent(
        HarPrediction(raw, 0.9), t0.add(Duration(milliseconds: (s * 1000).round())),
        shown: HarPrediction(shown, 0.9)));

    LatencyRun make({int reps = 1, List<LatencyRep>? done, void Function()? cue}) =>
        LatencyRun(
          task: LatencyTask.activity,
          from: 'sittingStanding',
          to: 'normalWalking',
          reps: reps,
          participant: 'p1',
          harEvents: har.stream,
          socialEvents: social.stream,
          clock: () => now,
          random: Random(1),
          minHold: const Duration(seconds: 2),
          maxHold: const Duration(seconds: 2),
          onCue: cue,
          onFinished: (r) => done?.addAll(r),
          stepSamples: 6,
          smoothing: true,
        );

    testWidgets('settle on FROM, cue, then first correct / shown / steady',
        (tester) async {
      final done = <LatencyRep>[];
      var cues = 0;
      final run = make(done: done, cue: () => cues++);
      run.start();
      expect(run.phase, LatencyPhase.settling);
      send('sittingStanding', 'sittingStanding', 0);
      send('sittingStanding', 'sittingStanding', 1);
      expect(run.phase, LatencyPhase.settling); // only 1 s steady
      send('sittingStanding', 'sittingStanding', 3.2);
      expect(run.phase, LatencyPhase.holding);
      now = t0.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 2));
      expect(run.phase, LatencyPhase.cued);
      expect(cues, 1);
      send('normalWalking', 'sittingStanding', 11); // raw first, display lags
      send('normalWalking', 'normalWalking', 12);
      send('miscMovement', 'sittingStanding', 12.5); // flicker resets steady
      send('normalWalking', 'normalWalking', 13);
      send('normalWalking', 'normalWalking', 14);
      expect(run.phase, LatencyPhase.cued);
      send('normalWalking', 'normalWalking', 16);
      expect(run.phase, LatencyPhase.finished);
      final r = done.single;
      expect(r.firstCorrect, const Duration(seconds: 1));
      expect(r.shown, const Duration(seconds: 2));
      expect(r.stable, const Duration(seconds: 3)); // run from 13 s held 3 s
      expect(r.fromReached, isTrue);
      expect(r.timedOut, isFalse);
      expect(LatencyRep.fromJson(r.toJson()).toJson(), r.toJson());
      run.dispose();
    });

    testWidgets('times out and flags a FROM that was never shown',
        (tester) async {
      final done = <LatencyRep>[];
      final run = make(reps: 2, done: done);
      run.start();
      await tester.pump(const Duration(seconds: 30)); // settle timeout
      expect(run.phase, LatencyPhase.holding);
      await tester.pump(const Duration(seconds: 2));
      expect(run.phase, LatencyPhase.cued);
      await tester.pump(const Duration(seconds: 30)); // no change seen
      expect(run.results.single.timedOut, isTrue);
      expect(run.results.single.fromReached, isFalse);
      expect(run.phase, LatencyPhase.settling); // second change
      run.cancel();
      expect(run.phase, LatencyPhase.idle);
      expect(done, isEmpty);
      run.dispose();
    });

    test('social changes use the social stream', () async {
      final run = LatencyRun(
        task: LatencyTask.social,
        from: 'breathingNormally',
        to: 'coughing',
        reps: 1,
        participant: 'p1',
        harEvents: har.stream,
        socialEvents: social.stream,
      )..start();
      send('normalWalking', 'normalWalking', 0); // ignored
      expect(run.shownLabel, isNull);
      run.cancel();
      run.dispose();
    });

    test('CSV: every row has the header columns', () {
      final reps = [
        LatencyRep(
            participant: 'a',
            task: LatencyTask.activity,
            from: 'sittingStanding',
            to: 'normalWalking',
            cueAt: t0,
            fromReached: true,
            firstCorrect: const Duration(milliseconds: 2100),
            shown: const Duration(milliseconds: 2600),
            stable: const Duration(milliseconds: 2600)),
        LatencyRep(
            participant: 'a',
            task: LatencyTask.social,
            from: 'breathingNormally',
            to: 'coughing',
            cueAt: t0,
            fromReached: false),
      ];
      for (final csv in [latencyRepsToCsv(reps), latencySummaryToCsv(reps)]) {
        final lines = csv.trim().split('\n');
        final n = lines.first.split(',').length;
        for (final l in lines) {
          expect(l.split(',').length, n, reason: l);
        }
      }
      expect(latencySummaryToCsv(reps), contains('activity,ALL,ALL,1,0'));
      expect(LatencyStats.of(reps).first.shownMean, 2.6);
    });
  });

  testWidgets('latency page: start shows the change, cancel returns',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _MemoryStore();
    final feed = LivePredictionFeed();
    final sensor =
        SensorController(session: UserSession(rememberLastUser: false));
    addTearDown(sensor.dispose);
    var cues = 0;
    await tester.pumpWidget(MaterialApp(
      home: LatencyTestPage(
        sensor: sensor,
        feed: feed,
        store: store,
        requireSensor: false,
        onCue: () => cues++,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('latency-start')));
    await tester.pump();
    expect(find.text('Change 1 of 3'), findsOneWidget);
    expect(find.text('Sitting / Standing'), findsOneWidget);
    // Cancel works and returns to the setup.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.byKey(const ValueKey('latency-start')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(cues, 0);
  });
}

/// Keeps reps in memory: real file I/O does not complete inside testWidgets.
class _MemoryStore extends LatencyStore {
  _MemoryStore() : super(() async => File('unused'));

  List<LatencyRep> saved = [];

  @override
  Future<List<LatencyRep>> load() async => List.of(saved);

  @override
  Future<void> save(List<LatencyRep> reps) async => saved = List.of(reps);
}
