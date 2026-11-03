import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/prediction_record.dart';

/// Owns its database connection. Call [close] when the repository is no longer
/// needed. Opening is explicit; importing this file never creates a database.
class PredictionRepository {
  static const databaseName = 'prediction_history.db';
  static const schemaVersion = 2;
  static const _table = 'prediction_history';

  // Append one migration per future schema version. Never edit a migration
  // already released. Sqflite runs create/upgrade callbacks in a transaction.
  static final List<Future<void> Function(Database)> _migrations = [
    (db) async {
      await db.execute('''
        CREATE TABLE $_table (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          task_type TEXT NOT NULL CHECK(task_type IN ('har', 'social')),
          label TEXT NOT NULL CHECK(length(trim(label)) > 0),
          timestamp INTEGER NOT NULL,
          confidence REAL CHECK(confidence IS NULL OR
            (confidence >= 0 AND confidence <= 1)),
          source TEXT NOT NULL CHECK(source IN ('live', 'replay')),
          window_start INTEGER,
          window_end INTEGER,
          CHECK(window_start IS NULL OR window_end IS NULL OR
            window_end >= window_start)
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_prediction_timestamp ON $_table(timestamp)',
      );
      await db.execute(
        'CREATE INDEX idx_prediction_task_timestamp '
        'ON $_table(task_type, timestamp)',
      );
    },
    // v2: the activity time each result stands for. The update interval can
    // be changed in Settings, so durations are summed rather than counted.
    (db) async {
      await db.execute(
        'ALTER TABLE $_table ADD COLUMN interval_ms INTEGER '
        'CHECK(interval_ms IS NULL OR interval_ms > 0)',
      );
    },
  ];

  final Database _database;

  PredictionRepository._(this._database);

  /// Defaults to sqflite's private database directory on supported mobile/macOS
  /// platforms. Tests can inject an FFI factory and a temporary database path.
  static Future<PredictionRepository> open({
    String? databasePath,
    DatabaseFactory? factory,
  }) async {
    final selectedFactory = factory ?? databaseFactory;
    final location = databasePath ??
        path.join(await selectedFactory.getDatabasesPath(), databaseName);
    final db = await selectedFactory.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        singleInstance: false,
        onCreate: (db, version) => _migrate(db, 0, version),
        onUpgrade: _migrate,
        // A newer database must never be silently recreated or downgraded.
        onDowngrade: (db, oldVersion, newVersion) async {
          throw StateError('Unsupported database downgrade: '
              '$oldVersion -> $newVersion');
        },
      ),
    );
    return PredictionRepository._(db);
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    for (var version = from; version < to; version++) {
      await _migrations[version](db);
    }
  }

  /// Inserts a new record and returns its generated id. Existing ids are
  /// rejected so callers cannot accidentally overwrite historical records.
  Future<int> insert(PredictionRecord record) {
    if (record.id != null) {
      throw ArgumentError('New predictions must not already have an id');
    }
    return _database.insert(_table, record.toMap());
  }

  /// Queries [start, end), newest first. Bounds are instants, not local dates:
  /// callers should convert their chosen day's boundaries to UTC. An exclusive
  /// end avoids counting midnight twice across consecutive daily queries.
  Future<List<PredictionRecord>> query({
    required DateTime start,
    required DateTime end,
    PredictionTaskType? taskType,
    int? limit,
    int offset = 0,
    bool newestFirst = true,
  }) async {
    _validateRange(start, end);
    if ((limit != null && limit <= 0) || offset < 0) {
      throw ArgumentError('limit must be positive and offset non-negative');
    }
    final rows = await _database.query(
      _table,
      where: _rangeWhere(taskType),
      whereArgs: _rangeArgs(start, end, taskType),
      orderBy: newestFirst ? 'timestamp DESC, id DESC' : 'timestamp ASC, id ASC',
      limit: limit ?? (offset > 0 ? -1 : null),
      offset: offset,
    );
    return rows.map(PredictionRecord.fromMap).toList();
  }

  /// Number of records per label in [start, end) for one task. Used for the
  /// daily summary: each HAR record represents one prediction interval.
  /// Pass [source] to count only live (or only replayed) results.
  Future<Map<String, int>> countByLabel({
    required DateTime start,
    required DateTime end,
    required PredictionTaskType taskType,
    PredictionSource? source,
  }) async {
    _validateRange(start, end);
    final rows = await _database.rawQuery(
      'SELECT label, COUNT(*) AS n FROM $_table '
      'WHERE ${_rangeWhere(taskType, source)} GROUP BY label',
      _rangeArgs(start, end, taskType, source),
    );
    return {
      for (final row in rows) row['label'] as String: (row['n'] as num).toInt(),
    };
  }

  /// Activity time per label in [start, end) for one task: the sum of each
  /// result's interval (old rows without one count as the original 2 s).
  Future<Map<String, Duration>> durationByLabel({
    required DateTime start,
    required DateTime end,
    required PredictionTaskType taskType,
    PredictionSource? source,
  }) async {
    _validateRange(start, end);
    final rows = await _database.rawQuery(
      'SELECT label, SUM(COALESCE(interval_ms, '
      '${PredictionRecord.legacyIntervalMs})) AS ms FROM $_table '
      'WHERE ${_rangeWhere(taskType, source)} GROUP BY label',
      _rangeArgs(start, end, taskType, source),
    );
    return {
      for (final row in rows)
        row['label'] as String:
            Duration(milliseconds: (row['ms'] as num).toInt()),
    };
  }

  /// Results grouped into time bins of [bin] starting at [start]: for every
  /// bin, task and label the number of results and the time they stand for.
  /// Used by the day timeline; one SQL query, however many results a day has.
  Future<List<TimelineCell>> timelineBins({
    required DateTime start,
    required DateTime end,
    required Duration bin,
  }) async {
    _validateRange(start, end);
    if (bin.inMicroseconds <= 0) throw ArgumentError.value(bin, 'bin');
    final rows = await _database.rawQuery(
      'SELECT (timestamp - ?) / ? AS bin, task_type, label, COUNT(*) AS n, '
      'SUM(COALESCE(interval_ms, ${PredictionRecord.legacyIntervalMs})) AS ms '
      'FROM $_table WHERE ${_rangeWhere(null)} '
      'GROUP BY bin, task_type, label ORDER BY bin',
      [
        start.toUtc().microsecondsSinceEpoch,
        bin.inMicroseconds,
        ..._rangeArgs(start, end, null),
      ],
    );
    return [
      for (final row in rows)
        TimelineCell(
          bin: (row['bin'] as num).toInt(),
          taskType:
              PredictionTaskType.values.byName(row['task_type'] as String),
          label: row['label'] as String,
          count: (row['n'] as num).toInt(),
          duration: Duration(milliseconds: (row['ms'] as num).toInt()),
        ),
    ];
  }

  /// Times of the first and last result in [start, end), or null if none.
  Future<({DateTime first, DateTime last})?> timeRange({
    required DateTime start,
    required DateTime end,
  }) async {
    _validateRange(start, end);
    final rows = await _database.rawQuery(
      'SELECT MIN(timestamp) AS a, MAX(timestamp) AS b FROM $_table '
      'WHERE ${_rangeWhere(null)}',
      _rangeArgs(start, end, null),
    );
    final a = rows.single['a'], b = rows.single['b'];
    if (a == null || b == null) return null;
    return (
      first: DateTime.fromMicrosecondsSinceEpoch(a as int, isUtc: true),
      last: DateTime.fromMicrosecondsSinceEpoch(b as int, isUtc: true),
    );
  }

  /// Number of rows in the database (Performance page, storage growth).
  Future<int> count() async {
    final rows = await _database.rawQuery('SELECT COUNT(*) AS n FROM $_table');
    return (rows.single['n'] as num).toInt();
  }

  /// Number of separate bouts of [label] in [start, end): consecutive records
  /// with that label form one bout, which ends at a different label or a gap
  /// longer than [maxGap] (e.g. a disconnect). Counts coughing episodes.
  Future<int> countEpisodes({
    required DateTime start,
    required DateTime end,
    required PredictionTaskType taskType,
    required String label,
    Duration maxGap = const Duration(seconds: 6),
    PredictionSource? source,
  }) async {
    _validateRange(start, end);
    final rows = await _database.query(
      _table,
      columns: ['label', 'timestamp'],
      where: _rangeWhere(taskType, source),
      whereArgs: _rangeArgs(start, end, taskType, source),
      orderBy: 'timestamp ASC, id ASC',
    );
    return countLabelEpisodes(
      [
        for (final row in rows)
          (
            label: row['label'] as String,
            at: DateTime.fromMicrosecondsSinceEpoch(row['timestamp'] as int,
                isUtc: true),
          ),
      ],
      label,
      maxGap: maxGap,
    );
  }

  Future<int> delete(int id) =>
      _database.delete(_table, where: 'id = ?', whereArgs: [id]);

  /// Deletes only records within [start, end), optionally for a single task.
  Future<int> deleteRange({
    required DateTime start,
    required DateTime end,
    PredictionTaskType? taskType,
  }) {
    _validateRange(start, end);
    return _database.delete(
      _table,
      where: _rangeWhere(taskType),
      whereArgs: _rangeArgs(start, end, taskType),
    );
  }

  Future<void> close() => _database.close();

  static void _validateRange(DateTime start, DateTime end) {
    if (end.isBefore(start)) {
      throw ArgumentError('end must not precede start');
    }
  }

  static String _rangeWhere(PredictionTaskType? taskType,
          [PredictionSource? source]) =>
      'timestamp >= ? AND timestamp < ?'
      '${taskType == null ? '' : ' AND task_type = ?'}'
      '${source == null ? '' : ' AND source = ?'}';

  static List<Object> _rangeArgs(
    DateTime start,
    DateTime end,
    PredictionTaskType? taskType, [
    PredictionSource? source,
  ]) =>
      [
        start.toUtc().microsecondsSinceEpoch,
        end.toUtc().microsecondsSinceEpoch,
        if (taskType != null) taskType.name,
        if (source != null) source.name,
      ];
}

/// One (bin, task, label) group of [PredictionRepository.timelineBins].
class TimelineCell {
  const TimelineCell({
    required this.bin,
    required this.taskType,
    required this.label,
    required this.count,
    required this.duration,
  });

  final int bin;
  final PredictionTaskType taskType;
  final String label;
  final int count;
  final Duration duration;
}

/// Counts runs of [label] in chronologically ordered [records]. A run ends at
/// any other label or when two records are more than [maxGap] apart.
int countLabelEpisodes(
  List<({String label, DateTime at})> records,
  String label, {
  Duration maxGap = const Duration(seconds: 6),
}) {
  var episodes = 0;
  var inRun = false;
  DateTime? previous;
  for (final record in records) {
    final gapBroken =
        previous != null && record.at.difference(previous) > maxGap;
    if (record.label == label) {
      if (!inRun || gapBroken) episodes++;
      inRun = true;
    } else {
      inRun = false;
    }
    previous = record.at;
  }
  return episodes;
}
