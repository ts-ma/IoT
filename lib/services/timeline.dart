import '../activity_catalog.dart';
import '../models/prediction_record.dart';
import 'prediction_repository.dart';

// Data behind the day timeline: the day is cut into equal time bins, and for
// each bin the app knows how long each activity and social signal was seen.

/// Which part of the day the timeline shows.
enum TimelineRange {
  /// From the hour of the first result to the hour after the last one, so a
  /// short session is not a sliver in a 24 h strip.
  monitored,

  /// Midnight to midnight.
  fullDay,
}

/// Bin sizes the timeline picks from: the smallest that gives at most
/// [maxBins] bins over the range.
const List<Duration> _binSizes = [
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 15),
  Duration(minutes: 30),
];
const int maxBins = 144;

Duration binSizeFor(Duration range) {
  for (final b in _binSizes) {
    if (range.inMicroseconds / b.inMicroseconds <= maxBins) return b;
  }
  return _binSizes.last;
}

class TimelineBin {
  TimelineBin(this.index, this.start, this.end);

  final int index;
  final DateTime start;
  final DateTime end;
  final Map<String, Duration> har = {};
  final Map<String, Duration> social = {};
  final Map<String, int> socialCounts = {};

  Duration get monitored => har.values.fold(Duration.zero, (a, b) => a + b);
  bool get isEmpty => har.isEmpty && social.isEmpty;

  /// Activity seen for the longest time in this bin, or null.
  String? get harLabel => _longest(har);
  String? get socialLabel => _longest(social);

  /// Share of the bin covered by activity results (0..1).
  double get coverage {
    final span = end.difference(start).inMicroseconds;
    return span <= 0 ? 0 : (monitored.inMicroseconds / span).clamp(0.0, 1.0);
  }

  bool get moving =>
      harLabel != null &&
      labelInfo(harLabel!).group == LabelGroup.dynamicActivity;

  static String? _longest(Map<String, Duration> m) {
    String? best;
    for (final e in m.entries) {
      if (best == null || e.value > m[best]!) best = e.key;
    }
    return best;
  }
}

class TimelineData {
  TimelineData({
    required this.start,
    required this.end,
    required this.binSize,
    required this.bins,
    required this.coughBouts,
  });

  /// Local time of the left edge and right edge.
  final DateTime start;
  final DateTime end;
  final Duration binSize;
  final List<TimelineBin> bins;

  /// Separate coughing bouts in the shown range.
  final int coughBouts;

  bool get isEmpty => bins.every((b) => b.isEmpty);

  Duration get monitored => bins.fold(Duration.zero, (a, b) => a + b.monitored);

  Duration groupTime(LabelGroup group) => bins.fold(
      Duration.zero,
      (a, b) =>
          a +
          b.har.entries
              .where((e) => labelInfo(e.key).group == group)
              .fold(Duration.zero, (x, e) => x + e.value));

  /// Activities present, longest first (for the legend).
  List<String> get activities {
    final total = <String, Duration>{};
    for (final b in bins) {
      b.har.forEach((l, d) => total[l] = (total[l] ?? Duration.zero) + d);
    }
    return total.keys.toList()..sort((a, b) => total[b]!.compareTo(total[a]!));
  }
}

/// Loads the timeline of the local calendar day containing [day].
Future<TimelineData> loadTimeline(
  PredictionRepository repo,
  DateTime day, {
  TimelineRange range = TimelineRange.monitored,
}) async {
  final midnight = DateTime(day.year, day.month, day.day);
  final nextMidnight = DateTime(day.year, day.month, day.day + 1);
  var start = midnight;
  var end = nextMidnight;
  if (range == TimelineRange.monitored) {
    final span = await repo.timeRange(start: midnight, end: nextMidnight);
    if (span != null) {
      final first = span.first.toLocal();
      final last = span.last.toLocal();
      start = DateTime(first.year, first.month, first.day, first.hour);
      end = DateTime(last.year, last.month, last.day, last.hour + 1);
      if (end.isAfter(nextMidnight)) end = nextMidnight;
    } else {
      // Nothing saved: an empty working day (08:00-20:00) looks less odd
      // than a full empty 24 h strip.
      start = DateTime(day.year, day.month, day.day, 8);
      end = DateTime(day.year, day.month, day.day, 20);
    }
  }
  final binSize = binSizeFor(end.difference(start));
  final count =
      (end.difference(start).inMicroseconds / binSize.inMicroseconds).ceil();
  final bins = [
    for (var i = 0; i < count; i++)
      TimelineBin(i, start.add(binSize * i), start.add(binSize * (i + 1))),
  ];
  final cells = await repo.timelineBins(start: start, end: end, bin: binSize);
  for (final c in cells) {
    if (c.bin < 0 || c.bin >= bins.length) continue;
    final b = bins[c.bin];
    if (c.taskType == PredictionTaskType.har) {
      b.har[c.label] = (b.har[c.label] ?? Duration.zero) + c.duration;
    } else {
      b.social[c.label] = (b.social[c.label] ?? Duration.zero) + c.duration;
      b.socialCounts[c.label] = (b.socialCounts[c.label] ?? 0) + c.count;
    }
  }
  final coughs = await repo.countEpisodes(
    start: start,
    end: end,
    taskType: PredictionTaskType.social,
    label: 'coughing',
  );
  return TimelineData(
      start: start, end: end, binSize: binSize, bins: bins, coughBouts: coughs);
}
