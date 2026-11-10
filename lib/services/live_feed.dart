import 'dart:async';

import '../har.dart';
import 'social_sample_processor.dart';

/// One new raw HAR result with the phone time it was produced, and the result
/// the Home screen shows after it (smoothed when smoothing is on).
class LiveHarEvent {
  LiveHarEvent(this.prediction, DateTime at, {HarPrediction? shown})
      : at = at.toUtc(),
        shown = shown ?? prediction;

  final HarPrediction prediction;
  final HarPrediction shown;
  final DateTime at;
}

/// Fan-out of every NEW raw prediction to screens that need the live stream
/// (the real-time test and the Home timeline). Persistence is handled
/// separately by PredictionHistoryWriter; this class does no I/O.
class LivePredictionFeed {
  final StreamController<LiveHarEvent> _har =
      StreamController<LiveHarEvent>.broadcast();
  final StreamController<SocialPredictionEvent> _social =
      StreamController<SocialPredictionEvent>.broadcast();

  Stream<LiveHarEvent> get harEvents => _har.stream;
  Stream<SocialPredictionEvent> get socialEvents => _social.stream;

  void addHar(HarPrediction prediction, {DateTime? at, HarPrediction? shown}) {
    _har.add(LiveHarEvent(prediction, at ?? DateTime.now(), shown: shown));
  }

  void addSocial(SocialPredictionEvent event) {
    _social.add(event);
  }
}

/// App-wide instance.
final LivePredictionFeed liveFeed = LivePredictionFeed();
