import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pdiot/activity_catalog.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/app_metrics.dart';
import 'package:pdiot/services/evaluation.dart';
import 'package:pdiot/services/live_feed.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:pdiot/chart_page.dart';
import 'package:pdiot/realtime_test_page.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/user_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('activity catalog', () {
    test('every model class has a readable name and the right group', () {
      for (final l in harClassOrder) {
        expect(isKnownLabel(l), isTrue, reason: l);
        expect(labelInfo(l).group, isNot(LabelGroup.social));
      }
      for (final l in socialClassOrder) {
        expect(labelInfo(l).group, LabelGroup.social);
      }
      expect(
          harClassOrder
              .where((l) => labelInfo(l).group == LabelGroup.staticActivity),
          hasLength(5));
      expect(
          harClassOrder
              .where((l) => labelInfo(l).group == LabelGroup.dynamicActivity),
          hasLength(6));
      expect(displayName('normalWalking'), 'Walking');
      expect(displayName('hyperventilation'), 'Hyperventilating');
    });

    test('unknown labels fall back to the raw label', () {
      expect(displayName('newClass'), 'newClass');
      expect(isKnownLabel('newClass'), isFalse);
    });

    test('formats durations', () {
      expect(formatDuration(const Duration(seconds: 8)), '8 s');
      expect(formatDuration(const Duration(minutes: 12, seconds: 5)),
          '12 min 05 s');
      expect(formatDuration(const Duration(hours: 1, minutes: 5)),
          '1 h 05 min');
    });
  });

  group('countLabelEpisodes', () {
    final t0 = DateTime.utc(2026, 11, 3, 12);
    // One result every 0.5 s (step 6), each standing for 0.5 s.
    ({String label, DateTime at, Duration interval}) r(String label, double s) =>
        (
          label: label,
          at: t0.add(Duration(milliseconds: (s * 1000).round())),
          interval: const Duration(milliseconds: 500),
        );
    List<({String label, DateTime at, Duration interval})> run(
            String label, double from, double to) =>
        [for (var s = from; s < to - 1e-9; s += 0.5) r(label, s)];

    test('4 s of coughing within 5 s is one episode, however many coughs', () {
      // A 10 s coughing fit with misread windows in between: one episode.
      final fit = [
        ...run('coughing', 0, 2),
        r('other', 2),
        ...run('coughing', 2.5, 6),
        r('breathingNormally', 6),
        ...run('coughing', 6.5, 10),
      ];
      expect(countLabelEpisodes(fit, 'coughing'), 1);
      expect(countLabelEpisodes(fit, 'other'), 0);
      expect(countLabelEpisodes([], 'coughing'), 0);
    });

    test('short or sparse coughing is not an episode', () {
      // 3.5 s of coughing: below 4 s.
      expect(countLabelEpisodes(run('coughing', 0, 3.5), 'coughing'), 0);
      // 8 single results 1 s apart = 4 s in total but spread over 8 s:
      // never 4 s within any 5 s.
      expect(
          countLabelEpisodes(
              [for (var s = 0; s < 8; s++) r('coughing', s.toDouble())],
              'coughing'),
          0);
      // Exactly 4 s within 5 s counts.
      expect(countLabelEpisodes(run('coughing', 0, 4), 'coughing'), 1);
    });

    test('a new episode needs 5 s without coughing in between', () {
      final twoFits = [
        ...run('coughing', 0, 4),
        ...run('breathingNormally', 4, 9),
        ...run('coughing', 9, 13), // 5.5 s after the last cough: new episode
      ];
      expect(countLabelEpisodes(twoFits, 'coughing'), 2);
      final oneFit = [
        ...run('coughing', 0, 4),
        ...run('breathingNormally', 4, 7),
        ...run('coughing', 7, 11), // only 3.5 s gap: same episode
      ];
      expect(countLabelEpisodes(oneFit, 'coughing'), 1);
    });
  });

  group('AppMetrics', () {
    test('counts lost packets from sequence numbers, including wrap-around',
        () {
      final m = AppMetrics();
      final t = DateTime.utc(2026, 11, 3);
      m.recordPacket(65534, 25, t);
      m.recordPacket(65535, 25, t.add(const Duration(seconds: 2)));
      // 65535 wraps to 0, so arriving at 1 means packet 0 was lost.
      m.recordPacket(1, 25, t.add(const Duration(seconds: 4)));
      expect(m.lostPackets, 1);
      expect(m.packets, 3);
      expect(m.samples, 75);
      expect(m.sampleRateHz, closeTo(75 / 4, 1e-9));
      m.recordPacket(40000, 25, t.add(const Duration(seconds: 6)));
      expect(m.lostPackets, 1, reason: 'counter restarts are not loss');
      m.endStream();
      m.recordPacket(10, 25, t.add(const Duration(seconds: 60)));
      expect(m.lostPackets, 1);
      m.reset();
      expect(m.packets, 0);
    });

    test('sample rate is per stream; gaps are found before decoding', () {
      final m = AppMetrics();
      final t = DateTime.utc(2026, 11, 3);
      // 10 min of streaming (7,500 samples), then a disconnect.
      m.recordPacket(0, 7500, t);
      m.recordPacket(1, 0, t.add(const Duration(minutes: 10)));
      m.endStream();
      // Reconnected: 1 min of 12.5 Hz must not read as (7,500 + 750) / 60.
      m.recordPacket(5, 0, t.add(const Duration(minutes: 20)));
      m.recordPacket(6, 750, t.add(const Duration(minutes: 21)));
      expect(m.sampleRateHz, closeTo(12.5, 1e-9));
      expect(m.samples, 8250, reason: 'the total still counts every stream');
      // packetGap only looks: 7 is next, 9 means two packets are missing.
      expect(m.packetGap(7), 0);
      expect(m.packetGap(9), 2);
      expect(m.packetGap(40000), 0, reason: 'counter restart, not loss');
      expect(m.lostPackets, 0);
      m.recordPacket(9, 32, t.add(const Duration(minutes: 22)));
      expect(m.lostPackets, 2);
    });

    test('tracks inference time of both models', () {
      final m = AppMetrics();
      m.recordHarInference(const Duration(milliseconds: 2));
      m.recordHarInference(const Duration(milliseconds: 4));
      m.recordSocialInference(const Duration(milliseconds: 5));
      expect(m.harInference.count, 2);
      expect(m.harInference.mean, const Duration(milliseconds: 3));
      expect(m.harInference.max, const Duration(milliseconds: 4));
      expect(m.socialInference.count, 1);
      expect(m.socialInference.last, const Duration(milliseconds: 5));
    });
  });

  group('real-time evaluation scoring', () {
    EvaluationTrial trial(String truth, List<String> har,
            {String? social, List<String> socialPreds = const []}) =>
        EvaluationTrial(
          participant: 'p1',
          trueActivity: truth,
          trueSocial: social,
          startedAt: DateTime.utc(2026, 11, 3),
          durationSeconds: 30,
          settleSeconds: 4,
          harPredictions: har,
          socialPredictions: socialPreds,
          harLatency: const Duration(seconds: 3),
        );

    test('per-class accuracy, group means and majority votes', () {
      final trials = [
        trial('sittingStanding', ['sittingStanding', 'sittingStanding']),
        trial('lyingBack', ['lyingBack', 'lyingLeft', 'lyingBack', 'x']),
        trial('running', ['running', 'normalWalking'],
            social: 'coughing', socialPreds: ['coughing', 'other', 'other']),
      ];
      final s = EvaluationSummary.from(trials);
      expect(s.scores.map((c) => c.label),
          ['sittingStanding', 'lyingBack', 'running', 'coughing']);
      expect(s.scores[1].accuracy, 0.5);
      expect(s.scores[1].majorityCorrect, 1);
      expect(s.groupMean(LabelGroup.staticActivity), closeTo(0.75, 1e-9));
      expect(s.groupMean(LabelGroup.dynamicActivity), 0.5);
      expect(s.groupMean(LabelGroup.social), closeTo(1 / 3, 1e-9));
      expect(s.scores[3].majorityCorrect, 0);
      expect(s.totalWindows, 11);
      expect(s.totalCorrect, 6);
      expect(majorityLabel([]), isNull);
      expect(majorityLabel(['a', 'b']), 'a');
    });

    test('trials round-trip through JSON and export as CSV', () async {
      final original = trial('running', ['running'],
          social: 'coughing', socialPreds: ['coughing']);
      final copy = EvaluationTrial.fromJson(
          Map<String, dynamic>.from(original.toJson()));
      expect(copy.trueActivity, 'running');
      expect(copy.trueSocial, 'coughing');
      expect(copy.harLatency, const Duration(seconds: 3));
      expect(copy.startedAt, original.startedAt);

      final csv = trialsToCsv([original, trial('lyingLeft', [])]);
      final lines = csv.trim().split('\n');
      expect(lines, hasLength(3));
      expect(lines[1], startsWith('p1,2026-11-03T00:00:00.000Z,30,4,running,1,1,100.0,'));
      final summary = summaryToCsv(EvaluationSummary.from([original]));
      expect(summary, contains('Dynamic activities,running,1,1,1,100.0,1,3.0'));
      expect(summary, contains('All,MEAN,,2,2,100.0,,'));

      final dir = await Directory.systemTemp.createTemp('pdiot_eval_');
      addTearDown(() => dir.delete(recursive: true));
      final store = EvaluationStore(
          file: () async => File(path.join(dir.path, 'trials.json')));
      expect(await store.load(), isEmpty);
      await store.save([original]);
      expect((await store.load()).single.trueSocial, 'coughing');
    });
  });

  group('repository aggregates', () {
    sqfliteFfiInit();
    late Directory dir;
    late PredictionRepository repo;
    final day = DateTime.utc(2026, 11, 3);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pdiot_agg_');
      repo = await PredictionRepository.open(
        databasePath: path.join(dir.path, 'h.db'),
        factory: databaseFactoryFfi,
      );
    });

    tearDown(() async {
      await repo.close();
      await dir.delete(recursive: true);
    });

    Future<void> add(PredictionTaskType task, String label, int seconds) =>
        repo.insert(PredictionRecord(
          taskType: task,
          label: label,
          timestamp: day.add(Duration(seconds: seconds)),
          source: PredictionSource.live,
          confidence: 0.9,
        ));

    test('counts per label and coughing episodes within one day only', () async {
      await add(PredictionTaskType.har, 'normalWalking', 0);
      await add(PredictionTaskType.har, 'normalWalking', 2);
      await add(PredictionTaskType.har, 'running', 4);
      await add(PredictionTaskType.har, 'running', 86400); // next day
      await add(PredictionTaskType.social, 'coughing', 0);
      await add(PredictionTaskType.social, 'coughing', 2);
      await add(PredictionTaskType.social, 'other', 4);
      await add(PredictionTaskType.social, 'coughing', 6);
      final end = day.add(const Duration(days: 1));
      expect(
          await repo.countByLabel(
              start: day, end: end, taskType: PredictionTaskType.har),
          {'normalWalking': 2, 'running': 1});
      expect(
          await repo.countByLabel(
              start: day, end: end, taskType: PredictionTaskType.social),
          {'coughing': 3, 'other': 1});
      expect(
          await repo.countEpisodes(
              start: day,
              end: end,
              taskType: PredictionTaskType.social,
              label: 'coughing'),
          1); // 0, 2, (other), 6 (2 s each): one episode
    });
  });

  group('pages', () {
    testWidgets('daily summary shows time per activity and coughing episodes',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _SummaryRepository(
        {
          'normalWalking': const Duration(minutes: 1),
          'sittingStanding': const Duration(minutes: 30),
        },
        {
          'coughing': const Duration(seconds: 24),
          'breathingNormally': const Duration(minutes: 3),
        },
        4,
      );
      await tester.pumpWidget(MaterialApp(
          home: ChartPage(openRepository: () async => repo)));
      await tester.pumpAndSettle();
      expect(find.text('Chart'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Day timeline'), findsOneWidget);
      expect(find.text('Walking'), findsWidgets);
      expect(find.text('1 min 00 s'), findsWidgets);
      expect(find.text('30 min 00 s'), findsWidgets);
      expect(find.text('4 coughing episodes'), findsOneWidget);
      expect(find.text('Last 7 days'), findsOneWidget);

      // The 7-day card shows one view at a time, chosen in its drop-down.
      expect(find.text('c = coughing episodes'), findsOneWidget);
      expect(find.byKey(const ValueKey('week-timelines')), findsNothing);
      expect(find.byKey(const ValueKey('day-timeline')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('week-view')));
      await tester.tap(find.byKey(const ValueKey('week-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Day timelines').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('week-timelines')), findsOneWidget);
      expect(find.text('c = coughing episodes'), findsNothing);
      // The day's own timeline + one per day of the week.
      expect(find.byKey(const ValueKey('day-timeline')), findsNWidgets(8));
      await tester.tap(find.byKey(const ValueKey('week-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Static / dynamic').last);
      await tester.pumpAndSettle();
      expect(find.text('c = coughing episodes'), findsOneWidget);
      expect(find.byKey(const ValueKey('week-timelines')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(repo.closed, isTrue);
    });

    testWidgets('daily summary explains an empty day', (tester) async {
      final repo = _SummaryRepository({}, {}, 0);
      await tester.pumpWidget(MaterialApp(
          home: ChartPage(openRepository: () async => repo)));
      await tester.pumpAndSettle();
      expect(find.textContaining('No results saved for Today'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('real-time trial scores live predictions after warm-up',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final feed = LivePredictionFeed();
      final store = _MemoryStore();
      final sensor =
          SensorController(session: UserSession(rememberLastUser: false));
      addTearDown(sensor.dispose);
      await tester.pumpWidget(MaterialApp(
        home: RealtimeTestPage(
            sensor: sensor, store: store, feed: feed, requireSensor: false),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start trial'));
      await tester.pump();
      expect(find.text('Trial running'), findsOneWidget);

      final now = DateTime.now();
      // Inside the 4 s warm-up: counts for latency but is not scored.
      feed.addHar(const HarPrediction('sittingStanding', 0.9),
          at: now.add(const Duration(seconds: 1)));
      feed.addHar(const HarPrediction('sittingStanding', 0.9),
          at: now.add(const Duration(seconds: 5)));
      feed.addHar(const HarPrediction('lyingBack', 0.6),
          at: now.add(const Duration(seconds: 7)));
      await tester.pump();
      // A packet update right after the start: inside the warm-up, so it
      // gives the shown latency but is not scored.
      sensor.updateFromPacket(
          accel: null,
          battery: null,
          charging: false,
          receivedAt: now,
          prediction: const HarPrediction('sittingStanding', 0.8));
      await tester.pump();

      await tester.tap(find.text('Finish now'));
      await tester.pump();
      final saved = store.saved.single;
      expect(saved.trueActivity, 'sittingStanding');
      expect(saved.harPredictions, ['sittingStanding', 'lyingBack']);
      expect(saved.harConfidences, [0.9, 0.6]);
      expect(saved.harCorrect, 1);
      expect(saved.harLatency, isNotNull);
      expect(saved.harShownLatency, isNotNull);
      expect(saved.harShown, isEmpty);
      expect(saved.stepSamples, isNotNull);
      expect(find.text('Start trial'), findsOneWidget);
      expect(find.text('50.0%'), findsWidgets); // raw accuracy 1/2
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

class _SummaryRepository implements PredictionRepository {
  _SummaryRepository(this.har, this.social, this.coughs);

  final Map<String, Duration> har;
  final Map<String, Duration> social;
  final int coughs;
  bool closed = false;

  static bool _isToday(DateTime start) {
    final today = DateTime.now();
    return start.year == today.year &&
        start.month == today.month &&
        start.day == today.day;
  }

  /// Only today has data, so the 7-day chart has one bar.
  @override
  Future<Map<String, Duration>> durationByLabel({
    required DateTime start,
    required DateTime end,
    required PredictionTaskType taskType,
    PredictionSource? source,
  }) async {
    if (!_isToday(start)) return {};
    return taskType == PredictionTaskType.har ? har : social;
  }

  @override
  Future<({DateTime first, DateTime last})?> timeRange({
    required DateTime start,
    required DateTime end,
  }) async {
    if (har.isEmpty) return null;
    return (
      first: start.add(const Duration(hours: 9)),
      last: start.add(const Duration(hours: 10)),
    );
  }

  @override
  Future<List<TimelineCell>> timelineBins({
    required DateTime start,
    required DateTime end,
    required Duration bin,
  }) async {
    return [
      for (final e in har.entries)
        TimelineCell(
          bin: 1,
          taskType: PredictionTaskType.har,
          label: e.key,
          count: 1,
          duration: e.value,
        ),
    ];
  }

  @override
  Future<int> countEpisodes({
    required DateTime start,
    required DateTime end,
    required PredictionTaskType taskType,
    required String label,
    Duration window = const Duration(seconds: 5),
    Duration minTime = const Duration(seconds: 4),
    PredictionSource? source,
  }) async =>
      coughs;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryStore extends EvaluationStore {
  List<EvaluationTrial> saved = [];

  @override
  Future<List<EvaluationTrial>> load() async => [];

  @override
  Future<void> save(List<EvaluationTrial> trials) async =>
      saved = List.of(trials);
}
