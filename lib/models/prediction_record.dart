enum PredictionTaskType { har, social }

/// Where a result came from. Only live sensor data is classified now (the
/// replay demo mode was removed); kept as a column for future sources.
enum PredictionSource { live }

/// One classified window. Dates are normalized to UTC and stored as epoch
/// microseconds, preserving both ordering and sub-millisecond precision.
class PredictionRecord {
  final int? id;
  final PredictionTaskType taskType;
  final String label;
  final DateTime timestamp;
  final double? confidence;
  final PredictionSource source;
  final DateTime? windowStart;
  final DateTime? windowEnd;

  /// Activity time this result stands for: the update interval in force when
  /// it was produced (Settings can change it). Null for rows saved before
  /// schema v2, which are counted as the original 2 s step.
  final int? intervalMs;

  /// Interval assumed for rows without [intervalMs] (the original 2 s step).
  static const int legacyIntervalMs = 2000;

  int get effectiveIntervalMs => intervalMs ?? legacyIntervalMs;

  PredictionRecord({
    this.id,
    required this.taskType,
    required this.label,
    required DateTime timestamp,
    this.confidence,
    required this.source,
    DateTime? windowStart,
    DateTime? windowEnd,
    this.intervalMs,
  })  : timestamp = timestamp.toUtc(),
        windowStart = windowStart?.toUtc(),
        windowEnd = windowEnd?.toUtc() {
    if (id != null && id! <= 0) {
      throw ArgumentError.value(id, 'id', 'Must be positive when supplied');
    }
    if (label.trim().isEmpty) {
      throw ArgumentError.value(label, 'label', 'Must not be empty');
    }
    if (confidence != null &&
        (!confidence!.isFinite || confidence! < 0 || confidence! > 1)) {
      throw ArgumentError.value(confidence, 'confidence', 'Must be in [0, 1]');
    }
    if (this.windowStart != null &&
        this.windowEnd != null &&
        this.windowEnd!.isBefore(this.windowStart!)) {
      throw ArgumentError('windowEnd must not precede windowStart');
    }
    if (intervalMs != null && intervalMs! <= 0) {
      throw ArgumentError.value(intervalMs, 'intervalMs', 'Must be positive');
    }
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'task_type': taskType.name,
        'label': label,
        'timestamp': timestamp.microsecondsSinceEpoch,
        'confidence': confidence,
        'source': source.name,
        'window_start': windowStart?.microsecondsSinceEpoch,
        'window_end': windowEnd?.microsecondsSinceEpoch,
        'interval_ms': intervalMs,
      };

  factory PredictionRecord.fromMap(Map<String, Object?> map) {
    DateTime? date(Object? value) => value == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(value as int, isUtc: true);

    return PredictionRecord(
      id: map['id'] as int?,
      taskType: PredictionTaskType.values.byName(map['task_type'] as String),
      label: map['label'] as String,
      timestamp: date(map['timestamp'])!,
      confidence: (map['confidence'] as num?)?.toDouble(),
      source: PredictionSource.values.byName(map['source'] as String),
      windowStart: date(map['window_start']),
      windowEnd: date(map['window_end']),
      intervalMs: map['interval_ms'] as int?,
    );
  }
}
