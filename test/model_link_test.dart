import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/services/evaluation.dart';
import 'package:pdiot/social.dart';

// Checks that the bundled models are the ones the code is wired to, and that
// the real-time test skips each model's own warm-up (HAR 4 s, Social 6 s).
void main() {
  test('code constants match the bundled model metadata', () {
    final har = jsonDecode(File(harMetaAsset).readAsStringSync());
    final social = jsonDecode(File(socialMetaAsset).readAsStringSync());
    expect(har['model_file'], harModelAsset.split('/').last);
    expect(social['model_file'], socialModelAsset.split('/').last);
    expect(social['window_samples'], socialWindowSamples);
    expect(social['step_samples'], socialStepSamples);
    expect(socialWindowSeconds, 6.0);
    expect(har['window_samples'], 50);
    for (final path in [harModelAsset, socialModelAsset]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  EvaluationTrial trial({int? socialSettle}) => EvaluationTrial(
        participant: 'p1',
        trueActivity: 'sittingStanding',
        trueSocial: 'coughing',
        startedAt: DateTime.utc(2026, 11, 3, 10),
        durationSeconds: 30,
        settleSeconds: 4,
        socialSettleSeconds: socialSettle,
        harPredictions: const ['sittingStanding'],
        socialPredictions: const ['coughing'],
      );

  test('Social warm-up is stored separately and exported', () {
    final t = trial(socialSettle: 8);
    expect(t.settleSeconds, 4);
    expect(t.socialSettleSeconds, 8);
    final back = EvaluationTrial.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
    expect(back.socialSettleSeconds, 8);
    final csv = trialsToCsv([t]).trim().split('\n');
    final column = csv.first.split(',').indexOf('social_settle_s');
    expect(column, greaterThan(0));
    expect(csv.last.split(',')[column], '8');
  });

  test('trials saved before the Social warm-up field still load', () {
    final old = trial().toJson()..remove('socialSettleSeconds');
    final back = EvaluationTrial.fromJson(old);
    expect(back.socialSettleSeconds, back.settleSeconds);
  });
}
