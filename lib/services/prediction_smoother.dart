import 'dart:collection';

import '../har.dart';

/// Display-only smoothing of HAR predictions by majority vote.
///
/// Consecutive windows overlap by 50%, so a single odd prediction in the
/// middle of a steady activity is usually a classification error, not a real
/// change. Showing the most common label of the last [size] predictions
/// removes that flicker at the cost of reacting up to (size - 1) predictions
/// later (~2 s per prediction). Ties go to the newest prediction, so a real
/// change of activity still shows as soon as it has a majority.
///
/// Only the screen uses this: history, evaluation and exports always use the
/// raw model output, so smoothing never hides what the model really said.
class PredictionSmoother {
  PredictionSmoother({this.size = 3}) {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'Must be positive');
  }

  final int size;
  final Queue<HarPrediction> _recent = Queue();

  int get length => _recent.length;

  /// Adds a raw prediction and returns the smoothed one. The confidence is
  /// the mean confidence of the winning label over the recent predictions.
  HarPrediction add(HarPrediction prediction) {
    _recent.addLast(prediction);
    while (_recent.length > size) {
      _recent.removeFirst();
    }
    final counts = <String, int>{};
    for (final p in _recent) {
      counts[p.label] = (counts[p.label] ?? 0) + 1;
    }
    var best = prediction.label;
    var bestCount = counts[best]!;
    counts.forEach((label, count) {
      if (count > bestCount) {
        best = label;
        bestCount = count;
      }
    });
    var total = 0.0;
    for (final p in _recent) {
      if (p.label == best) total += p.confidence;
    }
    return HarPrediction(best, total / bestCount);
  }

  void reset() => _recent.clear();
}
