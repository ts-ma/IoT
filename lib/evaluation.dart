import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'activity_catalog.dart';
import 'ble.dart' show respeckStreaming;
import 'globals.dart';
import 'services/evaluation.dart';
import 'services/live_feed.dart';
import 'services/social_sample_processor.dart';
import 'utils.dart';

const _notAssessed = '__none__';

/// Guided real-time accuracy test. One group member performs a known
/// activity (and social signal) while another starts a timed trial; every
/// live prediction in the trial is compared with the truth. Results are kept
/// across app launches and exported as the report's results table.
class EvaluationPage extends StatefulWidget {
  const EvaluationPage({super.key, this.store, this.feed, this.requireSensor});

  final EvaluationStore? store;
  final LivePredictionFeed? feed;

  /// Defaults to true: trials only start while the RESpeck is streaming.
  final bool? requireSensor;

  @override
  State<EvaluationPage> createState() => _EvaluationPageState();
}

class _EvaluationPageState extends State<EvaluationPage> {
  late final EvaluationStore _store = widget.store ?? EvaluationStore();
  late final LivePredictionFeed _feed = widget.feed ?? liveFeed;
  late final TextEditingController _participant =
      TextEditingController(text: subjectID ?? '');

  String _activity = harClassOrder.first;
  String _social = socialClassOrder.first;
  int _duration = 30;
  bool _skipWarmup = true;

  List<EvaluationTrial> _trials = [];
  bool _loading = true;

  // State of the running trial (null when idle).
  DateTime? _startedAt;
  Timer? _ticker;
  StreamSubscription<LiveHarEvent>? _harSub;
  StreamSubscription<SocialPredictionEvent>? _socialSub;
  final List<String> _harScored = [];
  final List<String> _socialScored = [];
  Duration? _harLatency;
  Duration? _socialLatency;
  String? _lastHar;
  String? _lastSocial;
  int _elapsed = 0;

  int get _settleSeconds => _skipWarmup ? 4 : 0;
  bool get _running => _startedAt != null;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTrials());
  }

  @override
  void dispose() {
    _stopListening();
    _participant.dispose();
    super.dispose();
  }

  Future<void> _loadTrials() async {
    try {
      final trials = await _store.load();
      if (!mounted) return;
      setState(() {
        _trials = trials;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Could not load evaluation trials: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _saveTrials() async {
    try {
      await _store.save(_trials);
    } catch (e) {
      debugPrint('Could not save evaluation trials: $e');
      showLongToast('Could not save the trial');
    }
  }

  void _stopListening() {
    _ticker?.cancel();
    _ticker = null;
    unawaited(_harSub?.cancel());
    unawaited(_socialSub?.cancel());
    _harSub = null;
    _socialSub = null;
  }

  void _start() {
    if ((widget.requireSensor ?? true) && !respeckStreaming) {
      showLongToast('Connect the RESpeck first - no live data is arriving');
      return;
    }
    final start = DateTime.now().toUtc();
    setState(() {
      _startedAt = start;
      _elapsed = 0;
      _harScored.clear();
      _socialScored.clear();
      _harLatency = null;
      _socialLatency = null;
      _lastHar = null;
      _lastSocial = null;
    });
    _harSub = _feed.harEvents.listen(_onHar);
    _socialSub = _feed.socialEvents.listen(_onSocial);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final begun = _startedAt;
      if (begun == null || !mounted) return;
      final elapsed = DateTime.now().toUtc().difference(begun).inSeconds;
      setState(() => _elapsed = elapsed);
      if (elapsed >= _duration) _finish();
    });
  }

  void _onHar(LiveHarEvent e) {
    final start = _startedAt;
    if (start == null || !mounted) return;
    final offset = e.at.difference(start);
    if (offset.isNegative) return;
    final label = e.prediction.label;
    setState(() {
      _lastHar = label;
      if (label == _activity) _harLatency ??= offset;
      if (offset.inMilliseconds >= _settleSeconds * 1000) _harScored.add(label);
    });
  }

  void _onSocial(SocialPredictionEvent e) {
    final start = _startedAt;
    if (start == null || !mounted || _social == _notAssessed) return;
    final offset = e.completedAt.difference(start);
    if (offset.isNegative) return;
    final label = e.prediction.label;
    setState(() {
      _lastSocial = label;
      if (label == _social) _socialLatency ??= offset;
      if (offset.inMilliseconds >= _settleSeconds * 1000) {
        _socialScored.add(label);
      }
    });
  }

  void _cancel() {
    _stopListening();
    setState(() => _startedAt = null);
  }

  void _finish() {
    final start = _startedAt;
    if (start == null) return;
    _stopListening();
    final trial = EvaluationTrial(
      participant: _participant.text.trim().isEmpty
          ? 'unknown'
          : _participant.text.trim(),
      trueActivity: _activity,
      trueSocial: _social == _notAssessed ? null : _social,
      startedAt: start,
      durationSeconds: _elapsed,
      settleSeconds: _settleSeconds,
      harPredictions: List.of(_harScored),
      socialPredictions: List.of(_socialScored),
      harLatency: _harLatency,
      socialLatency: _socialLatency,
    );
    setState(() {
      _startedAt = null;
      _trials = [..._trials, trial];
    });
    unawaited(_saveTrials());
    final acc = trial.harAccuracy;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(acc == null
            ? 'Trial saved, but no activity results arrived.'
            : 'Trial saved: ${displayName(_activity)} '
                '${(acc * 100).toStringAsFixed(0)}% correct '
                '(${trial.harCorrect}/${trial.harPredictions.length})'),
      ));
    }
  }

  Future<void> _deleteTrial(EvaluationTrial trial) async {
    setState(() => _trials = [..._trials]..remove(trial));
    await _saveTrials();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all trials?'),
        content: const Text('Export them first if you need them for the '
            'report. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete all')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _trials = []);
    await _saveTrials();
  }

  Future<void> _export() async {
    final folder = storageFolder;
    if (folder == null) {
      showLongToast('No storage folder available');
      return;
    }
    if (_trials.isEmpty) {
      showToast('No trials to export');
      return;
    }
    try {
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final trialsName = 'PDIoT_realtime_trials_$stamp.csv';
      final summaryName = 'PDIoT_realtime_summary_$stamp.csv';
      await File('${folder.path}/$trialsName')
          .writeAsString(trialsToCsv(_trials));
      await File('${folder.path}/$summaryName')
          .writeAsString(summaryToCsv(EvaluationSummary.from(_trials)));
      showLongToast('Saved $trialsName and $summaryName');
    } catch (e) {
      debugPrint('Export failed: $e');
      showLongToast('Export failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Real-time Test'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Export results as CSV',
            onPressed: _running ? null : _export,
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: 'Delete all trials',
            onPressed: _running || _trials.isEmpty ? null : _clearAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            _running ? _runningCard(context) : _setupCard(context),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _resultsCard(context),
              _trialsCard(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _setupCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return _Panel(
      title: 'New trial',
      icon: Icons.play_circle_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ask the participant to begin the activity, then press Start at '
            'the same moment. Every live result during the trial is compared '
            'with the activity and social signal chosen here.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _participant,
            decoration: const InputDecoration(
              labelText: 'Participant',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          const Text('True activity',
              style: TextStyle(fontWeight: FontWeight.bold)),
          DropdownButton<String>(
            isExpanded: true,
            value: _activity,
            items: [
              for (final l in harClassOrder)
                DropdownMenuItem<String>(
                  value: l,
                  child: Row(children: [
                    Icon(labelInfo(l).icon, size: 18, color: labelInfo(l).color),
                    const SizedBox(width: 8),
                    Text(displayName(l)),
                  ]),
                ),
            ],
            onChanged: (v) => setState(() => _activity = v ?? _activity),
          ),
          const SizedBox(height: 8),
          const Text('True social signal',
              style: TextStyle(fontWeight: FontWeight.bold)),
          DropdownButton<String>(
            isExpanded: true,
            value: _social,
            items: [
              for (final l in socialClassOrder)
                DropdownMenuItem<String>(
                  value: l,
                  child: Row(children: [
                    Icon(labelInfo(l).icon, size: 18, color: labelInfo(l).color),
                    const SizedBox(width: 8),
                    Text(displayName(l)),
                  ]),
                ),
              const DropdownMenuItem<String>(
                value: _notAssessed,
                child: Text('Not assessed (e.g. while moving)'),
              ),
            ],
            onChanged: (v) => setState(() => _social = v ?? _social),
          ),
          const SizedBox(height: 12),
          const Text('Duration', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 15, label: Text('15 s')),
              ButtonSegment(value: 30, label: Text('30 s')),
              ButtonSegment(value: 60, label: Text('60 s')),
            ],
            selected: {_duration},
            onSelectionChanged: (s) => setState(() => _duration = s.single),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _skipWarmup,
            onChanged: (v) => setState(() => _skipWarmup = v),
            title: const Text('Ignore the first 4 s'),
            subtitle: const Text(
                'Results whose 4 s window started before the trial are not '
                'scored. Latency is still measured from the start.'),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start trial'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _runningCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final remaining = (_duration - _elapsed).clamp(0, _duration);
    final correct = _harScored.where((l) => l == _activity).length;
    return _Panel(
      title: 'Trial running',
      icon: Icons.timer_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LabelAvatar(_activity, radius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName(_activity),
                        style: textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text(
                        '${_participant.text.trim()}'
                        '${_social == _notAssessed ? '' : ' · ${displayName(_social)}'}',
                        style: textTheme.bodySmall),
                  ],
                ),
              ),
              Text('${remaining}s',
                  style: textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _duration == 0 ? 0 : _elapsed / _duration,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 12),
          _liveRow(context, 'Activity now', _lastHar, _activity),
          if (_social != _notAssessed)
            _liveRow(context, 'Social now', _lastSocial, _social),
          const SizedBox(height: 8),
          Text(
            'Scored so far: $correct / ${_harScored.length} activity results '
            'correct'
            '${_harLatency == null ? '' : ' · first correct after '
                '${(_harLatency!.inMilliseconds / 1000).toStringAsFixed(1)} s'}',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: _cancel, child: const Text('Cancel')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                    onPressed: _finish, child: const Text('Finish now')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _liveRow(
      BuildContext context, String caption, String? label, String truth) {
    final ok = label == truth;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(caption)),
          Expanded(
            child: Text(label == null ? 'waiting…' : displayName(label),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (label != null)
            Icon(ok ? Icons.check_circle : Icons.cancel,
                color: ok ? Colors.green.shade600 : Colors.red.shade400),
        ],
      ),
    );
  }

  String _pct(double? v) => v == null ? '–' : '${(v * 100).toStringAsFixed(1)}%';

  Widget _resultsCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (_trials.isEmpty) {
      return _Panel(
        title: 'Results',
        icon: Icons.table_chart_outlined,
        child: Text(
          'No trials yet. Run each activity and social signal for every '
          'group member; the per-class accuracy table builds up here and can '
          'be exported for the report.',
          style: textTheme.bodySmall,
        ),
      );
    }
    final summary = EvaluationSummary.from(_trials);
    return _Panel(
      title: 'Results',
      icon: Icons.table_chart_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final g in LabelGroup.values)
                Expanded(
                  child: Column(
                    children: [
                      Text(_pct(summary.groupMean(g)),
                          style: textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text(g.shortTitle, style: textTheme.bodySmall),
                    ],
                  ),
                ),
              Expanded(
                child: Column(
                  children: [
                    Text(_pct(summary.overallMean),
                        style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary)),
                    Text('All classes', style: textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              headingRowHeight: 36,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 44,
              columns: const [
                DataColumn(label: Text('Class')),
                DataColumn(label: Text('Trials'), numeric: true),
                DataColumn(label: Text('Correct'), numeric: true),
                DataColumn(label: Text('Accuracy'), numeric: true),
                DataColumn(label: Text('Latency'), numeric: true),
              ],
              rows: [
                for (final s in summary.scores)
                  DataRow(cells: [
                    DataCell(Row(children: [
                      Icon(labelInfo(s.label).icon,
                          size: 16, color: labelInfo(s.label).color),
                      const SizedBox(width: 6),
                      Text(displayName(s.label)),
                    ])),
                    DataCell(Text('${s.trials}')),
                    DataCell(Text('${s.correct}/${s.windows}')),
                    DataCell(Text(_pct(s.accuracy))),
                    DataCell(Text(s.meanLatency == null
                        ? '–'
                        : '${(s.meanLatency!.inMilliseconds / 1000).toStringAsFixed(1)} s')),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Accuracy = correct live results / scored results for that class. '
            'Group values are the mean of the class accuracies, as in the '
            'coursework marking. Latency = time from trial start to the first '
            'correct result.',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _trialsCard(BuildContext context) {
    if (_trials.isEmpty) return const SizedBox.shrink();
    final fmt = DateFormat('d MMM HH:mm');
    return _Panel(
      title: 'Trials (${_trials.length})',
      icon: Icons.list_alt,
      child: Column(
        children: [
          for (final t in _trials.reversed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: LabelAvatar(t.trueActivity),
              title: Text('${displayName(t.trueActivity)}'
                  '${t.trueSocial == null ? '' : ' + ${displayName(t.trueSocial!)}'}'),
              subtitle: Text('${t.participant} · '
                  '${fmt.format(t.startedAt.toLocal())} · '
                  'activity ${_pct(t.harAccuracy)}'
                  '${t.trueSocial == null ? '' : ' · social ${_pct(t.socialAccuracy)}'}'),
              trailing: IconButton(
                tooltip: 'Delete trial',
                icon: const Icon(Icons.close),
                onPressed: _running ? null : () => _deleteTrial(t),
              ),
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.icon, required this.child});

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
              Expanded(
                child: Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
