import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../activity_catalog.dart';
import 'live_feed.dart';
import 'social_sample_processor.dart';

// Communication latency measured on the phone (CW3: "How long does it take for
// the classification output to be shown on your mobile app after performing
// the activity?").
//
// A cue-based test: the participant does the FROM class until the app shows
// it, waits a random 2-5 s, and at the cue (vibration + sound + screen) changes
// to the TO class. The app then times, from the cue:
//   first correct  the first raw model result equal to TO
//   shown          the first time the screen showed TO (activity: after the
//                  display smoothing; social results are shown unsmoothed)
//   stable         the start of the first run in which the screen kept TO for
//                  3 s (no flicker back), i.e. a clear change for a user
// All three include the participant's reaction to the cue (typically 0.2-0.4
// s) and the RESpeck's packet wait (one packet = 32 samples = 2.56 s).

enum LatencyTask { activity, social }

enum LatencyPhase { idle, settling, holding, cued, finished }

/// One timed change.
class LatencyRep {
  LatencyRep({
    required this.participant,
    required this.task,
    required this.from,
    required this.to,
    required DateTime cueAt,
    required this.fromReached,
    this.firstCorrect,
    this.shown,
    this.stable,
    this.stepSamples,
    this.smoothing,
  }) : cueAt = cueAt.toUtc();

  final String participant;
  final LatencyTask task;
  final String from;
  final String to;
  final DateTime cueAt;

  /// The screen showed FROM steadily before the cue (otherwise the change
  /// started from an unknown state; such reps are kept but flagged).
  final bool fromReached;
  final Duration? firstCorrect;
  final Duration? shown;
  final Duration? stable;

  /// Update interval and smoothing in force (they change the latency).
  final int? stepSamples;
  final bool? smoothing;

  bool get timedOut => stable == null;

  Map<String, Object?> toJson() => {
        'participant': participant,
        'task': task.name,
        'from': from,
        'to': to,
        'cueAt': cueAt.toIso8601String(),
        'fromReached': fromReached,
        'firstCorrectMs': firstCorrect?.inMilliseconds,
        'shownMs': shown?.inMilliseconds,
        'stableMs': stable?.inMilliseconds,
        'stepSamples': stepSamples,
        'smoothing': smoothing,
      };

  factory LatencyRep.fromJson(Map<String, dynamic> j) {
    Duration? ms(Object? v) =>
        v == null ? null : Duration(milliseconds: (v as num).toInt());
    return LatencyRep(
      participant: j['participant'] as String,
      task: LatencyTask.values.byName(j['task'] as String),
      from: j['from'] as String,
      to: j['to'] as String,
      cueAt: DateTime.parse(j['cueAt'] as String),
      fromReached: j['fromReached'] as bool? ?? true,
      firstCorrect: ms(j['firstCorrectMs']),
      shown: ms(j['shownMs']),
      stable: ms(j['stableMs']),
      stepSamples: (j['stepSamples'] as num?)?.toInt(),
      smoothing: j['smoothing'] as bool?,
    );
  }
}

/// Runs [reps] cued changes FROM -> TO and collects [LatencyRep]s.
class LatencyRun extends ChangeNotifier {
  LatencyRun({
    required this.task,
    required this.from,
    required this.to,
    required this.reps,
    required this.participant,
    required Stream<LiveHarEvent> harEvents,
    required Stream<SocialPredictionEvent> socialEvents,
    this.onCue,
    this.onFinished,
    this.stepSamples,
    this.smoothing,
    DateTime Function()? clock,
    Random? random,
    this.settleFor = const Duration(seconds: 3),
    this.settleTimeout = const Duration(seconds: 30),
    this.minHold = const Duration(seconds: 2),
    this.maxHold = const Duration(seconds: 5),
    this.stableFor = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 30),
  })  : _har = harEvents,
        _social = socialEvents,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random() {
    if (from == to) throw ArgumentError('FROM and TO must differ');
    if (reps < 1) throw ArgumentError.value(reps, 'reps');
  }

  final LatencyTask task;
  final String from;
  final String to;
  final int reps;
  final String participant;
  final void Function()? onCue;
  final void Function(List<LatencyRep>)? onFinished;
  final int? stepSamples;
  final bool? smoothing;
  final Stream<LiveHarEvent> _har;
  final Stream<SocialPredictionEvent> _social;
  final DateTime Function() _clock;
  final Random _random;
  final Duration settleFor, settleTimeout, minHold, maxHold, stableFor, timeout;

  LatencyPhase phase = LatencyPhase.idle;
  final List<LatencyRep> results = [];

  /// What the screen shows now (null until the first result).
  String? shownLabel;
  DateTime? cueAt;
  Duration? firstCorrect, shown;

  StreamSubscription<Object>? _sub;
  Timer? _timer;
  DateTime? _runStart; // start of the current run of the awaited label
  bool _fromReached = false;

  int get currentRep => min(results.length + 1, reps);

  void start() {
    if (phase != LatencyPhase.idle) return;
    _sub = task == LatencyTask.activity
        ? _har.listen((e) => _onResult(e.prediction.label, e.shown.label, e.at))
        : _social.listen((e) => _onResult(e.prediction.label,
            e.prediction.label, e.completedAt));
    _settle();
  }

  void _settle() {
    phase = LatencyPhase.settling;
    cueAt = null;
    firstCorrect = null;
    shown = null;
    _runStart = shownLabel == from ? _clock().toUtc() : null;
    _fromReached = false;
    _timer?.cancel();
    // Do not wait for ever if FROM is never recognised: cue anyway, flagged.
    _timer = Timer(settleTimeout, _hold);
    notifyListeners();
  }

  void _hold() {
    phase = LatencyPhase.holding;
    _timer?.cancel();
    final span = maxHold - minHold;
    final wait = minHold +
        Duration(
            milliseconds: span.inMilliseconds <= 0
                ? 0
                : _random.nextInt(span.inMilliseconds + 1));
    _timer = Timer(wait, _cue);
    notifyListeners();
  }

  void _cue() {
    phase = LatencyPhase.cued;
    cueAt = _clock().toUtc();
    _runStart = null;
    _timer?.cancel();
    _timer = Timer(timeout, () => _finishRep(null));
    try {
      onCue?.call();
    } catch (e) {
      debugPrint('Latency cue failed: $e');
    }
    notifyListeners();
  }

  void _onResult(String raw, String shownNow, DateTime at) {
    shownLabel = shownNow;
    switch (phase) {
      case LatencyPhase.settling:
        if (shownNow == from) {
          _runStart ??= at;
          if (at.difference(_runStart!) >= settleFor) {
            _fromReached = true;
            _hold();
            return;
          }
        } else {
          _runStart = null;
        }
      case LatencyPhase.cued:
        final cue = cueAt!;
        if (at.isBefore(cue)) break;
        if (raw == to) firstCorrect ??= at.difference(cue);
        if (shownNow == to) {
          shown ??= at.difference(cue);
          _runStart ??= at;
          if (at.difference(_runStart!) >= stableFor) {
            _finishRep(_runStart!.difference(cue));
            return;
          }
        } else {
          _runStart = null;
        }
      case LatencyPhase.idle:
      case LatencyPhase.holding:
      case LatencyPhase.finished:
        break;
    }
    notifyListeners();
  }

  void _finishRep(Duration? stable) {
    results.add(LatencyRep(
      participant: participant,
      task: task,
      from: from,
      to: to,
      cueAt: cueAt ?? _clock(),
      fromReached: _fromReached,
      firstCorrect: firstCorrect,
      shown: shown,
      stable: stable,
      stepSamples: stepSamples,
      smoothing: smoothing,
    ));
    if (results.length >= reps) {
      _stop();
      phase = LatencyPhase.finished;
      notifyListeners();
      onFinished?.call(List.unmodifiable(results));
    } else {
      _settle();
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// Stops without saving the rep in progress.
  void cancel() {
    _stop();
    phase = LatencyPhase.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}

/// Summary of the reps of one FROM -> TO change.
class LatencyStats {
  LatencyStats(this.task, this.from, this.to, this.reps);

  final LatencyTask task;
  final String from;
  final String to;
  final List<LatencyRep> reps;

  int get n => reps.length;
  int get timeouts => reps.where((r) => r.timedOut).length;

  static double? mean(Iterable<Duration?> v) {
    final s = v.whereType<Duration>().map((d) => d.inMilliseconds / 1000);
    return s.isEmpty ? null : s.reduce((a, b) => a + b) / s.length;
  }

  static double? median(Iterable<Duration?> v) {
    final s = v
        .whereType<Duration>()
        .map((d) => d.inMilliseconds / 1000)
        .toList()
      ..sort();
    if (s.isEmpty) return null;
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  double? get firstCorrectMean => mean(reps.map((r) => r.firstCorrect));
  double? get shownMean => mean(reps.map((r) => r.shown));
  double? get shownMedian => median(reps.map((r) => r.shown));
  double? get stableMean => mean(reps.map((r) => r.stable));
  double? get stableMedian => median(reps.map((r) => r.stable));

  /// Grouped by task and change, in model class order.
  static List<LatencyStats> of(List<LatencyRep> reps) {
    final map = <String, LatencyStats>{};
    for (final r in reps) {
      map
          .putIfAbsent('${r.task.name}|${r.from}|${r.to}',
              () => LatencyStats(r.task, r.from, r.to, []))
          .reps
          .add(r);
    }
    final order = [...harClassOrder, ...socialClassOrder];
    int rank(String l) => order.contains(l) ? order.indexOf(l) : order.length;
    return map.values.toList()
      ..sort((a, b) => a.task != b.task
          ? a.task.index.compareTo(b.task.index)
          : rank(a.to) != rank(b.to)
              ? rank(a.to).compareTo(rank(b.to))
              : rank(a.from).compareTo(rank(b.from)));
  }
}

String _csv(Object? v) {
  final t = v?.toString() ?? '';
  return t.contains(RegExp('[",\n]')) ? '"${t.replaceAll('"', '""')}"' : t;
}

String _s(Duration? d) =>
    d == null ? '' : (d.inMilliseconds / 1000).toStringAsFixed(2);
String _f(double? v) => v == null ? '' : v.toStringAsFixed(2);

/// One row per timed change (for the report's latency table).
String latencyRepsToCsv(List<LatencyRep> reps) {
  final b = StringBuffer('participant,task,from,to,cue_utc,from_reached,'
      'first_correct_s,shown_s,stable_s,timed_out,update_interval_samples,'
      'smoothing\n');
  for (final r in reps) {
    b.writeln([
      r.participant,
      r.task.name,
      r.from,
      r.to,
      r.cueAt.toIso8601String(),
      r.fromReached ? 1 : 0,
      _s(r.firstCorrect),
      _s(r.shown),
      _s(r.stable),
      r.timedOut ? 1 : 0,
      r.stepSamples ?? '',
      r.smoothing == null ? '' : (r.smoothing! ? 1 : 0),
    ].map(_csv).join(','));
  }
  return b.toString();
}

/// Mean / median per change and per task.
String latencySummaryToCsv(List<LatencyRep> reps) {
  final b = StringBuffer('task,from,to,n,timeouts,first_correct_mean_s,'
      'shown_mean_s,shown_median_s,stable_mean_s,stable_median_s\n');
  void row(String task, String from, String to, List<LatencyRep> r) {
    final s = LatencyStats(LatencyTask.activity, from, to, r);
    b.writeln([
      task,
      from,
      to,
      s.n,
      s.timeouts,
      _f(s.firstCorrectMean),
      _f(s.shownMean),
      _f(s.shownMedian),
      _f(s.stableMean),
      _f(s.stableMedian),
    ].map(_csv).join(','));
  }

  for (final s in LatencyStats.of(reps)) {
    row(s.task.name, s.from, s.to, s.reps);
  }
  for (final t in LatencyTask.values) {
    final r = reps.where((x) => x.task == t).toList();
    if (r.isNotEmpty) row(t.name, 'ALL', 'ALL', r);
  }
  return b.toString();
}

/// Persists reps as JSON in the user's folder (latency_tests.json).
class LatencyStore {
  LatencyStore(this._file);

  final Future<File> Function() _file;

  Future<List<LatencyRep>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    return [
      for (final j in jsonDecode(await f.readAsString()) as List)
        LatencyRep.fromJson(j as Map<String, dynamic>),
    ];
  }

  Future<void> save(List<LatencyRep> reps) async {
    final f = await _file();
    await f.writeAsString(jsonEncode([for (final r in reps) r.toJson()]),
        flush: true);
  }
}
