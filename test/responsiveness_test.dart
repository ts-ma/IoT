import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/services/app_settings.dart';
import 'package:pdiot/services/evaluation.dart';
import 'package:pdiot/services/live_feed.dart';
import 'package:pdiot/services/sensor_controller.dart';
import 'package:pdiot/services/user_session.dart';

// Display responsiveness (2026-11-09): every activity result goes into the
// smoother (a RESpeck packet carries 2.56 s of samples, i.e. several results),
// and the real-time test records when the right activity was SHOWN.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every result in a packet counts towards the majority of 3', () {
    appSettings.smoothHar.value = true;
    final sensor =
        SensorController(session: UserSession(rememberLastUser: false));
    addTearDown(sensor.dispose);
    // One packet's worth of results while sitting, then the wearer walks off:
    // the next packet brings several walking results at once.
    for (final l in ['sittingStanding', 'sittingStanding', 'sittingStanding']) {
      sensor.addHarResult(HarPrediction(l, 0.9));
    }
    expect(sensor.harShown!.label, 'sittingStanding');
    sensor.addHarResult(const HarPrediction('normalWalking', 0.8));
    expect(sensor.harShown!.label, 'sittingStanding');
    // Second walking result of the same packet: majority -> shown at once,
    // not two packets (5 s) later.
    final shown = sensor.addHarResult(const HarPrediction('normalWalking', 0.8));
    expect(shown.label, 'normalWalking');
    expect(sensor.harShown!.label, 'normalWalking');
    expect(sensor.harRaw!.label, 'normalWalking');
    expect(SensorController.isMoving('normalWalking'), isTrue);
    expect(SensorController.isMoving('lyingLeft'), isFalse);
  });

  test('smoothing off shows each raw result', () {
    appSettings.smoothHar.value = false;
    addTearDown(() => appSettings.smoothHar.value = true);
    final sensor =
        SensorController(session: UserSession(rememberLastUser: false));
    addTearDown(sensor.dispose);
    sensor.addHarResult(const HarPrediction('lyingBack', 0.9));
    sensor.addHarResult(const HarPrediction('running', 0.7));
    expect(sensor.harShown!.label, 'running');
  });

  test('live HAR events carry the shown result (raw when not given)', () {
    const raw = HarPrediction('running', 0.6);
    const shown = HarPrediction('normalWalking', 0.8);
    expect(LiveHarEvent(raw, DateTime.utc(2026)).shown, same(raw));
    expect(LiveHarEvent(raw, DateTime.utc(2026), shown: shown).shown,
        same(shown));
  });

  test('trials keep the shown latency; older trials load without it', () {
    final t = EvaluationTrial(
      participant: 's2503795',
      trueActivity: 'normalWalking',
      startedAt: DateTime.utc(2026, 11, 9, 12),
      durationSeconds: 30,
      settleSeconds: 4,
      harPredictions: const ['normalWalking', 'normalWalking'],
      socialPredictions: const [],
      harLatency: const Duration(milliseconds: 3100),
      harShownLatency: const Duration(milliseconds: 3600),
    );
    final back = EvaluationTrial.fromJson(t.toJson());
    expect(back.harShownLatency, const Duration(milliseconds: 3600));
    final old = Map<String, dynamic>.of(t.toJson())..remove('harShownLatencyMs');
    expect(EvaluationTrial.fromJson(old).harShownLatency, isNull);

    final csv = trialsToCsv([t]).split('\n');
    expect(csv.first.split(',').last, 'har_shown_latency_s');
    expect(csv[1].split(',').last, '3.6');
    final summary = EvaluationSummary.from([t]);
    expect(summary.scores.single.meanShownLatency,
        const Duration(milliseconds: 3600));
    final sumCsv = summaryToCsv(summary).split('\n');
    expect(sumCsv.first.split(',').last, 'mean_shown_latency_s');
    // Every row has the same number of columns.
    final cols = sumCsv.first.split(',').length;
    for (final row in sumCsv.where((r) => r.isNotEmpty)) {
      expect(row.split(',').length, cols, reason: row);
    }
  });
}
