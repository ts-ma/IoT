// Basic tests for the PDIoT recording app.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package.

import 'package:flutter_test/flutter_test.dart';

import 'package:pdiot/main.dart';
import 'package:pdiot/utils.dart';
import 'package:pdiot/har.dart';

void main() {
  testWidgets('Home page shows the recording controls',
      (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    expect(find.text('PDIoT'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Start recording'), findsOneWidget);
    expect(find.text('Stop recording'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Not recording'), findsOneWidget);
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
      // Add samples 0..8 (only x is set, so each sample is easy to identify).
      // The window is first full after sample 3, then ready again after every
      // 2 further samples: after samples 5 and 7.
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
  });
}
