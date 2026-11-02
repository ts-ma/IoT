import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:pdiot/history.dart';
import 'package:pdiot/main.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_repository.dart';

// Implements only the read/close API used by the page. Production always opens
// the Stage 1 SQLite repository; no sample records are shipped in the app.
class TestRepository implements PredictionRepository {
  final List<PredictionRecord> records = [];
  final List<int> offsets = [];
  bool fail = false;
  bool closed = false;
  Completer<void>? pending;

  @override
  Future<List<PredictionRecord>> query({
    required DateTime start,
    required DateTime end,
    PredictionTaskType? taskType,
    int? limit,
    int offset = 0,
  }) async {
    expect(limit, 51);
    offsets.add(offset);
    await pending?.future;
    if (fail) throw StateError('Test database failure');
    final sorted = records
        .where((r) =>
            r.taskType == taskType &&
            !r.timestamp.isBefore(start) &&
            r.timestamp.isBefore(end))
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.skip(offset).take(limit!).toList();
  }

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TestRepository repository;

  PredictionRecord record(
    String label, {
    PredictionTaskType task = PredictionTaskType.har,
    DateTime? timestamp,
    double? confidence,
    PredictionSource source = PredictionSource.live,
  }) =>
      PredictionRecord(
        taskType: task,
        label: label,
        timestamp: timestamp ?? DateTime.utc(2026, 6, 12, 13, 14, 15),
        source: source,
        confidence: confidence,
      );

  Future<void> showHistory(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HistoryPage(openRepository: () async => repository),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() => repository = TestRepository());

  testWidgets('empty history explains what will appear', (tester) async {
    await showHistory(tester);
    expect(find.text('Activity History'), findsOneWidget);
    expect(find.text('No HAR predictions saved.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byTooltip('Refresh history'), findsOneWidget);
  });

  testWidgets('shows label, local timestamp, confidence and source',
      (tester) async {
    final saved = record('normalWalking', confidence: 0.876);
    repository.records.addAll([
      saved,
      record('running', source: PredictionSource.replay),
    ]);
    await showHistory(tester);
    final local = saved.timestamp.toLocal();
    expect(find.text('normalWalking'), findsOneWidget);
    expect(find.text('88%'), findsOneWidget);
    expect(
      find.text('${DateFormat('yyyy-MM-dd HH:mm:ss').format(local)} '
          '${local.timeZoneName}\nHAR • Live'),
      findsOneWidget,
    );
    expect(find.textContaining('HAR • Replay'), findsOneWidget);
    expect(find.textContaining('%'), findsOneWidget);
  });

  testWidgets('switches between HAR and Social Signals', (tester) async {
    repository.records.addAll([
      record('walking'),
      record('talking', task: PredictionTaskType.social),
    ]);
    await showHistory(tester);
    expect(find.text('walking'), findsOneWidget);
    expect(find.text('talking'), findsNothing);
    await tester.tap(find.text('Social Signals'));
    await tester.pumpAndSettle();
    expect(find.text('talking'), findsOneWidget);
    expect(find.text('walking'), findsNothing);
    expect(find.textContaining('Social Signals • Live'), findsOneWidget);
    await tester.tap(find.text('HAR'));
    await tester.pumpAndSettle();
    expect(find.text('walking'), findsOneWidget);
  });

  testWidgets('preserves newest-first repository ordering', (tester) async {
    repository.records.addAll([
      record('older', timestamp: DateTime.utc(2026, 1, 1)),
      record('newer', timestamp: DateTime.utc(2026, 1, 2)),
    ]);
    await showHistory(tester);
    expect(tester.getTopLeft(find.text('newer')).dy,
        lessThan(tester.getTopLeft(find.text('older')).dy));
  });

  testWidgets('shows loading until the query completes', (tester) async {
    repository.pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: HistoryPage(openRepository: () async => repository),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading history…'), findsOneWidget);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('No HAR predictions saved.'), findsOneWidget);
  });

  testWidgets('query errors show retry and recover', (tester) async {
    repository.fail = true;
    await showHistory(tester);
    expect(
        find.text('Could not load history. Please try again.'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No HAR predictions saved.'), findsOneWidget);
  });

  testWidgets('opening errors can be retried', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      home: HistoryPage(openRepository: () async {
        if (attempts++ == 0) throw StateError('Cannot open');
        return repository;
      }),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('No HAR predictions saved.'), findsOneWidget);
  });

  testWidgets('paginates without accumulating records; refresh resets page',
      (tester) async {
    repository.records.addAll(List.generate(
      51,
      (i) => record('record $i', timestamp: DateTime.utc(2026, 1, 1, 0, i)),
    ));
    await showHistory(tester);
    expect(find.text('record 50'), findsOneWidget);
    expect(find.text('Page 1'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('record 0'), findsOneWidget);
    expect(find.text('record 50'), findsNothing);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Next'))
            .onPressed,
        isNull);
    await tester.tap(find.text('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh history'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1'), findsOneWidget);
    expect(repository.offsets, [0, 50, 0, 50, 0]);
  });

  testWidgets('refresh reads newly saved records', (tester) async {
    await showHistory(tester);
    repository.records.add(record('new prediction'));
    await tester.tap(find.byTooltip('Refresh history'));
    await tester.pumpAndSettle();
    expect(find.text('new prediction'), findsOneWidget);
  });

  testWidgets('closes repository on disposal and ignores pending query results',
      (tester) async {
    repository.pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: HistoryPage(openRepository: () async => repository),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(repository.closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closes a repository that finishes opening after disposal',
      (tester) async {
    final opening = Completer<PredictionRepository>();
    await tester.pumpWidget(MaterialApp(
      home: HistoryPage(openRepository: () => opening.future),
    ));
    await tester.pumpWidget(const SizedBox());
    opening.complete(repository);
    await tester.pumpAndSettle();
    expect(repository.closed, isTrue);
    expect(repository.offsets, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home opens History, returns normally and reopens',
      (tester) async {
    // No platform channel database is registered in this widget test. The
    // production route still opens normally and handles that opening error.
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Activity History'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('PDIoT'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Not recording'), findsOneWidget);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Activity History'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
