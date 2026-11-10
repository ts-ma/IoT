import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdiot/performance.dart';
import 'package:pdiot/services/app_metrics.dart';
import 'package:pdiot/services/device_stats.dart';
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
    expect(find.text('MEMORY (RSS)'), findsOneWidget);
    expect(find.text('Response time'), findsOneWidget);
    expect(find.text('How each number is measured'), findsOneWidget);
    sampler.dispose();
  });
}
