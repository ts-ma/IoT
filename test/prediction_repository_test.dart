import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late String databasePath;
  late PredictionRepository repository;
  final start = DateTime.utc(2026, 11, 2);
  final end = start.add(const Duration(days: 1));

  PredictionRecord record({
    DateTime? timestamp,
    PredictionTaskType taskType = PredictionTaskType.har,
    PredictionSource source = PredictionSource.live,
    double? confidence,
    DateTime? windowStart,
    DateTime? windowEnd,
    int? intervalMs,
    String? label,
  }) =>
      PredictionRecord(
        taskType: taskType,
        label: label ??
            (taskType == PredictionTaskType.har ? 'normalWalking' : 'talking'),
        timestamp: timestamp ?? start,
        confidence: confidence,
        source: source,
        windowStart: windowStart,
        windowEnd: windowEnd,
        intervalMs: intervalMs,
      );

  Future<PredictionRepository> open() => PredictionRepository.open(
        databasePath: databasePath,
        factory: databaseFactoryFfi,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pdiot_history_test_');
    databasePath = path.join(directory.path, 'history.db');
    repository = await open();
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test('inserts generated ids and round trips every field in UTC', () async {
    final timestamp = DateTime.parse('2026-11-02T01:00:00.123456+01:00');
    final input = record(
      timestamp: timestamp,
      taskType: PredictionTaskType.social,
      source: PredictionSource.live,
      confidence: 0.875,
      intervalMs: 960,
      windowStart: timestamp.subtract(const Duration(seconds: 4)),
      windowEnd: timestamp,
    );
    final id = await repository.insert(input);
    final rows = await repository.query(start: start, end: end);
    expect(id, greaterThan(0));
    expect(input.id, isNull);
    expect(rows.single.toMap(), {...input.toMap(), 'id': id});
    expect(rows.single.timestamp.isUtc, isTrue);
    expect(rows.single.windowStart!.isUtc, isTrue);
    expect(rows.single.windowEnd!.isUtc, isTrue);
  });

  test('preserves nullable fields', () async {
    await repository.insert(record());
    final row = (await repository.query(start: start, end: end)).single;
    expect(row.confidence, isNull);
    expect(row.windowStart, isNull);
    expect(row.windowEnd, isNull);
  });

  test('queries half-open ranges, task filters and deterministic pages',
      () async {
    await repository.insert(
      record(timestamp: start.subtract(const Duration(microseconds: 1))),
    );
    final first = await repository.insert(record());
    final second = await repository.insert(record());
    final social = await repository.insert(record(
      timestamp: start.add(const Duration(seconds: 2)),
      taskType: PredictionTaskType.social,
    ));
    await repository.insert(record(timestamp: end));

    final rows = await repository.query(start: start, end: end);
    expect(rows.map((r) => r.id), [social, second, first]);
    final har = await repository.query(
      start: start,
      end: end,
      taskType: PredictionTaskType.har,
    );
    expect(har.map((r) => r.id), [second, first]);
    expect(
      (await repository.query(start: start, end: end, limit: 1, offset: 1))
          .single
          .id,
      second,
    );
    expect(
      (await repository.query(start: start, end: end, offset: 1))
          .map((r) => r.id),
      [second, first],
    );
    expect(await repository.query(start: end, end: end), isEmpty);
  });

  test('deletes by id and range without deleting other tasks or days',
      () async {
    final id = await repository.insert(record());
    expect(await repository.delete(id), 1);
    expect(await repository.delete(id), 0);
    await repository.insert(record());
    await repository.insert(record(taskType: PredictionTaskType.social));
    await repository.insert(record(timestamp: end));
    expect(
      await repository.deleteRange(
        start: start,
        end: end,
        taskType: PredictionTaskType.har,
      ),
      1,
    );
    expect(
      (await repository.query(start: start, end: end)).single.taskType,
      PredictionTaskType.social,
    );
    expect(await repository.deleteRange(start: start, end: end), 1);
    expect(
      await repository.query(start: end, end: end.add(const Duration(days: 1))),
      hasLength(1),
    );
  });

  test('persists records and deletions after closing and reopening', () async {
    final id = await repository.insert(record(confidence: 1));
    await repository.close();
    repository = await open();
    expect((await repository.query(start: start, end: end)).single.id, id);
    await repository.delete(id);
    await repository.close();
    repository = await open();
    expect(await repository.query(start: start, end: end), isEmpty);
    expect(await repository.insert(record()), greaterThan(id));
  });

  test('creates versioned schema and both timestamp indexes', () async {
    final db = await databaseFactoryFfi.openDatabase(databasePath);
    try {
      expect(await db.getVersion(), PredictionRepository.schemaVersion);
      final indexes =
          await db.rawQuery('PRAGMA index_list(prediction_history)');
      expect(
          indexes.map((r) => r['name']),
          containsAll([
            'idx_prediction_timestamp',
            'idx_prediction_task_timestamp',
          ]));
    } finally {
      await db.close();
    }
  });

  test('rejects invalid model values and query arguments', () async {
    expect(() => record(confidence: double.nan), throwsArgumentError);
    expect(() => record(confidence: 1.1), throwsArgumentError);
    expect(
      () => record(windowStart: end, windowEnd: start),
      throwsArgumentError,
    );
    expect(
      () => PredictionRecord(
        taskType: PredictionTaskType.har,
        label: ' ',
        timestamp: start,
        source: PredictionSource.live,
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.query(start: end, end: start),
      throwsArgumentError,
    );
    await expectLater(
      repository.query(start: start, end: end, limit: 0),
      throwsArgumentError,
    );
    await expectLater(
      repository.query(start: start, end: end, offset: -1),
      throwsArgumentError,
    );
    final id = await repository.insert(record());
    final saved = (await repository.query(start: start, end: end)).single;
    expect(saved.id, id);
    expect(() => repository.insert(saved), throwsArgumentError);
  });

  test('durations sum each result interval; old rows count as 2 s', () async {
    await repository.insert(record(intervalMs: 1000));
    await repository.insert(record(intervalMs: 1000));
    await repository.insert(record()); // no interval: legacy 2 s
    await repository.insert(record(label: 'running', intervalMs: 480));
    expect(
        await repository.durationByLabel(
            start: start, end: end, taskType: PredictionTaskType.har),
        {
          'normalWalking': const Duration(seconds: 4),
          'running': const Duration(milliseconds: 480),
        });
    expect(() => record(intervalMs: 0), throwsArgumentError);
    expect(await repository.count(), 4);
  });

  test('timeline bins group results per time bin, task and label', () async {
    await repository.insert(record(intervalMs: 1000));
    await repository.insert(record(
        timestamp: start.add(const Duration(seconds: 30)), intervalMs: 1000));
    await repository.insert(record(
        timestamp: start.add(const Duration(minutes: 1, seconds: 5)),
        label: 'running',
        intervalMs: 1000));
    await repository.insert(record(
        timestamp: start.add(const Duration(seconds: 10)),
        taskType: PredictionTaskType.social,
        label: 'coughing'));
    final cells = await repository.timelineBins(
        start: start,
        end: start.add(const Duration(minutes: 2)),
        bin: const Duration(minutes: 1));
    expect(
        cells.map((c) => '${c.bin}:${c.taskType.name}:${c.label}:${c.count}:'
            '${c.duration.inMilliseconds}'),
        unorderedEquals([
          '0:har:normalWalking:2:2000',
          '0:social:coughing:1:2000',
          '1:har:running:1:1000',
        ]));
    final span = await repository.timeRange(start: start, end: end);
    expect(span!.first, start);
    expect(span.last, start.add(const Duration(minutes: 1, seconds: 5)));
    expect(await repository.timeRange(start: end, end: end), isNull);
    final ascending =
        await repository.query(start: start, end: end, newestFirst: false);
    expect(ascending.first.timestamp, start);
  });

  test('upgrades a version 1 database without losing rows', () async {
    await repository.close();
    await File(databasePath).delete();
    final v1 = await databaseFactoryFfi.openDatabase(databasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE prediction_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_type TEXT NOT NULL CHECK(task_type IN ('har', 'social')),
                label TEXT NOT NULL CHECK(length(trim(label)) > 0),
                timestamp INTEGER NOT NULL,
                confidence REAL,
                source TEXT NOT NULL CHECK(source IN ('live', 'replay')),
                window_start INTEGER,
                window_end INTEGER
              )''');
          },
        ));
    await v1.insert('prediction_history', {
      'task_type': 'har',
      'label': 'running',
      'timestamp': start.microsecondsSinceEpoch,
      'source': 'live',
    });
    await v1.close();
    repository = await open();
    final rows = await repository.query(start: start, end: end);
    expect(rows.single.label, 'running');
    expect(rows.single.intervalMs, isNull);
    expect(rows.single.effectiveIntervalMs, 2000);
    await repository.insert(record(intervalMs: 960));
    expect(
        (await repository.durationByLabel(
            start: start, end: end, taskType: PredictionTaskType.har)),
        {
          'running': const Duration(seconds: 2),
          'normalWalking': const Duration(milliseconds: 960),
        });
  });
}
