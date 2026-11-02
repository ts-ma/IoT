import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/social.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real Social TFLite inference matches exported example probabilities',
      () async {
    final classifier = await SocialClassifier.load();
    addTearDown(classifier.dispose);
    final example = jsonDecode(await rootBundle.loadString(
        'assets/models/social_cnn_example.json')) as Map<String, dynamic>;
    SocialPrediction? prediction;
    for (final row in example['input_window'] as List<dynamic>) {
      prediction = classifier.addSample((row[0] as num).toDouble(),
          (row[1] as num).toDouble(), (row[2] as num).toDouble());
    }
    expect(prediction, isNotNull);
    final expected = example['expected_probabilities'] as List<dynamic>;
    expect(prediction!.probabilities, hasLength(expected.length));
    for (var i = 0; i < expected.length; i++) {
      // Exported input/output were rounded to six decimal places. Allow small
      // CPU-kernel differences without accepting materially different outputs.
      expect(prediction.probabilities[i], closeTo(expected[i] as num, 1e-4));
    }
    expect(prediction.label, example['expected_class']);
    expect(prediction.confidence, closeTo(expected[0] as num, 1e-4));
    expect(example['true_class'], 'other'); // Not the expected prediction.
  }, skip: _missingNativeLibrary());
}

// These are the paths used by tflite_flutter 0.12.1's native bindings. Missing
// host libraries are explicit skips; model/runtime failures are never swallowed.
String? _missingNativeLibrary() {
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  String? library;
  if (Platform.isWindows) {
    library = '$executableDirectory/blobs/libtensorflowlite_c-win.dll';
  } else if (Platform.isLinux) {
    library = '$executableDirectory/blobs/libtensorflowlite_c-linux.so';
  } else if (Platform.isMacOS) {
    library = '${File(Platform.resolvedExecutable).parent.parent.path}'
        '/resources/libtensorflowlite_c-mac.dylib';
  }
  return library != null && !File(library).existsSync()
      ? 'Real inference not run: tflite_flutter native library missing: $library'
      : null;
}
