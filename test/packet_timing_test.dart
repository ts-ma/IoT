import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/services/app_metrics.dart';
import 'package:pdiot/widgets/live_chart.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 10, 12);

  test('packet interval and extra delay above the fastest packet', () {
    final m = AppMetrics();
    // RESpeck clock is 5 s behind the phone; packets every 2.56 s, the
    // second and fourth arrive 40 ms and 120 ms late.
    const respeck0 = 1000000;
    const late = [0, 40, 0, 120];
    for (var i = 0; i < late.length; i++) {
      final sent = respeck0 + i * 2560;
      final received = t0.add(Duration(milliseconds: i * 2560 + late[i]));
      m.recordPacket(i, 32, received, respeckMs: sent);
    }
    expect(m.packetExtraDelay.count, 4);
    expect(m.packetExtraDelay.last, const Duration(milliseconds: 120));
    expect(m.packetExtraDelay.max, const Duration(milliseconds: 120));
    expect(m.packetExtraDelay.min, Duration.zero);
    expect(m.packetInterval.count, 3);
    expect(m.packetInterval.min, const Duration(milliseconds: 2520));
    expect(m.packetInterval.max, const Duration(milliseconds: 2680));
  });

  test('a new stream or a restarted RESpeck clock starts the delay afresh',
      () {
    final m = AppMetrics();
    m.recordPacket(0, 32, t0, respeckMs: 500000);
    m.recordPacket(1, 32, t0.add(const Duration(milliseconds: 2600)),
        respeckMs: 502560); // 40 ms late
    expect(m.packetExtraDelay.last, const Duration(milliseconds: 40));
    // Clock restarted: offset jumps by minutes, so it is not a 5 min delay.
    m.recordPacket(2, 32, t0.add(const Duration(milliseconds: 5160)),
        respeckMs: 1000);
    expect(m.packetExtraDelay.last, Duration.zero);
    m.endStream();
    m.recordPacket(0, 32, t0.add(const Duration(minutes: 1)), respeckMs: 9);
    expect(m.packetExtraDelay.last, Duration.zero);
    // The gap across endStream is not a packet interval.
    expect(m.packetInterval.count, 2);
  });

  testWidgets('sparse two-line chart shows stats per line', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: LiveLineChart(
          title: 'Model inference time',
          unit: 'ms',
          capacity: 10,
          fill: false,
          dots: true,
          series: [
            ChartSeries('HAR', Colors.orange, [1, null, null, 3, null, 2],
                connectGaps: true),
            ChartSeries('Social', Colors.pink, [4, null, 6, null, null, 5],
                connectGaps: true),
          ],
        ),
      ),
    ));
    expect(find.textContaining('min 1.0 · avg 2.0 · max 3.0'), findsOneWidget);
    expect(find.textContaining('min 4.0 · avg 5.0 · max 6.0'), findsOneWidget);
  });
}
