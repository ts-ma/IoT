import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'activity_catalog.dart';
import 'har.dart' show harClassifier;
import 'services/evaluation.dart';
import 'services/live_feed.dart';
import 'services/raw_recorder.dart';
import 'services/sensor_controller.dart';
import 'services/social_sample_processor.dart';
import 'services/user_session.dart';
import 'social.dart' show socialWindowSeconds;
import 'utils.dart' show sentenceToCamelCase;
import 'widgets/common.dart';

const _notAssessed = '__none__';

/// Tools tab.
///
/// * Real-time test: one group member performs a known activity (and social
///   signal) while another runs a timed trial; every live result in the trial
///   is compared with the truth, and the raw sensor data of the trial is saved
///   to the user's raw/ folder. Results build the report's accuracy table.
/// * Free recording: raw sensor data to raw/ with chosen labels and no time
///   limit (the original data-collection tool).
class ToolsPage extends StatefulWidget {
  const ToolsPage({
    super.key,
    required this.sensor,
    this.store,
    this.feed,
    this.requireSensor,
    this.session,
  });

  final SensorController sensor;
  final EvaluationStore? store;
  final LivePredictionFeed? feed;
  final UserSession? session;

  /// Defaults to true: trials only start while the RESpeck is streaming.
  final bool? requireSensor;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  UserSession get _session => widget.session ?? userSession;
  RawRecorder get _recorder => widget.sensor.recorder;
  late final EvaluationStore _store = widget.store ?? EvaluationStore();
  late final LivePredictionFeed _feed = widget.feed ?? liveFeed;
  late final TextEditingController _participant =
      TextEditingController(text: _session.username ?? '');

  String _activity = harClassOrder.first;
  String _social = socialClassOrder.first;
  int _duration = 30;
  bool _skipWarmup = true;
  bool _saveRaw = true;

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
  String? _trialRawFile;
  int _elapsed = 0;

  // Free recording labels (the coursework recording names).
  static const _freeActivities = [
    'Standing',
    'Sitting',
    'Lying down on left',
    'Lying down right',
    'Lying down back',
    'Lying down on stomach',
    'Normal walking',
    'Ascending stairs',
    'Descending stairs',
    'Shuffle walking',
    'Running',
    'Miscellaneous movements',
  ];
  static const _freeSignals = [
    'Normal',
    'Coughing',
    'Hyperventilating',
    'Talking',
    'Eating',
    'Singing',
    'Laughing',
  ];
  String _freeActivity = _freeActivities.first;
  String _freeSignal = _freeSignals.first;
  Timer? _freeTicker;

  // Skip each model's own window length: until then its window still holds
  // data from before the trial (HAR 4 s, Social 8 s).
  int get _settleSeconds =>
      _skipWarmup ? ((harClassifier?.window.length ?? 50) / 12.5).ceil() : 0;
  int get _socialSettleSeconds => _skipWarmup ? socialWindowSeconds.ceil() : 0;
  bool get _running => _startedAt != null;
  bool get _freeRecording => _recorder.active && _recorder.purpose == 'free';

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_changed);
    widget.sensor.addListener(_changed);
    unawaited(_loadTrials());
  }

  @override
  void dispose() {
    _recorder.removeListener(_changed);
    widget.sensor.removeListener(_changed);
    _stopListening();
    _freeTicker?.cancel();
    // A trial cut short by leaving (e.g. log out) keeps no half recording.
    if (_recorder.purpose == 'trial') unawaited(_recorder.stop());
    _participant.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _loadTrials() async {
    if (!_session.loggedIn && widget.store == null) {
      setState(() => _loading = false);
      return;
    }
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
      _snack('Could not save the trial');
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

  // ------------------------------------------------------------- trials --

  Future<void> _start() async {
    if ((widget.requireSensor ?? true) && !widget.sensor.streaming) {
      _snack('Connect the RESpeck on Home first - no live data is arriving');
      return;
    }
    if (_recorder.active) {
      _snack('Stop the free recording first');
      return;
    }
    final start = DateTime.now().toUtc();
    String? rawName;
    final rawDir = _session.rawDir;
    if (_saveRaw && rawDir != null) {
      rawName = rawFileName(
        user: _session.username!,
        activity: _activity,
        signal: _social == _notAssessed ? 'notAssessed' : _social,
        at: start,
        respeckId: _session.profile?.respeckId,
      );
      try {
        await _recorder.start(
            folder: rawDir, fileName: rawName, purpose: 'trial');
      } catch (e) {
        debugPrint('Could not start the trial recording: $e');
        _snack('Could not create the raw data file - trial runs without it');
        rawName = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _startedAt = start;
      _elapsed = 0;
      _harScored.clear();
      _socialScored.clear();
      _harLatency = null;
      _socialLatency = null;
      _lastHar = null;
      _lastSocial = null;
      _trialRawFile = rawName;
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
      if (offset.inMilliseconds >= _socialSettleSeconds * 1000) {
        _socialScored.add(label);
      }
    });
  }

  Future<void> _cancel() async {
    _stopListening();
    final rawName = _trialRawFile;
    setState(() {
      _startedAt = null;
      _trialRawFile = null;
    });
    if (_recorder.purpose == 'trial') {
      final file = await _recorder.stop();
      // A cancelled trial is not a labelled recording: remove its file.
      if (file != null && rawName != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  void _finish() {
    final start = _startedAt;
    if (start == null) return;
    _stopListening();
    if (_recorder.purpose == 'trial') unawaited(_recorder.stop());
    final trial = EvaluationTrial(
      participant: _participant.text.trim().isEmpty
          ? (_session.username ?? 'unknown')
          : _participant.text.trim(),
      trueActivity: _activity,
      trueSocial: _social == _notAssessed ? null : _social,
      startedAt: start,
      durationSeconds: _elapsed,
      settleSeconds: _settleSeconds,
      socialSettleSeconds: _socialSettleSeconds,
      harPredictions: List.of(_harScored),
      socialPredictions: List.of(_socialScored),
      harLatency: _harLatency,
      socialLatency: _socialLatency,
      rawFile: _trialRawFile,
    );
    setState(() {
      _startedAt = null;
      _trialRawFile = null;
      _trials = [..._trials, trial];
    });
    unawaited(_saveTrials());
    final acc = trial.harAccuracy;
    _snack(acc == null
        ? 'Trial saved, but no activity results arrived.'
        : 'Trial saved: ${displayName(_activity)} '
            '${(acc * 100).toStringAsFixed(0)}% correct '
            '(${trial.harCorrect}/${trial.harPredictions.length})'
            '${trial.rawFile == null ? '' : ' · raw data in raw/'}');
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
            'report. Raw data files in raw/ are kept. This cannot be undone.'),
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
    final folder = _session.exportsDir;
    if (folder == null) {
      _snack('Log in to export');
      return;
    }
    if (_trials.isEmpty) {
      _snack('No trials to export');
      return;
    }
    try {
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final trialsName = 'PDIoT_realtime_trials_$stamp.csv';
      final summaryName = 'PDIoT_realtime_summary_$stamp.csv';
      await (await UserSession.fileIn(folder, trialsName))
          .writeAsString(trialsToCsv(_trials));
      await (await UserSession.fileIn(folder, summaryName))
          .writeAsString(summaryToCsv(EvaluationSummary.from(_trials)));
      _snack('Saved exports/$trialsName and $summaryName');
    } catch (e) {
      debugPrint('Export failed: $e');
      _snack('Export failed');
    }
  }

  // ----------------------------------------------------- free recording --

  Future<void> _startFree() async {
    if (!widget.sensor.streaming || !widget.sensor.receivedPacket) {
      _snack('Connect the RESpeck on Home first');
      return;
    }
    if (_recorder.active) {
      _snack('A recording is already running');
      return;
    }
    final rawDir = _session.rawDir;
    if (rawDir == null) {
      _snack('Log in to record');
      return;
    }
    final name = rawFileName(
      user: _session.username!,
      activity: sentenceToCamelCase(_freeActivity),
      signal: sentenceToCamelCase(_freeSignal),
      at: DateTime.now(),
      respeckId: _session.profile?.respeckId,
    );
    try {
      await _recorder.start(folder: rawDir, fileName: name, purpose: 'free');
      _freeTicker?.cancel();
      _freeTicker =
          Timer.periodic(const Duration(seconds: 1), (_) => _changed());
      _snack('Recording to raw/$name');
    } catch (e) {
      debugPrint('Could not start recording: $e');
      _snack('Could not create the recording file');
    }
  }

  Future<void> _stopFree() async {
    _freeTicker?.cancel();
    _freeTicker = null;
    if (_recorder.purpose != 'free') return;
    final file = await _recorder.stop();
    final samples = _recorder.samples;
    if (file != null) {
      _snack('Saved $samples samples to raw/${file.uri.pathSegments.last}');
    }
  }

  // ---------------------------------------------------------------- UI --

  @override
  Widget build(BuildContext context) {
    final canUse = _session.loggedIn || widget.store != null;
    return Scaffold(
      appBar: tabAppBar(context, 'Tools', session: _session, actions: [
        IconButton(
          tooltip: 'Export results as CSV',
          onPressed: _running || !canUse ? null : _export,
          icon: const Icon(Icons.download),
        ),
        IconButton(
          tooltip: 'Delete all trials',
          onPressed: _running || _trials.isEmpty ? null : _clearAll,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ]),
      body: !canUse
          ? LoginPrompt(
              session: _session, what: 'run real-time tests and record data')
          : ListView(
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
                _freeRecordingCard(context),
              ],
            ),
    );
  }

  DropdownMenuItem<String> _labelItem(String l) => DropdownMenuItem<String>(
        value: l,
        child: Row(children: [
          Icon(labelInfo(l).icon, size: 18, color: labelInfo(l).color),
          const SizedBox(width: 8),
          Text(displayName(l)),
        ]),
      );

  Widget _setupCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      title: 'Real-time test',
      icon: Icons.fact_check_outlined,
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
            key: const ValueKey('trial-activity'),
            isExpanded: true,
            value: _activity,
            items: [for (final l in harClassOrder) _labelItem(l)],
            onChanged: (v) => setState(() => _activity = v ?? _activity),
          ),
          const SizedBox(height: 8),
          const Text('True social signal',
              style: TextStyle(fontWeight: FontWeight.bold)),
          DropdownButton<String>(
            key: const ValueKey('trial-social'),
            isExpanded: true,
            value: _social,
            items: [
              for (final l in socialClassOrder) _labelItem(l),
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
            title: const Text('Ignore warm-up (HAR 4 s, Social 8 s)'),
            subtitle: const Text(
                'Results whose window started before the trial are not '
                'scored. Latency is still measured from the start.'),
          ),
          SwitchListTile(
            key: const ValueKey('trial-save-raw'),
            contentPadding: EdgeInsets.zero,
            value: _saveRaw,
            onChanged: (v) => setState(() => _saveRaw = v),
            title: const Text('Save raw sensor data'),
            subtitle: Text('The trial\'s accelerometer samples go to '
                '${_session.username ?? '<user>'}/raw/ as a labelled CSV.'),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _freeRecording ? null : _start,
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
    return SectionCard(
      title: 'Trial running',
      icon: Icons.timer_outlined,
      trailing: _recorder.purpose == 'trial'
          ? const Pill('REC raw', color: Colors.red)
          : null,
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

  String _pct(double? v) =>
      v == null ? '–' : '${(v * 100).toStringAsFixed(1)}%';

  Widget _resultsCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (_trials.isEmpty) {
      return SectionCard(
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
    return SectionCard(
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
    return SectionCard(
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
                  '${t.trueSocial == null ? '' : ' · social ${_pct(t.socialAccuracy)}'}'
                  '${t.rawFile == null ? '' : ' · raw saved'}'),
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

  Widget _freeRecordingCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final recording = _freeRecording;
    final elapsed = _recorder.elapsed.inSeconds;
    return SectionCard(
      key: const ValueKey('free-recording'),
      title: 'Free recording',
      icon: Icons.fiber_manual_record_outlined,
      trailing: recording ? const Pill('REC', color: Colors.red) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Record raw accelerometer data with no time limit, labelled with '
            'the activity and social signal being performed (e.g. new '
            'training data). Files go to ${_session.username ?? '<user>'}/raw/.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            key: const ValueKey('free-activity'),
            isExpanded: true,
            value: _freeActivity,
            items: [
              for (final a in _freeActivities)
                DropdownMenuItem(value: a, child: Text(a)),
            ],
            onChanged: recording
                ? null
                : (v) => setState(() => _freeActivity = v ?? _freeActivity),
          ),
          DropdownButton<String>(
            key: const ValueKey('free-signal'),
            isExpanded: true,
            value: _freeSignal,
            items: [
              for (final a in _freeSignals)
                DropdownMenuItem(value: a, child: Text(a)),
            ],
            onChanged: recording
                ? null
                : (v) => setState(() => _freeSignal = v ?? _freeSignal),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: recording
                    ? FilledButton.tonalIcon(
                        key: const ValueKey('free-stop'),
                        onPressed: _stopFree,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop recording'),
                      )
                    : FilledButton.icon(
                        key: const ValueKey('free-start'),
                        onPressed: _running ? null : _startFree,
                        icon: const Icon(Icons.fiber_manual_record),
                        label: const Text('Start recording'),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            recording
                ? 'Written ${_recorder.samples} samples ($elapsed s) to '
                    '${_recorder.fileName}'
                : 'Not recording',
            key: const ValueKey('free-status'),
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
