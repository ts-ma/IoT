import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pdiot/globals.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/home.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_history_writer.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:pdiot/services/replay.dart';
import 'package:pdiot/services/social_sample_processor.dart';
import 'package:pdiot/social.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// Demo replay: recorded files are streamed through the same pipeline as live
// BLE data. Native TFLite is faked; the windowing, wiring and storage are real.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseAccelCsv', () {
    test('cleaned CW2 format (timestamp,accelX,accelY,accelZ)', () {
      final s = parseAccelCsv('timestamp,accelX,accelY,accelZ\n'
          '1,0.1,-1.0,0.05\n2,0.2,-0.9,0.06\n');
      expect(s, [
        [0.1, -1.0, 0.05],
        [0.2, -0.9, 0.06]
      ]);
    });

    test('raw app format, extra columns, CRLF and a bad row', () {
      final s = parseAccelCsv(
          'receivedPhoneTimestamp,respeckTimestamp,packetSeqNum,sampleSeqNum,accelX,accelY,accelZ\r\n'
          '10,20,1,0,0.5,-0.5,0.25\r\n'
          '10,20,1,1,oops,-0.5,0.25\r\n'
          '11,21,2,0,0.4,-0.6,0.2\r\n');
      expect(s, [
        [0.5, -0.5, 0.25],
        [0.4, -0.6, 0.2]
      ]);
    });

    test('dataset format and headerless files', () {
      expect(parseAccelCsv('accelX,accelY,accelZ\n1,2,3\n'), [
        [1.0, 2.0, 3.0]
      ]);
      expect(parseAccelCsv('5,1,2,3\n6,4,5,6\n'), [
        [1.0, 2.0, 3.0],
        [4.0, 5.0, 6.0]
      ]);
      expect(parseAccelCsv(''), isEmpty);
    });
  });

  group('labelsFromFileName', () {
    test('cleaned CW2 names', () {
      var l = labelsFromFileName(
          'PDIOT_s2503795_LyingDownLeft_Coughing_05-10-2026_16-25-37.csv');
      expect([l.har, l.social], ['lyingLeft', 'coughing']);
      l = labelsFromFileName(
          'PDIOT_s2503795_AscendingStairs_Normal_05-10-2026_14-32-31.csv');
      expect([l.har, l.social], ['ascending', null]); // moving: no social label
      l = labelsFromFileName(
          'PDIOT_s2503795_Sitting_Eating_05-10-2026_14-49-56.csv');
      expect([l.har, l.social], ['sittingStanding', 'other']);
    });

    test('raw app recording names', () {
      var l = labelsFromFileName(
          'PDIoT_s1_lyingDownOnLeft_hyperventilating_2026-11-03T101010Z_AABB.csv');
      expect([l.har, l.social], ['lyingLeft', 'hyperventilation']);
      l = labelsFromFileName(
          'PDIoT_s1_miscellaneousMovements_normal_2026-11-03T101010Z_AABB.csv');
      expect([l.har, l.social], ['miscMovement', null]);
    });

    test('unknown names still replay without labels', () {
      final l = labelsFromFileName('my_walk.csv');
      expect([l.har, l.social], [null, null]);
    });
  });

  test('every bundled demo recording parses and has ground truth', () {
    final files = Directory('assets/demo')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList();
    expect(files, hasLength(44));
    for (final f in files) {
      final name = path.basename(f.path);
      final samples = parseAccelCsv(f.readAsStringSync());
      expect(samples.length, inInclusiveRange(350, 400), reason: name);
      expect(labelsFromFileName(name).har, isNotNull, reason: name);
    }
  });

  test('the demo tour finds all its scenes among the bundled recordings', () {
    final bundled = [
      for (final f in Directory('assets/demo').listSync().whereType<File>())
        ReplaySource(
            fileName: path.basename(f.path), read: f.readAsString, bundled: true)
    ];
    final tour = demoTour(bundled);
    expect(tour, hasLength(demoTourScenes.length));
    expect(tour.map((s) => s.labels.har).toList(), [
      'sittingStanding',
      'normalWalking',
      'ascending',
      'descending',
      'running',
      'shuffleWalking',
      'lyingBack',
      'sittingStanding',
      'sittingStanding',
      'sittingStanding',
    ]);
    expect(tour[7].labels.social, 'coughing');
    expect(tour[8].labels.social, 'hyperventilation');
  });

  group('ReplayController', () {
    ReplaySource src(String name, int n) => ReplaySource(
          fileName: name,
          read: () async => 'accelX,accelY,accelZ\n'
              '${List.generate(n, (i) => '$i,${-i},0.5').join('\n')}\n',
        );

    test('feeds every sample in order across recordings, then stops once',
        () async {
      final fed = <List<double>>[];
      var starts = 0, stops = 0, ticks = 0;
      final c = ReplayController(
        onSample: (x, y, z) => fed.add([x, y, z]),
        onStart: () => starts++,
        onStop: () => stops++,
        onTick: () => ticks++,
      );
      await c.play([src('PDIOT_a_Running_Normal_x.csv', 3), src('b.csv', 2)],
          autoStart: false);
      expect([starts, c.state, c.totalSamples], [1, ReplayState.paused, 5]);
      expect(c.total, const Duration(milliseconds: 400)); // 5 / 12.5 Hz

      c.advance(2);
      expect(c.itemIndex, 0);
      expect(c.current!.labels.har, 'running');
      c.advance(2); // crosses into the second recording
      expect(c.itemIndex, 1);
      expect(c.progress, closeTo(0.8, 1e-9));
      c.advance(10); // only one sample left
      expect(fed.map((s) => s[0]).toList(), [0, 1, 2, 0, 1]);
      expect([stops, c.state, c.progress], [1, ReplayState.finished, 1.0]);
      expect(ticks, 3);
      await c.stop(); // already finished: no second onStop
      expect(stops, 1);
      c.dispose();
    });

    test('stop mid-way ends the session; empty files are rejected', () async {
      var stops = 0;
      final c = ReplayController(onSample: (x, y, z) {}, onStop: () => stops++);
      await c.play([src('a.csv', 10)], autoStart: false);
      c.advance(3);
      await c.stop();
      expect([stops, c.state, c.active], [1, ReplayState.idle, false]);
      await expectLater(
          c.play([ReplaySource(fileName: 'e.csv', read: () async => 'x\n')]),
          throwsFormatException);
      expect(c.state, ReplayState.idle);
      expect(stops, 1);
      c.dispose();
    });

    test('speed changes how many samples each tick delivers', () async {
      final c = ReplayController(onSample: (x, y, z) {});
      expect(() => c.speed = 0, throwsArgumentError);
      c.speed = 4;
      expect(c.speed, 4);
      c.dispose();
    });
  });

  test('daily-summary counts can exclude replayed results', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('replay_db');
    final repo = await PredictionRepository.open(
        databasePath: path.join(dir.path, 'h.db'), factory: databaseFactoryFfi);
    final t = DateTime.utc(2026, 11, 3, 12);
    for (final s in [
      PredictionSource.live,
      PredictionSource.replay,
      PredictionSource.replay
    ]) {
      await repo.insert(PredictionRecord(
          taskType: PredictionTaskType.social,
          label: 'coughing',
          timestamp: t,
          confidence: 0.9,
          source: s));
    }
    final day = DateTime.utc(2026, 11, 3);
    final end = day.add(const Duration(days: 1));
    expect(
        await repo.countByLabel(
            start: day, end: end, taskType: PredictionTaskType.social),
        {'coughing': 3});
    expect(
        await repo.countByLabel(
            start: day,
            end: end,
            taskType: PredictionTaskType.social,
            source: PredictionSource.live),
        {'coughing': 1});
    expect(
        await repo.countEpisodes(
            start: day,
            end: end,
            taskType: PredictionTaskType.social,
            label: 'coughing',
            source: PredictionSource.live),
        1);
    await repo.close();
    await dir.delete(recursive: true);
  });

  testWidgets('home replay: plays a bundled recording through both models',
      (tester) async {
    final runner = _Runner();
    late SocialClassifier classifier;
    await tester.runAsync(() async {
      classifier = await SocialClassifier.load(createRunner: () async => runner);
    });
    final writer = _CapturingWriter();
    // Wired exactly as main.dart does: every new Social result is persisted.
    final processor = SocialSampleProcessor(
        classifier: () => classifier, onPrediction: writer.captureSocial);
    harClassifier = _Har();
    addTearDown(() {
      harClassifier = null;
      processor.dispose();
      classifier.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: MyHomePage(
          title: 'PDIoT', socialProcessor: processor, historyWriter: writer),
    ));
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 200))); // asset manifest
    await tester.pump();
    final card = find.byKey(const ValueKey('replay-card'));
    await tester.ensureVisible(card);
    expect(find.textContaining('Demo tour (10 scenes'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('replay-play')));
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 300))); // read the CSVs
    await tester.pump();
    expect(replayActive, isTrue);
    expect(writer.source, PredictionSource.replay);
    expect(find.textContaining('Scene 1/10'), findsOneWidget);

    // 8 s of the first scene at 12.5 Hz -> 100 samples: 3 HAR results (at
    // samples 50, 75 and 100) and the first Social result (sample 100).
    await tester.pump(const Duration(seconds: 8));
    expect(writer.records.where((r) => r.taskType == PredictionTaskType.har),
        hasLength(3));
    expect(writer.records.where((r) => r.taskType == PredictionTaskType.social),
        hasLength(1));
    expect(writer.records.every((r) => r.source == PredictionSource.replay),
        isTrue);
    expect(processor.status, SocialPredictionStatus.ready);

    await tester.tap(find.byKey(const ValueKey('replay-stop')));
    await tester.pump();
    expect(replayActive, isFalse);
    expect(writer.source, PredictionSource.live);
    expect(processor.status, SocialPredictionStatus.disconnected);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _CapturingWriter extends PredictionHistoryWriter {
  final List<PredictionRecord> records = [];

  @override
  bool enqueue(PredictionRecord record) {
    records.add(record);
    return true;
  }
}

class _Runner implements SocialModelRunner {
  @override
  List<int> get inputShape => [1, socialWindowSamples, 3];
  @override
  TensorType get inputType => TensorType.float32;
  @override
  List<int> get outputShape => [1, 4];
  @override
  TensorType get outputType => TensorType.float32;
  @override
  List<double> run(List<List<List<double>>> batch) => [0.1, 0.7, 0.1, 0.1];
  @override
  void close() {}
}

/// HAR stand-in with the real 50/25 window: a result every 25 samples once
/// the first 50 have arrived.
class _Har implements HarClassifier {
  @override
  List<String> get classes => ['sittingStanding'];
  @override
  final window = SampleWindow(50, 25);
  @override
  HarPrediction? addSample(double x, double y, double z) =>
      window.add(x, y, z) ? const HarPrediction('sittingStanding', 0.9) : null;
  @override
  void reset() => window.clear();
}
