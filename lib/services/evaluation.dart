import 'dart:convert';
import 'dart:io';

import '../activity_catalog.dart';
import 'user_session.dart';

// Real-time accuracy testing (Coursework 3, "Real-time classification
// accuracy"). A trial is one person performing one known activity (and,
// optionally, one known social signal) for a fixed time while the app records
// two things:
//   shown  what the screen displayed after each RESpeck packet (every 2.56 s):
//          the activity after smoothing (if on) and the social signal, or
//          "paused"/"none" when no social signal was on screen. This is what
//          CW3 asks for ("how many times the correct classification result is
//          shown on your app") and is the main figure.
//   raw    every model result (every update step), before smoothing. Several
//          raw results are made per packet but only the last reaches the
//          screen; kept for the critical analysis (smoothing, model vs app).
// Scoring follows the coursework's offline scheme: accuracy per class, then
// the mean over the classes of each group, so classes with more trials do not
// carry more weight.

/// Recorded in the shown social list when the social card showed no social
/// signal (paused because the shown activity was a movement, or no result).
/// Always counted as wrong.
const String socialPausedLabel = 'paused';
const String socialNoneLabel = 'none';

/// The most common label, ties broken by the label seen first. Null if empty.
String? majorityLabel(List<String> labels) {
  if (labels.isEmpty) return null;
  final counts = <String, int>{};
  for (final l in labels) {
    counts[l] = (counts[l] ?? 0) + 1;
  }
  var best = labels.first;
  for (final l in labels) {
    if (counts[l]! > counts[best]!) best = l;
  }
  return best;
}

class EvaluationTrial {
  EvaluationTrial({
    required this.participant,
    required this.trueActivity,
    this.trueSocial,
    required DateTime startedAt,
    required this.durationSeconds,
    required this.settleSeconds,
    int? socialSettleSeconds,
    required this.harPredictions,
    required this.socialPredictions,
    this.harLatency,
    this.harShownLatency,
    this.socialLatency,
    this.socialShownLatency,
    this.rawFile,
    List<double>? harConfidences,
    List<double>? socialConfidences,
    List<String>? harShown,
    List<double>? harShownConfidences,
    List<String>? socialShown,
    List<double?>? socialShownConfidences,
    this.stepSamples,
    this.smoothing,
    this.platform,
  })  : startedAt = startedAt.toUtc(),
        socialSettleSeconds = socialSettleSeconds ?? settleSeconds,
        harConfidences = harConfidences ?? const [],
        socialConfidences = socialConfidences ?? const [],
        harShown = harShown ?? const [],
        harShownConfidences = harShownConfidences ?? const [],
        socialShown = socialShown ?? const [],
        socialShownConfidences = socialShownConfidences ?? const [];

  final String participant;
  final String trueActivity;

  /// Null when the trial did not assess social signals (e.g. running).
  final String? trueSocial;
  final DateTime startedAt;
  final int durationSeconds;

  /// HAR predictions finishing within this many seconds of the start are not
  /// scored: their window still contains data from before the trial.
  final int settleSeconds;

  /// The same for Social predictions, whose window is longer (8 s). Trials
  /// saved before this field existed fall back to [settleSeconds].
  final int socialSettleSeconds;

  /// Scored raw predictions (every model result), in order.
  final List<String> harPredictions;
  final List<String> socialPredictions;

  /// Model confidence (top-class probability) of each raw prediction, same
  /// order. Empty for trials saved before confidences were recorded.
  final List<double> harConfidences;
  final List<double> socialConfidences;

  /// What the screen showed after each scored packet update (see the file
  /// comment), with its confidence. Social entries may be [socialPausedLabel]
  /// or [socialNoneLabel] (confidence null). Empty for older trials.
  final List<String> harShown;
  final List<double> harShownConfidences;
  final List<String> socialShown;
  final List<double?> socialShownConfidences;

  /// Settings in force: update step (samples), activity smoothing, and
  /// "ios"/"android". Null for older trials.
  final int? stepSamples;
  final bool? smoothing;
  final String? platform;

  /// Start of trial until the first correct prediction (scored or not): the
  /// observed end-to-end latency, including the model's window length.
  final Duration? harLatency;
  final Duration? socialLatency;

  /// Start of trial until the screen first SHOWED the true activity / social
  /// signal (after a packet update): what a user sees. Null for older trials.
  final Duration? harShownLatency;
  final Duration? socialShownLatency;

  /// Raw sensor CSV saved for this trial in the user's raw/ folder, if any.
  final String? rawFile;

  int get harCorrect => harPredictions.where((p) => p == trueActivity).length;

  int get socialCorrect => trueSocial == null
      ? 0
      : socialPredictions.where((p) => p == trueSocial).length;

  double? get harAccuracy =>
      harPredictions.isEmpty ? null : harCorrect / harPredictions.length;

  double? get socialAccuracy => trueSocial == null || socialPredictions.isEmpty
      ? null
      : socialCorrect / socialPredictions.length;

  String? get harMajority => majorityLabel(harPredictions);
  String? get socialMajority => majorityLabel(socialPredictions);

  int get harShownCorrect => harShown.where((p) => p == trueActivity).length;
  int get socialShownCorrect =>
      trueSocial == null ? 0 : socialShown.where((p) => p == trueSocial).length;

  double? get harShownAccuracy =>
      harShown.isEmpty ? null : harShownCorrect / harShown.length;
  double? get socialShownAccuracy => trueSocial == null || socialShown.isEmpty
      ? null
      : socialShownCorrect / socialShown.length;

  String? get harShownMajority => majorityLabel(harShown);
  String? get socialShownMajority => majorityLabel(socialShown);

  double? get harMeanConfidence => _meanD(harConfidences);
  double? get socialMeanConfidence => _meanD(socialConfidences);
  double? get harShownMeanConfidence => _meanD(harShownConfidences);
  double? get socialShownMeanConfidence =>
      _meanD(socialShownConfidences.whereType<double>());

  static double? _meanD(Iterable<double> v) {
    final l = v.toList();
    return l.isEmpty ? null : l.reduce((a, b) => a + b) / l.length;
  }

  Map<String, Object?> toJson() => {
        'participant': participant,
        'trueActivity': trueActivity,
        'trueSocial': trueSocial,
        'startedAt': startedAt.toIso8601String(),
        'durationSeconds': durationSeconds,
        'settleSeconds': settleSeconds,
        'socialSettleSeconds': socialSettleSeconds,
        'harPredictions': harPredictions,
        'socialPredictions': socialPredictions,
        'harLatencyMs': harLatency?.inMilliseconds,
        'harShownLatencyMs': harShownLatency?.inMilliseconds,
        'socialLatencyMs': socialLatency?.inMilliseconds,
        'socialShownLatencyMs': socialShownLatency?.inMilliseconds,
        'rawFile': rawFile,
        'harConfidences': harConfidences,
        'socialConfidences': socialConfidences,
        'harShown': harShown,
        'harShownConfidences': harShownConfidences,
        'socialShown': socialShown,
        'socialShownConfidences': socialShownConfidences,
        'stepSamples': stepSamples,
        'smoothing': smoothing,
        'platform': platform,
      };

  factory EvaluationTrial.fromJson(Map<String, dynamic> json) {
    Duration? ms(Object? v) =>
        v == null ? null : Duration(milliseconds: (v as num).toInt());
    List<String>? strings(Object? v) =>
        v == null ? null : List<String>.from(v as List);
    List<double>? doubles(Object? v) =>
        v == null ? null : [for (final x in v as List) (x as num).toDouble()];
    return EvaluationTrial(
      participant: json['participant'] as String,
      trueActivity: json['trueActivity'] as String,
      trueSocial: json['trueSocial'] as String?,
      startedAt: DateTime.parse(json['startedAt'] as String),
      durationSeconds: (json['durationSeconds'] as num).toInt(),
      settleSeconds: (json['settleSeconds'] as num).toInt(),
      socialSettleSeconds: (json['socialSettleSeconds'] as num?)?.toInt(),
      harPredictions: List<String>.from(json['harPredictions'] as List),
      socialPredictions: List<String>.from(json['socialPredictions'] as List),
      harLatency: ms(json['harLatencyMs']),
      harShownLatency: ms(json['harShownLatencyMs']),
      socialLatency: ms(json['socialLatencyMs']),
      socialShownLatency: ms(json['socialShownLatencyMs']),
      rawFile: json['rawFile'] as String?,
      harConfidences: doubles(json['harConfidences']),
      socialConfidences: doubles(json['socialConfidences']),
      harShown: strings(json['harShown']),
      harShownConfidences: doubles(json['harShownConfidences']),
      socialShown: strings(json['socialShown']),
      socialShownConfidences: json['socialShownConfidences'] == null
          ? null
          : [
              for (final x in json['socialShownConfidences'] as List)
                (x as num?)?.toDouble()
            ],
      stepSamples: (json['stepSamples'] as num?)?.toInt(),
      smoothing: json['smoothing'] as bool?,
      platform: json['platform'] as String?,
    );
  }
}

/// Aggregated result for one true class.
class ClassScore {
  ClassScore(this.label);

  final String label;
  int trials = 0;
  int windows = 0;
  int correct = 0;

  /// Trials whose most common raw prediction was correct.
  int majorityCorrect = 0;

  /// Screen updates scored / correct (what the app showed).
  int shown = 0;
  int shownCorrect = 0;

  /// Trials whose most common SHOWN result was correct (trials with screen
  /// data only; [shownTrials] counts them).
  int shownTrials = 0;
  int shownMajorityCorrect = 0;
  final List<double> confidences = [];
  final List<Duration> latencies = [];

  /// Latency until the true class was shown on screen.
  final List<Duration> shownLatencies = [];

  /// Raw accuracy: correct model results / model results.
  double? get accuracy => windows == 0 ? null : correct / windows;

  /// Shown accuracy: correct screen updates / screen updates (main figure).
  double? get shownAccuracy => shown == 0 ? null : shownCorrect / shown;

  double? get shownMajorityAccuracy =>
      shownTrials == 0 ? null : shownMajorityCorrect / shownTrials;

  double? get meanConfidence => confidences.isEmpty
      ? null
      : confidences.reduce((a, b) => a + b) / confidences.length;

  double? get majorityAccuracy => trials == 0 ? null : majorityCorrect / trials;

  Duration? get meanLatency => _meanOf(latencies);
  Duration? get meanShownLatency => _meanOf(shownLatencies);

  static Duration? _meanOf(List<Duration> values) => values.isEmpty
      ? null
      : Duration(
          microseconds: values.fold<int>(0, (a, d) => a + d.inMicroseconds) ~/
              values.length);
}

class EvaluationSummary {
  EvaluationSummary._(this.scores);

  /// Every class (HAR then Social, in model order) that has been tested.
  final List<ClassScore> scores;

  factory EvaluationSummary.from(List<EvaluationTrial> trials) {
    final byLabel = <String, ClassScore>{};
    void add(String label, List<String> predictions, List<String> shown,
        List<double> confidences, Duration? latency, Duration? shownLatency) {
      final score = byLabel.putIfAbsent(label, () => ClassScore(label));
      score.trials++;
      score.windows += predictions.length;
      score.correct += predictions.where((p) => p == label).length;
      if (majorityLabel(predictions) == label) score.majorityCorrect++;
      if (shown.isNotEmpty) {
        score.shownTrials++;
        score.shown += shown.length;
        score.shownCorrect += shown.where((p) => p == label).length;
        if (majorityLabel(shown) == label) score.shownMajorityCorrect++;
      }
      score.confidences.addAll(confidences);
      if (latency != null) score.latencies.add(latency);
      if (shownLatency != null) score.shownLatencies.add(shownLatency);
    }

    for (final t in trials) {
      add(t.trueActivity, t.harPredictions, t.harShown, t.harConfidences,
          t.harLatency, t.harShownLatency);
      final social = t.trueSocial;
      if (social != null) {
        add(social, t.socialPredictions, t.socialShown, t.socialConfidences,
            t.socialLatency, t.socialShownLatency ?? t.socialLatency);
      }
    }
    final order = [...harClassOrder, ...socialClassOrder];
    final scores = byLabel.values.toList()
      ..sort((a, b) {
        int rank(String l) {
          final i = order.indexOf(l);
          return i < 0 ? order.length : i;
        }

        return rank(a.label).compareTo(rank(b.label));
      });
    return EvaluationSummary._(scores);
  }

  Iterable<ClassScore> inGroup(LabelGroup group) =>
      scores.where((s) => labelInfo(s.label).group == group);

  /// Mean of the per-class RAW accuracies within [group] (coursework scheme).
  double? groupMean(LabelGroup group) =>
      _mean(inGroup(group).map((s) => s.accuracy));

  /// Mean of all per-class raw accuracies.
  double? get overallMean => _mean(scores.map((s) => s.accuracy));

  /// The same for what the screen showed (the main real-time figure).
  double? groupShownMean(LabelGroup group) =>
      _mean(inGroup(group).map((s) => s.shownAccuracy));
  double? get overallShownMean => _mean(scores.map((s) => s.shownAccuracy));

  int get totalWindows => scores.fold(0, (a, s) => a + s.windows);
  int get totalCorrect => scores.fold(0, (a, s) => a + s.correct);
  int get totalShown => scores.fold(0, (a, s) => a + s.shown);
  int get totalShownCorrect => scores.fold(0, (a, s) => a + s.shownCorrect);

  static double? _mean(Iterable<double?> values) {
    final present = values.whereType<double>().toList();
    if (present.isEmpty) return null;
    return present.reduce((a, b) => a + b) / present.length;
  }
}

String _csv(Object? value) {
  final text = value?.toString() ?? '';
  return text.contains(RegExp('[",\n]'))
      ? '"${text.replaceAll('"', '""')}"'
      : text;
}

String _pct(double? v) => v == null ? '' : (v * 100).toStringAsFixed(1);
String _secs(Duration? d) =>
    d == null ? '' : (d.inMilliseconds / 1000).toStringAsFixed(1);

/// One row per trial: the "table of activities performed and classification
/// results" requested for the report.
String trialsToCsv(List<EvaluationTrial> trials) {
  final b = StringBuffer(
      'participant,started_utc,duration_s,settle_s,true_activity,har_windows,'
      'har_correct,har_accuracy_pct,har_majority,har_latency_s,true_social,'
      'social_windows,social_correct,social_accuracy_pct,social_majority,'
      'social_latency_s,har_predictions,social_predictions,social_settle_s,'
      'raw_file,har_shown_latency_s,har_shown_updates,har_shown_correct,'
      'har_shown_accuracy_pct,har_shown_majority,har_mean_confidence_pct,'
      'har_shown_mean_confidence_pct,social_shown_updates,'
      'social_shown_correct,social_shown_accuracy_pct,social_shown_majority,'
      'social_shown_latency_s,social_mean_confidence_pct,'
      'social_shown_mean_confidence_pct,har_shown,social_shown,'
      'har_confidences,social_confidences,step_samples,smoothing,platform\n');
  for (final t in trials) {
    b.writeln([
      t.participant,
      t.startedAt.toIso8601String(),
      t.durationSeconds,
      t.settleSeconds,
      t.trueActivity,
      t.harPredictions.length,
      t.harCorrect,
      _pct(t.harAccuracy),
      t.harMajority ?? '',
      _secs(t.harLatency),
      t.trueSocial ?? '',
      t.trueSocial == null ? '' : t.socialPredictions.length,
      t.trueSocial == null ? '' : t.socialCorrect,
      _pct(t.socialAccuracy),
      t.trueSocial == null ? '' : (t.socialMajority ?? ''),
      _secs(t.socialLatency),
      t.harPredictions.join(' '),
      t.socialPredictions.join(' '),
      t.socialSettleSeconds,
      t.rawFile ?? '',
      _secs(t.harShownLatency),
      t.harShown.length,
      t.harShownCorrect,
      _pct(t.harShownAccuracy),
      t.harShownMajority ?? '',
      _pct(t.harMeanConfidence),
      _pct(t.harShownMeanConfidence),
      t.trueSocial == null ? '' : t.socialShown.length,
      t.trueSocial == null ? '' : t.socialShownCorrect,
      _pct(t.socialShownAccuracy),
      t.trueSocial == null ? '' : (t.socialShownMajority ?? ''),
      _secs(t.socialShownLatency),
      _pct(t.socialMeanConfidence),
      _pct(t.socialShownMeanConfidence),
      t.harShown.join(' '),
      t.socialShown.join(' '),
      t.harConfidences.map((c) => c.toStringAsFixed(3)).join(' '),
      t.socialConfidences.map((c) => c.toStringAsFixed(3)).join(' '),
      t.stepSamples ?? '',
      t.smoothing == null ? '' : (t.smoothing! ? 1 : 0),
      t.platform ?? '',
    ].map(_csv).join(','));
  }
  return b.toString();
}

/// Confusion matrices of the real-time test (rows = true class, columns =
/// result), counted over every scored result: activity shown, activity raw,
/// social shown (incl. "paused"/"none" columns) and social raw.
String confusionToCsv(List<EvaluationTrial> trials) {
  final b = StringBuffer();
  void matrix(String title, List<String> rows, List<String> cols,
      Iterable<(String, List<String>)> pairs) {
    final counts = <String, Map<String, int>>{};
    final extra = <String>[];
    for (final (truth, results) in pairs) {
      for (final r in results) {
        if (!cols.contains(r) && !extra.contains(r)) extra.add(r);
        final row = counts.putIfAbsent(truth, () => {});
        row[r] = (row[r] ?? 0) + 1;
      }
    }
    final allCols = [...cols, ...extra];
    b.writeln(title);
    b.writeln(['true \\ result', ...allCols, 'total', 'accuracy_pct']
        .map(_csv)
        .join(','));
    for (final r in rows) {
      final row = counts[r];
      if (row == null) continue;
      final total = row.values.fold<int>(0, (a, v) => a + v);
      b.writeln([
        r,
        for (final c in allCols) row[c] ?? 0,
        total,
        _pct(total == 0 ? null : (row[r] ?? 0) / total),
      ].map(_csv).join(','));
    }
    b.writeln();
  }

  matrix('Activity - shown on screen', harClassOrder, harClassOrder,
      [for (final t in trials) (t.trueActivity, t.harShown)]);
  matrix('Activity - raw model results', harClassOrder, harClassOrder,
      [for (final t in trials) (t.trueActivity, t.harPredictions)]);
  matrix('Social - shown on screen', socialClassOrder, [
    ...socialClassOrder,
    socialPausedLabel,
    socialNoneLabel
  ], [
    for (final t in trials)
      if (t.trueSocial != null) (t.trueSocial!, t.socialShown)
  ]);
  matrix('Social - raw model results', socialClassOrder, socialClassOrder, [
    for (final t in trials)
      if (t.trueSocial != null) (t.trueSocial!, t.socialPredictions)
  ]);
  return b.toString();
}

/// Per-class and per-group accuracy, ready for the report's results table.
String summaryToCsv(EvaluationSummary summary) {
  final b = StringBuffer('group,class,trials,windows,correct,accuracy_pct,'
      'majority_correct_trials,mean_latency_s,mean_shown_latency_s,'
      'shown_updates,shown_correct,shown_accuracy_pct,shown_trials,'
      'shown_majority_correct_trials,mean_confidence_pct\n');
  for (final s in summary.scores) {
    b.writeln([
      labelInfo(s.label).group.title,
      s.label,
      s.trials,
      s.windows,
      s.correct,
      _pct(s.accuracy),
      s.majorityCorrect,
      _secs(s.meanLatency),
      _secs(s.meanShownLatency),
      s.shown,
      s.shownCorrect,
      _pct(s.shownAccuracy),
      s.shownTrials,
      s.shownMajorityCorrect,
      _pct(s.meanConfidence),
    ].map(_csv).join(','));
  }
  for (final g in LabelGroup.values) {
    b.writeln([
      g.title, 'MEAN', '', '', '', _pct(summary.groupMean(g)), '', '', '', //
      '', '', _pct(summary.groupShownMean(g)), '', '', '',
    ].map(_csv).join(','));
  }
  b.writeln([
    'All',
    'MEAN',
    '',
    summary.totalWindows,
    summary.totalCorrect,
    _pct(summary.overallMean),
    '',
    '',
    '',
    summary.totalShown,
    summary.totalShownCorrect,
    _pct(summary.overallShownMean),
    '',
    '',
    '',
  ].map(_csv).join(','));
  return b.toString();
}

/// Persists trials as JSON in the logged-in user's folder
/// (realtime_trials.json), so a test session can span several app launches.
class EvaluationStore {
  EvaluationStore({Future<File> Function()? file})
      : _file = file ?? _defaultFile;

  final Future<File> Function() _file;

  static Future<File> _defaultFile() async {
    final file = userSession.trialsFile;
    if (file == null) throw StateError('Log in to keep real-time trials');
    return file;
  }

  Future<List<EvaluationTrial>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final data = jsonDecode(await file.readAsString());
    return [
      for (final t in data as List)
        EvaluationTrial.fromJson(t as Map<String, dynamic>),
    ];
  }

  Future<void> save(List<EvaluationTrial> trials) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode([for (final t in trials) t.toJson()]),
      flush: true,
    );
  }
}
