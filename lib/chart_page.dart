import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'activity_catalog.dart';
import 'app_shell.dart' show AppTab, shellTab;
import 'models/prediction_record.dart';
import 'services/prediction_repository.dart';
import 'services/timeline.dart';
import 'services/user_session.dart';
import 'widgets/common.dart';
import 'widgets/day_timeline.dart';

/// Totals for one calendar day: the time each activity and social signal was
/// seen (each result stands for the update interval it was made with).
class DayTotals {
  DayTotals(this.day, this.har, this.social, this.coughEpisodes);

  /// Local midnight.
  final DateTime day;
  final Map<String, Duration> har;
  final Map<String, Duration> social;
  final int coughEpisodes;

  Duration _sum(Iterable<Duration> d) => d.fold(Duration.zero, (a, b) => a + b);

  Duration _group(LabelGroup group) => _sum(har.entries
      .where((e) => labelInfo(e.key).group == group)
      .map((e) => e.value));

  Duration get staticTime => _group(LabelGroup.staticActivity);
  Duration get dynamicTime => _group(LabelGroup.dynamicActivity);
  Duration get harTime => _sum(har.values);
  Duration get socialTime => _sum(social.values);
  bool get isEmpty => har.isEmpty && social.isEmpty;
}

/// Chart tab, the coursework's "history of activities and social signals
/// performed each day": the day timeline, time per activity, coughing bouts
/// and time per social signal for any chosen day, plus a 7-day trend.
class ChartPage extends StatefulWidget {
  const ChartPage(
      {super.key, this.openRepository, this.initialDay, this.session});

  final Future<PredictionRepository> Function()? openRepository;
  final DateTime? initialDay;
  final UserSession? session;

  @override
  State<ChartPage> createState() => _ChartPageState();
}

class _ChartPageState extends State<ChartPage> {
  UserSession get _session => widget.session ?? userSession;
  PredictionRepository? _repository;
  late DateTime _day;
  bool _loading = true;
  bool _failed = false;
  DayTotals? _totals;
  List<DayTotals> _week = [];
  TimelineData? _timeline;
  TimelineRange _range = TimelineRange.monitored;

  static DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);
  static DateTime _nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

  @override
  void initState() {
    super.initState();
    _day = _midnight(widget.initialDay ?? DateTime.now());
    shellTab.addListener(_tabChanged);
    unawaited(_load());
  }

  void _tabChanged() {
    if (shellTab.value == AppTab.chart && !_loading) unawaited(_load());
  }

  @override
  void dispose() {
    shellTab.removeListener(_tabChanged);
    final repository = _repository;
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

  Future<DayTotals> _totalsFor(PredictionRepository repo, DateTime day) async {
    final end = _nextDay(day);
    final har = await repo.durationByLabel(
        start: day, end: end, taskType: PredictionTaskType.har);
    final social = await repo.durationByLabel(
        start: day, end: end, taskType: PredictionTaskType.social);
    final coughs = (social['coughing'] ?? Duration.zero) == Duration.zero
        ? 0
        : await repo.countEpisodes(
            start: day,
            end: end,
            taskType: PredictionTaskType.social,
            label: 'coughing');
    return DayTotals(day, har, social, coughs);
  }

  Future<void> _load() async {
    if (!_session.loggedIn && widget.openRepository == null) {
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
      final timeline = await loadTimeline(repo, _day, range: _range);
      final totals = await _totalsFor(repo, _day);
      final week = <DayTotals>[];
      for (var i = 6; i >= 0; i--) {
        final d = DateTime(_day.year, _day.month, _day.day - i);
        week.add(i == 0 ? totals : await _totalsFor(repo, d));
      }
      if (!mounted) return;
      setState(() {
        _timeline = timeline;
        _totals = totals;
        _week = week;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Daily summary failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  bool get _isToday => _day == _midnight(DateTime.now());

  void _goTo(DateTime day) {
    final target = _midnight(day);
    if (target.isAfter(_midnight(DateTime.now()))) return;
    _day = target;
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

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export() async {
    final folder = _session.exportsDir;
    if (folder == null) {
      _snack('Log in to export');
      return;
    }
    try {
      final repo = await _repo();
      if (repo == null) return;
      final rows = (await repo.query(start: _day, end: _nextDay(_day)))
          .reversed
          .toList();
      if (rows.isEmpty) {
        _snack('Nothing to export for this day');
        return;
      }
      final b = StringBuffer('local_time,utc_time,task,label,display_name,'
          'confidence,interval_ms,source\n');
      final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
      for (final r in rows) {
        b.writeln([
          fmt.format(r.timestamp.toLocal()),
          r.timestamp.toIso8601String(),
          r.taskType.name,
          r.label,
          displayName(r.label),
          r.confidence?.toStringAsFixed(4) ?? '',
          r.effectiveIntervalMs,
          r.source.name,
        ].join(','));
      }
      final name = 'PDIoT_history_${DateFormat('yyyy-MM-dd').format(_day)}.csv';
      final file = await UserSession.fileIn(folder, name);
      await file.writeAsString(b.toString());
      _snack('Saved ${rows.length} results to exports/$name');
    } catch (e) {
      debugPrint('Export failed: $e');
      _snack('Export failed');
    }
  }

  Future<void> _deleteDay() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this day?'),
        content: Text('All saved results for ${_dayTitle(_day)} will be '
            'permanently deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final repo = await _repo();
      if (repo == null) return;
      final n = await repo.deleteRange(start: _day, end: _nextDay(_day));
      _snack('Deleted $n results');
    } catch (e) {
      _snack('Could not delete');
    }
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = _session.loggedIn || widget.openRepository != null;
    return Scaffold(
      appBar: tabAppBar(context, 'Chart', session: _session, actions: [
        IconButton(
          tooltip: 'Export day as CSV',
          onPressed: _loading || !loggedIn ? null : _export,
          icon: const Icon(Icons.download),
        ),
        IconButton(
          tooltip: 'Delete this day',
          onPressed: _loading || !loggedIn ? null : _deleteDay,
          icon: const Icon(Icons.delete_outline),
        ),
      ]),
      body: !loggedIn
          ? LoginPrompt(session: _session, what: 'see your charts')
          : SafeArea(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    _dayNavigator(context),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(48),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_failed)
                      _message(context, Icons.error_outline,
                          'Could not load the summary.',
                          retry: true)
                    else ...[
                      if (_timeline != null) _timelineCard(context, _timeline!),
                      if (_totals == null || _totals!.isEmpty)
                        _message(
                            context,
                            Icons.event_busy,
                            'No results saved for ${_dayTitle(_day)}.\n'
                            'Connect the RESpeck on Home and every result is '
                            'saved automatically.')
                      else ...[
                        _overviewCard(context, _totals!),
                        _activityCard(context, _totals!),
                        _socialCard(context, _totals!),
                      ],
                      _weekCard(context),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _timelineCard(BuildContext context, TimelineData data) {
    return _Card(
      title: 'Day timeline',
      icon: Icons.view_timeline_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<TimelineRange>(
            key: const ValueKey('timeline-range'),
            segments: const [
              ButtonSegment(
                  value: TimelineRange.monitored,
                  label: Text('Monitored hours')),
              ButtonSegment(value: TimelineRange.fullDay, label: Text('24 h')),
            ],
            selected: {_range},
            showSelectedIcon: false,
            onSelectionChanged: (v) {
              _range = v.single;
              unawaited(_load());
            },
          ),
          const SizedBox(height: 12),
          DayTimeline(data: data),
          const SizedBox(height: 4),
          Text(
            'Each block is ${formatDuration(data.binSize)}, coloured by the '
            'activity seen longest in it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _dayNavigator(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous day',
          onPressed: _loading
              ? null
              : () => _goTo(DateTime(_day.year, _day.month, _day.day - 1)),
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
          onPressed: _loading || _isToday
              ? null
              : () => _goTo(DateTime(_day.year, _day.month, _day.day + 1)),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  Widget _message(BuildContext context, IconData icon, String text,
      {bool retry = false}) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (retry) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }

  Widget _overviewCard(BuildContext context, DayTotals t) {
    final textTheme = Theme.of(context).textTheme;
    final entries = harClassOrder
        .where((l) => (t.har[l] ?? Duration.zero) > Duration.zero)
        .map((l) => MapEntry(l, t.har[l]!))
        .toList()
      ..addAll(t.har.entries.where((e) => !harClassOrder.contains(e.key)));
    return _Card(
      title: 'Overview',
      icon: Icons.today,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Stat(formatDuration(t.harTime), 'monitored'),
              _Stat(formatDuration(t.staticTime), 'static'),
              _Stat(formatDuration(t.dynamicTime), 'active'),
              _Stat('${t.coughEpisodes}', 'cough bouts'),
            ],
          ),
          if (t.harTime > Duration.zero) ...[
            const SizedBox(height: 16),
            // Proportion of the monitored time spent in each activity.
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 14,
                child: Row(
                  children: [
                    for (final e in entries)
                      Expanded(
                        flex: (e.value.inSeconds).clamp(1, 1 << 30),
                        child: Container(color: labelInfo(e.key).color),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('Share of monitored time per activity',
                style: textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _activityCard(BuildContext context, DayTotals t) {
    final labels = [
      ...harClassOrder
          .where((l) => (t.har[l] ?? Duration.zero) > Duration.zero),
      ...t.har.keys.where((l) => !harClassOrder.contains(l)),
    ]..sort((a, b) => t.har[b]!.compareTo(t.har[a]!));
    final max = labels.isEmpty ? 1 : t.har[labels.first]!.inMilliseconds;
    return _Card(
      title: 'Physical activity',
      icon: Icons.directions_walk,
      child: labels.isEmpty
          ? const Text('No activity results on this day.')
          : Column(
              children: [
                for (final l in labels)
                  _BarRow(
                    label: l,
                    fraction: t.har[l]!.inMilliseconds / (max == 0 ? 1 : max),
                    value: formatDuration(t.har[l]!),
                  ),
              ],
            ),
    );
  }

  Widget _socialCard(BuildContext context, DayTotals t) {
    final textTheme = Theme.of(context).textTheme;
    final labels = [
      ...socialClassOrder
          .where((l) => (t.social[l] ?? Duration.zero) > Duration.zero),
      ...t.social.keys.where((l) => !socialClassOrder.contains(l)),
    ];
    final max = labels.isEmpty
        ? 1
        : labels
            .map((l) => t.social[l]!.inMilliseconds)
            .reduce((a, b) => a > b ? a : b);
    return _Card(
      title: 'Social signals',
      icon: Icons.graphic_eq,
      child: labels.isEmpty
          ? const Text('No social signal results on this day.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const LabelAvatar('coughing'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        t.coughEpisodes == 1
                            ? 'Coughed in 1 separate bout'
                            : 'Coughed in ${t.coughEpisodes} separate bouts',
                        style: textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final l in labels)
                  _BarRow(
                    label: l,
                    fraction:
                        t.social[l]!.inMilliseconds / (max == 0 ? 1 : max),
                    value: formatDuration(t.social[l]!),
                  ),
                const SizedBox(height: 4),
                Text(
                  'A bout is a run of consecutive coughing results; each '
                  'result looks at the last 8 s of data.',
                  style: textTheme.bodySmall,
                ),
              ],
            ),
    );
  }

  Widget _weekCard(BuildContext context) {
    if (_week.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final maxCount = _week
        .map((d) => d.harTime.inSeconds)
        .fold<int>(0, (a, b) => a > b ? a : b);
    const staticColor = Color(0xFF5C6BC0);
    const dynamicColor = Color(0xFF66BB6A);
    const chartHeight = 120.0;
    return _Card(
      title: 'Last 7 days',
      icon: Icons.bar_chart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: chartHeight + 72,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in _week)
                  Expanded(
                    child: InkWell(
                      onTap: () => _goTo(d.day),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              d.harTime == Duration.zero
                                  ? ''
                                  : '${d.harTime.inMinutes}m',
                              style: textTheme.labelSmall,
                            ),
                            const SizedBox(height: 2),
                            if (maxCount > 0 && d.dynamicTime.inSeconds > 0)
                              Container(
                                height: chartHeight *
                                    d.dynamicTime.inSeconds /
                                    maxCount,
                                decoration: const BoxDecoration(
                                  color: dynamicColor,
                                  borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(4)),
                                ),
                              ),
                            if (maxCount > 0 && d.staticTime.inSeconds > 0)
                              Container(
                                height: chartHeight *
                                    d.staticTime.inSeconds /
                                    maxCount,
                                color: staticColor,
                              ),
                            const SizedBox(height: 4),
                            Text(
                              DateFormat('E').format(d.day).substring(0, 2),
                              style: textTheme.labelSmall?.copyWith(
                                fontWeight: d.day == _day
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: d.day == _day ? scheme.primary : null,
                              ),
                            ),
                            Text(
                              d.coughEpisodes > 0 ? '${d.coughEpisodes}c' : '',
                              style: textTheme.labelSmall?.copyWith(
                                  color: labelInfo('coughing').color),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            children: [
              _legend(staticColor, 'Static'),
              _legend(dynamicColor, 'Dynamic'),
              _legend(labelInfo('coughing').color, 'c = cough bouts'),
            ],
          ),
          const SizedBox(height: 4),
          Text('Tap a day to open it.', style: textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _legend(Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.caption);

  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text(value,
              textAlign: TextAlign.center,
              style:
                  textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          Text(caption,
              textAlign: TextAlign.center, style: textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow(
      {required this.label, required this.fraction, required this.value});

  final String label;
  final double fraction;
  final String value;

  @override
  Widget build(BuildContext context) {
    final info = labelInfo(label);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          LabelAvatar(label, radius: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                        child: Text(info.displayName,
                            style: textTheme.bodyMedium)),
                    Text(value,
                        style: textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.0, 1.0),
                    minHeight: 6,
                    color: info.color,
                    backgroundColor: info.color.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
