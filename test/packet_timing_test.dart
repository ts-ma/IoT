import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/services/app_metrics.dart';
import 'package:pdiot/widgets/live_chart.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 10, 12);

  test('packet interval: time between packets on the phone', () {
    final m = AppMetrics();
    // Packets every 2.56 s; the second and fourth arrive 40 ms and 120 ms
    // late, so the intervals around them are longer and shorter.
    const late = [0, 40, 0, 120];
    for (var i = 0; i < late.length; i++) {
      m.recordPacket(i, 32, t0.add(Duration(milliseconds: i * 2560 + late[i])));
    }
    expect(m.packetInterval.count, 3);
    expect(m.packetInterval.min, const Duration(milliseconds: 2520));
    expect(m.packetInterval.max, const Duration(milliseconds: 2680));
  });

  test('a new stream does not count the gap as a packet interval', () {
    final m = AppMetrics();
    m.recordPacket(0, 32, t0);
    m.recordPacket(1, 32, t0.add(const Duration(milliseconds: 2600)));
    m.endStream();
    m.recordPacket(0, 32, t0.add(const Duration(minutes: 1)));
    m.recordPacket(1, 32, t0.add(const Duration(minutes: 1, seconds: 3)));
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
