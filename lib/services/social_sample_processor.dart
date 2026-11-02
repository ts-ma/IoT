import 'package:flutter/foundation.dart';

import '../social.dart';

/// One NEW inference, never a cached UI result. Completion time is phone UTC,
/// not the sensor timestamp or the start/end time of the four-second window.
class SocialPredictionEvent {
  SocialPredictionEvent({
    required this.prediction,
    required DateTime completedAt,
    required this.processingDuration,
  }) : completedAt = completedAt.toUtc();

  final SocialPrediction prediction;
  final DateTime completedAt;

  /// Time spent in addSample for the call that completed this inference,
  /// including window maintenance. Excludes event delivery and database work.
  final Duration processingDuration;
}

/// Social-only adapter for decoded BLE samples. Owns no interpreter or BLE
/// connection. The app supplies the already-loaded Stage 4C classifier.
class SocialSampleProcessor {
  SocialSampleProcessor({
    required SocialClassifier? Function() classifier,
    void Function(SocialPredictionEvent)? onPrediction,
    void Function(Object, StackTrace)? onError,
    DateTime Function()? clock,
  })  : _classifier = classifier,
        _onPrediction = onPrediction,
        _onError = onError,
        _clock = clock ?? DateTime.now;

  final SocialClassifier? Function() _classifier;
  final void Function(SocialPredictionEvent)? _onPrediction;
  final void Function(Object, StackTrace)? _onError;
  final DateTime Function() _clock;
  bool _active = false;
  bool _failed = false;

  bool get isActive => _active;
  bool get failed => _failed;
  int inferenceCount = 0;
  int errorCount = 0;
  int deliveryErrorCount = 0;
  Duration? lastInferenceDuration;
  Duration maxInferenceDuration = Duration.zero;
  Object? lastError;

  /// A fresh sensor session always requires a full window. Reconnection also
  /// permits another attempt after a previous session's inference failure.
  void startSession() {
    _active = true;
    _failed = false;
    _reset();
  }

  void endSession() {
    _active = false;
    _reset();
  }

  /// For a confirmed notification-stream error; does not reset HAR or guess
  /// packet-loss semantics. No result is retained or replayed across this gap.
  void resetStream() => _reset();

  void _reset() {
    try {
      _classifier()?.reset();
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  /// Synchronous, independent of recording. Callbacks should only update state
  /// or enqueue work; never do synchronous I/O here. No result is deduplicated
  /// by label, and every non-null result is delivered before the next sample.
  void addSample(double x, double y, double z) {
    if (!_active || _failed) return;
    SocialPredictionEvent event;
    try {
      final classifier = _classifier();
      if (classifier == null) {
        return; // Startup failure/unavailable: HAR proceeds.
      }
      final timer = Stopwatch()..start();
      final prediction = classifier.addSample(x, y, z);
      timer.stop();
      if (prediction == null) return;
      final completedAt = _clock(); // Capture before observers or async work.
      lastInferenceDuration = timer.elapsed;
      if (timer.elapsed > maxInferenceDuration) {
        maxInferenceDuration = timer.elapsed;
      }
      inferenceCount++;
      event = SocialPredictionEvent(
        prediction: prediction,
        completedAt: completedAt,
        processingDuration: timer.elapsed,
      );
    } catch (error, stack) {
      // Do not repeatedly throw/log on every subsequent sample. HAR and CSV
      // continue; reconnecting starts Social with a fresh window and retry.
      _fail(error, stack);
      return;
    }
    try {
      _onPrediction?.call(event);
    } catch (error, stack) {
      // An observer failure must not abort the packet or suppress later results.
      deliveryErrorCount++;
      _report(error, stack);
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (_failed) return;
    _failed = true;
    errorCount++;
    _report(error, stack);
  }

  void _report(Object error, StackTrace stack) {
    lastError = error;
    try {
      if (_onError != null) {
        _onError(error, stack);
      } else {
        debugPrint('Social stream processing failed: $error');
      }
    } catch (_) {
      // Even a diagnostic callback must not interrupt BLE/HAR/CSV processing.
    }
  }
}
