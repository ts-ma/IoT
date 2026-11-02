import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// Static repository-file checks only: these tests do not load an interpreter,
// execute inference, or establish that the saved predictions are reproducible.
void main() {
  const labels = [
    'breathingNormally',
    'coughing',
    'hyperventilation',
    'other',
  ];
  late Map<String, dynamic> meta;
  late Map<String, dynamic> example;
  late _FlatBuffer model;
  late int graph;
  late List<int> tensors;

  setUpAll(() {
    meta = jsonDecode(File('model/social_cnn_meta.json').readAsStringSync())
        as Map<String, dynamic>;
    example =
        jsonDecode(File('model/social_cnn_example.json').readAsStringSync())
            as Map<String, dynamic>;
    model = _FlatBuffer(File('model/social_cnn.tflite').readAsBytesSync());
    graph = model.tables(model.root, 2).single;
    tensors = model.tables(graph, 0);
  });

  test('metadata fixes the Social sampling, window and channel contract', () {
    expect(meta['model_file'], 'social_cnn.tflite');
    expect(meta['task'], 'social_signal');
    expect(meta['sampling_frequency_hz'], 12.5);
    expect(meta['window_samples'], 50);
    expect(meta['step_samples'], 25);
    expect(meta['input']['shape'], [1, 50, 3]);
    expect(meta['input']['dtype'], 'float32');
    expect(meta['input']['channels'], ['accelX', 'accelY', 'accelZ']);
    expect(meta['input']['units'], 'g (raw accelerometer values)');
    expect(meta['output']['shape'], [1, 4]);
    expect(meta['output']['dtype'], 'float32');
    expect(meta['output']['classes'], labels);
    // The current JSON stores a literal backslash-u2013 in this description.
    expect(meta['normalization'], startsWith('inside the model'));
    expect(meta['normalization'], endsWith('feed raw values'));
  });

  test('TFLite binary input and output agree with metadata', () {
    expect(ascii.decode(model.bytes.sublist(4, 8)), 'TFL3');
    expect(model.bytes.length, 50508);
    expect(model.uintField(model.root, 0), 3); // TFLite schema version.
    final input = tensors[model.ints(graph, 1).single];
    final output = tensors[model.ints(graph, 2).single];
    expect(model.ints(input, 0), meta['input']['shape']);
    expect(model.ints(output, 0), meta['output']['shape']);
    // TensorType.FLOAT32 is enum value 0 (also the omitted-field default).
    expect(model.byteField(input, 1), 0);
    expect(model.byteField(output, 1), 0);
    expect(model.ints(input, 7), [-1, 50, 3]);
    expect(model.ints(output, 7), [-1, 4]);
  });

  test('binary embeds per-axis subtraction and inverse standard deviation', () {
    final operators = model.tables(graph, 3);
    final codes = model.tables(model.root, 1);
    final buffers = model.tables(model.root, 4);
    int opcode(int operator) =>
        model.uintField(codes[model.uintField(operator, 0)], 3);

    List<double> constant(int tensorIndex) {
      final tensor = tensors[tensorIndex];
      expect(model.byteField(tensor, 1), 0);
      expect(model.ints(tensor, 0), [1, 1, 3]);
      return model.floats(buffers[model.uintField(tensor, 2)], 0);
    }

    final subtract = operators[0];
    final multiply = operators[1];
    expect(opcode(subtract), 41); // BuiltinOperator.SUB.
    expect(opcode(multiply), 18); // BuiltinOperator.MUL.
    final subtractInputs = model.ints(subtract, 1);
    final multiplyInputs = model.ints(multiply, 1);
    expect(subtractInputs, hasLength(2));
    expect(multiplyInputs, hasLength(2));
    expect(subtractInputs.first, model.ints(graph, 1).single);
    expect(multiplyInputs.first, model.ints(subtract, 2).single);
    expect(
      constant(subtractInputs[1]),
      orderedEquals([
        -0.08247149735689163,
        -0.3982255458831787,
        0.061153262853622437,
      ]),
    );
    expect(
      constant(multiplyInputs[1]),
      orderedEquals([
        1.9124904870986938,
        2.2301547527313232,
        1.6275293827056885,
      ]),
    );
  });

  test('saved input has 50 rows of three finite numeric axis values', () {
    final rows = example['input_window'] as List<dynamic>;
    expect(rows, hasLength(meta['window_samples'] as int));
    for (final row in rows) {
      expect(row, isA<List<dynamic>>());
      expect(row, hasLength(3));
      for (final value in row as List<dynamic>) {
        expect(value, isA<num>());
        expect((value as num).isFinite, isTrue);
      }
    }
    // Axis semantics and chronological order come from notebook source;
    // the JSON has no timestamps or per-column names to prove them alone.
  });

  test('saved probabilities are finite, bounded and approximately sum to one',
      () {
    final probabilities = example['expected_probabilities'] as List<dynamic>;
    expect(probabilities, hasLength(labels.length));
    for (final value in probabilities) {
      expect(value, isA<num>());
      expect((value as num).isFinite, isTrue);
      expect(value, inInclusiveRange(0, 1));
    }
    final sum = probabilities.cast<num>().fold<double>(0, (a, b) => a + b);
    // Notebook exports round each probability to six decimal places.
    expect(sum, closeTo(1, 1e-5));
  });

  test('expected prediction is saved argmax, independently of ground truth',
      () {
    final probabilities =
        (example['expected_probabilities'] as List<dynamic>).cast<num>();
    var best = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[best]) best = i;
    }
    expect(example['expected_class'], labels[best]);
    expect(example['expected_class'], 'breathingNormally');
    expect(example['true_class'], 'other');
    expect(labels, contains(example['true_class']));
    expect(example['expected_class'], isNot(example['true_class']));
  });
}

// Minimal read-only FlatBuffer inspection for the TFLite schema fields above.
// Table slots use the TFLite Model/SubGraph/Tensor/Operator/Buffer schema.
// This is not a general model verifier and does not execute model operations.
class _FlatBuffer {
  _FlatBuffer(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;

  int get root => data.getUint32(0, Endian.little);

  int _field(int table, int slot) {
    final vtable = table - data.getInt32(table, Endian.little);
    final entry = 4 + slot * 2;
    if (entry >= data.getUint16(vtable, Endian.little)) return 0;
    final offset = data.getUint16(vtable + entry, Endian.little);
    return offset == 0 ? 0 : table + offset;
  }

  int _target(int offset) => offset + data.getUint32(offset, Endian.little);

  int uintField(int table, int slot) {
    final offset = _field(table, slot);
    return offset == 0 ? 0 : data.getUint32(offset, Endian.little);
  }

  int byteField(int table, int slot) {
    final offset = _field(table, slot);
    return offset == 0 ? 0 : data.getUint8(offset);
  }

  List<int> _elements(int table, int slot, int width) {
    final field = _field(table, slot);
    if (field == 0) return [];
    final vector = _target(field);
    final length = data.getUint32(vector, Endian.little);
    if (vector + 4 + length * width > bytes.length) {
      throw const FormatException('FlatBuffer vector exceeds model length');
    }
    return List.generate(length, (i) => vector + 4 + i * width);
  }

  List<int> tables(int table, int slot) =>
      _elements(table, slot, 4).map(_target).toList();

  List<int> ints(int table, int slot) => _elements(table, slot, 4)
      .map((offset) => data.getInt32(offset, Endian.little))
      .toList();

  List<double> floats(int table, int slot) {
    final offsets = _elements(table, slot, 1); // Buffer.data is a byte vector.
    if (offsets.length % 4 != 0) {
      throw const FormatException(
          'Float32 buffer length is not divisible by 4');
    }
    return [
      for (var i = 0; i < offsets.length; i += 4)
        data.getFloat32(offsets[i], Endian.little),
    ];
  }
}
