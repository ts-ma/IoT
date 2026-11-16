import 'dart:math' as math;

import 'packet_feed.dart';

// Sensor-to-app delay test (Tools › Sensor-to-app delay test): the time from
// the RESpeck finishing a packet (measuring its last sample) to that packet
// arriving in the app.
//
// The RESpeck's clock and the phone's clock are not synchronised, so the
// delay of a packet cannot be read from its timestamp. Instead one clock sees
// both ends: the RESpeck is held flat against the back of the phone and the
// two are flicked together. The phone's own accelerometer measures each flick
// on the phone clock; the RESpeck measures the same flick, and its samples
// arrive later in a Bluetooth packet, also timed on the phone clock.
//
// Each RESpeck sample gets a "nominal" time: when it would have been measured
// if its packet had reached the app instantly (packet arrival minus 80 ms for
// every later sample in the packet). The real measurement time is that minus
// the sensor-to-app delay D. For each flick the test tries every D and keeps the
// one where the RESpeck's motion lines up best with the phone's (Pearson
// correlation of the two motion curves).
//
// D covers waiting for a Bluetooth slot, transmission (and any retries) and
// the phone's Bluetooth stack and plugin up to the app, plus any small
// processing inside the RESpeck. The wait while the RESpeck fills the packet
// (up to 2.48 s, 1.24 s on average) comes before it and follows from the
// sample's position in the packet.

/// RESpeck sample spacing (12.5 Hz).
const Duration respeckSamplePeriod = Duration(milliseconds: 80);

/// Phone motion (gravity removed) as a magnitude in g, at the time the phone
/// measured it (phone clock).
class PhoneMotion {
  const PhoneMotion(this.at, this.g);
  final DateTime at;
  final double g;
}

/// One RESpeck sample (g, with gravity) at its nominal time.
class RespeckMotion {
  const RespeckMotion(this.nominal, this.x, this.y, this.z,
      {this.packetArrival, this.index});
  final DateTime nominal;
  final double x, y, z;
  final DateTime? packetArrival;
  final int? index;
}

/// The samples of [packet] with their nominal times.
List<RespeckMotion> respeckMotionOf(RespeckPacket packet) {
  final n = packet.samples.length;
  return [
    for (var i = 0; i < n; i++)
      RespeckMotion(
        packet.receivedAt.subtract(respeckSamplePeriod * (n - 1 - i)),
        packet.samples[i].x,
        packet.samples[i].y,
        packet.samples[i].z,
        packetArrival: packet.receivedAt,
        index: i,
      ),
  ];
}

/// Result for one flick. [delay] is null when the two motions did not line
/// up well enough ([reason] says why).
class FlickResult {
  const FlickResult({
    required this.at,
    this.delay,
    this.correlation,
    this.respeckPeakG,
    this.reason,
  });

  /// When the phone felt the flick start (phone clock).
  final DateTime at;
  final Duration? delay;

  /// How well the motions lined up at [delay] (Pearson r, 1 = perfectly).
  final double? correlation;

  /// Largest RESpeck movement in g around the flick.
  final double? respeckPeakG;
  final String? reason;

  bool get valid => delay != null;
}

class BleDelaySummary {
  BleDelaySummary(List<FlickResult> results)
      : flicks = results.length,
        delaysMs = [
          for (final r in results)
            if (r.valid) r.delay!.inMicroseconds / 1000
        ]..sort();

  final int flicks;

  /// Delays of the valid flicks in ms, sorted.
  final List<double> delaysMs;

  int get valid => delaysMs.length;

  double? get mean =>
      valid == 0 ? null : delaysMs.reduce((a, b) => a + b) / valid;

  double? get median {
    if (valid == 0) return null;
    final m = valid ~/ 2;
    return valid.isOdd ? delaysMs[m] : (delaysMs[m - 1] + delaysMs[m]) / 2;
  }

  double? get min => valid == 0 ? null : delaysMs.first;
  double? get max => valid == 0 ? null : delaysMs.last;

  /// Sample standard deviation.
  double? get sd {
    if (valid < 2) return null;
    final m = mean!;
    final v =
        delaysMs.fold<double>(0, (a, d) => a + (d - m) * (d - m)) / (valid - 1);
    return math.sqrt(v);
  }
}

class BleDelayAnalysis {
  BleDelayAnalysis({
    this.flickThresholdG = 0.6,
    this.minGap = const Duration(milliseconds: 1500),
    this.minDelay = const Duration(milliseconds: -100),
    this.maxDelay = const Duration(milliseconds: 1500),
    this.step = const Duration(milliseconds: 5),
    this.minCorrelation = 0.6,
    this.minRespeckPeakG = 0.15,
  });

  /// Phone motion above this starts a flick.
  final double flickThresholdG;

  /// Flicks closer than this are one flick.
  final Duration minGap;

  /// Delays tried.
  final Duration minDelay, maxDelay, step;

  /// A flick only counts when the motions line up at least this well.
  final double minCorrelation;

  /// ...and the RESpeck moved at least this much.
  final double minRespeckPeakG;

  /// Times when the phone's motion first rose above the threshold, at least
  /// [minGap] apart. [phone] must be in time order.
  List<DateTime> detectFlicks(List<PhoneMotion> phone) {
    final flicks = <DateTime>[];
    DateTime? last;
    for (final p in phone) {
      if (p.g < flickThresholdG) continue;
      if (last != null && p.at.difference(last) < minGap) {
        last = p.at;
        continue;
      }
      flicks.add(p.at);
      last = p.at;
    }
    return flicks;
  }

  /// Every flick the phone felt, each with its delay.
  List<FlickResult> analyse(
      List<PhoneMotion> phone, List<RespeckMotion> respeck) {
    final sortedPhone = List.of(phone)..sort((a, b) => a.at.compareTo(b.at));
    final sortedRespeck = List.of(respeck)
      ..sort((a, b) => a.nominal.compareTo(b.nominal));
    return [
      for (final at in detectFlicks(sortedPhone))
        analyseFlick(at, sortedPhone, sortedRespeck),
    ];
  }

  /// The delay for the flick that started at [at]. Both lists sorted by time.
  FlickResult analyseFlick(
      DateTime at, List<PhoneMotion> phone, List<RespeckMotion> respeck) {
    DateTime t(int ms) => at.add(Duration(milliseconds: ms));

    // RESpeck at rest before the flick: its average is gravity in its own
    // axes, so movement = distance from it (orientation does not matter).
    // Nominal times are later than the real ones, so samples whose nominal
    // time is before the flick were measured before it.
    final quiet = respeck
        .where(
            (r) => r.nominal.isAfter(t(-1500)) && r.nominal.isBefore(t(-200)))
        .toList();
    if (quiet.length < 3) {
      return FlickResult(at: at, reason: 'no RESpeck data before the flick');
    }
    final bx = quiet.map((r) => r.x).reduce((a, b) => a + b) / quiet.length;
    final by = quiet.map((r) => r.y).reduce((a, b) => a + b) / quiet.length;
    final bz = quiet.map((r) => r.z).reduce((a, b) => a + b) / quiet.length;

    final candidates = [
      for (final r in respeck)
        if (r.nominal.isAfter(t(-600)) && r.nominal.isBefore(t(2500)))
          (
            nominal: r.nominal,
            move: math.sqrt((r.x - bx) * (r.x - bx) +
                (r.y - by) * (r.y - by) +
                (r.z - bz) * (r.z - bz)),
          ),
    ];
    if (candidates.isEmpty) {
      return FlickResult(at: at, reason: 'no RESpeck packet after the flick');
    }
    final peak = candidates.map((c) => c.move).reduce(math.max);
    if (peak < minRespeckPeakG) {
      return FlickResult(
          at: at,
          respeckPeakG: peak,
          reason: 'the RESpeck hardly moved (hold it against the phone)');
    }

    final phoneTimes = [for (final p in phone) p.at.microsecondsSinceEpoch];
    double? phoneAt(int us) {
      // Mean phone motion within ±40 ms (one RESpeck sample's span).
      const half = 40000;
      var lo = _lowerBound(phoneTimes, us - half);
      var sum = 0.0, n = 0;
      while (lo < phoneTimes.length && phoneTimes[lo] <= us + half) {
        sum += phone[lo].g;
        n++;
        lo++;
      }
      return n == 0 ? null : sum / n;
    }

    double? bestR;
    int? bestD;
    final fromUs = t(-500).microsecondsSinceEpoch;
    final toUs = t(800).microsecondsSinceEpoch;
    for (var d = minDelay.inMicroseconds;
        d <= maxDelay.inMicroseconds;
        d += step.inMicroseconds) {
      final xs = <double>[], ys = <double>[];
      for (final c in candidates) {
        final real = c.nominal.microsecondsSinceEpoch - d;
        if (real < fromUs || real > toUs) continue;
        final q = phoneAt(real);
        if (q == null) continue;
        xs.add(c.move);
        ys.add(q);
      }
      if (xs.length < 6) continue;
      final r = _pearson(xs, ys);
      if (r != null && (bestR == null || r > bestR)) {
        bestR = r;
        bestD = d;
      }
    }
    if (bestR == null || bestD == null) {
      return FlickResult(
          at: at, respeckPeakG: peak, reason: 'not enough data to compare');
    }
    if (bestR < minCorrelation) {
      return FlickResult(
          at: at,
          correlation: bestR,
          respeckPeakG: peak,
          reason: 'the two motions did not match');
    }
    return FlickResult(
      at: at,
      delay: Duration(microseconds: bestD),
      correlation: bestR,
      respeckPeakG: peak,
    );
  }

  static int _lowerBound(List<int> sorted, int value) {
    var lo = 0, hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static double? _pearson(List<double> x, List<double> y) {
    final n = x.length;
    final mx = x.reduce((a, b) => a + b) / n;
    final my = y.reduce((a, b) => a + b) / n;
    var sxy = 0.0, sxx = 0.0, syy = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = x[i] - mx, dy = y[i] - my;
      sxy += dx * dy;
      sxx += dx * dx;
      syy += dy * dy;
    }
    if (sxx <= 0 || syy <= 0) return null;
    return sxy / math.sqrt(sxx * syy);
  }
}

/// Per-flick results as CSV.
String flicksToCsv(List<FlickResult> results) {
  final b = StringBuffer(
      'flick,phone_flick_time_utc,delay_ms,match_r,respeck_peak_g,valid,reason\n');
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    b.writeln([
      i + 1,
      r.at.toUtc().toIso8601String(),
      r.delay == null
          ? ''
          : (r.delay!.inMicroseconds / 1000).toStringAsFixed(1),
      r.correlation?.toStringAsFixed(3) ?? '',
      r.respeckPeakG?.toStringAsFixed(3) ?? '',
      r.valid ? 1 : 0,
      r.reason ?? '',
    ].join(','));
  }
  return b.toString();
}

/// Every recorded sample, to check or redo the analysis offline.
String bleDelaySamplesToCsv(
    List<PhoneMotion> phone, List<RespeckMotion> respeck) {
  final b = StringBuffer('source,time_utc,phone_motion_g,packet_arrival_utc,'
      'index_in_packet,x_g,y_g,z_g\n');
  for (final p in phone) {
    b.writeln('phone,${p.at.toUtc().toIso8601String()},'
        '${p.g.toStringAsFixed(4)},,,,,');
  }
  for (final r in respeck) {
    b.writeln('respeck,${r.nominal.toUtc().toIso8601String()},,'
        '${r.packetArrival?.toUtc().toIso8601String() ?? ''},'
        '${r.index ?? ''},${r.x},${r.y},${r.z}');
  }
  return b.toString();
}
