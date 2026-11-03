import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/app_shell.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/home.dart';
import 'package:pdiot/main.dart';
import 'package:pdiot/services/app_settings.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/social_sample_processor.dart';
import 'package:pdiot/services/user_session.dart';
import 'package:pdiot/social.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// Widget/state tests use the real classifier's validation and windowing with a
// fake native runner. They do not claim native inference or device BLE parity.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Runner runner;
  late SocialClassifier classifier;
  late _ObservedProcessor processor;
  late SensorController sensor;

  setUp(() async {
    appSettings.stepSamples.value = 25; // trained step; Settings default is 12
    sensor = SensorController(session: UserSession(rememberLastUser: false));
    runner = _Runner();
    classifier = await SocialClassifier.load(createRunner: () async => runner);
    processor = _ObservedProcessor(
      classifier: () => classifier,
      onError: (error, stack) {},
    );
  });

  tearDown(() {
    sensor.dispose();
    processor.dispose();
    classifier.dispose();
  });

  Future<void> showHome(WidgetTester tester,
      {SocialSampleProcessor? source}) async {
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
          sensor: sensor,
          session: sensor.session,
          socialProcessor: source ?? processor),
    ));
  }

  void feed(int count, {SocialSampleProcessor? source}) {
    for (var i = 0; i < count; i++) {
      (source ?? processor).addSample(0.1, -0.2, 0.9);
    }
  }

  String status(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('social-prediction-status')))
      .data!;

  final labelFinder = find.byKey(const ValueKey('social-prediction-label'));
  final confidenceFinder =
      find.byKey(const ValueKey('social-prediction-confidence'));

  const displayLabels = [
    'Normal Breathing',
    'Coughing',
    'Hyperventilating',
    'Other Social Signals',
  ];
  for (var index = 0; index < displayLabels.length; index++) {
    testWidgets('displays ${displayLabels[index]} with formatted confidence',
        (tester) async {
      runner.index = index;
      processor.startSession();
      await showHome(tester);
      feed(100);
      await tester.pump();
      expect(tester.widget<Text>(labelFinder).data, displayLabels[index]);
      expect(tester.widget<Text>(confidenceFinder).data, 'Confidence: 87.7%');
      expect(status(tester), 'Live prediction');
      expect(processor.latestPrediction!.prediction.label, socialLabels[index]);
      expect(processor.latestPrediction!.prediction.confidence, 0.87655);
      expect(
          find.text(
              'Social predictions are most reliable for stationary activities.'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('disconnected then warm-up; no prediction before sample 100',
      (tester) async {
    await showHome(tester);
    expect(status(tester), 'Disconnected');
    expect(labelFinder, findsNothing);
    processor.startSession();
    await tester.pump();
    expect(status(tester), 'Collecting data... (first result after about 8 s)');
    feed(99);
    await tester.pump();
    expect(labelFinder, findsNothing);
    expect(confidenceFinder, findsNothing);
    expect(runner.calls, 0);
    feed(1);
    await tester.pump();
    expect(runner.calls, 1);
    expect(labelFinder, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'keeps latest prediction while waiting, then updates at next step',
      (tester) async {
    processor.startSession();
    await showHome(tester);
    feed(100);
    await tester.pump();
    runner.index = 1;
    feed(24);
    await tester.pump();
    expect(tester.widget<Text>(labelFinder).data, 'Normal Breathing');
    expect(status(tester), 'Live prediction');
    feed(1);
    await tester.pump();
    expect(tester.widget<Text>(labelFinder).data, 'Coughing');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('multiple results before a frame show the final model output',
      (tester) async {
    runner.sequence = [0, 1, 2];
    processor.startSession();
    await showHome(tester);
    feed(150);
    await tester.pump();
    expect(runner.calls, 3);
    expect(tester.widget<Text>(labelFinder).data, 'Hyperventilating');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'disconnect, interruption and session changes clear stale results',
      (tester) async {
    processor.startSession();
    await showHome(tester);
    feed(100);
    await tester.pump();
    expect(labelFinder, findsOneWidget);
    processor.endSession();
    await tester.pump();
    expect(status(tester), 'Disconnected');
    expect(labelFinder, findsNothing);
    expect(confidenceFinder, findsNothing);
    processor.startSession();
    feed(99);
    await tester.pump();
    expect(status(tester), 'Collecting data... (first result after about 8 s)');
    expect(labelFinder, findsNothing);
    feed(1);
    await tester.pump();
    processor.resetStream();
    await tester.pump();
    expect(status(tester), 'Collecting data... (first result after about 8 s)');
    expect(labelFinder, findsNothing);
    feed(100);
    await tester.pump();
    processor.startSession(); // Even without a separate end-session event.
    await tester.pump();
    expect(status(tester), 'Collecting data... (first result after about 8 s)');
    expect(labelFinder, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed model loading shows unavailable without predictions',
      (tester) async {
    final session = SocialClassifierSession(loader: () async {
      throw StateError('model failed to load');
    });
    await expectLater(session.load(), throwsStateError);
    await tester.pumpWidget(MyApp(socialSession: session, startPerfSampler: false));
    expect(status(tester), 'Social model unavailable');
    expect(labelFinder, findsNothing);
    expect(confidenceFinder, findsNothing);
    final source =
        tester.widget<AppShell>(find.byType(AppShell)).socialProcessor!;
    source.startSession();
    feed(100, source: source);
    await tester.pump();
    expect(status(tester), 'Social model unavailable');
    expect(labelFinder, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Social inference errors clear result and leave HAR visible',
      (tester) async {
    final oldHar = harClassifier;
    harClassifier = _Har();
    addTearDown(() => harClassifier = oldHar);
    processor.startSession();
    await showHome(tester);
    sensor.updateFromPacket(
      accel: 'test acceleration',
      battery: null,
      charging: false,
      receivedAt: DateTime.utc(2026, 11, 2),
      prediction: const HarPrediction('running', 0.91),
    );
    feed(100);
    await tester.pump();
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Confidence: 91%'), findsOneWidget);
    expect(labelFinder, findsOneWidget);
    // Moving HAR output neither changes nor suppresses Social probabilities.
    expect(tester.widget<Text>(labelFinder).data, 'Normal Breathing');
    expect(tester.widget<Text>(confidenceFinder).data, 'Confidence: 87.7%');
    runner.fail = true;
    feed(25);
    await tester.pump();
    expect(status(tester), 'Social inference error — reconnect to retry');
    expect(labelFinder, findsNothing);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Confidence: 91%'), findsOneWidget);
    runner.fail = false;
    processor.startSession();
    await tester.pump();
    expect(status(tester), 'Collecting data... (first result after about 8 s)');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tab navigation keeps one Home subscription and live results',
      (tester) async {
    final session = SocialClassifierSession(loader: () async => classifier);
    await session.load();
    await tester.pumpWidget(MyApp(socialSession: session, startPerfSampler: false));
    final shellProcessor =
        tester.widget<AppShell>(find.byType(AppShell)).socialProcessor!;
    shellProcessor.startSession();
    feed(100, source: shellProcessor);
    await tester.pump();
    expect(tester.widget<Text>(labelFinder).data, 'Normal Breathing');
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey('tab-history')));
      await tester.pump();
      runner.index = 1;
      feed(25, source: shellProcessor); // Home is offstage but subscribed.
      await tester.tap(find.byKey(const ValueKey('tab-home')));
      await tester.pump();
      expect(tester.widget<Text>(labelFinder).data, 'Coughing');
    }
    shellProcessor.endSession();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing processor detaches old source and clears its result',
      (tester) async {
    processor.startSession();
    await showHome(tester);
    feed(100);
    await tester.pump();
    final replacement = _ObservedProcessor(classifier: () => null);
    addTearDown(replacement.dispose);
    await showHome(tester, source: replacement);
    expect(processor.observerCount, 0);
    expect(replacement.observerCount, 1);
    expect(status(tester), 'Social model unavailable');
    expect(labelFinder, findsNothing);
    processor.resetStream(); // Old source no longer updates this Home.
    await tester.pump();
    expect(status(tester), 'Social model unavailable');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(replacement.observerCount, 0);
  });

  test('state notifications occur on transitions/results, not every sample',
      () {
    var notifications = 0;
    processor.addListener(() => notifications++);
    expect(processor.status, SocialPredictionStatus.disconnected);
    processor.startSession();
    expect(notifications, 1);
    feed(99);
    expect(notifications, 1);
    feed(1);
    expect(notifications, 2);
    expect(processor.status, SocialPredictionStatus.ready);
    feed(24);
    expect(notifications, 2);
    processor.resetStream();
    expect(notifications, 3);
    expect(processor.latestPrediction, isNull);
    expect(processor.status, SocialPredictionStatus.collecting);
    processor.endSession();
    expect(processor.status, SocialPredictionStatus.disconnected);
  });
}

class _ObservedProcessor extends SocialSampleProcessor {
  _ObservedProcessor({required super.classifier, super.onError});

  final List<VoidCallback> _observers = [];
  int get observerCount => _observers.length;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _observers.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _observers.remove(listener);
  }
}

class _Runner implements SocialModelRunner {
  int index = 0;
  int calls = 0;
  bool fail = false;
  List<int> sequence = [];
  @override
  List<int> get inputShape => [1, 100, 3];
  @override
  TensorType get inputType => TensorType.float32;
  @override
  List<int> get outputShape => [1, 4];
  @override
  TensorType get outputType => TensorType.float32;
  @override
  List<double> run(List<List<List<double>>> batch) {
    calls++;
    if (fail) throw StateError('native inference failed');
    final selected = sequence.isEmpty ? index : sequence[calls - 1];
    return List<double>.filled(4, (1 - 0.87655) / 3)..[selected] = 0.87655;
  }

  @override
  void close() {}
}

class _Har implements HarClassifier {
  @override
  List<String> get classes => ['running'];
  @override
  final window = SampleWindow(50, 25);
  @override
  HarPrediction? addSample(double x, double y, double z) => null;
  @override
  void reset() => window.clear();
}
