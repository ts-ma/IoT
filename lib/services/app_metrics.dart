// In-app performance counters.
//
// The coursework report must state the app's communication latency, model
// cost and data rate. These counters cover what only the app can see: how
// fast samples arrive, whether BLE packets are lost, how long each model call
// takes and how often predictions are actually shown. They are plain counters
// updated from the BLE callback (no I/O, no notifications); PerfSampler reads
// them once a second together with CPU, memory, battery and storage.

import 'change_latency.dart';

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

  /// Packets missing according to the RESpeck's 16-bit sequence numbers.
  int lostPackets = 0;
  int? _lastSequence;

  /// Time spent inside the TFLite call for each model.
  final DurationStat harInference = DurationStat();
  final DurationStat socialInference = DurationStat();

  /// Time between consecutive HAR / Social predictions - how often the
  /// display actually updates (expected ~2 s).
  final DurationStat harUpdateInterval = DurationStat();
  final DurationStat socialUpdateInterval = DurationStat();
  DateTime? _lastHarAt;
  DateTime? _lastSocialAt;

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

  /// Packet arrival -> its results handed to the display (decoding, both
  /// models for every result in the packet, smoothing). The screen draws on
  /// the next frame (<= 16 ms later).
  final DurationStat packetToDisplay = DurationStat();

  /// Live time to show a change: from where the raw signal changed to the
  /// screen switching label (see change_latency.dart).
  final ChangeLatencyEstimator changeEstimator = ChangeLatencyEstimator();
  final DurationStat activityChange = DurationStat();
  final DurationStat socialChange = DurationStat();
  int activityUnclear = 0, socialUnclear = 0;

  /// The latest measured switches, oldest first (for the chart).
  final List<ChangeEstimate> recentChanges = [];
  static const int recentCapacity = 40;

  void recordSample(double x, double y, double z, DateTime at) =>
      changeEstimator.addSample(x, y, z, at);

  void recordPacketProcessing(Duration elapsed) => packetToDisplay.add(elapsed);

  /// The shown label switched [from] -> [to] at [shownAt]. Returns the
  /// estimate, or null when the signal shows no clear change ("unclear").
  ChangeEstimate? recordShownChange(
      ChangeTask task, String from, String to, DateTime shownAt) {
    final e = changeEstimator.estimate(
        task: task, from: from, to: to, shownAt: shownAt);
    final stat = task == ChangeTask.activity ? activityChange : socialChange;
    if (e == null) {
      if (task == ChangeTask.activity) {
        activityUnclear++;
      } else {
        socialUnclear++;
      }
      return null;
    }
    stat.add(e.latency);
    recentChanges.add(e);
    if (recentChanges.length > recentCapacity) recentChanges.removeAt(0);
    return e;
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
    final previous = _lastSequence;
    if (previous != null) {
      final expected = (previous + 1) & 0xFFFF;
      final gap = (sequence - expected) & 0xFFFF;
      // A very large gap means the sensor restarted its counter rather than
      // that thousands of packets vanished, so it is not counted as loss.
      if (gap > 0 && gap < 1000) lostPackets += gap;
    }
    _lastSequence = sequence;
  }

  void recordHarInference(Duration elapsed) {
    harInference.add(elapsed);
    final now = _clock();
    final last = _lastHarAt;
    if (last != null) harUpdateInterval.add(now.difference(last));
    _lastHarAt = now;
  }

  void recordSocialInference(Duration elapsed, DateTime completedAt) {
    socialInference.add(elapsed);
    final last = _lastSocialAt;
    if (last != null) socialUpdateInterval.add(completedAt.difference(last));
    _lastSocialAt = completedAt;
  }

  /// Measured sample rate of the current stream (Hz). The RESpeck nominally
  /// streams at 12.5 Hz; a lower value points to lost packets.
  double get sampleRateHz {
    final start = streamStartedAt;
    final end = lastPacketAt;
    if (start == null || end == null) return 0;
    final seconds = end.difference(start).inMilliseconds / 1000;
    return seconds <= 0 ? 0 : samples / seconds;
  }

  double get packetLossPercent {
    final expected = packets + lostPackets;
    return expected == 0 ? 0 : 100 * lostPackets / expected;
  }

  Duration get streamUptime {
    final start = streamStartedAt;
    return start == null ? Duration.zero : _clock().difference(start);
  }

  /// Called on disconnect: a new stream starts its own rate/loss statistics
  /// and the time across the gap is not counted as an update interval.
  void endStream() {
    streamStartedAt = null;
    lastPacketAt = null;
    _lastSequence = null;
    _lastHarAt = null;
    _lastSocialAt = null;
    _offsetsMs.clear();
    changeEstimator.clear();
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
    packetToDisplay.reset();
    activityChange.reset();
    socialChange.reset();
    activityUnclear = 0;
    socialUnclear = 0;
    recentChanges.clear();
    harUpdateInterval.reset();
    socialUpdateInterval.reset();
  }
}

/// App-wide instance, written by ble.dart/har.dart/main.dart.
final AppMetrics appMetrics = AppMetrics();
