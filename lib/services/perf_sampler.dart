import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'app_metrics.dart';
import 'device_stats.dart';
import 'sensor_controller.dart';
import 'user_session.dart';

/// One reading per second of everything the Performance tab plots.
class PerfSample {
  PerfSample({
    required this.time,
    this.cpuPercent,
    this.rssMb,
    this.phoneLevel,
    this.phoneCharging,
    this.phoneCurrentMa,
    this.phonePowerMw,
    this.respeckLevel,
    this.harMs,
    this.socialMs,
    this.sampleRateHz,
    this.lostPackets,
    this.storageMb,
    this.streaming,
    this.activityShown,
    this.socialStatus,
    this.packetDelayMs,
    this.packetIntervalS,
    this.packetToDisplayMs,
    this.activityChangeS,
    this.socialChangeS,
  });

  final DateTime time;

  /// Process CPU use since the previous sample, % of one core.
  final double? cpuPercent;
  final double? rssMb;
  final int? phoneLevel;
  final bool? phoneCharging;
  final double? phoneCurrentMa;
  final double? phonePowerMw;
  final int? respeckLevel;

  /// Mean model call time of the results made in this second (null if none).
  final double? harMs;
  final double? socialMs;

  /// Samples received from the RESpeck in this second (nominal 12.5).
  final double? sampleRateHz;
  final int? lostPackets;

  /// Size of the user's folder (history, raw data, exports, logs).
  final double? storageMb;

  /// Test conditions per second, so a log can be split into "sensor streaming
  /// / idle" and "moving (social paused) / still" when reporting power & CPU.
  final bool? streaming;
  final String? activityShown;

  /// SocialPredictionStatus name, e.g. ready or pausedMoving.
  final String? socialStatus;

  /// RESpeck -> phone delay above the fastest recent packet (mean of the
  /// packets in this second; see AppMetrics.packetExtraDelay).
  final double? packetDelayMs;

  /// Time since the previous packet, for the packets in this second.
  final double? packetIntervalS;

  /// Packet arrival -> results handed to the display (mean this second).
  final double? packetToDisplayMs;

  /// Live time to show a change, for switches shown in this second.
  final double? activityChangeS;
  final double? socialChangeS;

  static const csvHeader = 'local_time,cpu_percent_one_core,rss_mb,'
      'phone_battery_pct,phone_charging,phone_current_ma,phone_power_mw,'
      'respeck_battery_pct,har_inference_ms,social_inference_ms,'
      'sample_rate_hz,lost_packets_total,storage_mb,streaming,'
      'activity_shown,social_status,respeck_extra_delay_ms,packet_interval_s,'
      'packet_to_display_ms,activity_change_shown_s,social_change_shown_s';

  String toCsv() {
    String f(num? v, [int digits = 2]) =>
        v == null ? '' : v.toStringAsFixed(digits);
    return [
      DateFormat('yyyy-MM-dd HH:mm:ss').format(time),
      f(cpuPercent),
      f(rssMb, 1),
      phoneLevel ?? '',
      phoneCharging == null ? '' : (phoneCharging! ? 1 : 0),
      f(phoneCurrentMa, 1),
      f(phonePowerMw, 1),
      respeckLevel ?? '',
      f(harMs, 3),
      f(socialMs, 3),
      f(sampleRateHz, 2),
      lostPackets ?? '',
      f(storageMb, 3),
      streaming == null ? '' : (streaming! ? 1 : 0),
      activityShown ?? '',
      socialStatus ?? '',
      f(packetDelayMs, 0),
      f(packetIntervalS, 3),
      f(packetToDisplayMs, 2),
      f(activityChangeS, 2),
      f(socialChangeS, 2),
    ].join(',');
  }
}

/// Bytes used in the user's folder, by kind.
class StorageStats {
  StorageStats({
    this.database = 0,
    this.raw = 0,
    this.rawFiles = 0,
    this.exports = 0,
    this.performance = 0,
    this.other = 0,
  });

  int database;
  int raw;
  int rawFiles;
  int exports;
  int performance;
  int other;

  int get total => database + raw + exports + performance + other;

  static Future<StorageStats> scan(Directory? userDir) async {
    final s = StorageStats();
    if (userDir == null || !await userDir.exists()) return s;
    await for (final e in userDir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      int size;
      try {
        size = await e.length();
      } catch (_) {
        continue;
      }
      final rel = p.relative(e.path, from: userDir.path);
      final top = p.split(rel).first;
      if (top == 'raw') {
        s.raw += size;
        s.rawFiles++;
      } else if (top == 'exports') {
        s.exports += size;
      } else if (top == 'performance') {
        s.performance += size;
      } else if (top.startsWith('history.db')) {
        s.database += size; // includes -wal / -journal files
      } else {
        s.other += size;
      }
    }
    return s;
  }
}

/// Samples CPU, memory, batteries, model timing and storage once a second,
/// keeps the last [capacity] samples for the live graphs and can log every
/// sample to `<user>/performance/` for the report.
class PerfSampler extends ChangeNotifier {
  PerfSampler({
    this.sensor,
    UserSession? session,
    AppMetrics? metrics,
    CpuClock? cpu,
    PowerChannel? power,
    this.capacity = 300,
    this.interval = const Duration(seconds: 1),
  })  : _session = session ?? userSession,
        _metrics = metrics ?? appMetrics,
        _cpu = cpu,
        _power = power ?? PowerChannel();

  final SensorController? sensor;
  final UserSession _session;
  final AppMetrics _metrics;
  final CpuClock? _cpu;
  final PowerChannel _power;
  final int capacity;
  final Duration interval;

  final Queue<PerfSample> _samples = Queue();
  List<PerfSample> get samples => List.unmodifiable(_samples);
  PerfSample? get latest => _samples.isEmpty ? null : _samples.last;

  Timer? _timer;
  int _ticks = 0;
  bool _busy = false;

  double? _lastCpu;
  DateTime? _lastCpuAt;
  int _lastHarCount = 0, _lastSocialCount = 0;
  int _lastHarTotalUs = 0, _lastSocialTotalUs = 0;
  int _lastDelayCount = 0, _lastDelayTotalUs = 0;
  int _lastIntervalCount = 0, _lastIntervalTotalUs = 0;
  int _lastProcCount = 0, _lastProcTotalUs = 0;
  int _lastActChangeCount = 0, _lastActChangeTotalUs = 0;
  int _lastSocChangeCount = 0, _lastSocChangeTotalUs = 0;
  int _lastSamples = 0;
  DateTime? _lastSamplesAt;
  PhoneBattery? _battery;

  /// First battery readings since the sampler started, for drain rates.
  ({DateTime at, int level})? _phoneStart;
  ({DateTime at, int level})? _respeckStart;

  StorageStats storage = StorageStats();

  /// Where the CPU figure comes from (shown on the page).
  String get cpuSource => (_cpu ?? CpuClock.instance).source;
  int get cores => Platform.numberOfProcessors;

  IOSink? _log;
  File? _logFile;
  DateTime? _logStarted;

  /// Called when a log starts/stops for the settings in force (update
  /// interval, smoothing, models). Set by the app; tests leave it null.
  Map<String, Object?> Function()? describeSettings;

  /// `<log>.conditions.json` next to the CSV: what the report has to state
  /// about how performance was measured (platform, OS, app version, settings,
  /// start/end and duration). The phone model is not readable without an
  /// extra plugin - note it by hand.
  Future<void> _writeConditions({DateTime? ended}) async {
    final file = _logFile;
    final started = _logStarted;
    if (file == null || started == null) return;
    try {
      final info = <String, Object?>{
        'log_file': p.basename(file.path),
        'platform': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'cpu_cores': Platform.numberOfProcessors,
        'cpu_source': cpuSource,
        'dart': Platform.version.split(' ').first,
        'started': started.toIso8601String(),
        'ended': ended?.toIso8601String(),
        'duration_s': ended?.difference(started).inSeconds,
        'sample_interval_s': interval.inMilliseconds / 1000,
        'classification': 'on the phone (TensorFlow Lite), no server',
        'phone_model': 'fill in by hand',
        ...?describeSettings?.call(),
      };
      final out =
          File(file.path.replaceFirst(RegExp(r'\.csv$'), '.conditions.json'));
      await out.writeAsString(const JsonEncoder.withIndent('  ').convert(info),
          flush: true);
    } catch (e) {
      debugPrint('Could not write the log conditions: $e');
    }
  }

  bool get logging => _log != null;
  File? get logFile => _logFile;

  bool get running => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(sample()));
    unawaited(sample());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Takes one sample now (the timer calls this every [interval]).
  Future<void> sample() async {
    if (_busy) return;
    _busy = true;
    try {
      final now = DateTime.now();
      final cpu = (_cpu ?? CpuClock.instance).read();
      double? cpuPercent;
      if (cpu != null && _lastCpu != null && _lastCpuAt != null) {
        final wall = now.difference(_lastCpuAt!).inMicroseconds / 1e6;
        if (wall > 0) cpuPercent = 100 * (cpu - _lastCpu!) / wall;
      }
      _lastCpu = cpu;
      _lastCpuAt = now;

      final rss = currentRssBytes();

      if (_ticks % 5 == 0) _battery = await _power.read() ?? _battery;
      final b = _battery;
      if (b?.level != null && _phoneStart == null) {
        _phoneStart = (at: now, level: b!.level!);
      }
      final respeck = sensor?.streaming == true ? sensor?.respeckBattery : null;
      if (respeck != null && _respeckStart == null) {
        _respeckStart = (at: now, level: respeck);
      }

      double? meanMs(DurationStat s, int lastCount, int lastTotal) {
        final n = s.count - lastCount;
        if (n <= 0) return null;
        return (s.totalMicros - lastTotal) / n / 1000;
      }

      final harMs =
          meanMs(_metrics.harInference, _lastHarCount, _lastHarTotalUs);
      final socialMs = meanMs(
          _metrics.socialInference, _lastSocialCount, _lastSocialTotalUs);
      _lastHarCount = _metrics.harInference.count;
      _lastHarTotalUs = _metrics.harInference.totalMicros;
      _lastSocialCount = _metrics.socialInference.count;
      _lastSocialTotalUs = _metrics.socialInference.totalMicros;
      final delayMs =
          meanMs(_metrics.packetExtraDelay, _lastDelayCount, _lastDelayTotalUs);
      final intervalMs = meanMs(
          _metrics.packetInterval, _lastIntervalCount, _lastIntervalTotalUs);
      _lastDelayCount = _metrics.packetExtraDelay.count;
      _lastDelayTotalUs = _metrics.packetExtraDelay.totalMicros;
      _lastIntervalCount = _metrics.packetInterval.count;
      _lastIntervalTotalUs = _metrics.packetInterval.totalMicros;
      final procMs =
          meanMs(_metrics.packetToDisplay, _lastProcCount, _lastProcTotalUs);
      final actMs = meanMs(
          _metrics.activityChange, _lastActChangeCount, _lastActChangeTotalUs);
      final socMs = meanMs(
          _metrics.socialChange, _lastSocChangeCount, _lastSocChangeTotalUs);
      _lastProcCount = _metrics.packetToDisplay.count;
      _lastProcTotalUs = _metrics.packetToDisplay.totalMicros;
      _lastActChangeCount = _metrics.activityChange.count;
      _lastActChangeTotalUs = _metrics.activityChange.totalMicros;
      _lastSocChangeCount = _metrics.socialChange.count;
      _lastSocChangeTotalUs = _metrics.socialChange.totalMicros;

      double? rate;
      final streaming = sensor?.streaming ?? false;
      if (streaming && _lastSamplesAt != null) {
        final dt = now.difference(_lastSamplesAt!).inMicroseconds / 1e6;
        final dn = _metrics.samples - _lastSamples;
        if (dt > 0 && dn >= 0) rate = dn / dt;
      }
      _lastSamples = _metrics.samples;
      _lastSamplesAt = now;

      if (_ticks % 15 == 0) {
        storage = await StorageStats.scan(_session.userDir);
      }

      final sample = PerfSample(
        time: now,
        cpuPercent: cpuPercent,
        rssMb: rss == null ? null : rss / (1024 * 1024),
        phoneLevel: b?.level,
        phoneCharging: b?.charging,
        phoneCurrentMa:
            b?.currentMicroA == null ? null : b!.currentMicroA!.abs() / 1000,
        phonePowerMw: b?.powerMilliW,
        respeckLevel: respeck,
        harMs: harMs,
        socialMs: socialMs,
        sampleRateHz: rate,
        lostPackets: streaming ? _metrics.lostPackets : null,
        storageMb: storage.total / (1024 * 1024),
        streaming: sensor == null ? null : streaming,
        activityShown: sensor?.harShown?.label,
        socialStatus: sensor?.socialProcessor?.status.name,
        packetDelayMs: delayMs,
        packetIntervalS: intervalMs == null ? null : intervalMs / 1000,
        packetToDisplayMs: procMs,
        activityChangeS: actMs == null ? null : actMs / 1000,
        socialChangeS: socMs == null ? null : socMs / 1000,
      );
      _samples.addLast(sample);
      while (_samples.length > capacity) {
        _samples.removeFirst();
      }
      _log?.writeln(sample.toCsv());
      _ticks++;
      notifyListeners();
    } catch (e) {
      debugPrint('Performance sample failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// Phone battery drain since sampling started, in % per hour. Null until
  /// 10 minutes have passed and at least 1 % has gone: battery levels move in
  /// 1 % steps, so earlier figures are mostly rounding noise.
  double? get phoneDrainPerHour => _drain(_phoneStart, _battery?.level);
  double? get respeckDrainPerHour =>
      _drain(_respeckStart, sensor?.respeckBattery);

  Duration? get phoneObserved =>
      _phoneStart == null ? null : DateTime.now().difference(_phoneStart!.at);

  double? _drain(({DateTime at, int level})? start, int? now) {
    if (start == null || now == null) return null;
    final dropped = start.level - now;
    final elapsed = DateTime.now().difference(start.at);
    if (dropped < 1 || elapsed < const Duration(minutes: 10)) return null;
    final hours = elapsed.inSeconds / 3600;
    return dropped / hours;
  }

  /// Starts or stops writing every sample to `<user>/performance/`.
  Future<String?> setLogging(bool on) async {
    if (on == logging) return null;
    if (!on) {
      final sink = _log;
      _log = null;
      notifyListeners();
      await sink?.flush();
      await sink?.close();
      await _writeConditions(ended: DateTime.now());
      return null;
    }
    final dir = _session.performanceDir;
    if (dir == null) return 'Log in to save a performance log';
    try {
      final name =
          'perf_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv';
      final file = await UserSession.fileIn(dir, name);
      final sink = file.openWrite();
      sink.done.catchError((Object e) => debugPrint('Perf log error: $e'));
      sink.writeln(PerfSample.csvHeader);
      _log = sink;
      _logFile = file;
      _logStarted = DateTime.now();
      await _writeConditions();
      notifyListeners();
      return null;
    } catch (e) {
      return 'Could not create the performance log';
    }
  }

  /// Clears the graphs and the drain baselines (the Reset button).
  void resetHistory() {
    _samples.clear();
    _phoneStart = null;
    _respeckStart = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    final sink = _log;
    _log = null;
    unawaited(sink?.close());
    super.dispose();
  }
}
