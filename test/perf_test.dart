import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdiot/performance.dart';
import 'package:pdiot/services/app_metrics.dart';
import 'package:pdiot/services/device_stats.dart';
import 'package:pdiot/services/latency_test.dart';
import 'package:pdiot/services/perf_sampler.dart';
import 'package:pdiot/services/user_session.dart';
import 'package:pdiot/widgets/live_chart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('/proc/self/stat: utime + stime after the command name', () {
    // Field 2 can contain spaces and parentheses.
    const stat = '1234 (Flutter (UI) x) S 1 2 3 4 5 6 7 8 9 10 250 75 0 0 20';
    expect(parseProcStatCpuSeconds(stat), closeTo(3.25, 1e-9));
    expect(parseProcStatCpuSeconds('garbage'), isNull);
  });

  test('getrusage reads this process CPU time and it only grows', () {
    final clock = CpuClock.instance;
    final a = clock.read();
    var x = 0.0;
    for (var i = 0; i < 3000000; i++) {
      x += i * 1e-9;
    }
    final b = clock.read();
    expect(x, greaterThan(0));
    expect(a, isNotNull);
    expect(clock.source, 'getrusage');
    expect(b!, greaterThanOrEqualTo(a!));
    expect(currentRssBytes(), greaterThan(1024 * 1024));
  });

  test('phone power = |current| x voltage; missing values are unknown', () {
    final b = PhoneBattery.fromMap({
      'level': 81,
      'charging': false,
      'currentMicroA': -350000,
      'voltageMilliV': 3900,
    });
    expect(b.level, 81);
    expect(b.powerMilliW, closeTo(1365, 1e-9));
    final ios = PhoneBattery.fromMap({'level': -1, 'charging': true});
    expect(ios.level, isNull);
    expect(ios.powerMilliW, isNull);
  });

  test('sampler: CPU %, model timing, battery, storage and the CSV log',
      () async {
    final storage = await Directory.systemTemp.createTemp('pdiot_perf_');
    addTearDown(() => storage.delete(recursive: true));
    final session =
        UserSession(storage: () async => storage, rememberLastUser: false);
    await session.init();
    await session.create('harry');
    await File(p.join(session.rawDir!.path, 'a.csv')).writeAsString('x' * 2048);

    const channel = MethodChannel('pdiot/power');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => {
                  'level': 64,
                  'charging': false,
                  'currentMicroA': 200000,
                  'voltageMilliV': 4000,
                });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final metrics = AppMetrics();
    final sampler = PerfSampler(
        session: session,
        metrics: metrics,
        capacity: 3,
        power: PowerChannel(channel: channel));
    await sampler.sample();
    metrics.recordHarInference(const Duration(microseconds: 1500));
    metrics.recordHarInference(const Duration(microseconds: 2500));
    expect(await sampler.setLogging(true), isNull);
    await sampler.sample();
    final s = sampler.latest!;
    expect(s.cpuPercent, isNotNull);
    expect(s.rssMb, greaterThan(1));
    expect(s.harMs, closeTo(2.0, 1e-9)); // mean of the two calls this second
    expect(s.socialMs, isNull);
    expect(s.phoneLevel, 64);
    expect(s.phonePowerMw, closeTo(800, 1e-9));
    expect(sampler.storage.raw, 2048);
    expect(sampler.storage.rawFiles, 1);
    for (var i = 0; i < 3; i++) {
      await sampler.sample();
    }
    expect(sampler.samples, hasLength(3)); // ring buffer
    final log = sampler.logFile!;
    await sampler.setLogging(false);
    final lines = await log.readAsLines();
    expect(lines.first, PerfSample.csvHeader);
    expect(lines, hasLength(5)); // header + 4 samples while logging
    expect(p.dirname(log.path), session.performanceDir!.path);
    // Every row has the header's columns; the conditions file sits next to it.
    for (final l in lines) {
      expect(l.split(',').length, PerfSample.csvHeader.split(',').length);
    }
    final cond = File(log.path.replaceFirst('.csv', '.conditions.json'));
    final info = jsonDecode(await cond.readAsString()) as Map<String, dynamic>;
    expect(info['platform'], Platform.operatingSystem);
    expect(info['duration_s'], isA<int>());
    expect(info['log_file'], p.basename(log.path));
    sampler.dispose();
  });

  testWidgets('live chart and Performance tab render with data',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: LiveLineChart(
          title: 'CPU',
          unit: '%',
          capacity: 10,
          series: [
            ChartSeries('CPU', Colors.cyan, [1, 2, null, 4, 8.5]),
          ],
        ),
      ),
    ));
    expect(find.text('CPU'), findsOneWidget);
    expect(find.textContaining('max 8.5'), findsOneWidget);

    final session =
        UserSession(storage: () async => null, rememberLastUser: false);
    final sampler = PerfSampler(session: session, metrics: AppMetrics());
    await tester.runAsync(sampler.sample);
    await tester
        .pumpWidget(MaterialApp(home: PerformancePage(sampler: sampler)));
    expect(find.text('Live monitor'), findsOneWidget);
    expect(find.text('MEMORY'), findsOneWidget);
    expect(find.text('Response time'), findsOneWidget);
    expect(find.text('How each number is measured'), findsOneWidget);
    // Battery, power and the removed latency rows are gone.
    expect(find.text('Phone battery'), findsNothing);
    expect(find.text('RESpeck battery'), findsNothing);
    expect(find.text('PACKET → DISPLAY UPDATE'), findsNothing);
    expect(find.text('SENSOR SAMPLE RATE'), findsNothing);
    expect(find.text('STORAGE USED'), findsNothing);
    expect(find.text('History writer'), findsNothing);
    expect(find.text('RESPECK → PHONE EXTRA DELAY'), findsNothing);
    expect(find.text('PACKET INTERVAL'), findsOneWidget);
    expect(find.textContaining('change shown'), findsNothing);
    expect(find.textContaining('without a clear signal change'), findsNothing);

    // One model at a time: activity first, social from the drop-down.
    expect(find.text('harry_har_cnn.tflite'), findsOneWidget);
    expect(find.textContaining('static 99.4 %'), findsOneWidget);
    expect(find.textContaining('breathing 89.3 %'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Social signal').last);
    await tester.pumpAndSettle();
    expect(find.text('harry_social_cnn.tflite'), findsOneWidget);
    expect(find.textContaining('breathing 89.3 %'), findsOneWidget);
    expect(find.textContaining('static 99.4 %'), findsNothing);
    expect(find.text('75 samples (6 s)'), findsOneWidget);
    sampler.dispose();
  });

  testWidgets('Response time shows the latency-test mean and median',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('pdiot_perf_lat_')))!;
    addTearDown(() => dir.delete(recursive: true));
    final session =
        UserSession(storage: () async => dir, rememberLastUser: false);
    await tester.runAsync(() async {
      await session.init();
      await session.create('harry');
    });
    LatencyRep rep(LatencyTask task, int shownMs,
            {String start = 'button', String? rawAtStart}) =>
        LatencyRep(
          participant: 'harry',
          task: task,
          from: task == LatencyTask.activity
              ? 'sittingStanding'
              : 'breathingNormally',
          to: task == LatencyTask.activity ? 'normalWalking' : 'coughing',
          cueAt: DateTime.utc(2026, 11, 15),
          fromReached: true,
          shown: Duration(milliseconds: shownMs),
          stable: Duration(milliseconds: shownMs),
          start: start,
          rawAtStart: rawAtStart,
        );
    await tester
        .runAsync(() => LatencyStore(() async => session.latencyFile!).save([
              rep(LatencyTask.activity, 2000),
              rep(LatencyTask.activity, 3000),
              rep(LatencyTask.activity, 7000),
              // Left out: started too early, and the old cue-started method.
              rep(LatencyTask.activity, 500, rawAtStart: 'normalWalking'),
              rep(LatencyTask.activity, 9000, start: 'cue'),
              rep(LatencyTask.social, 5000),
            ]));
    await tester
        .pumpWidget(MaterialApp(home: PerformancePage(session: session)));
    // The page reads the file in the background (several real I/O steps).
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    // Activity: 2, 3 and 7 s -> mean 4.00 s, median 3.00 s.
    expect(find.text('4.00 s (3 changes)'), findsOneWidget);
    expect(find.text('3.00 s (3 changes)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Social signal').last);
    await tester.pumpAndSettle();
    expect(find.text('5.00 s (1 change)'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
