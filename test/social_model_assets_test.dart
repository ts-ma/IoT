import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/social.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final model in [
    (
      name: 'harry_har_cnn',
      asset: harModelAsset,
      meta: harMetaAsset,
      window: 50,
      classes: 11
    ),
    (
      name: 'harry_social_rnn',
      asset: socialModelAsset,
      meta: socialMetaAsset,
      window: 75,
      classes: 4
    ),
  ]) {
    test('bundled ${model.name} files match the supplied assets', () async {
      for (final path in [
        model.asset,
        model.meta,
        'assets/models/${model.name}_example.json'
      ]) {
        final data = await rootBundle.load(path);
        final bytes =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        expect(bytes, orderedEquals(File(path).readAsBytesSync()));
      }
    });
    test('${model.name} metadata and example agree', () async {
      final meta = jsonDecode(await rootBundle.loadString(model.meta));
      final example = jsonDecode(await rootBundle
          .loadString('assets/models/${model.name}_example.json'));
      expect(meta['model_file'], '${model.name}.tflite');
      expect(meta['input']['shape'], [1, model.window, 3]);
      expect(meta['window_samples'], model.window);
      expect(meta['step_samples'], 25);
      expect(meta['output']['shape'], [1, model.classes]);
      expect(example['input_window'], hasLength(model.window));
      final labels = List<String>.from(meta['output']['classes']);
      expect(labels, hasLength(model.classes));
      if (model.name == 'harry_social_rnn') expect(labels, socialLabels);
      final probabilities =
          (example['expected_probabilities'] as List).cast<num>();
      expect(probabilities, hasLength(model.classes));
      var best = 0;
      for (var i = 1; i < probabilities.length; i++) {
        if (probabilities[i] > probabilities[best]) best = i;
      }
      expect(example['expected_class'], labels[best]);
      expect(labels, contains(example['true_class']));
    });
  }
}
