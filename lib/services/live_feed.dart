import 'dart:async';

import '../activity_catalog.dart';
import '../har.dart';
import 'social_sample_processor.dart';

/// One new raw HAR result with the phone time it was produced.
class LiveHarEvent {
  LiveHarEvent(this.prediction, DateTime at) : at = at.toUtc();

  final HarPrediction prediction;
  final DateTime at;
}

/// Running totals since the app started, shown on the home screen. Every
/// prediction stands for [harPredictionSeconds] of activity.
class SessionStats {
  final Map<String, int> harCounts = {};
  final Map<String, int> socialCounts = {};

  /// Number of separate coughing bouts: consecutive coughing windows are one
  /// bout, so a 10 s cough is counted once rather than five times.
  int coughEpisodes = 0;
  String? _lastSocialLabel;

  int get harPredictions => harCounts.values.fold(0, (a, b) => a + b);
  int get socialPredictions => socialCounts.values.fold(0, (a, b) => a + b);

  Duration get monitoredTime => durationForPredictions(harPredictions);

  Duration durationOf(String label) =>
      durationForPredictions(harCounts[label] ?? 0);

  /// HAR labels ordered by time spent, longest first.
  List<MapEntry<String, int>> get topActivities =>
      harCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  void addHar(String label) {
    harCounts[label] = (harCounts[label] ?? 0) + 1;
  }

  void addSocial(String label) {
    socialCounts[label] = (socialCounts[label] ?? 0) + 1;
    if (label == 'coughing' && _lastSocialLabel != 'coughing') {
      coughEpisodes++;
    }
    _lastSocialLabel = label;
  }

  /// A gap in the data (disconnect) ends any coughing bout in progress.
  void breakRun() => _lastSocialLabel = null;

  void reset() {
    harCounts.clear();
    socialCounts.clear();
    coughEpisodes = 0;
    _lastSocialLabel = null;
  }
}

/// Fan-out of every NEW raw prediction to screens that need the live stream
/// (the real-time evaluation page) and to the session totals. Persistence is
/// handled separately by PredictionHistoryWriter; this class does no I/O.
class LivePredictionFeed {
  final StreamController<LiveHarEvent> _har =
      StreamController<LiveHarEvent>.broadcast();
  final StreamController<SocialPredictionEvent> _social =
      StreamController<SocialPredictionEvent>.broadcast();
  final SessionStats session = SessionStats();

  Stream<LiveHarEvent> get harEvents => _har.stream;
  Stream<SocialPredictionEvent> get socialEvents => _social.stream;

  void addHar(HarPrediction prediction, {DateTime? at}) {
    session.addHar(prediction.label);
    _har.add(LiveHarEvent(prediction, at ?? DateTime.now()));
  }

  void addSocial(SocialPredictionEvent event) {
    session.addSocial(event.prediction.label);
    _social.add(event);
  }
}

/// App-wide instance.
final LivePredictionFeed liveFeed = LivePredictionFeed();
