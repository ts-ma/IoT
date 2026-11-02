import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Uses Flutter's real test asset bundle, without mocking rootBundle.
  // These checks load assets only; they do not invoke TFLite inference.
  test('bundled Social files load and match their verified originals',
      () async {
    for (final name in [
      'social_cnn.tflite',
      'social_cnn_meta.json',
      'social_cnn_example.json',
    ]) {
      final data = await rootBundle.load('assets/models/$name');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      expect(bytes, orderedEquals(File('model/$name').readAsBytesSync()),
          reason: '$name must remain byte-identical to the verified original');
    }
  });

  test('bundled metadata and example decode with the verified class ordering',
      () async {
    final meta = jsonDecode(
      await rootBundle.loadString('assets/models/social_cnn_meta.json'),
    ) as Map<String, dynamic>;
    final example = jsonDecode(
      await rootBundle.loadString('assets/models/social_cnn_example.json'),
    ) as Map<String, dynamic>;

    expect(meta['model_file'], 'social_cnn.tflite');
    expect(meta['input']['shape'], [1, 50, 3]);
    expect(meta['output']['classes'], [
      'breathingNormally',
      'coughing',
      'hyperventilation',
      'other',
    ]);
    expect(example['input_window'], hasLength(50));
    final probabilities =
        (example['expected_probabilities'] as List<dynamic>).cast<num>();
    expect(probabilities, hasLength(4));
    var best = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[best]) best = i;
    }
    expect(example['expected_class'], meta['output']['classes'][best]);
    expect(example['expected_class'], 'breathingNormally');
    expect(example['true_class'], 'other');
  });
}
