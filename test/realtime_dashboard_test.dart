import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/activity_catalog.dart';
import 'package:pdiot/realtime_dashboard_page.dart';
import 'package:pdiot/services/evaluation.dart';

// Real-time accuracy: a tested class without any result counts as 0 % (it
// must not vanish from the group mean), coverage is reported, and the
// dashboard shows every dynamic activity and static + social pair.
void main() {
  EvaluationTrial trial(String activity, String? social,
          {List<String>? harShown,
          List<String>? socialShown,
          String participant = 'A'}) =>
      EvaluationTrial(
        participant: participant,
        trueActivity: activity,
        trueSocial: social,
        startedAt: DateTime.utc(2026, 11, 15, 12),
        durationSeconds: 30,
        settleSeconds: 4,
        harPredictions: harShown ?? const [],
        socialPredictions: socialShown ?? const [],
        harShown: harShown,
        socialShown: socialShown,
      );

  test('a tested class with no result counts as 0 in the group mean', () {
    final summary = EvaluationSummary.from([
      trial('sittingStanding', 'breathingNormally',
          harShown: ['sittingStanding', 'sittingStanding'],
          socialShown: ['breathingNormally', 'breathingNormally']),
      trial('sittingStanding', 'coughing',
          harShown: ['sittingStanding', 'sittingStanding'],
          socialShown: ['coughing', 'other']),
      trial('sittingStanding', 'hyperventilation',
          harShown: ['sittingStanding'], socialShown: const []),
    ]);
    final hyper =
        summary.scores.singleWhere((s) => s.label == 'hyperventilation');
    expect(hyper.noResultTrials, 1);
    expect(hyper.shownAccuracy, 0.0);
    // (100 + 50 + 0) / 3, not (100 + 50) / 2.
    expect(summary.groupShownMean(LabelGroup.social), closeTo(0.5, 1e-9));
    expect(summary.testedIn(LabelGroup.social), 3);
    expect(EvaluationSummary.expectedIn(LabelGroup.social), hasLength(4));
    expect(summary.testedIn(LabelGroup.staticActivity), 1);
    expect(
        EvaluationSummary.expectedIn(LabelGroup.staticActivity), hasLength(5));
    expect(
        EvaluationSummary.expectedIn(LabelGroup.dynamicActivity), hasLength(6));
    expect(summary.noResultTrials, 1);

    final csv = summaryToCsv(summary).split('\n').where((r) => r.isNotEmpty);
    final cols = csv.first.split(',').length;
    for (final row in csv) {
      expect(row.split(',').length, cols, reason: row);
    }
    expect(csv.first, endsWith('no_result_trials'));
    expect(csv.any((r) => r.contains('3/4 classes')), isTrue);
  });

  testWidgets('dashboard shows dynamic activities and static + social pairs',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: RealtimeDashboardPage(trials: [
        trial('normalWalking', null,
            harShown: ['normalWalking', 'normalWalking', 'running']),
        trial('lyingLeft', 'coughing',
            harShown: ['lyingLeft', 'lyingLeft'],
            socialShown: ['coughing', socialPausedLabel],
            participant: 'B'),
      ]),
    ));

    final walking =
        find.byKey(const ValueKey('dashboard-dynamic-normalWalking'));
    expect(find.descendant(of: walking, matching: find.text('67%')),
        findsOneWidget);
    final running = find.byKey(const ValueKey('dashboard-dynamic-running'));
    expect(find.descendant(of: running, matching: find.text('not tested')),
        findsOneWidget);

    final pair =
        find.byKey(const ValueKey('dashboard-combo-lyingLeft-coughing'));
    expect(find.descendant(of: pair, matching: find.text('100%')),
        findsOneWidget); // activity
    expect(find.descendant(of: pair, matching: find.text('50%')),
        findsOneWidget); // social: "paused" counts as wrong
    final untested =
        find.byKey(const ValueKey('dashboard-combo-lyingBack-coughing'));
    expect(
        find.descendant(
            of: untested, matching: find.textContaining('not tested')),
        findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('dashboard-coverage')))
            .data,
        contains('tested: 1 of 20'));
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('dashboard-group-dynamicActivity')),
            matching: find.text('1 of 6 tested')),
        findsOneWidget);

    // Filtering by participant: only B's trial is left.
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('dashboard-dynamic-normalWalking')),
            matching: find.text('not tested')),
        findsOneWidget);
  });
}
