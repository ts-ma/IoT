// Live "time to show a change", without a test.
//
// The models re-check the last 4 s (activity) or 6 s (social) of data every
// update interval. After the wearer changes, the window slowly fills with the
// new movement and the screen switches once enough of it is new. The app
// knows when the screen switched but not when the wearer changed, so at every
// switch it looks back through the raw accelerometer data and finds where the
// signal itself changed (a single change point: the split that best separates
// the stretch into two parts with different variance per axis). The time from
// that point to the switch is the live latency.
//
// Two signals are tried, as tested offline on the group's recordings joined
// end to end (true change known; model_harry change-point check):
//   1. sample-to-sample differences (jerk): any change of motion or breathing
//      pattern; used when its gain is >= 0.8;
//   2. raw values: posture/tilt changes that barely change the jerk (e.g.
//      lying back -> lying left); used when its gain is >= 3.0.
// Neither clear -> the switch is counted as "unclear" (often a brief misread
// rather than a real change). Offline: activity 86 % of changes found, 98 %
// within 1 s, 7 % false alarms on stretches without a change; social 83 %,
// 95 % within 1 s, 3 % false alarms. Real changes take a second or two
// (sitting down), so expect about +-1 s in use.
//
// Sample times are the phone's packet arrival time minus 80 ms per later
// sample in the packet, so the (unmeasurable, tens of ms) BLE delay makes the
// latency read slightly low.

import 'dart:math' as math;
import 'dart:typed_data';

enum ChangeTask { activity, social }

/// One measured switch of the shown label.
class ChangeEstimate {
  const ChangeEstimate({
    required this.task,
    required this.from,
    required this.to,
    required this.shownAt,
    required this.changedAt,
    required this.signal,
    required this.gain,
  });

  final ChangeTask task;
  final String from;
  final String to;
  final DateTime shownAt;

  /// Where the raw signal changed.
  final DateTime changedAt;

  /// 'motion' (jerk) or 'posture' (raw values).
  final String signal;
  final double gain;

  Duration get latency => shownAt.difference(changedAt);
}

class ChangeLatencyEstimator {
  ChangeLatencyEstimator({this.hz = 12.5});

  final double hz;

  static const activityLookback = Duration(seconds: 12);
  static const socialLookback = Duration(seconds: 14);
  static const minSegment = Duration(milliseconds: 1500);
  static const motionGain = 0.8;
  static const postureGain = 3.0;

  /// Samples kept: the longest look-back plus a margin.
  int get capacity => (socialLookback.inMilliseconds / 1000 * hz).ceil() + 25;

  final List<int> _t = []; // ms since epoch
  final List<double> _x = [], _y = [], _z = [];

  int get length => _t.length;

  void addSample(double x, double y, double z, DateTime at) {
    _t.add(at.millisecondsSinceEpoch);
    _x.add(x);
    _y.add(y);
    _z.add(z);
    final extra = _t.length - capacity;
    if (extra > 0) {
      _t.removeRange(0, extra);
      _x.removeRange(0, extra);
      _y.removeRange(0, extra);
      _z.removeRange(0, extra);
    }
  }

  void clear() {
    _t.clear();
    _x.clear();
    _y.clear();
    _z.clear();
  }

  /// The change point behind a switch shown at [shownAt], or null when the
  /// signal shows no clear change (or there is too little continuous data).
  ChangeEstimate? estimate({
    required ChangeTask task,
    required String from,
    required String to,
    required DateTime shownAt,
  }) {
    final lookback =
        task == ChangeTask.activity ? activityLookback : socialLookback;
    final endMs = shownAt.millisecondsSinceEpoch;
    final startMs = endMs - lookback.inMilliseconds;
    var first = _t.length;
    while (first > 0 && _t[first - 1] > startMs) {
      first--;
    }
    final n = _t.length - first;
    final expected = lookback.inMilliseconds / 1000 * hz;
    if (n < 0.85 * expected) return null;
    for (var i = first + 1; i < _t.length; i++) {
      if (_t[i] - _t[i - 1] > 3000) return null; // a gap in the stream
    }
    // 18 samples (1.44 s) at 12.5 Hz, as in the offline evaluation.
    final minSeg = (minSegment.inMilliseconds / 1000 * hz).floor();

    // 1. Jerk (sample-to-sample differences).
    final m = n - 1;
    final d = Float64List(m * 3);
    for (var i = 0; i < m; i++) {
      final a = first + i;
      d[i * 3] = _x[a + 1] - _x[a];
      d[i * 3 + 1] = _y[a + 1] - _y[a];
      d[i * 3 + 2] = _z[a + 1] - _z[a];
    }
    var best = changePoint(d, m, minSeg);
    var signal = 'motion';
    var index = best == null ? null : first + best.index + 1;
    if (best == null || best.gain < motionGain) {
      // 2. Raw values (posture / tilt).
      final r = Float64List(n * 3);
      for (var i = 0; i < n; i++) {
        r[i * 3] = _x[first + i];
        r[i * 3 + 1] = _y[first + i];
        r[i * 3 + 2] = _z[first + i];
      }
      best = changePoint(r, n, minSeg);
      signal = 'posture';
      index = best == null ? null : first + best.index;
      if (best == null || best.gain < postureGain) return null;
    }
    return ChangeEstimate(
      task: task,
      from: from,
      to: to,
      shownAt: shownAt,
      changedAt: DateTime.fromMillisecondsSinceEpoch(_t[index!], isUtc: true)
          .toLocal(),
      signal: signal,
      gain: best.gain,
    );
  }

  /// Best single split of [n] rows of 3 values (row-major in [v]): the index
  /// k (first row of the second part) maximising the drop in Gaussian cost
  /// n*sum(log var) per row, with both parts at least [minSeg] rows long.
  static ({int index, double gain})? changePoint(
      Float64List v, int n, int minSeg) {
    if (n < 2 * minSeg) return null;
    final c1 = Float64List((n + 1) * 3), c2 = Float64List((n + 1) * 3);
    for (var i = 0; i < n; i++) {
      for (var a = 0; a < 3; a++) {
        final x = v[i * 3 + a];
        c1[(i + 1) * 3 + a] = c1[i * 3 + a] + x;
        c2[(i + 1) * 3 + a] = c2[i * 3 + a] + x * x;
      }
    }
    double cost(int from, int to) {
      final len = to - from;
      var sum = 0.0;
      for (var a = 0; a < 3; a++) {
        final mu = (c1[to * 3 + a] - c1[from * 3 + a]) / len;
        final variance = (c2[to * 3 + a] - c2[from * 3 + a]) / len - mu * mu;
        sum += math.log(math.max(variance, 0) + 1e-6);
      }
      return len * sum;
    }

    final full = cost(0, n);
    var bestGain = double.negativeInfinity;
    var bestK = -1;
    for (var k = minSeg; k <= n - minSeg; k++) {
      final g = full - cost(0, k) - cost(k, n);
      if (g > bestGain) {
        bestGain = g;
        bestK = k;
      }
    }
    return bestK < 0 ? null : (index: bestK, gain: bestGain / n);
  }
}
