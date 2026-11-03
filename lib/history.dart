import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'activity_catalog.dart';
import 'app_shell.dart' show AppTab, shellTab;
import 'models/prediction_record.dart';
import 'services/prediction_repository.dart';
import 'services/user_session.dart';
import 'widgets/common.dart';

// History tab: what the models said, with the activity and the social signal
// of the same moment side by side. Both models classify the same samples at
// the same step, so each activity result has a social result made within a
// fraction of a second of it (once the longer social window has filled).

/// One activity result and the social result closest to it in time.
class JoinedResult {
  JoinedResult(this.har, this.social);

  final PredictionRecord har;
  final PredictionRecord? social;
}

/// A stretch of time in which neither label changed.
class HistoryEpisode {
  HistoryEpisode(this.first);

  final JoinedResult first;
  late JoinedResult last = first;
  int count = 1;
  double _harConfidence = 0;
  double _socialConfidence = 0;
  int _socialCount = 0;
  Duration duration = Duration.zero;

  String get harLabel => first.har.label;
  String? get socialLabel => first.social?.label;
  DateTime get start => first.har.timestamp;
  DateTime get end => last.har.timestamp;
  double get harConfidence => _harConfidence / count;
  double? get socialConfidence =>
      _socialCount == 0 ? null : _socialConfidence / _socialCount;

  void _add(JoinedResult r) {
    last = r;
    count++;
    _addStats(r);
  }

  void _addStats(JoinedResult r) {
    _harConfidence += r.har.confidence ?? 0;
    duration += Duration(milliseconds: r.har.effectiveIntervalMs);
    final c = r.social?.confidence;
    if (c != null) {
      _socialConfidence += c;
      _socialCount++;
    }
  }
}

/// Pairs every HAR record with the nearest social record (or none, e.g.
/// while the 8 s social window is still filling). Both models classify the
/// same sample, so a true pair is milliseconds apart; the allowed gap is 3/4
/// of the result interval (at least 300 ms) unless [tolerance] is given, so
/// one social result is never shown against two activity results. Both lists
/// must be in ascending time order; the result is too.
List<JoinedResult> joinResults(
  List<PredictionRecord> har,
  List<PredictionRecord> social, {
  Duration? tolerance,
}) {
  final out = <JoinedResult>[];
  var j = 0;
  for (final h in har) {
    final allowed = tolerance ??
        Duration(
            milliseconds:
                (h.effectiveIntervalMs * 0.75).round().clamp(300, 1 << 30));
    // Move j to the last social record not after h (within the window).
    while (j + 1 < social.length &&
        !social[j + 1].timestamp.isAfter(h.timestamp)) {
      j++;
    }
    PredictionRecord? best;
    var bestGap = allowed;
    for (final k in [j, j + 1]) {
      if (k < 0 || k >= social.length) continue;
      final gap = social[k].timestamp.difference(h.timestamp).abs();
      if (gap <= bestGap) {
        best = social[k];
        bestGap = gap;
      }
    }
    out.add(JoinedResult(h, best));
  }
  return out;
}

/// Run-length groups of joined results (ascending in, newest first out). A
/// gap longer than [maxGap] (e.g. a disconnect) also starts a new episode.
List<HistoryEpisode> groupEpisodes(
  List<JoinedResult> joined, {
  Duration maxGap = const Duration(seconds: 6),
}) {
  final episodes = <HistoryEpisode>[];
  HistoryEpisode? current;
  for (final r in joined) {
    final c = current;
    if (c != null &&
        c.harLabel == r.har.label &&
        c.socialLabel == r.social?.label &&
        r.har.timestamp.difference(c.end) <= maxGap) {
      c._add(r);
    } else {
      current = HistoryEpisode(r).._addStats(r);
      episodes.add(current);
    }
  }
  return episodes.reversed.toList();
}

enum HistoryView { episodes, results }

class HistoryPage extends StatefulWidget {
  const HistoryPage(
      {super.key, this.openRepository, this.session, this.initialDay});

  /// Tests inject a repository; the page owns and closes what it opens.
  final Future<PredictionRepository> Function()? openRepository;
  final UserSession? session;
  final DateTime? initialDay;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  static const pageSize = 50;
  UserSession get _session => widget.session ?? userSession;

  PredictionRepository? _repository;
  late DateTime _day;
  HistoryView _view = HistoryView.episodes;
  List<HistoryEpisode> _episodes = [];
  List<JoinedResult> _results = [];
  int _offset = 0;
  bool _hasNext = false;
  bool _loading = true;
  bool _failed = false;

  static DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);
  DateTime get _dayEnd => DateTime(_day.year, _day.month, _day.day + 1);
  bool get _canRead => _session.loggedIn || widget.openRepository != null;

  @override
  void initState() {
    super.initState();
    _day = _midnight(widget.initialDay ?? DateTime.now());
    shellTab.addListener(_tabChanged);
    unawaited(_load());
  }

  void _tabChanged() {
    if (shellTab.value == AppTab.history && !_loading) unawaited(_load());
  }

  @override
  void dispose() {
    shellTab.removeListener(_tabChanged);
    final repository = _repository;
    _repository = null;
    if (repository != null) {
      unawaited(repository.close().catchError((Object e) {
        debugPrint('Could not close history database: $e');
      }));
    }
    super.dispose();
  }

  Future<PredictionRepository?> _repo() async {
    if (_repository != null) return _repository;
    final repository =
        await (widget.openRepository ?? _session.openRepository)();
    if (!mounted) {
      await repository.close();
      return null;
    }
    return _repository = repository;
  }

  Future<void> _load() async {
    if (!_canRead) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final repo = await _repo();
      if (repo == null) return;
      if (_view == HistoryView.episodes) {
        final har = await repo.query(
            start: _day,
            end: _dayEnd,
            taskType: PredictionTaskType.har,
            newestFirst: false);
        final social = await repo.query(
            start: _day,
            end: _dayEnd,
            taskType: PredictionTaskType.social,
            newestFirst: false);
        if (!mounted) return;
        setState(() {
          _episodes = groupEpisodes(joinResults(har, social));
          _loading = false;
        });
      } else {
        final page = await repo.query(
          start: _day,
          end: _dayEnd,
          taskType: PredictionTaskType.har,
          limit: pageSize + 1,
          offset: _offset,
        );
        final har = page.take(pageSize).toList().reversed.toList();
        var social = <PredictionRecord>[];
        if (har.isNotEmpty) {
          social = await repo.query(
            start: har.first.timestamp.subtract(const Duration(seconds: 2)),
            end: har.last.timestamp.add(const Duration(seconds: 2)),
            taskType: PredictionTaskType.social,
            newestFirst: false,
          );
        }
        if (!mounted) return;
        setState(() {
          _results = joinResults(har, social).reversed.toList();
          _hasNext = page.length > pageSize;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('History failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _goTo(DateTime day) {
    final target = _midnight(day);
    if (target.isAfter(_midnight(DateTime.now()))) return;
    _day = target;
    _offset = 0;
    unawaited(_load());
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) _goTo(picked);
  }

  String _dayTitle(DateTime d) {
    final today = _midnight(DateTime.now());
    if (d == today) return 'Today';
    if (d == DateTime(today.year, today.month, today.day - 1)) {
      return 'Yesterday';
    }
    return DateFormat('EEE d MMM yyyy').format(d);
  }

  @override
  Widget build(BuildContext context) {
    final isToday = _day == _midnight(DateTime.now());
    return Scaffold(
      appBar: tabAppBar(context, 'History', session: _session, actions: [
        IconButton(
          tooltip: 'Refresh history',
          onPressed: _loading || !_canRead ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ]),
      body: !_canRead
          ? LoginPrompt(session: _session, what: 'see your history')
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Previous day',
                        onPressed: _loading
                            ? null
                            : () => _goTo(
                                DateTime(_day.year, _day.month, _day.day - 1)),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _loading ? null : _pickDay,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(_dayTitle(_day),
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next day',
                        onPressed: _loading || isToday
                            ? null
                            : () => _goTo(
                                DateTime(_day.year, _day.month, _day.day + 1)),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<HistoryView>(
                    segments: const [
                      ButtonSegment(
                          value: HistoryView.episodes,
                          label: Text('Episodes'),
                          icon: Icon(Icons.view_agenda_outlined)),
                      ButtonSegment(
                          value: HistoryView.results,
                          label: Text('Every result'),
                          icon: Icon(Icons.list)),
                    ],
                    selected: {_view},
                    onSelectionChanged: _loading
                        ? null
                        : (v) {
                            _view = v.single;
                            _offset = 0;
                            unawaited(_load());
                          },
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(child: _content(context)),
                if (_view == HistoryView.results &&
                    !_loading &&
                    !_failed &&
                    (_results.isNotEmpty || _offset > 0))
                  _pager(),
              ],
            ),
    );
  }

  Widget _pager() {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton(
            onPressed: _offset == 0
                ? null
                : () {
                    _offset -= pageSize;
                    unawaited(_load());
                  },
            child: const Text('Previous'),
          ),
          Text('Page ${_offset ~/ pageSize + 1}'),
          TextButton(
            onPressed: !_hasNext
                ? null
                : () {
                    _offset += pageSize;
                    unawaited(_load());
                  },
            child: const Text('Next'),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
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
        child: MessageView(
          icon: Icons.error_outline,
          text: 'Could not load history. Please try again.',
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }
    final empty =
        _view == HistoryView.episodes ? _episodes.isEmpty : _results.isEmpty;
    if (empty) {
      return Center(
        child: MessageView(
          icon: Icons.history,
          text: 'No results saved for ${_dayTitle(_day)}.\n'
              'Connect the RESpeck on Home; every result is saved.',
        ),
      );
    }
    if (_view == HistoryView.episodes) {
      return ListView.separated(
        key: ValueKey('history-episodes-$_day'),
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: _episodes.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, i) => _episodeTile(context, _episodes[i]),
      );
    }
    return ListView.separated(
      key: ValueKey('history-results-$_day-$_offset'),
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _results.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, i) => _resultTile(context, _results[i]),
    );
  }

  Widget _episodeTile(BuildContext context, HistoryEpisode e) {
    final textTheme = Theme.of(context).textTheme;
    final hms = DateFormat('HH:mm:ss');
    final moving = labelInfo(e.harLabel).group == LabelGroup.dynamicActivity;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                  '${hms.format(e.start.toLocal())} – ${hms.format(e.end.toLocal())}',
                  style: textTheme.labelLarge),
              const Spacer(),
              Text('${formatDuration(e.duration)} · ${e.count} results',
                  style: textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _LabelCell(
                  label: e.harLabel,
                  confidence: e.harConfidence,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: e.socialLabel == null
                    ? Text('Social: warming up', style: textTheme.bodySmall)
                    : _LabelCell(
                        label: e.socialLabel!,
                        confidence: e.socialConfidence,
                        dim: moving,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultTile(BuildContext context, JoinedResult r) {
    final textTheme = Theme.of(context).textTheme;
    final local = r.har.timestamp.toLocal();
    final moving = labelInfo(r.har.label).group == LabelGroup.dynamicActivity;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(DateFormat('HH:mm:ss').format(local),
                style: textTheme.labelMedium),
          ),
          Expanded(
              child:
                  _LabelCell(label: r.har.label, confidence: r.har.confidence)),
          const SizedBox(width: 8),
          Expanded(
            child: r.social == null
                ? Text('—', style: textTheme.bodySmall)
                : _LabelCell(
                    label: r.social!.label,
                    confidence: r.social!.confidence,
                    dim: moving,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Small avatar, readable name and confidence.
class _LabelCell extends StatelessWidget {
  const _LabelCell({required this.label, this.confidence, this.dim = false});

  final String label;
  final double? confidence;

  /// Social result while moving: shown faded, as it is less reliable.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Opacity(
      opacity: dim ? 0.55 : 1,
      child: Row(
        children: [
          LabelAvatar(label, radius: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (confidence != null)
                  Text('${(confidence! * 100).toStringAsFixed(0)}%',
                      style: textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
