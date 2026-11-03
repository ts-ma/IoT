import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/prediction_record.dart';

/// Owns its database connection. Call [close] when the repository is no longer
/// needed. Opening is explicit; importing this file never creates a database.
class PredictionRepository {
  static const databaseName = 'prediction_history.db';
  static const schemaVersion = 1;
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
  }) async {
    _validateRange(start, end);
    if ((limit != null && limit <= 0) || offset < 0) {
      throw ArgumentError('limit must be positive and offset non-negative');
    }
    final rows = await _database.query(
      _table,
      where: _rangeWhere(taskType),
      whereArgs: _rangeArgs(start, end, taskType),
      orderBy: 'timestamp DESC, id DESC',
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
