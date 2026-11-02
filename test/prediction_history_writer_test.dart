import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pdiot/har.dart';
import 'package:pdiot/home.dart';
import 'package:pdiot/main.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_history_writer.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class WriterTestRepository implements PredictionRepository {
  final saved = <PredictionRecord>[];
  final attempted = <PredictionRecord>[];
  Completer<void>? gate;
  bool failNext = false;
  bool failClose = false;
  int active = 0;
  int maxActive = 0;
  int closeCount = 0;

  @override
  Future<int> insert(PredictionRecord record) async {
    active++;
    if (active > maxActive) maxActive = active;
    attempted.add(record);
    try {
      await gate?.future;
      if (failNext) {
        failNext = false;
        throw StateError('Insert failed');
      }
      saved.add(record);
      return saved.length;
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    expect(active, 0);
    closeCount++;
    if (failClose) throw StateError('Close failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const prediction = HarPrediction('normalWalking', 0.87654321);
  final timestamp = DateTime.parse('2026-11-02T13:14:15.123456+01:00');
  late WriterTestRepository repository;
  late PredictionHistoryWriter writer;
  var opens = 0;

  setUp(() {
    repository = WriterTestRepository();
    opens = 0;
    writer = PredictionHistoryWriter(
      openRepository: () async {
        opens++;
        return repository;
      },
      clock: () => timestamp,
    );
  });

  tearDown(() async {
    await writer.shutdown();
    writer.dispose();
  });

  test('one new inference saves exactly one record with exact fields',
      () async {
    writer.capture(prediction);
    await writer.flush();
    final saved = repository.saved.single;
    expect(saved.id, isNull);
    expect(saved.label, prediction.label);
    expect(saved.confidence, prediction.confidence);
    expect(saved.timestamp, timestamp.toUtc());
    expect(saved.timestamp.isUtc, isTrue);
    expect(saved.taskType, PredictionTaskType.har);
    expect(saved.source, PredictionSource.live);
    expect(saved.windowStart, isNull);
    expect(saved.windowEnd, isNull);
    expect(opens, 1);
  });

  test('null results do not open SQLite or write anything', () async {
    writer.capture(null);
    await writer.flush();
    expect(repository.saved, isEmpty);
    expect(opens, 0);
  });

  test('later packets with no new inference do not repeat old predictions',
      () async {
    // Each inner list represents raw addSample results from a BLE packet.
    final packets = <List<HarPrediction?>>[
      [null, prediction, null],
      [null, null],
      [null],
    ];
    for (final packet in packets) {
      for (final result in packet) {
        writer.capture(result);
      }
    }
    await writer.flush();
    expect(repository.saved, hasLength(1));
  });

  test('identical labels from consecutive real inferences remain separate',
      () async {
    writer.capture(prediction);
    writer.capture(prediction);
    await writer.flush();
    expect(repository.saved, hasLength(2));
    expect(repository.saved.map((r) => r.label),
        [prediction.label, prediction.label]);
    expect(opens, 1);
    expect(repository.maxActive, 1);
  });

  test('multiple inferences from one packet are preserved in FIFO order',
      () async {
    final packet = <HarPrediction?>[
      prediction,
      null,
      const HarPrediction('running', 0.9),
      null,
      const HarPrediction('lyingLeft', 0.95),
    ];
    packet.forEach(writer.capture);
    await writer.flush();
    expect(repository.saved.map((r) => r.label),
        ['normalWalking', 'running', 'lyingLeft']);
    expect(repository.maxActive, 1);
  });

  test('insertion failure is observed and does not poison later writes',
      () async {
    var notifications = 0;
    writer.addListener(() => notifications++);
    repository.failNext = true;
    expect(() => writer.capture(prediction), returnsNormally);
    writer.capture(const HarPrediction('running', 0.9));
    await writer.flush();
    expect(repository.attempted, hasLength(2));
    expect(repository.saved.single.label, 'running');
    expect(writer.errorCount, 1);
    expect(writer.droppedRecordCount, 1);
    expect(writer.lastError, isA<StateError>());
    expect(notifications, 1);
    writer.capture(prediction);
    await writer.flush();
    expect(repository.saved, hasLength(2));
  });

  test('opening failure is contained and opening is retried for next record',
      () async {
    final recovering = PredictionHistoryWriter(openRepository: () async {
      if (opens++ == 0) throw StateError('Database unavailable');
      return repository;
    });
    recovering.capture(prediction);
    await recovering.flush();
    expect(recovering.errorCount, 1);
    expect(recovering.droppedRecordCount, 1);
    recovering.capture(prediction);
    await recovering.flush();
    expect(repository.saved, hasLength(1));
    expect(opens, 2);
    await recovering.shutdown();
    recovering.dispose();
  });

  test('capacity includes in-flight writes and overflow is observable',
      () async {
    final bounded = PredictionHistoryWriter(
      capacity: 2,
      openRepository: () async => repository,
    );
    repository.gate = Completer<void>();
    bounded.capture(prediction);
    await Future<void>.delayed(Duration.zero);
    bounded.capture(prediction);
    bounded.capture(prediction);
    expect(bounded.pendingCount, 2);
    expect(repository.attempted, hasLength(1));
    expect(bounded.droppedRecordCount, 1);
    expect(bounded.errorCount, 0);
    repository.gate!.complete();
    await bounded.flush();
    expect(repository.saved, hasLength(2));
    expect(bounded.pendingCount, 0);
    bounded.capture(prediction);
    await bounded.shutdown();
    expect(repository.saved, hasLength(3));
    bounded.dispose();
  });

  test('flush waits for pending writes without closing the connection',
      () async {
    repository.gate = Completer<void>();
    writer.capture(prediction);
    var flushed = false;
    final flushing = writer.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    expect(repository.closeCount, 0);
    repository.gate!.complete();
    await flushing;
    expect(repository.saved, hasLength(1));
    expect(repository.closeCount, 0);
  });

  test('shutdown drains, closes once and rejects new work', () async {
    repository.gate = Completer<void>();
    writer.capture(prediction);
    final closing = writer.shutdown();
    writer.capture(prediction);
    expect(writer.droppedRecordCount, 1);
    await Future<void>.delayed(Duration.zero);
    expect(repository.closeCount, 0);
    repository.gate!.complete();
    await closing;
    await writer.shutdown();
    expect(repository.saved, hasLength(1));
    expect(repository.closeCount, 1);
  });

  test('dispose safely drains even when inserts and closing fail', () async {
    repository.failNext = true;
    repository.failClose = true;
    writer.capture(prediction);
    // Dispose clears listeners while the asynchronous drain is still pending.
    final disposable = writer;
    disposable.dispose();
    await disposable.shutdown();
    expect(disposable.errorCount, 2);
    expect(disposable.droppedRecordCount, 1);
    expect(repository.closeCount, 1);
    // Avoid disposing this notifier twice in tearDown.
    writer = PredictionHistoryWriter(openRepository: () async => repository);
  });

  test('timestamp is captured before a delayed database open', () async {
    final opening = Completer<PredictionRepository>();
    var now = timestamp;
    final delayed = PredictionHistoryWriter(
      openRepository: () => opening.future,
      clock: () => now,
    );
    delayed.capture(prediction);
    now = now.add(const Duration(hours: 1));
    opening.complete(repository);
    await delayed.flush();
    expect(repository.saved.single.timestamp, timestamp.toUtc());
    await delayed.shutdown();
    delayed.dispose();
  });

  test('writer and History connection share real persisted SQLite records',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('pdiot_writer_');
    final dbPath = path.join(directory.path, 'prediction_history.db');
    Future<PredictionRepository> open() => PredictionRepository.open(
          databasePath: dbPath,
          factory: databaseFactoryFfi,
        );
    final liveWriter = PredictionHistoryWriter(openRepository: open);
    PredictionRepository? reader;
    try {
      liveWriter.capture(prediction);
      await liveWriter.flush();
      reader = await open();
      // Exercise separate read/write connections to the unchanged schema.
      liveWriter.capture(prediction);
      await reader.query(start: DateTime.utc(2020), end: DateTime.utc(2100));
      await liveWriter.flush();
      await liveWriter.shutdown();
      final rows = await reader.query(
        start: DateTime.utc(2020),
        end: DateTime.utc(2100),
        taskType: PredictionTaskType.har,
      );
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.id != null), isTrue);
      expect(rows.every((r) => r.label == prediction.label), isTrue);
      expect(liveWriter.errorCount, 0);
    } finally {
      await liveWriter.shutdown();
      liveWriter.dispose();
      await reader?.close();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('app owns writer across History navigation and disposes it',
      (tester) async {
    await tester.pumpWidget(const MyApp());
    final appWriter =
        tester.widget<MyHomePage>(find.byType(MyHomePage)).historyWriter!;
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<MyHomePage>(find.byType(MyHomePage)).historyWriter,
        same(appWriter));
    await tester.pumpWidget(const SizedBox());
    await appWriter.shutdown();
    appWriter.capture(prediction);
    expect(appWriter.droppedRecordCount, 1);
    expect(tester.takeException(), isNull);
  });
}
