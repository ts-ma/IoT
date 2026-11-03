import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/main.dart';
import 'package:pdiot/social.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// All runner outputs in this file are fake. Real model parity is tested only
// by social_classifier_native_test.dart when the native runtime is available.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> metadata() => jsonDecode(
        File('assets/models/harry_social_meta.json').readAsStringSync(),
      ) as Map<String, dynamic>;

  Future<SocialClassifier> load(_FakeRunner runner) =>
      SocialClassifier.load(createRunner: () async => runner);

  SocialPrediction? feed(SocialClassifier classifier, int from, int until) {
    SocialPrediction? result;
    for (var i = from; i < until; i++) {
      result = classifier.addSample(i.toDouble(), -i.toDouble(), 0.5);
    }
    return result;
  }

  test('loads bundled metadata with exact immutable class ordering', () async {
    final runner = _FakeRunner();
    final classifier = await load(runner);
    addTearDown(classifier.dispose);
    expect(classifier.classes,
        ['breathingNormally', 'coughing', 'hyperventilation', 'other']);
    expect(() => classifier.classes.add('talking'), throwsUnsupportedError);
    expect(runner.calls, 0);
  });

  test('first inference at 100, none at 99 or 124, second at 125', () async {
    final runner = _FakeRunner();
    final classifier = await load(runner);
    addTearDown(classifier.dispose);
    expect(feed(classifier, 0, 99), isNull);
    expect(runner.calls, 0);
    final first = feed(classifier, 99, 100)!;
    expect(first.label, 'coughing');
    expect(first.confidence, 0.6);
    expect(first.probabilities, [0.1, 0.6, 0.2, 0.1]);
    expect(runner.calls, 1);
    expect(feed(classifier, 100, 124), isNull);
    expect(runner.calls, 1);
    final second = feed(classifier, 124, 125)!;
    expect(runner.calls, 2);
    expect(identical(first, second), isFalse);
    expect(first.probabilities.every((p) => p.isFinite && p >= 0 && p <= 1),
        isTrue);
    expect(() => first.probabilities[0] = 0, throwsUnsupportedError);
    // Exactly raw axes in g: no scaling, normalization or axis permutation.
    expect(runner.windows[0].single, [
      for (var i = 0; i < 100; i++) [i.toDouble(), -i.toDouble(), 0.5]
    ]);
    expect(runner.windows[1].single, [
      for (var i = 25; i < 125; i++) [i.toDouble(), -i.toDouble(), 0.5]
    ]);
  });

  test('Social windows are independent of each other and HAR window state',
      () async {
    final firstRunner = _FakeRunner();
    final secondRunner = _FakeRunner();
    final first = await load(firstRunner);
    final second = await load(secondRunner);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final harWindow = SampleWindow(50, 25);
    harWindow.add(9, 8, 7);
    feed(first, 0, 100);
    feed(second, 0, 99);
    first.reset();
    expect(firstRunner.calls, 1);
    expect(secondRunner.calls, 0);
    expect(second.addSample(99, -99, 0.5), isNotNull);
    expect(harWindow.batch.single, [
      [9.0, 8.0, 7.0]
    ]);
    expect(first.addSample(100, 0, 0), isNull);
  });

  test('reset clears a partial window and restarts the full warm-up', () async {
    final runner = _FakeRunner();
    final classifier = await load(runner);
    addTearDown(classifier.dispose);
    feed(classifier, 0, 99);
    classifier.reset();
    expect(feed(classifier, 100, 199), isNull);
    expect(runner.calls, 0);
    expect(feed(classifier, 199, 200), isNotNull);
    expect(runner.windows.single.single.first, [100.0, -100.0, 0.5]);
    classifier.reset();
    expect(feed(classifier, 200, 299), isNull);
    expect(runner.calls, 1);
    expect(feed(classifier, 299, 300), isNotNull);
  });

  final invalidMetadata = <String, void Function(Map<String, dynamic>)>{
    'model file': (m) => m['model_file'] = 'harry_har.tflite',
    'task': (m) => m['task'] = 'daily_activity',
    'rate': (m) => m['sampling_frequency_hz'] = 25,
    'window': (m) => m['window_samples'] = 49,
    'step': (m) => m['step_samples'] = 0,
    'input shape': (m) => m['input']['shape'] = [1, 3, 50],
    'input dtype': (m) => m['input']['dtype'] = 'int8',
    'axis order': (m) =>
        m['input']['channels'] = ['accelZ', 'accelY', 'accelX'],
    'units': (m) => m['input']['units'] = 'm/s2',
    'output shape': (m) => m['output']['shape'] = [1, 11],
    'output dtype': (m) => m['output']['dtype'] = 'int8',
    'labels': (m) => m['output']['classes'] = [
          'other',
          'coughing',
          'hyperventilation',
          'breathingNormally'
        ],
    'normalization': (m) => m['normalization'] = 'external',
    'missing input': (m) => m.remove('input'),
  };
  for (final entry in invalidMetadata.entries) {
    test('rejects invalid metadata ${entry.key} before creating interpreter',
        () async {
      final meta = metadata();
      entry.value(meta);
      var creations = 0;
      await expectLater(
        SocialClassifier.load(
          metadataBundle: _JsonBundle(jsonEncode(meta)),
          createRunner: () async {
            creations++;
            return _FakeRunner();
          },
        ),
        throwsFormatException,
      );
      expect(creations, 0);
    });
  }

  for (final text in ['{', '[]', 'null']) {
    test('rejects malformed or non-object metadata $text', () async {
      await expectLater(
        SocialClassifier.load(metadataBundle: _JsonBundle(text)),
        throwsFormatException,
      );
    });
  }

  final invalidTensors = <String, void Function(_FakeRunner)>{
    'input shape': (r) => r.inputShape = [1, 49, 3],
    'input dtype': (r) => r.inputType = TensorType.int8,
    'output shape': (r) => r.outputShape = [1, 11],
    'output dtype': (r) => r.outputType = TensorType.int8,
  };
  for (final entry in invalidTensors.entries) {
    test('rejects binary ${entry.key} and closes allocated runner', () async {
      final runner = _FakeRunner();
      entry.value(runner);
      await expectLater(load(runner), throwsFormatException);
      expect(runner.closes, 1);
      expect(runner.calls, 0);
    });
  }

  for (final probabilities in <List<double>>[
    [double.nan, 0, 0, 1],
    [double.infinity, 0, 0, 0],
    [-0.1, 0.6, 0.2, 0.3],
    [1.1, 0, 0, 0],
    [0.1, 0.1, 0.1, 0.1],
    [0.5, 0.5],
  ]) {
    test('rejects invalid inference probabilities $probabilities', () async {
      final runner = _FakeRunner()..probabilities = probabilities;
      final classifier = await load(runner);
      addTearDown(classifier.dispose);
      feed(classifier, 0, 99);
      expect(() => classifier.addSample(99, -99, 0.5), throwsStateError);
      runner.probabilities = [0.1, 0.6, 0.2, 0.1];
      expect(feed(classifier, 100, 199), isNull);
      expect(runner.calls, 1);
      expect(feed(classifier, 199, 200), isNotNull);
    });
  }

  test('non-finite acceleration clears the window without invoking runner',
      () async {
    final runner = _FakeRunner();
    final classifier = await load(runner);
    addTearDown(classifier.dispose);
    feed(classifier, 0, 99);
    expect(() => classifier.addSample(0, double.nan, 0), throwsArgumentError);
    expect(feed(classifier, 100, 199), isNull);
    expect(runner.calls, 0);
  });

  test('runner exceptions produce no prediction and require a fresh window',
      () async {
    final runner = _FakeRunner()..error = StateError('inference failed');
    final classifier = await load(runner);
    addTearDown(classifier.dispose);
    feed(classifier, 0, 99);
    expect(() => classifier.addSample(99, -99, 0.5), throwsStateError);
    runner.error = null;
    expect(feed(classifier, 100, 199), isNull);
    expect(feed(classifier, 199, 200), isNotNull);
  });

  test('dispose closes once and rejects further use', () async {
    final runner = _FakeRunner();
    final classifier = await load(runner);
    classifier.dispose();
    classifier.dispose();
    expect(runner.closes, 1);
    expect(() => classifier.addSample(0, 0, 0), throwsStateError);
    expect(classifier.reset, throwsStateError);
  });

  test('session shares concurrent loads and closes exactly once', () async {
    final runner = _FakeRunner();
    var loads = 0;
    final session = SocialClassifierSession(loader: () {
      loads++;
      return load(runner);
    });
    await Future.wait([session.load(), session.load()]);
    await session.load();
    expect(loads, 1);
    expect(session.classifier, isNotNull);
    session.dispose();
    session.dispose();
    expect(session.classifier, isNull);
    expect(runner.closes, 1);
    expect(session.load, throwsStateError);
  });

  test('session disposed during loading closes late interpreter', () async {
    final runner = _FakeRunner();
    final pending = Completer<SocialClassifier>();
    final session = SocialClassifierSession(loader: () => pending.future);
    final loading = session.load();
    session.dispose();
    pending.complete(await load(runner));
    await loading;
    expect(session.classifier, isNull);
    expect(runner.closes, 1);
  });

  testWidgets('Social loading failure leaves HAR and the app usable',
      (tester) async {
    final previousHar = harClassifier;
    final fakeHar = _FakeHarClassifier();
    harClassifier = fakeHar;
    addTearDown(() => harClassifier = previousHar);
    final session = SocialClassifierSession(
      loader: () => SocialClassifier.load(createRunner: () async {
        throw StateError('native Social loading failed');
      }),
    );
    // Same independent failure boundary used by main: failure is caught before
    // mounting the app. This tests isolation with a fake HAR, not HAR inference.
    await tester.runAsync(() async {
      await expectLater(session.load(), throwsStateError);
    });
    expect(session.classifier, isNull);
    await tester.pumpWidget(MyApp(socialSession: session));
    expect(find.text('PDIoT'), findsOneWidget);
    expect(harClassifier, same(fakeHar));
    expect(harClassifier!.addSample(0, 0, 1)?.label, 'normalWalking');
    expect(fakeHar.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('app detachment and disposal close Social without double close',
      (tester) async {
    final runner = _FakeRunner();
    final session = SocialClassifierSession(loader: () => load(runner));
    await tester.runAsync(session.load);
    await tester.pumpWidget(MyApp(socialSession: session));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(runner.closes, 1);
    expect(session.classifier, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(runner.closes, 1);
  });
}

class _FakeRunner implements SocialModelRunner {
  @override
  List<int> inputShape = [1, 100, 3];
  @override
  TensorType inputType = TensorType.float32;
  @override
  List<int> outputShape = [1, 4];
  @override
  TensorType outputType = TensorType.float32;
  List<double> probabilities = [0.1, 0.6, 0.2, 0.1];
  Object? error;
  int calls = 0;
  int closes = 0;
  final List<List<List<List<double>>>> windows = [];

  @override
  List<double> run(List<List<List<double>>> batch) {
    calls++;
    windows.add([
      for (final window in batch)
        [for (final row in window) List<double>.of(row)],
    ]);
    if (error != null) throw error!;
    return List.of(probabilities);
  }

  @override
  void close() => closes++;
}

class _JsonBundle extends CachingAssetBundle {
  _JsonBundle(this.json);
  final String json;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(json)));
}

class _FakeHarClassifier implements HarClassifier {
  int calls = 0;
  @override
  final classes = ['normalWalking'];
  @override
  final window = SampleWindow(50, 25);

  @override
  HarPrediction? addSample(double x, double y, double z) {
    calls++;
    return const HarPrediction('normalWalking', 0.9);
  }

  @override
  void reset() => window.clear();
}
