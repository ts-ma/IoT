import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../har.dart';
import '../models/prediction_record.dart';
import 'prediction_repository.dart';

/// Application-owned, lazy SQLite connection with a bounded FIFO. Failures drop
/// only the affected record: automatic retries could duplicate a committed row.
/// Listen for diagnostics changes, or inspect [errorCount], [droppedRecordCount]
/// and [lastError]. Capacity includes the record currently being written.
class PredictionHistoryWriter extends ChangeNotifier {
  PredictionHistoryWriter({
    Future<PredictionRepository> Function()? openRepository,
    DateTime Function()? clock,
    this.capacity = 256,
  })  : _openRepository = openRepository ?? PredictionRepository.open,
        _clock = clock ?? DateTime.now {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }

  final Future<PredictionRepository> Function() _openRepository;
  final DateTime Function() _clock;
  final int capacity;
  final Queue<PredictionRecord> _queue = Queue();
  PredictionRepository? _repository;
  Future<void>? _draining;
  Future<void>? _shutdown;
  bool _inFlight = false;
  bool _accepting = true;
  bool _disposed = false;

  int errorCount = 0;
  int droppedRecordCount = 0;
  Object? lastError;
  int get pendingCount => _queue.length + (_inFlight ? 1 : 0);

  /// Call with the RAW result of a live addSample, never a cached UI prediction.
  /// The clock is read synchronously before any queue or database awaits.
  void capture(HarPrediction? prediction) {
    if (prediction == null) return;
    final timestamp = _clock().toUtc();
    try {
      enqueue(PredictionRecord(
        taskType: PredictionTaskType.har,
        label: prediction.label,
        timestamp: timestamp,
        confidence: prediction.confidence,
        source: PredictionSource.live,
      ));
    } catch (error) {
      _failure(error, dropped: true);
    }
  }

  /// Returns false if the newest record was dropped due to capacity or shutdown.
  /// Never awaits I/O on the caller's BLE callback.
  bool enqueue(PredictionRecord record) {
    if (!_accepting || pendingCount >= capacity) {
      droppedRecordCount++;
      _report();
      return false;
    }
    _queue.add(record);
    _draining ??= Future<void>.microtask(_drain);
    return true;
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final record = _queue.removeFirst();
        _inFlight = true;
        try {
          _repository ??= await _openRepository();
          await _repository!.insert(record);
        } catch (error) {
          // Failed opening is retried for the next record; failed inserts do
          // not poison the queue. BLE and CSV processing remain independent.
          _failure(error, dropped: true);
        } finally {
          _inFlight = false;
        }
      }
    } finally {
      _draining = null;
    }
  }

  void _failure(Object error, {required bool dropped}) {
    errorCount++;
    if (dropped) droppedRecordCount++;
    lastError = error;
    _report();
  }

  void _report() {
    if (!_disposed) notifyListeners();
  }

  /// Waits until queued writes finish (including handled failures). Check the
  /// counters for losses; flushing does not mean every record was persisted.
  Future<void> flush() async {
    while (_draining != null) {
      await _draining;
    }
  }

  /// Stops accepting records, drains the queue, then closes its own connection.
  Future<void> shutdown() => _shutdown ??= _finish();

  Future<void> _finish() async {
    _accepting = false;
    await flush();
    try {
      await _repository?.close();
    } catch (error) {
      _failure(error, dropped: false);
    } finally {
      _repository = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
