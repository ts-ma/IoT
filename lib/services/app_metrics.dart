// In-app performance counters.
//
// The coursework report must state the app's communication latency, model
// cost and data rate. These counters cover what only the app can see: how
// fast samples arrive, whether BLE packets are lost and how long each model
// call takes. They are plain counters
// updated from the BLE callback (no I/O, no notifications); PerfSampler reads
// them once a second together with CPU, memory, battery and storage.

/// Count, last, min, mean and maximum of a series of durations.
class DurationStat {
  int count = 0;
  Duration last = Duration.zero;
  Duration min = Duration.zero;
  Duration max = Duration.zero;
  int _totalMicros = 0;

  void add(Duration d) {
    if (count == 0 || d < min) min = d;
    count++;
    last = d;
    if (d > max) max = d;
    _totalMicros += d.inMicroseconds;
  }

  int get totalMicros => _totalMicros;

  Duration get mean => count == 0
      ? Duration.zero
      : Duration(microseconds: _totalMicros ~/ count);

  void reset() {
    count = 0;
    last = Duration.zero;
    min = Duration.zero;
    max = Duration.zero;
    _totalMicros = 0;
  }
}

class AppMetrics {
  AppMetrics({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// First packet of the current uninterrupted stream (null when not streaming).
  DateTime? streamStartedAt;
  DateTime? lastPacketAt;
  int packets = 0;
  int samples = 0;

  /// Samples of the current stream only (reset on disconnect), for the
  /// measured sample rate. [samples] counts every stream since the last reset.
  int streamSamples = 0;

  /// Packets missing according to the RESpeck's 16-bit sequence numbers.
  int lostPackets = 0;
  int? _lastSequence;

  /// Time spent inside the TFLite call for each model.
  final DurationStat harInference = DurationStat();
  final DurationStat socialInference = DurationStat();

  /// Time between consecutive packets arriving on the phone (nominal 2.56 s:
  /// 32 samples at 12.5 Hz).
  final DurationStat packetInterval = DurationStat();

  /// RESpeck -> phone transmission delay above the fastest packet among the
  /// last [delayWindow] packets ("extra delay"). Each packet carries the
  /// RESpeck's own timestamp, but the two clocks are not synchronised, so the
  /// fixed part of the delay cannot be measured - only how much later than
  /// the quickest recent packet each one arrived (BLE scheduling, retries,
  /// the phone being busy). The rolling minimum also absorbs slow drift
  /// between the two clocks.
  final DurationStat packetExtraDelay = DurationStat();
  static const int delayWindow = 100; // ~4 min of packets
  final List<int> _offsetsMs = [];

  /// Packets missing between the previous packet and one with [sequence]
  /// (the RESpeck's 16-bit counter, wrapping at 65535), without recording
  /// anything. 0 for the first packet of a stream, and for a very large jump,
  /// which means the sensor restarted its counter rather than that thousands
  /// of packets vanished.
  int packetGap(int sequence) {
    final previous = _lastSequence;
    if (previous == null) return 0;
    final expected = (previous + 1) & 0xFFFF;
    final gap = (sequence - expected) & 0xFFFF;
    return gap > 0 && gap < 1000 ? gap : 0;
  }

  /// Record one decoded BLE packet carrying [sampleCount] samples.
  /// [respeckMs] is the packet's timestamp from the RESpeck clock.
  void recordPacket(int sequence, int sampleCount, DateTime receivedAt,
      {int? respeckMs}) {
    streamStartedAt ??= receivedAt;
    final previousAt = lastPacketAt;
    if (previousAt != null) {
      packetInterval.add(receivedAt.difference(previousAt));
    }
    if (respeckMs != null) {
      final offset = receivedAt.millisecondsSinceEpoch - respeckMs;
      // A jump of more than a minute means the RESpeck clock restarted.
      if (_offsetsMs.isNotEmpty && (offset - _offsetsMs.last).abs() > 60000) {
        _offsetsMs.clear();
      }
      _offsetsMs.add(offset);
      if (_offsetsMs.length > delayWindow) _offsetsMs.removeAt(0);
      final fastest = _offsetsMs.reduce((a, b) => a < b ? a : b);
      packetExtraDelay.add(Duration(milliseconds: offset - fastest));
    }
    lastPacketAt = receivedAt;
    packets++;
    samples += sampleCount;
    streamSamples += sampleCount;
    lostPackets += packetGap(sequence);
    _lastSequence = sequence;
  }

  /// [elapsed] is the time inside the TFLite call only.
  void recordHarInference(Duration elapsed) => harInference.add(elapsed);

  /// [elapsed] is the time inside the TFLite call only, as for HAR.
  void recordSocialInference(Duration elapsed) => socialInference.add(elapsed);

  /// Measured sample rate of the current stream (Hz): its samples over its
  /// duration. The RESpeck nominally streams at 12.5 Hz; a lower value points
  /// to lost packets. The first packet's samples were measured before the
  /// stream's start time, so a short stream reads slightly high.
  double get sampleRateHz {
    final start = streamStartedAt;
    final end = lastPacketAt;
    if (start == null || end == null) return 0;
    final seconds = end.difference(start).inMilliseconds / 1000;
    return seconds <= 0 ? 0 : streamSamples / seconds;
  }

  double get packetLossPercent {
    final expected = packets + lostPackets;
    return expected == 0 ? 0 : 100 * lostPackets / expected;
  }

  Duration get streamUptime {
    final start = streamStartedAt;
    return start == null ? Duration.zero : _clock().difference(start);
  }

  /// Called on disconnect: a new stream starts its own rate/loss statistics.
  void endStream() {
    streamStartedAt = null;
    lastPacketAt = null;
    streamSamples = 0;
    _lastSequence = null;
    _offsetsMs.clear();
  }

  void reset() {
    endStream();
    packets = 0;
    samples = 0;
    lostPackets = 0;
    harInference.reset();
    socialInference.reset();
    packetInterval.reset();
    packetExtraDelay.reset();
  }
}

/// App-wide instance, written by ble.dart/har.dart/main.dart.
final AppMetrics appMetrics = AppMetrics();
