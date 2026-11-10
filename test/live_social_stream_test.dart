import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/ble.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/app_shell.dart';
import 'package:pdiot/main.dart';
import 'package:pdiot/services/app_settings.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_history_writer.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:pdiot/services/social_sample_processor.dart';
import 'package:pdiot/social.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// Decoded-sample integration tests. Social uses the real window/classifier
// wrapper with a fake interpreter; HAR uses a windowed double. No BLE hardware,
// packet decoding, or native inference is simulated as a successful device test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HarClassifier? originalHar;
  late _HarDouble har;
  late _SocialRunner runner;
  late SocialClassifier social;
  late SocialSampleProcessor processor;
  late List<SocialPredictionEvent> events;
  late List<Object> errors;
  late List<HarPrediction> harEvents;

  setUp(() async {
    // These tests pin the trained 25-sample step (Settings default is 12).
    appSettings.stepSamples.value = 25;
    originalHar = harClassifier;
    har = _HarDouble();
    harClassifier = har;
    runner = _SocialRunner();
    social = await SocialClassifier.load(createRunner: () async => runner);
    events = [];
    errors = [];
    harEvents = [];
    processor = SocialSampleProcessor(
      classifier: () => social,
      onPrediction: events.add,
      onError: (error, stack) => errors.add(error),
    )..startSession();
  });

  tearDown(() {
    processor.endSession();
    social.dispose();
    harClassifier = originalHar;
  });

  // Exactly the helper called inside one existing BLE notification's sample
  // loop. Large batches exercise multiple inferences without packet-level loss.
  void feedPacket(int start, int end, {void Function(HarPrediction)? capture}) {
    for (var i = start; i < end; i++) {
      processDecodedSample(
        i / 100,
        -i / 100,
        0.75,
        onPrediction: capture ?? harEvents.add,
        socialProcessor: processor,
      );
    }
  }

  test('one decoded sample feeds the same raw axes to both classifiers', () {
    final socialDouble = _SocialDouble();
    final adapter = SocialSampleProcessor(classifier: () => socialDouble)
      ..startSession();
    processDecodedSample(0.12, -0.34, 0.98, socialProcessor: adapter);
    expect(har.samples.single, [0.12, -0.34, 0.98]);
    expect(socialDouble.samples.single, har.samples.single);
    adapter.endSession();
  });

  test('HAR inputs, raw outputs and callback ordering match direct HAR use',
      () {
    final baseline = _HarDouble();
    final expected = <HarPrediction>[];
    for (var i = 0; i < 100; i++) {
      final p = baseline.addSample(i / 100, -i / 100, 0.75);
      if (p != null) expected.add(p);
    }
    for (var i = 0; i < 100; i++) {
      final before = processor.inferenceCount;
      final result = processDecodedSample(
        i / 100,
        -i / 100,
        0.75,
        socialProcessor: processor,
        onPrediction: (prediction) {
          // HAR history callback still runs before Social on the same sample.
          expect(processor.inferenceCount, before);
          harEvents.add(prediction);
        },
      );
      if (result != null) expect(result, same(harEvents.last));
    }
    expect(har.samples, baseline.samples);
    expect(harEvents.map((p) => p.label), expected.map((p) => p.label));
    expect(
        harEvents.map((p) => p.confidence), expected.map((p) => p.confidence));
    expect(har.resets, 0);
  });

  test('Social events occur at samples 75 and 100, never 74 or 99', () {
    feedPacket(0, 74);
    expect(events, isEmpty);
    expect(runner.calls, 0);
    feedPacket(74, 75);
    expect(events, hasLength(1));
    feedPacket(75, 99);
    expect(events, hasLength(1));
    feedPacket(99, 100);
    expect(events, hasLength(2));
    expect(runner.calls, 2);
    expect(runner.windows[0].single.first, [0.0, 0.0, 0.75]);
    expect(runner.windows[1].single.first, [0.25, -0.25, 0.75]);
  });

  test('all new Social inferences from one packet are preserved in order', () {
    var clockReads = 0;
    final base = DateTime.parse('2026-11-02T14:00:00+01:00');
    processor = SocialSampleProcessor(
      classifier: () => social,
      clock: () {
        // Model invocation has completed before the completion clock is read.
        expect(runner.calls, clockReads + 1);
        return base.add(Duration(microseconds: clockReads++));
      },
      onPrediction: events.add,
    )..startSession();
    feedPacket(0, 150); // Four Social results at 75, 100, 125 and 175.
    expect(events, hasLength(4));
    expect(clockReads, 4);
    expect(events.map((e) => e.completedAt), [
      for (var i = 0; i < 4; i++) base.toUtc().add(Duration(microseconds: i)),
    ]);
    expect(events.every((e) => e.completedAt.isUtc), isTrue);
    expect(events.map((e) => e.prediction.label), everyElement('coughing'));
    expect(events.map((e) => e.prediction.confidence), everyElement(0.7));
    expect(processor.inferenceCount, 4);
    expect(processor.lastInferenceDuration, events.last.processingDuration);
    expect(processor.maxInferenceDuration >= events.last.processingDuration,
        isTrue);
  });

  test('null does not replay a cached result; equal labels remain separate',
      () {
    feedPacket(0, 75);
    final first = events.single;
    feedPacket(75, 99);
    expect(events, [first]);
    feedPacket(99, 100);
    expect(events, hasLength(2));
    expect(events.last.prediction.label, first.prediction.label);
    expect(identical(events.last, first), isFalse);
    expect(identical(events.last.prediction, first.prediction), isFalse);
  });

  test('Social inference failure is reported once and HAR keeps processing',
      () {
    runner.fail = true;
    feedPacket(0, 125);
    expect(har.samples, hasLength(125));
    expect(harEvents, hasLength(4));
    expect(events, isEmpty);
    expect(runner.calls, 1);
    expect(errors, hasLength(1));
    expect(processor.failed, isTrue);
    expect(processor.errorCount, 1);
    expect(har.resets, 0);
    runner.fail = false;
    processor.endSession();
    processor.startSession();
    feedPacket(125, 199);
    expect(events, isEmpty);
    feedPacket(199, 200);
    expect(events, hasLength(1));
    expect(processor.failed, isFalse);
  });

  test('event and diagnostic callback errors cannot abort subsequent samples',
      () {
    processor = SocialSampleProcessor(
      classifier: () => social,
      onPrediction: (event) => throw StateError('observer failed'),
      onError: (error, stack) => throw StateError('reporter failed'),
    )..startSession();
    expect(() => feedPacket(0, 75), returnsNormally);
    expect(har.samples, hasLength(75));
    expect(harEvents, hasLength(2));
    expect(processor.inferenceCount, 1);
    expect(processor.deliveryErrorCount, 1);
    expect(processor.failed, isFalse);
  });

  test('unavailable or disposed Social classifier does not block HAR', () {
    processor = SocialSampleProcessor(classifier: () => null)..startSession();
    feedPacket(0, 75);
    expect(har.samples, hasLength(75));
    expect(harEvents, hasLength(2));
    social.dispose();
    processor = SocialSampleProcessor(
      classifier: () => social,
      onError: (error, stack) => errors.add(error),
    )..startSession();
    feedPacket(75, 100);
    expect(har.samples, hasLength(100));
    expect(harEvents, hasLength(3));
    expect(errors, hasLength(1));
  });

  test('disconnect and reconnect clear Social state without resetting HAR', () {
    feedPacket(0, 74);
    processor.endSession();
    expect(processor.isActive, isFalse);
    feedPacket(74, 75); // A late callback cannot feed Social after disconnect.
    expect(events, isEmpty);
    processor.startSession();
    feedPacket(75, 149);
    expect(events, isEmpty);
    feedPacket(149, 150);
    expect(events, hasLength(1));
    expect(runner.windows.single.single.first, [0.75, -0.75, 0.75]);
    expect(har.samples, hasLength(150));
    expect(har.resets, 0);
  });

  test('confirmed stream interruption requires a full fresh Social window', () {
    feedPacket(0, 75);
    processor.resetStream();
    expect(processor.isActive, isTrue);
    feedPacket(75, 149);
    expect(events, hasLength(1));
    feedPacket(149, 150);
    expect(events, hasLength(2));
    expect(runner.windows.last.single.first, [0.75, -0.75, 0.75]);
    expect(har.resets, 0);
  });

  test('HAR history retains all raw results without awaiting SQLite in loop',
      () async {
    final repository = _RepositoryDouble();
    final gate = Completer<void>();
    final timestamp = DateTime.utc(2026, 11, 2, 12);
    final writer = PredictionHistoryWriter(
      openRepository: () async {
        await gate.future;
        return repository;
      },
      clock: () => timestamp,
    );
    addTearDown(() async {
      await writer.shutdown();
      writer.dispose();
    });
    feedPacket(0, 125, capture: writer.capture);
    // All samples and Social events finish before a delayed DB even opens.
    expect(har.samples, hasLength(125));
    expect(events, hasLength(3)); // Social windows complete at 75, 100, 125.
    expect(writer.pendingCount, 4);
    expect(repository.saved, isEmpty);
    gate.complete();
    await writer.flush();
    expect(repository.saved, hasLength(4));
    expect(repository.saved.map((r) => r.taskType),
        everyElement(PredictionTaskType.har));
    expect(repository.saved.map((r) => r.source),
        everyElement(PredictionSource.live));
    expect(repository.saved.map((r) => r.label), everyElement('normalWalking'));
    expect(repository.saved.map((r) => r.confidence), everyElement(0.9));
    expect(repository.saved.map((r) => r.timestamp), everyElement(timestamp));
    expect(writer.errorCount, 0);
  });

  testWidgets('app wiring survives rebuilds and ignores the CSV recording flag',
      (tester) async {
    final appRepository = _RepositoryDouble();
    final appWriter = PredictionHistoryWriter(
      openRepository: () async => appRepository,
    );
    final session = SocialClassifierSession(loader: () async => social);
    await session.load();
    await tester.pumpWidget(MyApp(
      socialSession: session,
      onSocialPrediction: events.add,
      createHistoryWriter: () => appWriter,
    ));
    final shell = tester.widget<AppShell>(find.byType(AppShell));
    final connectedProcessor = shell.socialProcessor!;
    connectedProcessor.startSession();
    final recorder = shell.sensor.recorder;
    // The extracted decoded-sample path has no dependency on CSV/UI state.
    for (var i = 0; i < 75; i++) {
      expect(recorder.active, isFalse);
      processDecodedSample(0, 0, 1, socialProcessor: connectedProcessor);
    }
    expect(events, hasLength(1));
    await tester.pumpWidget(MyApp(
      socialSession: session,
      onSocialPrediction: events.add,
      createHistoryWriter: () => appWriter,
    ));
    expect(tester.widget<AppShell>(find.byType(AppShell)).socialProcessor,
        same(connectedProcessor));
    expect(events, hasLength(1)); // Rebuild emits nothing.
    for (var i = 0; i < 25; i++) {
      processDecodedSample(0, 0, 1, socialProcessor: connectedProcessor);
    }
    expect(events, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await appWriter.shutdown();
    expect(appRepository.saved, hasLength(2));
    expect(appRepository.saved.map((r) => r.taskType),
        everyElement(PredictionTaskType.social));
    expect(connectedProcessor.isActive, isFalse);
    expect(session.classifier, isNull);
  });
}

class _HarDouble implements HarClassifier {
  final List<List<double>> samples = [];
  int resets = 0;
  @override
  final classes = ['normalWalking'];
  @override
  final window = SampleWindow(50, 25);

  @override
  HarPrediction? addSample(double x, double y, double z) {
    samples.add([x, y, z]);
    return window.add(x, y, z)
        ? const HarPrediction('normalWalking', 0.9)
        : null;
  }

  @override
  void reset() {
    resets++;
    window.clear();
  }
}

class _SocialRunner implements SocialModelRunner {
  int calls = 0;
  bool fail = false;
  final List<List<List<List<double>>>> windows = [];
  @override
  List<int> get inputShape => [1, 75, 3];
  @override
  List<int> get outputShape => [1, 4];
  @override
  TensorType get inputType => TensorType.float32;
  @override
  TensorType get outputType => TensorType.float32;

  @override
  List<double> run(List<List<List<double>>> batch) {
    calls++;
    if (fail) throw StateError('Social inference failed');
    windows.add([
      for (final window in batch)
        [for (final sample in window) List<double>.of(sample)],
    ]);
    return [0.1, 0.7, 0.1, 0.1];
  }

  @override
  void close() {}
}

class _SocialDouble implements SocialClassifier {
  final List<List<double>> samples = [];
  @override
  int step = 25;
  @override
  List<String> get classes => socialLabels;
  @override
  SocialPrediction? addSample(double x, double y, double z,
      {bool infer = true}) {
    samples.add([x, y, z]);
    return null;
  }

  @override
  void reset() => samples.clear();
  @override
  void dispose() {}
}

class _RepositoryDouble implements PredictionRepository {
  final List<PredictionRecord> saved = [];
  @override
  Future<int> insert(PredictionRecord record) async {
    saved.add(record);
    return saved.length;
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
