import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/services/evaluation.dart';

void main() {
  EvaluationTrial trial() => EvaluationTrial(
        participant: 'p1',
        trueActivity: 'sittingStanding',
        trueSocial: 'coughing',
        startedAt: DateTime.utc(2026, 11, 11, 12),
        durationSeconds: 30,
        settleSeconds: 4,
        socialSettleSeconds: 6,
        harPredictions: const ['sittingStanding', 'lyingBack', 'sittingStanding'],
        harConfidences: const [0.9, 0.5, 0.7],
        socialPredictions: const ['coughing', 'other'],
        socialConfidences: const [0.8, 0.6],
        harShown: const ['sittingStanding', 'sittingStanding'],
        harShownConfidences: const [0.9, 0.7],
        socialShown: const ['coughing', socialPausedLabel],
        socialShownConfidences: const [0.8, null],
        socialShownLatency: const Duration(milliseconds: 6400),
        stepSamples: 6,
        smoothing: true,
        platform: 'ios',
      );

  test('shown and raw are scored separately; paused social counts as wrong',
      () {
    final t = trial();
    expect(t.harShownAccuracy, 1.0);
    expect(t.harAccuracy, closeTo(2 / 3, 1e-9));
    expect(t.socialShownAccuracy, 0.5);
    expect(t.socialAccuracy, 0.5);
    expect(t.harMeanConfidence, closeTo(0.7, 1e-9));
    expect(t.socialShownMeanConfidence, closeTo(0.8, 1e-9));

    final s = EvaluationSummary.from([t]);
    final sitting = s.scores.firstWhere((c) => c.label == 'sittingStanding');
    expect(sitting.shownAccuracy, 1.0);
    expect(sitting.accuracy, closeTo(2 / 3, 1e-9));
    expect(sitting.shownMajorityCorrect, 1);
    final cough = s.scores.firstWhere((c) => c.label == 'coughing');
    expect(cough.shownCorrect, 1);
    expect(cough.shown, 2);
    expect(cough.meanShownLatency, const Duration(milliseconds: 6400));
  });

  test('JSON round trip keeps the new fields; old trials still load', () {
    final t = trial();
    final back = EvaluationTrial.fromJson(t.toJson());
    expect(back.harShown, t.harShown);
    expect(back.socialShownConfidences, [0.8, null]);
    expect(back.harConfidences, t.harConfidences);
    expect(back.stepSamples, 6);
    expect(back.smoothing, isTrue);
    expect(back.platform, 'ios');

    final old = Map<String, dynamic>.of(t.toJson())
      ..removeWhere((k, _) => !const {
            'participant', 'trueActivity', 'trueSocial', 'startedAt',
            'durationSeconds', 'settleSeconds', 'harPredictions',
            'socialPredictions',
          }.contains(k));
    final legacy = EvaluationTrial.fromJson(old);
    expect(legacy.harShown, isEmpty);
    expect(legacy.harShownAccuracy, isNull);
    expect(EvaluationSummary.from([legacy]).scores.first.shownAccuracy, isNull);
  });

  test('confusion CSV has shown and raw matrices with a paused column', () {
    final csv = confusionToCsv([trial()]);
    expect(csv, contains('Activity - shown on screen'));
    expect(csv, contains('Activity - raw model results'));
    expect(csv, contains('Social - shown on screen'));
    final lines = csv.split('\n');
    final socialHeader = lines[lines.indexOf('Social - shown on screen') + 1];
    expect(socialHeader.split(','), contains(socialPausedLabel));
    final rawRow = lines
        .skipWhile((l) => l != 'Activity - raw model results')
        .firstWhere((l) => l.startsWith('sittingStanding,'));
    // 2 of 3 raw results correct.
    expect(rawRow.split(',').last, '66.7');
  });
}
