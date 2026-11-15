import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/home.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/user_session.dart';

// The activity card shows one probability bar per class, from the latest model
// result, like the Social card.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SensorController sensor;
  HarClassifier? oldHar;

  setUp(() {
    oldHar = harClassifier;
    harClassifier = _Har();
    sensor = SensorController(session: UserSession(rememberLastUser: false));
  });

  tearDown(() {
    harClassifier = oldHar;
    sensor.dispose();
  });

  Future<void> show(WidgetTester tester, HarPrediction p) async {
    await tester.pumpWidget(MaterialApp(
      home: HomePage(sensor: sensor, session: sensor.session),
    ));
    sensor.updateFromPacket(
      accel: 'test acceleration',
      battery: null,
      charging: false,
      receivedAt: DateTime.utc(2026, 11, 13),
      prediction: p,
    );
    await tester.pump();
  }

  testWidgets('one bar per class with the model probabilities',
      (tester) async {
    await show(tester, const HarPrediction('lyingBack', 0.7, [0.7, 0.2, 0.1]));
    final bars = find.byKey(const ValueKey('har-probabilities'));
    expect(bars, findsOneWidget);
    expect(
        find.descendant(of: bars, matching: find.byType(LinearProgressIndicator)),
        findsNWidgets(3));
    for (final pct in ['70%', '20%', '10%']) {
      expect(find.descendant(of: bars, matching: find.text(pct)),
          findsOneWidget);
    }
    expect(find.descendant(of: bars, matching: find.text('Running')),
        findsOneWidget);
    expect(find.text('Model output'), findsOneWidget);
    expect(find.text('Confidence: 70%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no bars when the probabilities are unknown', (tester) async {
    await show(tester, const HarPrediction('lyingBack', 0.9));
    expect(find.byKey(const ValueKey('har-probabilities')), findsNothing);
    expect(find.text('Confidence: 90%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Har implements HarClassifier {
  @override
  List<String> get classes => ['lyingBack', 'running', 'normalWalking'];
  @override
  final window = SampleWindow(50, 25);
  @override
  HarPrediction? addSample(double x, double y, double z) => null;
  @override
  void reset() => window.clear();
}
