import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/services/ble_delay_test.dart';
import 'package:pdiot/services/packet_feed.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/user_session.dart';
import 'package:pdiot/ble_delay_page.dart';
import 'package:pdiot/tools_page.dart';

// Simulated session: flicks every 4 s, the phone samples its motion at
// 100 Hz, the RESpeck at 12.5 Hz in 32-sample packets that reach the app a
// known delay after their last sample. The analysis must find that delay.
void main() {
  final t0 = DateTime.utc(2026, 11, 15, 12);
  const flickEvery = 4000; // ms
  const flicks = 6;

  // Movement (g) at time ms: a 250 ms half-sine jolt starting 2 s into each
  // 4 s period, plus a smaller rebound.
  double motion(double ms) {
    final inPeriod = ms % flickEvery - 2000;
    if (ms >= flicks * flickEvery || inPeriod < 0) return 0;
    if (inPeriod < 250) return 1.5 * math.sin(math.pi * inPeriod / 250);
    if (inPeriod < 450) {
      return 0.5 * math.sin(math.pi * (inPeriod - 250) / 200);
    }
    return 0;
  }

  List<PhoneMotion> phone() => [
        for (var ms = 0; ms < flicks * flickEvery + 3000; ms += 10)
          PhoneMotion(t0.add(Duration(milliseconds: ms)), motion(ms.toDouble())),
      ];

  /// RESpeck packets: gravity on z plus the jolt along x; packet k holds
  /// samples 32k..32k+31 and arrives [delay] (+ [jitter] for odd packets)
  /// after its last sample.
  List<RespeckMotion> respeck(int delayMs, {int jitterMs = 0}) {
    final out = <RespeckMotion>[];
    for (var k = 0; k * 32 * 80 < flicks * flickEvery + 3000; k++) {
      final lastSampleMs = (k * 32 + 31) * 80;
      final arrival = t0.add(Duration(
          milliseconds: lastSampleMs + delayMs + (k.isOdd ? jitterMs : 0)));
      out.addAll(respeckMotionOf(RespeckPacket(
        receivedAt: arrival,
        sequence: k,
        samples: [
          for (var i = 0; i < 32; i++)
            (x: motion(((k * 32 + i) * 80).toDouble()), y: 0.0, z: -1.0),
        ],
      )));
    }
    return out;
  }

  test('finds the sensor-to-app delay of every flick', () {
    final results = BleDelayAnalysis().analyse(phone(), respeck(120));
    expect(results, hasLength(flicks));
    for (final r in results) {
      expect(r.valid, isTrue, reason: r.reason);
      expect(r.delay!.inMilliseconds, closeTo(120, 40));
      expect(r.correlation, greaterThan(0.9));
    }
    final s = BleDelaySummary(results);
    expect(s.valid, flicks);
    expect(s.median, closeTo(120, 30));
    expect(s.sd, isNotNull);
  });

  test('a later packet gives a larger delay', () {
    final results =
        BleDelayAnalysis().analyse(phone(), respeck(60, jitterMs: 300));
    final s = BleDelaySummary(results);
    expect(s.valid, flicks);
    // Every packet: 60 ms; odd packets a further 300 ms late.
    expect(s.min, closeTo(60, 40));
    expect(s.max, closeTo(360, 40));
  });

  test('a RESpeck that did not move is reported, not timed', () {
    final still = [
      for (final r in respeck(120)) RespeckMotion(r.nominal, 0, 0, -1),
    ];
    final results = BleDelayAnalysis().analyse(phone(), still);
    expect(results, hasLength(flicks));
    expect(results.every((r) => !r.valid), isTrue);
    expect(results.first.reason, contains('hardly moved'));
    expect(BleDelaySummary(results).median, isNull);
  });

  test('CSV exports have one row per flick and per sample', () {
    final p = phone().take(5).toList();
    final r = respeck(120).take(3).toList();
    final results = BleDelayAnalysis().analyse(phone(), respeck(120));
    expect(flicksToCsv(results).trim().split('\n'), hasLength(flicks + 1));
    expect(bleDelaySamplesToCsv(p, r).trim().split('\n'), hasLength(9));
  });

  testWidgets('the page opens from Tools, checks the sensor, runs and cancels',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sensor =
        SensorController(session: UserSession(rememberLastUser: false));
    addTearDown(sensor.dispose);
    await tester.pumpWidget(MaterialApp(home: ToolsPage(sensor: sensor)));
    await tester.tap(find.byKey(const ValueKey('open-ble-delay-test')));
    await tester.pumpAndSettle();
    expect(find.text('Sensor-to-app delay test'), findsOneWidget);
    // Not connected: nothing starts.
    await tester.tap(find.byKey(const ValueKey('ble-start')));
    await tester.pump();
    expect(find.text('Connect the RESpeck on Home first - no live data is '
        'arriving'), findsOneWidget);
    expect(find.byKey(const ValueKey('ble-prompt')), findsNothing);

    // With simulated inputs it runs: hold still first, then cancel.
    final packets = StreamController<RespeckPacket>.broadcast();
    final phone = StreamController<PhoneMotion>.broadcast();
    addTearDown(packets.close);
    addTearDown(phone.close);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
      home: BleDelayTestPage(
        sensor: sensor,
        requireSensor: false,
        packets: packets.stream,
        phoneMotion: () => phone.stream,
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('ble-start')));
    await tester.pump();
    expect(find.byKey(const ValueKey('ble-prompt')), findsOneWidget);
    expect(find.text('Hold still'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.byKey(const ValueKey('ble-prompt')), findsNothing);
    expect(find.byKey(const ValueKey('ble-start')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
