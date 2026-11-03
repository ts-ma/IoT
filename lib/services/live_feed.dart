import 'dart:async';

import '../har.dart';
import 'social_sample_processor.dart';

/// One new raw HAR result with the phone time it was produced.
class LiveHarEvent {
  LiveHarEvent(this.prediction, DateTime at) : at = at.toUtc();

  final HarPrediction prediction;
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

  void addHar(HarPrediction prediction, {DateTime? at}) {
    _har.add(LiveHarEvent(prediction, at ?? DateTime.now()));
  }

  void addSocial(SocialPredictionEvent event) {
    _social.add(event);
  }
}

/// App-wide instance.
final LivePredictionFeed liveFeed = LivePredictionFeed();
