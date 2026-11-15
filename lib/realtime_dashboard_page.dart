import 'package:flutter/material.dart';

import 'activity_catalog.dart';
import 'services/evaluation.dart';
import 'widgets/common.dart';

/// Real-time accuracy dashboard (Tools › Real-time test › Open dashboard).
///
/// Shows the saved real-time trials the way the report needs them:
///  - the coursework groups (static, dynamic, social), with how many of their
///    classes were tested and how many trials gave no result;
///  - every dynamic activity on its own (social signals are not assessed
///    while moving);
///  - every static activity + social signal combination (5 x 4 = 20), with
///    the activity accuracy and the social accuracy of those trials.
/// Accuracy is the shown accuracy: screen updates showing the right class /
/// all scored screen updates, as in the Results table.
class RealtimeDashboardPage extends StatefulWidget {
  const RealtimeDashboardPage({super.key, required this.trials});

  final List<EvaluationTrial> trials;

  @override
  State<RealtimeDashboardPage> createState() => _RealtimeDashboardPageState();
}

/// Coursework targets: each static class 90 %, dynamic 85 %, social 75 %.
double targetFor(LabelGroup group) => switch (group) {
      LabelGroup.staticActivity => 0.90,
      LabelGroup.dynamicActivity => 0.85,
      LabelGroup.social => 0.75,
    };

class _RealtimeDashboardPageState extends State<RealtimeDashboardPage> {
  /// Null = every participant.
  String? _participant;

  List<EvaluationTrial> get _selected => _participant == null
      ? widget.trials
      : widget.trials.where((t) => t.participant == _participant).toList();

  @override
  Widget build(BuildContext context) {
    final participants = {for (final t in widget.trials) t.participant}.toList()
      ..sort();
    final trials = _selected;
    final summary = EvaluationSummary.from(trials);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Real-time accuracy'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            if (participants.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('dashboard-all'),
                      label: const Text('Everyone'),
                      selected: _participant == null,
                      onSelected: (_) => setState(() => _participant = null),
                    ),
                    for (final p in participants)
                      ChoiceChip(
                        label: Text(p),
                        selected: _participant == p,
                        onSelected: (_) => setState(() => _participant = p),
                      ),
                  ],
                ),
              ),
            _overviewCard(context, trials, summary),
            _dynamicCard(context, summary),
            _staticSocialCard(context, trials, summary),
            _notes(context),
          ],
        ),
      ),
    );
  }

  Widget _overviewCard(BuildContext context, List<EvaluationTrial> trials,
      EvaluationSummary summary) {
    final textTheme = Theme.of(context).textTheme;
    final combos = {
      for (final t in trials)
        if (t.trueSocial != null &&
            labelInfo(t.trueActivity).group == LabelGroup.staticActivity)
          '${t.trueActivity}|${t.trueSocial}'
    }.length;
    return SectionCard(
      icon: Icons.dashboard_outlined,
      title: 'Overview',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final g in LabelGroup.values)
                Expanded(
                  child: _GroupTile(
                    key: ValueKey('dashboard-group-${g.name}'),
                    group: g,
                    mean: summary.groupShownMean(g),
                    tested: summary.testedIn(g),
                    expected: EvaluationSummary.expectedIn(g).length,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${trials.length} trials · '
            '${summary.noResultTrials} with no result (counted as 0 %) · '
            'static + social combinations tested: $combos of '
            '${_staticLabels.length * socialClassOrder.length}',
            key: const ValueKey('dashboard-coverage'),
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _dynamicCard(BuildContext context, EvaluationSummary summary) {
    final labels = EvaluationSummary.expectedIn(LabelGroup.dynamicActivity);
    return SectionCard(
      icon: Icons.directions_run,
      title: 'Dynamic activities',
      child: Column(
        children: [
          for (final l in labels)
            _AccuracyRow(
              key: ValueKey('dashboard-dynamic-$l'),
              label: l,
              score: _score(summary, l),
              target: targetFor(LabelGroup.dynamicActivity),
            ),
        ],
      ),
    );
  }

  Widget _staticSocialCard(BuildContext context, List<EvaluationTrial> trials,
      EvaluationSummary summary) {
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      icon: Icons.airline_seat_recline_normal,
      title: 'Static activities + social signals',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final a in _staticLabels) ...[
            _AccuracyRow(
              key: ValueKey('dashboard-static-$a'),
              label: a,
              score: _score(summary, a),
              target: targetFor(LabelGroup.staticActivity),
              bold: true,
            ),
            for (final s in socialClassOrder)
              _ComboRow(
                key: ValueKey('dashboard-combo-$a-$s'),
                social: s,
                summary: EvaluationSummary.from([
                  for (final t in trials)
                    if (t.trueActivity == a && t.trueSocial == s) t,
                ]),
                activity: a,
              ),
            if (a != _staticLabels.last) const Divider(height: 20),
          ],
          const SizedBox(height: 8),
          Text(
            'Each combination row: Activity = was the right activity shown, '
            'Social = was the right social signal shown, in the trials of '
            'that pair.',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _notes(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(
        'Accuracy = screen updates (one per RESpeck packet, after the '
        'warm-up) showing the right class / all scored screen updates. For '
        'social signals, "paused" or no result on screen counts as wrong, and '
        'a trial that gave no result at all counts as 0 %. Group values are '
        'the mean of their tested classes, as in the coursework marking; '
        'untested classes are not in the mean, so check "x of y tested". '
        'Targets: each static class 90 %, dynamic 85 %, social 75 %.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  static List<String> get _staticLabels =>
      EvaluationSummary.expectedIn(LabelGroup.staticActivity);

  static ClassScore? _score(EvaluationSummary summary, String label) {
    for (final s in summary.scores) {
      if (s.label == label) return s;
    }
    return null;
  }
}

String _pct(double? v) => v == null ? '–' : '${(v * 100).toStringAsFixed(0)}%';

Color _passColor(BuildContext context, double? value, double target) {
  if (value == null) return Theme.of(context).colorScheme.onSurfaceVariant;
  return value >= target ? Colors.green.shade600 : Colors.orange.shade700;
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    super.key,
    required this.group,
    required this.mean,
    required this.tested,
    required this.expected,
  });

  final LabelGroup group;
  final double? mean;
  final int tested;
  final int expected;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(_pct(mean),
            style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: _passColor(context, mean, targetFor(group)))),
        Text(group.shortTitle, style: textTheme.bodyMedium),
        Text('$tested of $expected tested', style: textTheme.bodySmall),
      ],
    );
  }
}

/// One class: icon, name, accuracy bar and figures.
class _AccuracyRow extends StatelessWidget {
  const _AccuracyRow({
    super.key,
    required this.label,
    required this.score,
    required this.target,
    this.bold = false,
  });

  final String label;
  final ClassScore? score;
  final double target;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final info = labelInfo(label);
    final s = score;
    final acc = s?.shownAccuracy;
    final tested = s != null && s.trials > 0;
    final detail = !tested
        ? 'not tested'
        : '${s.trials} trial${s.trials == 1 ? '' : 's'}'
            '${s.noResultTrials > 0 ? ' · ${s.noResultTrials} no result' : ''}'
            '${s.meanShownLatency == null ? '' : ' · shown after ${(s.meanShownLatency!.inMilliseconds / 1000).toStringAsFixed(1)} s'}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(info.icon, size: 20, color: info.color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(info.displayName,
                          style: bold
                              ? textTheme.titleSmall
                              : textTheme.bodyMedium),
                    ),
                    Text(_pct(acc),
                        style: textTheme.titleSmall?.copyWith(
                            color: _passColor(context, acc, target))),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: acc ?? 0,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  color: _passColor(context, acc, target),
                ),
                const SizedBox(height: 2),
                Text(detail, style: textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One static activity + social signal pair: activity and social accuracy.
class _ComboRow extends StatelessWidget {
  const _ComboRow({
    super.key,
    required this.social,
    required this.activity,
    required this.summary,
  });

  final String social;
  final String activity;

  /// Built from the trials of this pair only.
  final EvaluationSummary summary;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    ClassScore? find(String l) {
      for (final s in summary.scores) {
        if (s.label == l) return s;
      }
      return null;
    }

    final a = find(activity);
    final s = find(social);
    final trials = a?.trials ?? 0;
    final info = labelInfo(social);
    final dim = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 30, top: 3, bottom: 3),
      child: Row(
        children: [
          Icon(info.icon, size: 16, color: trials == 0 ? dim : info.color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              trials == 0
                  ? '${info.displayName} · not tested'
                  : '${info.displayName} · $trials',
              style: textTheme.bodySmall
                  ?.copyWith(color: trials == 0 ? dim : null),
            ),
          ),
          if (trials > 0) ...[
            _MiniValue('Activity', a?.shownAccuracy,
                targetFor(LabelGroup.staticActivity)),
            const SizedBox(width: 12),
            _MiniValue(
                'Social', s?.shownAccuracy, targetFor(LabelGroup.social)),
          ],
        ],
      ),
    );
  }
}

class _MiniValue extends StatelessWidget {
  const _MiniValue(this.caption, this.value, this.target);

  final String caption;
  final double? value;
  final double target;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: 64,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(_pct(value),
              style: textTheme.labelLarge
                  ?.copyWith(color: _passColor(context, value, target))),
          Text(caption, style: textTheme.labelSmall),
        ],
      ),
    );
  }
}
