import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/history.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:pdiot/services/user_session.dart';

// Implements only the read/close API used by the page.
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
    bool newestFirst = true,
  }) async {
    offsets.add(offset);
    await pending?.future;
    if (fail) throw StateError('Test database failure');
    final sorted = records
        .where((r) =>
            (taskType == null || r.taskType == taskType) &&
            !r.timestamp.isBefore(start) &&
            r.timestamp.isBefore(end))
        .toList()
      ..sort((a, b) => newestFirst
          ? b.timestamp.compareTo(a.timestamp)
          : a.timestamp.compareTo(b.timestamp));
    final page = sorted.skip(offset);
    return (limit == null ? page : page.take(limit)).toList();
  }

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TestRepository repository;
  final day = DateTime(2026, 11, 3);
  final t0 = DateTime(2026, 11, 3, 10).toUtc();

  PredictionRecord har(String label, int seconds, {double confidence = 0.9}) =>
      PredictionRecord(
        taskType: PredictionTaskType.har,
        label: label,
        timestamp: t0.add(Duration(seconds: seconds)),
        source: PredictionSource.live,
        confidence: confidence,
        intervalMs: 1000,
      );

  PredictionRecord social(String label, int seconds, {int ms = 0}) =>
      PredictionRecord(
        taskType: PredictionTaskType.social,
        label: label,
        timestamp: t0.add(Duration(seconds: seconds, milliseconds: ms)),
        source: PredictionSource.live,
        confidence: 0.8,
        intervalMs: 1000,
      );

  Future<void> showHistory(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home:
          HistoryPage(openRepository: () async => repository, initialDay: day),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() => repository = TestRepository());

  group('joinResults / groupEpisodes', () {
    test('pairs each activity result with the nearest social result', () {
      final joined = joinResults(
        [
          har('sittingStanding', 0),
          har('sittingStanding', 1),
          har('running', 9)
        ],
        [social('coughing', 0, ms: 30), social('other', 1, ms: 100)],
      );
      expect(joined.map((j) => j.social?.label),
          ['coughing', 'other', null]); // 9 s has no social result near it
    });

    test('episodes break on either label, or a gap', () {
      final joined = joinResults(
        [
          for (var i = 0; i < 4; i++) har('sittingStanding', i),
          har('sittingStanding', 4),
          har('normalWalking', 5),
          har('normalWalking', 30), // after a disconnect
        ],
        [
          for (var i = 0; i < 3; i++) social('breathingNormally', i),
          social('coughing', 3),
          social('coughing', 4),
        ],
      );
      final episodes = groupEpisodes(joined);
      // Newest first.
      expect(episodes.map((e) => '${e.harLabel}/${e.socialLabel}/${e.count}'), [
        'normalWalking/null/1',
        'normalWalking/null/1',
        'sittingStanding/coughing/2',
        'sittingStanding/breathingNormally/3',
      ]);
      expect(episodes.last.duration, const Duration(seconds: 3));
      expect(episodes.last.socialConfidence, closeTo(0.8, 1e-9));
    });
  });

  testWidgets('empty day explains what will appear', (tester) async {
    await showHistory(tester);
    expect(find.text('History'), findsOneWidget);
    expect(find.textContaining('No results saved for'), findsOneWidget);
    expect(find.byTooltip('Refresh history'), findsOneWidget);
  });

  testWidgets('episodes show the activity and the social signal together',
      (tester) async {
    repository.records.addAll([
      for (var i = 0; i < 3; i++) har('sittingStanding', i, confidence: 0.8),
      for (var i = 0; i < 3; i++) social('coughing', i),
    ]);
    await showHistory(tester);
    expect(find.text('Sitting / Standing'), findsOneWidget);
    expect(find.text('Coughing'), findsOneWidget);
    expect(find.text('3 s · 3 results'), findsOneWidget);
    expect(find.text('80%'), findsWidgets);
  });

  testWidgets('every-result view pairs rows and paginates', (tester) async {
    repository.records.addAll([
      for (var i = 0; i < 51; i++) har('normalWalking', i),
      social('other', 50),
    ]);
    await showHistory(tester);
    await tester.tap(find.text('Every result'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1'), findsOneWidget);
    // Newest row (50 s) has its social result; older rows have none.
    expect(find.text('Other Social Signals'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('Walking'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh history'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2'), findsOneWidget);
    await tester.tap(find.text('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1'), findsOneWidget);
  });

  testWidgets('shows loading until the query completes', (tester) async {
    repository.pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home:
          HistoryPage(openRepository: () async => repository, initialDay: day),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading history…'), findsOneWidget);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('query errors show retry and recover', (tester) async {
    repository.fail = true;
    await showHistory(tester);
    expect(
        find.text('Could not load history. Please try again.'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No results saved for'), findsOneWidget);
  });

  testWidgets('closes repository on disposal and ignores pending results',
      (tester) async {
    repository.pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home:
          HistoryPage(openRepository: () async => repository, initialDay: day),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(repository.closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asks to log in when nobody is logged in', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HistoryPage(session: UserSession(rememberLastUser: false)),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Log in or create a user to see your history'),
        findsOneWidget);
  });
}
