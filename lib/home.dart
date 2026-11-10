import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'activity_catalog.dart';
import 'app_shell.dart' show AppTab, shellTab;
import 'har.dart';
import 'scanning.dart';
import 'services/app_settings.dart';
import 'services/prediction_repository.dart';
import 'services/sensor_controller.dart';
import 'services/social_sample_processor.dart';
import 'services/timeline.dart';
import 'services/user_session.dart';
import 'social.dart';
import 'user_page.dart';
import 'widgets/common.dart';
import 'widgets/day_timeline.dart';

/// Home tab: pair and connect the RESpeck, the live activity and social
/// signal, and today's timeline.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.sensor,
    this.socialProcessor,
    this.session,
    this.openRepository,
    this.onOpenChart,
  });

  final SensorController sensor;
  final SocialSampleProcessor? socialProcessor;
  final UserSession? session;

  /// Tests inject a repository; the app opens the user's history database.
  final Future<PredictionRepository> Function()? openRepository;
  final VoidCallback? onOpenChart;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  UserSession get _session => widget.session ?? userSession;
  SensorController get _sensor => widget.sensor;

  PredictionRepository? _repository;
  TimelineData? _today;
  Timer? _refresh;
  bool _loadingTimeline = false;

  @override
  void initState() {
    super.initState();
    widget.socialProcessor?.addListener(_changed);
    shellTab.addListener(_tabChanged);
    unawaited(_loadTimeline());
    _refresh = Timer.periodic(const Duration(seconds: 20), (_) {
      if (shellTab.value == AppTab.home) unawaited(_loadTimeline());
    });
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.socialProcessor != widget.socialProcessor) {
      oldWidget.socialProcessor?.removeListener(_changed);
      widget.socialProcessor?.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _tabChanged() {
    if (shellTab.value == AppTab.home) unawaited(_loadTimeline());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    shellTab.removeListener(_tabChanged);
    widget.socialProcessor?.removeListener(_changed);
    final repository = _repository;
    _repository = null;
    if (repository != null) {
      unawaited(repository.close().catchError((Object e) {
        debugPrint('Could not close history database: $e');
      }));
    }
    super.dispose();
  }

  Future<void> _loadTimeline() async {
    if (_loadingTimeline || !_session.loggedIn) return;
    _loadingTimeline = true;
    try {
      _repository ??=
          await (widget.openRepository ?? _session.openRepository)();
      if (!mounted) return;
      final data = await loadTimeline(_repository!, DateTime.now());
      if (!mounted) return;
      setState(() => _today = data);
    } catch (e) {
      debugPrint('Home timeline failed: $e');
    } finally {
      _loadingTimeline = false;
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: tabAppBar(context, 'PDIoT', session: _session),
      body: ListenableBuilder(
        listenable: Listenable.merge([_sensor, _session]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            if (!_session.loggedIn) _welcomeCard(context),
            _sensorCard(context),
            _harCard(context),
            _socialCard(context),
            if (_session.loggedIn) _todayCard(context),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ welcome --

  Widget _welcomeCard(BuildContext context) {
    return SectionCard(
      key: const ValueKey('welcome-card'),
      icon: Icons.waving_hand_outlined,
      title: 'Welcome',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Create a user (or log in) with the round button at the '
              'top left. Your sensor pairing, history and recordings are kept '
              'in your own folder.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => UserPage(session: _session))),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Log in / create user'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- sensor --

  Widget _sensorCard(BuildContext context) {
    final s = _sensor;
    final streaming = s.streaming;
    final loggedIn = _session.loggedIn;
    final paired = loggedIn && s.paired;
    IconData icon;
    Color color;
    String status;
    String detail;
    if (!loggedIn) {
      icon = Icons.lock_outline;
      color = Colors.grey.shade600;
      status = 'Log in to use a sensor';
      detail = 'The RESpeck is paired to your user';
    } else if (!paired) {
      icon = Icons.qr_code_scanner;
      color = Theme.of(context).colorScheme.primary;
      status = 'Pair your RESpeck';
      detail = 'Scan the QR code on the back of the sensor, or type its ID';
    } else if (s.connecting) {
      icon = Icons.bluetooth_searching;
      color = Colors.amber.shade700;
      status = 'Connecting…';
      detail = 'RESpeck ${_session.profile?.respeckId}';
    } else if (streaming) {
      icon = Icons.bluetooth_connected;
      color = Colors.green.shade600;
      status = 'Streaming live data';
      detail = 'RESpeck ${_session.profile?.respeckId}';
    } else {
      icon = Icons.bluetooth_disabled;
      color = Colors.grey.shade600;
      status = 'Not connected';
      detail = 'RESpeck ${_session.profile?.respeckId}';
    }
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      key: const ValueKey('sensor-card'),
      icon: Icons.sensors,
      title: 'Sensor',
      trailing: paired && !s.connecting
          ? PopupMenuButton<String>(
              key: const ValueKey('sensor-menu'),
              tooltip: 'Sensor options',
              onSelected: (v) => v == 'change' ? _pairDialog() : _forget(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'change', child: Text('Change sensor')),
                PopupMenuItem(value: 'forget', child: Text('Forget sensor')),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(status,
                        key: const ValueKey('connection-status'),
                        style: textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(detail, style: textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          if (paired &&
              (s.respeckBattery != null || s.accelText.isNotEmpty)) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (s.respeckBattery != null)
                  Chip(
                    avatar: Icon(
                        s.respeckCharging
                            ? Icons.battery_charging_full
                            : Icons.battery_std,
                        size: 18),
                    label: Text('Battery ${s.respeckBattery}%'
                        '${s.respeckCharging ? ' (charging)' : ''}'),
                    visualDensity: VisualDensity.compact,
                  ),
                if (s.accelText.isNotEmpty)
                  Chip(
                    avatar: const Icon(Icons.vibration, size: 18),
                    label: Text(s.accelText),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          if (paired && !streaming && !s.connecting) ...[
            const SizedBox(height: 8),
            Text(
                'Wake the RESpeck by shaking it (green light), then press '
                'Connect.',
                style: textTheme.bodySmall),
          ],
          if (loggedIn) ...[
            const SizedBox(height: 12),
            if (!paired)
              Row(
                children: [
                  FilledButton.icon(
                    key: const ValueKey('pair-scan'),
                    onPressed: _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR code'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('pair-manual'),
                    onPressed: _pairDialog,
                    child: const Text('Enter ID'),
                  ),
                ],
              )
            else
              Row(
                children: [
                  if (streaming || s.connected)
                    OutlinedButton.icon(
                      key: const ValueKey('disconnect-button'),
                      onPressed: _disconnect,
                      icon: const Icon(Icons.bluetooth_disabled),
                      label: const Text('Disconnect'),
                    )
                  else
                    FilledButton.icon(
                      key: const ValueKey('connect-button'),
                      onPressed: s.connecting ? null : _connect,
                      icon: const Icon(Icons.bluetooth),
                      label: const Text('Connect'),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _connect() async {
    final error = await _sensor.connect();
    if (error != null) {
      _message(error);
    } else if (_sensor.streaming) {
      _message('Connected to RESpeck ${_session.profile?.respeckId}');
    }
  }

  Future<void> _disconnect() async {
    await _sensor.disconnect();
    _message('Disconnected');
  }

  Future<void> _scan() async {
    final result = await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const ScanningPage()));
    if (!mounted) return;
    if (result is! String || result.trim().isEmpty) {
      _message('No QR code scanned');
      return;
    }
    await _pair(result);
  }

  Future<void> _pair(String id) async {
    try {
      if (_sensor.connected || _sensor.streaming) await _sensor.disconnect();
      await _session.setRespeck(id);
      _message('Paired with RESpeck ${id.trim()} - press Connect');
    } catch (e) {
      _message('Could not save the pairing: $e');
    }
  }

  Future<void> _pairDialog() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _RespeckIdDialog(initial: _session.profile?.respeckId),
    );
    if (id == null || id.trim().isEmpty || !mounted) return;
    await _pair(id);
  }

  Future<void> _forget() async {
    if (_sensor.connected || _sensor.streaming) await _sensor.disconnect();
    try {
      await _session.setRespeck(null);
      _message('Sensor forgotten');
    } catch (e) {
      _message('Could not forget the sensor: $e');
    }
  }

  // ----------------------------------------------------------- activity --

  Widget _harCard(BuildContext context) {
    final shown = _sensor.harShown;
    final raw = _sensor.harRaw;
    final textTheme = Theme.of(context).textTheme;
    final interval = stepLabel(appSettings.stepSamples.value);
    Widget body;
    if (harClassifier == null) {
      body = const Text('Classifier not available');
    } else if (shown == null) {
      body = Text(
        _sensor.streaming
            ? 'Collecting data… the first result appears about 4 s after '
                'data starts, then every $interval.'
            : 'Connect the RESpeck to start activity recognition.',
        style: textTheme.bodyMedium,
      );
    } else {
      final updated = _sensor.harUpdatedAt == null
          ? ''
          : 'Updated ${DateFormat('HH:mm:ss').format(_sensor.harUpdatedAt!.toLocal())}';
      final smoothing =
          appSettings.smoothHar.value ? ' · majority of last 3 results' : '';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PredictionDisplay(
            label: shown.label,
            confidence: shown.confidence,
            confidenceText:
                'Confidence: ${(shown.confidence * 100).toStringAsFixed(0)}%',
            labelKey: const ValueKey('har-prediction-label'),
            confidenceKey: const ValueKey('har-prediction-confidence'),
          ),
          const SizedBox(height: 8),
          Text('$updated$smoothing · new result every $interval',
              style: textTheme.bodySmall),
          if (raw != null && raw.label != shown.label)
            Text(
              'Latest raw result: ${displayName(raw.label)} '
              '(${(raw.confidence * 100).toStringAsFixed(0)}%)',
              style: textTheme.bodySmall,
            ),
        ],
      );
    }
    return SectionCard(
      icon: Icons.directions_run,
      title: 'Detected activity',
      trailing:
          shown == null ? null : Pill(labelInfo(shown.label).group.shortTitle),
      child: body,
    );
  }

  // ------------------------------------------------------------- social --

  Widget _socialCard(BuildContext context) {
    final processor = widget.socialProcessor;
    final status = processor?.status ?? SocialPredictionStatus.unavailable;
    final event = processor?.latestPrediction;
    final statusText = switch (status) {
      SocialPredictionStatus.unavailable => 'Social model unavailable',
      SocialPredictionStatus.disconnected => 'Disconnected',
      SocialPredictionStatus.collecting =>
        'Collecting data... (first result after about '
        '${socialWindowSeconds.toStringAsFixed(0)} s)',
      SocialPredictionStatus.ready => 'Live prediction',
      SocialPredictionStatus.error =>
        'Social inference error — reconnect to retry',
      SocialPredictionStatus.pausedMoving => 'Paused while you are moving',
    };
    final statusColor = switch (status) {
      SocialPredictionStatus.ready => Colors.green.shade600,
      SocialPredictionStatus.collecting => Colors.amber.shade700,
      SocialPredictionStatus.error => Colors.red.shade600,
      SocialPredictionStatus.pausedMoving => Colors.blueGrey.shade400,
      _ => Colors.grey.shade600,
    };
    final label = event?.prediction.label;
    final probabilities = event?.prediction.probabilities ?? const <double>[];
    final shownHar = _sensor.harShown;
    final paused = status == SocialPredictionStatus.pausedMoving;
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      key: const ValueKey('social-signal-result'),
      icon: Icons.graphic_eq,
      title: 'Social Signal',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: statusColor),
              const SizedBox(width: 6),
              Flexible(
                child: Text(statusText,
                    key: const ValueKey('social-prediction-status')),
              ),
            ],
          ),
          if (event != null &&
              label != null &&
              socialLabels.contains(label)) ...[
            const SizedBox(height: 12),
            PredictionDisplay(
              label: label,
              confidence: event.prediction.confidence,
              confidenceText: 'Confidence: '
                  '${(event.prediction.confidence * 100).toStringAsFixed(1)}%',
              labelKey: const ValueKey('social-prediction-label'),
              confidenceKey: const ValueKey('social-prediction-confidence'),
            ),
            if (probabilities.length == socialClassOrder.length) ...[
              const SizedBox(height: 12),
              for (var i = 0; i < socialClassOrder.length; i++)
                _ProbabilityRow(socialClassOrder[i], probabilities[i]),
            ],
          ],
          if (paused) ...[
            const SizedBox(height: 12),
            Row(
              key: const ValueKey('social-paused'),
              children: [
                Icon(
                    shownHar == null
                        ? Icons.directions_walk
                        : labelInfo(shownHar.label).icon,
                    size: 32,
                    color: Colors.blueGrey.shade400),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${shownHar == null ? 'Moving' : displayName(shownHar.label)}'
                    ' detected. Social signals resume as soon as you sit, '
                    'stand or lie still.',
                    style: textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Social signals are only detected while you are still (sitting, '
            'standing or lying down).',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- today --

  Widget _todayCard(BuildContext context) {
    final data = _today;
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      key: const ValueKey('today-card'),
      icon: Icons.view_timeline_outlined,
      title: 'Today',
      trailing: TextButton(
        onPressed: widget.onOpenChart,
        child: const Text('Open Chart'),
      ),
      child: data == null
          ? Text('Loading today…', style: textTheme.bodySmall)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatTile(formatDuration(data.monitored), 'monitored'),
                    _StatTile(
                        formatDuration(
                            data.groupTime(LabelGroup.dynamicActivity)),
                        'active'),
                    _StatTile('${data.coughBouts}', 'times coughed'),
                  ],
                ),
                const SizedBox(height: 12),
                DayTimeline(data: data, compact: true),
              ],
            ),
    );
  }
}

/// Asks for the RESpeck ID by hand (the text under the QR code). Owns its
/// text controller, so it is only disposed after the dialog has closed.
class _RespeckIdDialog extends StatefulWidget {
  const _RespeckIdDialog({this.initial});

  final String? initial;

  @override
  State<_RespeckIdDialog> createState() => _RespeckIdDialogState();
}

class _RespeckIdDialogState extends State<_RespeckIdDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('RESpeck ID'),
      content: TextField(
        key: const ValueKey('respeck-id-field'),
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'ID from the QR code',
          hintText: 'e.g. E0:3B:AB:69:5A:1C',
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            key: const ValueKey('respeck-id-save'),
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('Pair')),
      ],
    );
  }
}

/// One class probability as a thin bar, for the full Social output.
class _ProbabilityRow extends StatelessWidget {
  const _ProbabilityRow(this.label, this.probability);

  final String label;
  final double probability;

  @override
  Widget build(BuildContext context) {
    final info = labelInfo(label);
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(info.displayName,
                style: style, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: probability.clamp(0.0, 1.0),
                minHeight: 6,
                color: info.color,
                backgroundColor: info.color.withValues(alpha: 0.12),
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('${(probability * 100).toStringAsFixed(0)}%',
                style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile(this.value, this.caption);

  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style:
                  textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
          Text(caption,
              style: textTheme.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
