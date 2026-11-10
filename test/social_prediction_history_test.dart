import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pdiot/ble.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/history.dart';
import 'package:pdiot/app_shell.dart';
import 'package:pdiot/services/app_settings.dart';
import 'package:pdiot/main.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_history_writer.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:pdiot/services/social_sample_processor.dart';
import 'package:pdiot/social.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// Real Social windowing with a fake interpreter. File-backed SQLite tests below
// exercise actual persistence; other repository tests use a controlled double.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Runner runner;
  late SocialClassifier classifier;
  late _Repository repository;
  late PredictionHistoryWriter writer;
  late SocialSampleProcessor processor;
  late List<SocialPredictionEvent> events;
  var opens = 0;
  var writerOwnedByApp = false;
  final completion = DateTime.parse('2026-11-02T14:15:16.123456+01:00');
  final writerTime = DateTime.utc(2026, 11, 3); // Deliberately different.

  setUp(() async {
    appSettings.stepSamples.value = 25; // trained step; Settings default is 6
    runner = _Runner();
    classifier = await SocialClassifier.load(createRunner: () async => runner);
    repository = _Repository();
    opens = 0;
    writerOwnedByApp = false;
    writer = PredictionHistoryWriter(
      openRepository: () async {
        opens++;
        return repository;
      },
      clock: () => writerTime,
    );
    events = [];
    processor = SocialSampleProcessor(
      classifier: () => classifier,
      clock: () => completion.add(Duration(microseconds: runner.calls)),
      onPrediction: (event) {
        events.add(event);
        writer.captureSocial(event);
      },
    )..startSession();
  });

  tearDown(() async {
    processor.dispose();
    classifier.dispose();
    if (!writerOwnedByApp) {
      await writer.shutdown();
      writer.dispose();
    }
  });

  void feed(int count) {
    for (var i = 0; i < count; i++) {
      processor.addSample(0.1, -0.2, 0.9);
    }
  }

  test('one new Social inference preserves exact model fields and event time',
      () async {
    feed(100);
    await writer.flush();
    final saved = repository.saved.single;
    final event = events.single;
    expect(saved.taskType, PredictionTaskType.social);
    expect(saved.source, PredictionSource.live);
    expect(saved.label, 'hyperventilation'); // Never the display name.
    expect(saved.confidence, 0.87654321);
    expect(saved.timestamp, event.completedAt);
    expect(saved.timestamp,
        completion.toUtc().add(const Duration(microseconds: 1)));
    expect(saved.timestamp.isUtc, isTrue);
    expect(saved.timestamp, isNot(writerTime));
    expect(saved.windowStart, isNull);
    expect(saved.windowEnd, isNull);
    expect(saved.id, isNull);
  });

  test('null and warm-up results never open the database or repeat old results',
      () async {
    writer.captureSocial(null);
    feed(99);
    await writer.flush();
    expect(opens, 0);
    expect(repository.saved, isEmpty);
    feed(1);
    await writer.flush();
    feed(24);
    await writer.flush();
    expect(repository.saved, hasLength(1));
    expect(opens, 1);
  });

  test('all identical-label windows from a single batch stay distinct and FIFO',
      () async {
    feed(175); // Social windows complete at 100, 125, 150, 175.
    expect(events, hasLength(4));
    expect(writer.pendingCount, 4);
    await writer.flush();
    expect(repository.saved, hasLength(4));
    expect(
        repository.saved.map((r) => r.label), everyElement('hyperventilation'));
    expect(repository.saved.map((r) => r.timestamp),
        events.map((e) => e.completedAt));
  });

  test('direct startup/example inference is not a live persistence event',
      () async {
    for (var i = 0; i < 100; i++) {
      classifier.addSample(0, 0, 1);
    }
    classifier.reset();
    await writer.flush();
    expect(events, isEmpty);
    expect(repository.saved, isEmpty);
    expect(opens, 0);
  });

  test('Social and HAR share the bounded queue and observable overflow',
      () async {
    await writer.shutdown();
    writer.dispose();
    writer = PredictionHistoryWriter(
      capacity: 2,
      openRepository: () async => repository,
      clock: () => writerTime,
    );
    writer.capture(const HarPrediction('normalWalking', 0.9));
    feed(125); // First Social accepted, second dropped: one shared capacity.
    expect(writer.pendingCount, 2);
    expect(writer.droppedRecordCount, 1);
    await writer.flush();
    expect(repository.saved.map((r) => r.taskType),
        [PredictionTaskType.har, PredictionTaskType.social]);
  });

  test('delayed database work does not block decoded samples or event times',
      () async {
    final gate = Completer<void>();
    repository.gate = gate;
    feed(100);
    await Future<void>.delayed(Duration.zero); // Insert is now in flight.
    expect(writer.pendingCount, 1);
    feed(75);
    expect(runner.calls, 4);
    expect(events, hasLength(4));
    expect(repository.saved, isEmpty);
    gate.complete();
    await writer.flush();
    expect(repository.saved.map((r) => r.timestamp),
        events.map((e) => e.completedAt));
  });

  test('Social insert failure does not abort BLE/HAR or later queued writes',
      () async {
    repository.failNextSocial = true;
    final oldHar = harClassifier;
    final har = _Har();
    harClassifier = har;
    addTearDown(() => harClassifier = oldHar);
    expect(() {
      for (var i = 0; i < 125; i++) {
        processDecodedSample(0.1, -0.2, 0.9,
            onPrediction: writer.capture, socialProcessor: processor);
      }
    }, returnsNormally);
    await writer.flush();
    expect(har.calls, 125);
    expect(events, hasLength(2));
    expect(processor.failed, isFalse);
    expect(writer.errorCount, 1);
    expect(writer.droppedRecordCount, 1);
    expect(repository.saved.where((r) => r.taskType == PredictionTaskType.har),
        hasLength(4));
    expect(
        repository.saved.where((r) => r.taskType == PredictionTaskType.social),
        hasLength(1));
  });

  test('shutdown drains both tasks, closes once and rejects late Social work',
      () async {
    writer.capture(const HarPrediction('normalWalking', 0.9));
    feed(100);
    await writer.shutdown();
    expect(repository.saved, hasLength(2));
    expect(repository.closes, 1);
    feed(25);
    expect(writer.droppedRecordCount, 1);
    await writer.shutdown();
    expect(repository.closes, 1);
  });

  test('Social records survive closing and reopening a file-backed database',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('pdiot_social_');
    final databasePath = path.join(directory.path, 'prediction_history.db');
    Future<PredictionRepository> open() => PredictionRepository.open(
          databasePath: databasePath,
          factory: databaseFactoryFfi,
        );
    final diskWriter = PredictionHistoryWriter(openRepository: open);
    PredictionRepository? reopened;
    try {
      feed(125);
      for (final event in events) {
        diskWriter.captureSocial(event);
      }
      diskWriter.capture(const HarPrediction('normalWalking', 0.9));
      await diskWriter
          .shutdown(); // Flush and close the writer's DB connection.
      reopened =
          await open(); // New connection, same real file, no in-memory DB.
      final social = await reopened.query(
        start: DateTime.utc(2020),
        end: DateTime.utc(2100),
        taskType: PredictionTaskType.social,
      );
      expect(social, hasLength(2));
      expect(social.map((r) => r.timestamp),
          events.reversed.map((e) => e.completedAt));
      expect(social.map((r) => r.confidence), everyElement(0.87654321));
      expect(social.map((r) => r.label), everyElement('hyperventilation'));
      expect(social.every((r) => r.source == PredictionSource.live), isTrue);
      expect(social.every((r) => r.id != null), isTrue);
      expect(social.every((r) => r.windowStart == null && r.windowEnd == null),
          isTrue);
      final har = await reopened.query(
        start: DateTime.utc(2020),
        end: DateTime.utc(2100),
        taskType: PredictionTaskType.har,
      );
      expect(har.single.label, 'normalWalking');
    } finally {
      await diskWriter.shutdown();
      diskWriter.dispose();
      await reopened?.close();
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
      'app captures once before observers; rebuilds and tab switches do not save',
      (tester) async {
    writerOwnedByApp = true;
    processor.dispose(); // The app below owns its own live processor.
    final session = SocialClassifierSession(loader: () async => classifier);
    await session.load();
    final observed = <SocialPredictionEvent>[];
    Widget app() => MyApp(
          socialSession: session,
          createHistoryWriter: () => writer,
          startPerfSampler: false,
          onSocialPrediction: (event) {
            observed.add(event);
            throw StateError('diagnostic observer failed');
          },
        );
    await tester.pumpWidget(app());
    final shell = tester.widget<AppShell>(find.byType(AppShell));
    final source = shell.socialProcessor!..startSession();
    expect(writer.pendingCount, 0);
    // Only decoded samples emit new inference events. Same app owner as BLE.
    for (var i = 0; i < 125; i++) {
      source.addSample(0.1, -0.2, 0.9);
    }
    await tester.pump();
    await writer.flush();
    expect(repository.saved, hasLength(2));
    expect(observed, hasLength(2));
    expect(source.deliveryErrorCount, 2);
    expect(find.text('Hyperventilating'), findsWidgets);
    await tester.pumpWidget(app());
    for (final t in ['tools', 'history', 'chart', 'home']) {
      await tester.tap(find.byKey(ValueKey('tab-$t')));
      await tester.pump();
    }
    source.resetStream();
    source.endSession();
    await tester.pump();
    await writer.flush();
    expect(repository.saved, hasLength(2));
    expect(repository.saved.map((r) => r.timestamp),
        observed.map((e) => e.completedAt));
    await tester.pumpWidget(const SizedBox.shrink());
    await writer.shutdown();
    expect(repository.closes, 1);
  });

  testWidgets('History joins real saved activity and social records',
      (tester) async {
    sqfliteFfiInit();
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('pdiot_social_ui_')))!;
    final databasePath = path.join(directory.path, 'prediction_history.db');
    Future<PredictionRepository> open() => PredictionRepository.open(
          databasePath: databasePath,
          factory: databaseFactoryFfi,
        );
    final now = DateTime.now().toUtc();
    final diskWriter =
        PredictionHistoryWriter(openRepository: open, clock: () => now);
    try {
      feed(100);
      await tester.runAsync(() async {
        diskWriter.captureSocial(SocialPredictionEvent(
            prediction: events.single.prediction,
            completedAt: now,
            processingDuration: Duration.zero));
        diskWriter.capture(const HarPrediction('normalWalking', 0.9));
        await diskWriter.flush();
      });
      await tester
          .pumpWidget(MaterialApp(home: HistoryPage(openRepository: open)));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      // One row: the activity and the social signal of the same moment.
      expect(find.text('Walking'), findsOneWidget);
      expect(find.text('Hyperventilating'), findsOneWidget);
      await tester.tap(find.text('Every result'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.text('Walking'), findsOneWidget);
      expect(find.text('Hyperventilating'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await diskWriter.shutdown();
        await directory.delete(recursive: true);
      });
      diskWriter.dispose();
    }
  });
}

class _Runner implements SocialModelRunner {
  int calls = 0;
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
    return [0.04, 0.05, 0.87654321, 0.03345679];
  }

  @override
  void close() {}
}

class _Repository implements PredictionRepository {
  final List<PredictionRecord> saved = [];
  Completer<void>? gate;
  bool failNextSocial = false;
  int closes = 0;
  @override
  Future<int> insert(PredictionRecord record) async {
    await gate?.future;
    if (record.taskType == PredictionTaskType.social && failNextSocial) {
      failNextSocial = false;
      throw StateError('Social insert failed');
    }
    saved.add(record);
    return saved.length;
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Har implements HarClassifier {
  int calls = 0;
  @override
  List<String> get classes => ['normalWalking'];
  @override
  final window = SampleWindow(50, 25);
  @override
  HarPrediction? addSample(double x, double y, double z) {
    calls++;
    return window.add(x, y, z)
        ? const HarPrediction('normalWalking', 0.9)
        : null;
  }

  @override
  void reset() => window.clear();
}
