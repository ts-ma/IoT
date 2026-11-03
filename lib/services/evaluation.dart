import 'dart:convert';
import 'dart:io';

import '../activity_catalog.dart';
import 'user_session.dart';

// Real-time accuracy testing (Coursework 3, "Real-time classification
// accuracy"). A trial is one person performing one known activity (and,
// optionally, one known social signal) for a fixed time while the app records
// every live prediction. Scoring follows the coursework's offline scheme:
// accuracy per class, then the mean over the classes of each group, so
// classes with more trials do not carry more weight.

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
    this.socialLatency,
    this.rawFile,
  })  : startedAt = startedAt.toUtc(),
        socialSettleSeconds = socialSettleSeconds ?? settleSeconds;

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

  /// Scored raw predictions, in order.
  final List<String> harPredictions;
  final List<String> socialPredictions;

  /// Start of trial until the first correct prediction (scored or not): the
  /// observed end-to-end latency, including the model's window length.
  final Duration? harLatency;
  final Duration? socialLatency;

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
        'socialLatencyMs': socialLatency?.inMilliseconds,
        'rawFile': rawFile,
      };

  factory EvaluationTrial.fromJson(Map<String, dynamic> json) {
    Duration? ms(Object? v) =>
        v == null ? null : Duration(milliseconds: (v as num).toInt());
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
      socialLatency: ms(json['socialLatencyMs']),
      rawFile: json['rawFile'] as String?,
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

  /// Trials whose most common prediction was correct.
  int majorityCorrect = 0;
  final List<Duration> latencies = [];

  double? get accuracy => windows == 0 ? null : correct / windows;

  double? get majorityAccuracy => trials == 0 ? null : majorityCorrect / trials;

  Duration? get meanLatency => latencies.isEmpty
      ? null
      : Duration(
          microseconds:
              latencies.fold<int>(0, (a, d) => a + d.inMicroseconds) ~/
                  latencies.length);
}

class EvaluationSummary {
  EvaluationSummary._(this.scores);

  /// Every class (HAR then Social, in model order) that has been tested.
  final List<ClassScore> scores;

  factory EvaluationSummary.from(List<EvaluationTrial> trials) {
    final byLabel = <String, ClassScore>{};
    void add(String label, List<String> predictions, Duration? latency) {
      final score = byLabel.putIfAbsent(label, () => ClassScore(label));
      score.trials++;
      score.windows += predictions.length;
      score.correct += predictions.where((p) => p == label).length;
      if (majorityLabel(predictions) == label) score.majorityCorrect++;
      if (latency != null) score.latencies.add(latency);
    }

    for (final t in trials) {
      add(t.trueActivity, t.harPredictions, t.harLatency);
      final social = t.trueSocial;
      if (social != null) add(social, t.socialPredictions, t.socialLatency);
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

  /// Mean of the per-class accuracies within [group] (coursework scheme).
  double? groupMean(LabelGroup group) =>
      _mean(inGroup(group).map((s) => s.accuracy));

  /// Mean of all per-class accuracies.
  double? get overallMean => _mean(scores.map((s) => s.accuracy));

  int get totalWindows => scores.fold(0, (a, s) => a + s.windows);
  int get totalCorrect => scores.fold(0, (a, s) => a + s.correct);

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
      'raw_file\n');
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
    ].map(_csv).join(','));
  }
  return b.toString();
}

/// Per-class and per-group accuracy, ready for the report's results table.
String summaryToCsv(EvaluationSummary summary) {
  final b = StringBuffer('group,class,trials,windows,correct,accuracy_pct,'
      'majority_correct_trials,mean_latency_s\n');
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
    ].map(_csv).join(','));
  }
  for (final g in LabelGroup.values) {
    b.writeln([g.title, 'MEAN', '', '', '', _pct(summary.groupMean(g)), '', '']
        .map(_csv)
        .join(','));
  }
  b.writeln(['All', 'MEAN', '', summary.totalWindows, summary.totalCorrect,
      _pct(summary.overallMean), '', ''].map(_csv).join(','));
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
