import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pdiot/main.dart';
import 'package:pdiot/services/app_settings.dart';
import 'package:pdiot/utils.dart';
import 'package:pdiot/har.dart';

void main() {
  testWidgets(
      'shell: five tabs, Home in the middle, user and settings at top '
      'left', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp(startPerfSampler: false));
    await tester.pump();

    // Home is the large round button between the four labelled tabs.
    final home = tester.getCenter(find.byKey(const ValueKey('tab-home')));
    final x = {
      for (final t in ['tools', 'performance', 'history', 'chart'])
        t: tester.getCenter(find.byKey(ValueKey('tab-$t'))).dx,
    };
    expect(x['tools']!, lessThan(x['performance']!));
    expect(x['performance']!, lessThan(home.dx));
    expect(home.dx, lessThan(x['history']!));
    expect(x['history']!, lessThan(x['chart']!));
    expect(find.text('PDIoT'), findsOneWidget);
    expect(find.text('Welcome'), findsOneWidget); // nobody logged in

    // The user button and the gear sit at the top left.
    final user = tester.getCenter(find.byKey(const ValueKey('user-button')));
    final gear =
        tester.getCenter(find.byKey(const ValueKey('settings-button')));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(user.dx, lessThan(width / 4));
    expect(gear.dx, greaterThan(user.dx));

    for (final t in ['tools', 'performance', 'history', 'chart']) {
      await tester.tap(find.byKey(ValueKey('tab-$t')));
      await tester.pump();
    }
    expect(find.text('Chart'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('tab-home')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pumpAndSettle();
    expect(find.text('Update interval'), findsOneWidget);
    expect(find.text('Pairing'), findsNothing); // moved to the Home sensor card
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('user-button')));
    await tester.pumpAndSettle();
    expect(find.text('Not logged in'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('messages float above the Home button without moving it',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp(startPerfSampler: false));
    await tester.pump();
    final home = find.byKey(const ValueKey('tab-home'));
    final before = tester.getRect(home);
    ScaffoldMessenger.of(tester.element(find.text('PDIoT')))
        .showSnackBar(const SnackBar(content: Text('Logged in as harry')));
    await tester.pumpAndSettle();
    expect(tester.getRect(home), before);
    expect(tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(before.top));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('sentenceToCamelCase', () {
    test('joins the words of an activity name', () {
      expect(sentenceToCamelCase('Lying down on left'), 'lyingDownOnLeft');
      expect(sentenceToCamelCase('Standing'), 'standing');
    });

    test('tolerates empty and oddly spaced input', () {
      expect(sentenceToCamelCase(''), '');
      expect(sentenceToCamelCase('   '), '');
      expect(sentenceToCamelCase('  Normal   walking '), 'normalWalking');
    });
  });

  group('combineAccelBytes', () {
    test('decodes positive values', () {
      expect(combineAccelBytes(0, 0), 0.0);
      // 0x4000 = 16384 = 1g
      expect(combineAccelBytes(0x40, 0x00), 1.0);
    });

    test('decodes negative values', () {
      // 0xC000 as a signed 16 bit value is -16384 = -1g. The upper byte is
      // read from the packet with getInt8, so it arrives here as -64.
      expect(combineAccelBytes(-64, 0x00), -1.0);
      // 0xFFFF = -1
      expect(combineAccelBytes(-1, 0xFF), -1 / 16384.0);
    });
  });

  // The sliding window decides when the activity classifier runs. These tests
  // use a small window (4 samples, step 2) so the expected pattern is easy to
  // follow; the real model uses 50 and 25.
  group('SampleWindow', () {
    test('is ready once full, then every step samples', () {
      final w = SampleWindow(4, 2);
      final ready = [for (int i = 0; i < 9; i++) w.add(i.toDouble(), 0, 0)];
      expect(
          ready, [false, false, false, true, false, true, false, true, false]);
      // After 9 samples the window holds the newest 4, oldest first
      expect(w.batch[0].map((s) => s[0]), [5.0, 6.0, 7.0, 8.0]);
    });

    // After a disconnect the window is cleared, and must fill up again
    // completely before the next prediction
    test('starts again after clear', () {
      final w = SampleWindow(2, 1);
      w.add(0, 0, 0);
      w.add(0, 0, 0);
      w.clear();
      expect(w.add(0, 0, 0), false);
      expect(w.add(0, 0, 0), true);
    });

    test('the step can change while streaming (update interval setting)', () {
      final w = SampleWindow(4, 2);
      for (var i = 0; i < 4; i++) {
        w.add(0, 0, 0);
      }
      w.step = 1; // faster: every new sample completes a result
      expect([w.add(0, 0, 0), w.add(0, 0, 0)], [true, true]);
      w.step = 3;
      expect([w.add(0, 0, 0), w.add(0, 0, 0), w.add(0, 0, 0)],
          [false, false, true]);
      expect(() => w.step = 0, throwsArgumentError);
      expect(() => SampleWindow(4, 0), throwsArgumentError);
    });
  });

  test('update interval choices and labels', () {
    expect(stepChoices, [25, 12, 6]);
    expect(stepChoices.map(stepLabel), ['2 s', '1 s', '0.5 s']);
    final s = AppSettings();
    expect(s.stepSamples.value, defaultStepSamples);
    expect(s.resultIntervalMs, 960);
    s.stepSamples.value = 25;
    expect(s.resultIntervalMs, 2000);
    expect(() => s.setStepSamples(7), throwsArgumentError);
  });
}
