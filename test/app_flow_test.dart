import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdiot/home.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/evaluation.dart';
import 'package:pdiot/services/live_feed.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:pdiot/services/raw_recorder.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/timeline.dart';
import 'package:pdiot/services/user_session.dart';
import 'package:pdiot/tools_page.dart';
import 'package:pdiot/widgets/day_timeline.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Real file I/O started from the fake-async test zone needs real time and
/// a pump for each step (create, open, write, close).
Future<void> settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

void main() {
  sqfliteFfiInit();
  late Directory storage;
  late UserSession session;
  late SensorController sensor;

  setUp(() async {
    storage = await Directory.systemTemp.createTemp('pdiot_flow_');
    session =
        UserSession(storage: () async => storage, rememberLastUser: false);
    await session.init();
    await session.create('harry');
    sensor = SensorController(session: session);
  });

  tearDown(() async {
    sensor.dispose();
    if (await storage.exists()) await storage.delete(recursive: true);
  });

  Future<PredictionRepository> openDb() => PredictionRepository.open(
      databasePath: session.databasePath!, factory: databaseFactoryFfi);

  group('timeline', () {
    test('bin size gives at most 144 bins', () {
      expect(binSizeFor(const Duration(hours: 1)), const Duration(seconds: 30));
      expect(
          binSizeFor(const Duration(hours: 24)), const Duration(minutes: 10));
      expect(
          binSizeFor(const Duration(minutes: 10)), const Duration(seconds: 10));
    });

    test('monitored range, dominant activity per bin, cough bouts', () async {
      final repo = await openDb();
      final day = DateTime(2026, 11, 3);
      final t = DateTime(2026, 11, 3, 10, 0, 5).toUtc();
      Future<void> add(PredictionTaskType task, String label, int s) =>
          repo.insert(PredictionRecord(
              taskType: task,
              label: label,
              timestamp: t.add(Duration(seconds: s)),
              source: PredictionSource.live,
              intervalMs: 1000));
      for (var i = 0; i < 20; i++) {
        await add(PredictionTaskType.har, 'sittingStanding', i);
      }
      for (var i = 20; i < 25; i++) {
        await add(PredictionTaskType.har, 'normalWalking', i);
      }
      for (final s in [3, 4, 12]) {
        await add(PredictionTaskType.social, 'coughing', s);
      }
      final data = await loadTimeline(repo, day);
      expect(data.start, DateTime(2026, 11, 3, 10));
      expect(data.end, DateTime(2026, 11, 3, 11));
      expect(data.binSize, const Duration(seconds: 30));
      expect(data.bins.first.harLabel, 'sittingStanding'); // 10:00:00-10:00:30
      expect(data.bins.first.har['normalWalking'], const Duration(seconds: 5));
      expect(data.monitored, const Duration(seconds: 25));
      expect(data.coughBouts, 2);
      expect(data.activities, ['sittingStanding', 'normalWalking']);
      final full = await loadTimeline(repo, day, range: TimelineRange.fullDay);
      expect(full.bins, hasLength(144));
      final empty = await loadTimeline(repo, DateTime(2026, 11, 4));
      expect(empty.isEmpty, isTrue);
      await repo.close();
    });

    testWidgets('timeline shows details of the tapped bin', (tester) async {
      final data = TimelineData(
        start: DateTime(2026, 11, 3, 10),
        end: DateTime(2026, 11, 3, 11),
        binSize: const Duration(minutes: 30),
        bins: [
          TimelineBin(
              0, DateTime(2026, 11, 3, 10), DateTime(2026, 11, 3, 10, 30))
            ..har['running'] = const Duration(minutes: 5)
            ..social['coughing'] = const Duration(minutes: 1)
            ..socialCounts['coughing'] = 30,
          TimelineBin(
              1, DateTime(2026, 11, 3, 10, 30), DateTime(2026, 11, 3, 11)),
        ],
        coughBouts: 1,
      );
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(width: 400, child: DayTimeline(data: data)))));
      expect(find.textContaining('Tap or drag'), findsOneWidget);
      await tester.tapAt(
          tester.getTopLeft(find.byKey(const ValueKey('day-timeline'))) +
              const Offset(20, 10));
      await tester.pump();
      expect(
          find.text('10:00–10:30 · Running 5 min 00 s · mostly Coughing · '
              '30 coughing results'),
          findsOneWidget);
      await tester.tapAt(
          tester.getTopLeft(find.byKey(const ValueKey('day-timeline'))) +
              const Offset(300, 10));
      await tester.pump();
      expect(find.text('10:30–11:00 · no data'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget); // legend
    });
  });

  testWidgets('Home: pair with an ID, then Connect; forget returns to pairing',
      (tester) async {
    late PredictionRepository repo;
    await tester.runAsync(() async => repo = await openDb());
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
          sensor: sensor, session: session, openRepository: () async => repo),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    String status() => tester
        .widget<Text>(find.byKey(const ValueKey('connection-status')))
        .data!;
    expect(status(), 'Pair your RESpeck');
    expect(find.byKey(const ValueKey('pair-scan')), findsOneWidget);
    expect(find.byKey(const ValueKey('connect-button')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pair-manual')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('respeck-id-field')), 'E0:3B:AB:69:5A:1C');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('respeck-id-save')));
    });
    await tester.pumpAndSettle();
    await settleIo(tester); // saving profile.json is real file I/O
    expect(status(), 'Not connected');
    expect(find.text('RESpeck E0:3B:AB:69:5A:1C'), findsOneWidget);
    expect(find.byKey(const ValueKey('connect-button')), findsOneWidget);
    expect(session.profile!.respeckId, 'E0:3B:AB:69:5A:1C');
    expect(find.byKey(const ValueKey('today-card')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sensor-menu')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Forget sensor'));
    });
    await settleIo(tester);
    expect(status(), 'Pair your RESpeck');
    expect(session.profile!.respeckId, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(repo.close);
  });

  testWidgets('Tools: a trial saves its raw sensor data to <user>/raw/',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feed = LivePredictionFeed();
    final store = _MemoryStore();
    await tester.pumpWidget(MaterialApp(
      home: ToolsPage(
        sensor: sensor,
        session: session,
        store: store,
        feed: feed,
        requireSensor: false,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Free recording'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Start trial'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Trial running'), findsOneWidget);
    expect(find.text('REC raw'), findsOneWidget);
    expect(sensor.recorder.purpose, 'trial');
    // What ble.dart hands the recorder for one packet.
    sensor.recorder.write('1,2,3,0,0.1,-0.9,0.2\n1,2,3,1,0.1,-0.9,0.2\n', 2);
    await tester.runAsync(() async {
      await tester.tap(find.text('Finish now'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    final trial = store.saved.single;
    expect(trial.rawFile,
        startsWith('PDIoT_harry_sittingStanding_breathingNormally_'));
    final file = File(p.join(session.rawDir!.path, trial.rawFile!));
    final lines = (await tester.runAsync(file.readAsLines))!;
    expect(lines.first, rawCsvHeader);
    expect(lines, hasLength(3));
    expect(sensor.recorder.active, isFalse);

    // Free recording needs live data.
    await tester.tap(find.byKey(const ValueKey('free-start')));
    await tester.pump();
    expect(find.text('Connect the RESpeck on Home first'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('raw file names follow the coursework pattern', () {
    expect(
        rawFileName(
            user: 'harry',
            activity: 'running',
            signal: 'notAssessed',
            at: DateTime.utc(2026, 11, 3, 0, 5, 9),
            respeckId: 'E0:3B:AB:69:5A:1C'),
        'PDIoT_harry_running_notAssessed_2026-11-03T000509Z_E03BAB695A1C.csv');
  });
}

class _MemoryStore extends EvaluationStore {
  List<EvaluationTrial> saved = [];

  @override
  Future<List<EvaluationTrial>> load() async => [];

  @override
  Future<void> save(List<EvaluationTrial> trials) async =>
      saved = List.of(trials);
}
