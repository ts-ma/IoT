import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'activity_catalog.dart';
import 'models/prediction_record.dart';
import 'services/prediction_repository.dart';

/// Reads existing history only. The page owns and closes the repository opened
/// by [openRepository], including injected repositories used in tests.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.openRepository});

  final Future<PredictionRepository> Function()? openRepository;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  static const _pageSize = 50;
  // Cover Dart's representable timestamp range, rather than restricting users
  // to today or excluding records whose device clock was ahead.
  static final _start =
      DateTime.fromMillisecondsSinceEpoch(-8640000000000000, isUtc: true);
  static final _end =
      DateTime.fromMillisecondsSinceEpoch(8640000000000000, isUtc: true);

  PredictionRepository? _repository;
  PredictionTaskType _task = PredictionTaskType.har;
  List<PredictionRecord> _records = [];
  int _offset = 0;
  bool _loading = true;
  bool _hasNext = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _records = [];
    });
    try {
      if (_repository == null) {
        final repository = await (widget.openRepository?.call() ??
            PredictionRepository.open());
        if (!mounted) {
          await _close(repository);
          return;
        }
        _repository = repository;
      }
      final rows = await _repository!.query(
        start: _start,
        end: _end,
        taskType: _task,
        limit: _pageSize + 1,
        offset: _offset,
      );
      if (!mounted) return;
      setState(() {
        _records = rows.take(_pageSize).toList();
        _hasNext = rows.length > _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  static Future<void> _close(PredictionRepository repository) async {
    try {
      await repository.close();
    } catch (error) {
      debugPrint('Could not close history database: $error');
    }
  }

  @override
  void dispose() {
    final repository = _repository;
    if (repository != null) unawaited(_close(repository));
    super.dispose();
  }

  void _refresh() {
    _offset = 0;
    unawaited(_load());
  }

  String get _taskName =>
      _task == PredictionTaskType.har ? 'HAR' : 'Social Signals';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity History'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Refresh history',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SegmentedButton<PredictionTaskType>(
                segments: const [
                  ButtonSegment(
                    value: PredictionTaskType.har,
                    label: Text('HAR'),
                    icon: Icon(Icons.directions_walk),
                  ),
                  ButtonSegment(
                    value: PredictionTaskType.social,
                    label: Text('Social Signals'),
                    icon: Icon(Icons.forum_outlined),
                  ),
                ],
                selected: {_task},
                onSelectionChanged: _loading
                    ? null
                    : (selection) {
                        _task = selection.single;
                        _refresh();
                      },
              ),
            ),
            Expanded(child: _content()),
            if (!_loading && !_failed && (_records.isNotEmpty || _offset > 0))
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      onPressed: _offset == 0
                          ? null
                          : () {
                              _offset -= _pageSize;
                              unawaited(_load());
                            },
                      child: const Text('Previous'),
                    ),
                    Text('Page ${_offset ~/ _pageSize + 1}'),
                    TextButton(
                      onPressed: !_hasNext
                          ? null
                          : () {
                              _offset += _pageSize;
                              unawaited(_load());
                            },
                      child: const Text('Next'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading history…'),
          ],
        ),
      );
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              const Text('Could not load history. Please try again.'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_records.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history, size: 48),
              const SizedBox(height: 12),
              Text('No $_taskName predictions saved.'),
              const SizedBox(height: 8),
              const Text(
                'Saved predictions will appear here. '
                'Use Refresh to check for updates.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      key: ValueKey('history-$_task-$_offset'),
      itemCount: _records.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final record = _records[index];
        final local = record.timestamp.toLocal();
        return ListTile(
          leading: LabelAvatar(record.label),
          title: Text(displayName(record.label)),
          subtitle: Text(
            '${DateFormat('yyyy-MM-dd HH:mm:ss').format(local)} '
            '${local.timeZoneName}\n'
            '$_taskName • '
            '${record.source == PredictionSource.live ? 'Live' : 'Replay'}',
          ),
          isThreeLine: true,
          trailing: record.confidence == null
              ? null
              : Text('${(record.confidence! * 100).toStringAsFixed(0)}%'),
        );
      },
    );
  }
}
