import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'activity_catalog.dart';
import 'services/app_settings.dart';
import 'services/latency_test.dart';
import 'services/live_feed.dart';
import 'services/sensor_controller.dart';
import 'services/user_session.dart';
import 'widgets/common.dart';

/// Tools → Latency test: cued changes timed on the phone (see
/// services/latency_test.dart for the definitions).
class LatencyTestPage extends StatefulWidget {
  const LatencyTestPage({
    super.key,
    required this.sensor,
    this.session,
    this.feed,
    this.store,
    this.requireSensor = true,
    this.onCue,
  });

  final SensorController sensor;
  final UserSession? session;
  final LivePredictionFeed? feed;
  final LatencyStore? store;
  final bool requireSensor;

  /// Replaces the vibration + sound (tests).
  final void Function()? onCue;

  @override
  State<LatencyTestPage> createState() => _LatencyTestPageState();
}

class _LatencyTestPageState extends State<LatencyTestPage> {
  UserSession get _session => widget.session ?? userSession;
  late final LatencyStore _store = widget.store ??
      LatencyStore(() async {
        final f = _session.latencyFile;
        if (f == null) throw StateError('Log in to keep latency tests');
        return f;
      });
  late final TextEditingController _participant =
      TextEditingController(text: _session.username ?? '');

  LatencyTask _task = LatencyTask.activity;
  String _from = 'sittingStanding';
  String _to = 'normalWalking';
  int _reps = 5;
  List<LatencyRep> _saved = [];
  LatencyRun? _run;
  Timer? _ticker;

  List<String> get _classes =>
      _task == LatencyTask.activity ? harClassOrder : socialClassOrder;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _run?.dispose();
    _participant.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final reps = await _store.load();
      if (mounted) setState(() => _saved = reps);
    } catch (e) {
      debugPrint('Could not load latency tests: $e');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _cue() {
    if (widget.onCue != null) {
      widget.onCue!();
      return;
    }
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    Future.delayed(const Duration(milliseconds: 150), HapticFeedback.heavyImpact);
  }

  void _start() {
    if (widget.requireSensor && !widget.sensor.streaming) {
      _snack('Connect the RESpeck on Home first - no live data is arriving');
      return;
    }
    final feed = widget.feed ?? liveFeed;
    final run = LatencyRun(
      task: _task,
      from: _from,
      to: _to,
      reps: _reps,
      participant: _participant.text.trim().isEmpty
          ? (_session.username ?? 'unknown')
          : _participant.text.trim(),
      harEvents: feed.harEvents,
      socialEvents: feed.socialEvents,
      stepSamples: appSettings.stepSamples.value,
      smoothing: appSettings.smoothHar.value,
      onCue: _cue,
      onFinished: (reps) => unawaited(_finished(reps)),
    )..addListener(_changed);
    run.shownLabel = _task == LatencyTask.activity
        ? widget.sensor.harShown?.label
        : widget.sensor.socialProcessor?.latestPrediction?.prediction.label;
    setState(() => _run = run);
    run.start();
    _ticker = Timer.periodic(
        const Duration(milliseconds: 200), (_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _finished(List<LatencyRep> reps) async {
    _ticker?.cancel();
    final all = [..._saved, ...reps];
    setState(() {
      _saved = all;
      _run?.removeListener(_changed);
      _run = null;
    });
    try {
      await _store.save(all);
      final shown = LatencyStats.mean(reps.map((r) => r.shown));
      _snack('Saved ${reps.length} changes'
          '${shown == null ? '' : ' · shown after ${shown.toStringAsFixed(1)} s on average'}');
    } catch (e) {
      _snack('Could not save the latency test: $e');
    }
  }

  void _cancel() {
    _ticker?.cancel();
    _run?.removeListener(_changed);
    _run?.cancel();
    setState(() => _run = null);
  }

  Future<void> _export() async {
    final folder = _session.exportsDir;
    if (folder == null || _saved.isEmpty) {
      _snack(folder == null ? 'Log in to export' : 'No latency tests yet');
      return;
    }
    try {
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final a = 'PDIoT_latency_changes_$stamp.csv';
      final b = 'PDIoT_latency_summary_$stamp.csv';
      await (await UserSession.fileIn(folder, a))
          .writeAsString(latencyRepsToCsv(_saved));
      await (await UserSession.fileIn(folder, b))
          .writeAsString(latencySummaryToCsv(_saved));
      _snack('Saved exports/$a and $b');
    } catch (e) {
      _snack('Export failed');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete all latency tests?'),
        content: Text('${_saved.length} timed changes will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saved = []);
    try {
      await _store.save([]);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Latency test'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
              tooltip: 'Export CSV',
              onPressed: run == null ? _export : null,
              icon: const Icon(Icons.file_download_outlined)),
          IconButton(
              tooltip: 'Delete all',
              onPressed: run == null && _saved.isNotEmpty ? _clear : null,
              icon: const Icon(Icons.delete_sweep_outlined)),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            run == null ? _setup(context) : _running(context, run),
            if (_saved.isNotEmpty) _results(context),
          ],
        ),
      ),
    );
  }

  Widget _labelDropdown(String key, String value, ValueChanged<String> on,
          {String? exclude}) =>
      DropdownButton<String>(
        key: ValueKey(key),
        isExpanded: true,
        value: value,
        items: [
          for (final l in _classes)
            if (l != exclude)
              DropdownMenuItem(
                value: l,
                child: Row(children: [
                  Icon(labelInfo(l).icon, size: 18, color: labelInfo(l).color),
                  const SizedBox(width: 8),
                  Text(displayName(l)),
                ]),
              ),
        ],
        onChanged: (v) => setState(() => on(v ?? value)),
      );

  Widget _setup(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      icon: Icons.timer_outlined,
      title: 'Time a change',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Do the first class until the app shows it. After a random 2-5 s '
            'the phone vibrates and beeps: change to the second class at once. '
            'The app times how long until the new class is shown. Repeat for '
            'each change and each group member.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<LatencyTask>(
            key: const ValueKey('latency-task'),
            segments: const [
              ButtonSegment(
                  value: LatencyTask.activity, label: Text('Activity')),
              ButtonSegment(
                  value: LatencyTask.social, label: Text('Social signal')),
            ],
            selected: {_task},
            onSelectionChanged: (s) => setState(() {
              _task = s.single;
              _from = _classes[0];
              _to = _classes[_task == LatencyTask.activity ? 5 : 1];
            }),
          ),
          if (_task == LatencyTask.social)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Stay sitting, standing or lying for both classes: social '
                'signals are paused while you move.',
                style: textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _participant,
            decoration: const InputDecoration(
                labelText: 'Participant',
                prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 8),
          const Text('From', style: TextStyle(fontWeight: FontWeight.bold)),
          _labelDropdown('latency-from', _from, (v) {
            _from = v;
            if (_to == v) _to = _classes.firstWhere((c) => c != v);
          }),
          const Text('Change to', style: TextStyle(fontWeight: FontWeight.bold)),
          _labelDropdown('latency-to', _to, (v) => _to = v, exclude: _from),
          const SizedBox(height: 8),
          const Text('Repeats', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 3, label: Text('3')),
              ButtonSegment(value: 5, label: Text('5')),
              ButtonSegment(value: 10, label: Text('10')),
            ],
            selected: {_reps},
            onSelectionChanged: (s) => setState(() => _reps = s.single),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('latency-start'),
              onPressed: _start,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _running(BuildContext context, LatencyRun run) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final cued = run.phase == LatencyPhase.cued;
    final since = run.cueAt == null
        ? null
        : DateTime.now().toUtc().difference(run.cueAt!).inMilliseconds / 1000;
    final (String big, String small, Color bg) = switch (run.phase) {
      LatencyPhase.settling => (
          displayName(run.from),
          'Do this until the screen shows it…',
          scheme.surfaceContainerHighest
        ),
      LatencyPhase.holding => (
          displayName(run.from),
          'Keep going - get ready to change',
          scheme.surfaceContainerHighest
        ),
      LatencyPhase.cued => (
          'NOW: ${displayName(run.to)}',
          'Change now!',
          Colors.orange.shade300
        ),
      _ => ('', '', scheme.surface),
    };
    String t(Duration? d) => d == null
        ? '…'
        : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
    return SectionCard(
      icon: Icons.timer_outlined,
      title: 'Change ${run.currentRep} of ${run.reps}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            key: const ValueKey('latency-cue'),
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
            decoration: BoxDecoration(
                color: bg, borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              Text(big,
                  textAlign: TextAlign.center,
                  style: textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(small, style: textTheme.titleMedium),
              if (cued && since != null)
                Text('${since.toStringAsFixed(1)} s',
                    style: textTheme.displaySmall),
            ]),
          ),
          const SizedBox(height: 12),
          Text('Screen shows: '
              '${run.shownLabel == null ? '–' : displayName(run.shownLabel!)}',
              style: textTheme.titleMedium),
          if (cued) ...[
            const SizedBox(height: 6),
            Text('First correct result: ${t(run.firstCorrect)} · '
                'shown: ${t(run.shown)} · steady for 3 s: waiting'),
          ],
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
        ],
      ),
    );
  }

  Widget _results(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    String f(double? v) => v == null ? '–' : '${v.toStringAsFixed(1)} s';
    final stats = LatencyStats.of(_saved);
    return SectionCard(
      icon: Icons.table_chart_outlined,
      title: 'Results (${_saved.length} changes)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 14,
              headingRowHeight: 36,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 44,
              columns: const [
                DataColumn(label: Text('Change')),
                DataColumn(label: Text('n'), numeric: true),
                DataColumn(label: Text('Shown'), numeric: true),
                DataColumn(label: Text('Steady'), numeric: true),
                DataColumn(label: Text('First correct'), numeric: true),
                DataColumn(label: Text('Timeouts'), numeric: true),
              ],
              rows: [
                for (final s in stats)
                  DataRow(cells: [
                    DataCell(Text(
                        '${displayName(s.from)} → ${displayName(s.to)}')),
                    DataCell(Text('${s.n}')),
                    DataCell(Text(f(s.shownMean))),
                    DataCell(Text(f(s.stableMean))),
                    DataCell(Text(f(s.firstCorrectMean))),
                    DataCell(Text('${s.timeouts}')),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Means from the cue. Shown = the screen first showed the new class; '
            'Steady = it then stayed for 3 s; First correct = the first raw '
            'model result. All include your reaction to the cue (~0.3 s) and '
            'the wait for the RESpeck packet (data arrives every 2.56 s). '
            'Timeouts: not steady within 30 s. Export gives every change and '
            'the per-change mean / median as CSV.',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
