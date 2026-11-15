import 'package:flutter/material.dart';

import 'ble_delay_page.dart';
import 'free_recording_page.dart';
import 'latency_page.dart';
import 'realtime_test_page.dart';
import 'services/evaluation.dart';
import 'services/live_feed.dart';
import 'services/sensor_controller.dart';
import 'services/user_session.dart';
import 'widgets/common.dart';

/// Tools tab: one card per tool, each opening the tool on its own page.
///
/// * Real-time test: scored trials for the real-time accuracy table.
/// * Latency test: how long a change takes to show on screen.
/// * Sensor-to-app delay test: from the RESpeck finishing a packet to that
///   packet arriving in the app.
/// * Free recording: labelled raw sensor data with no time limit.
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

  /// Passed to the real-time test (tests inject these).
  final EvaluationStore? store;
  final LivePredictionFeed? feed;
  final UserSession? session;

  /// Defaults to true: tests only start while the RESpeck is streaming.
  final bool? requireSensor;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  UserSession get _session => widget.session ?? userSession;

  @override
  void initState() {
    super.initState();
    widget.sensor.recorder.addListener(_changed);
  }

  @override
  void dispose() {
    widget.sensor.recorder.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _open(Widget page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final recorder = widget.sensor.recorder;
    final freeRecording = recorder.active && recorder.purpose == 'free';
    return Scaffold(
      appBar: tabAppBar(context, 'Tools', session: _session),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _ToolCard(
            icon: Icons.fact_check_outlined,
            title: 'Real-time test',
            text: 'Timed, scored trials: a participant does a known activity '
                'and social signal while the app checks what it shows. Builds '
                'the per-class accuracy table and the dashboard for the '
                'report, and saves each trial\'s raw data.',
            buttonKey: const ValueKey('open-realtime-test'),
            button: 'Open real-time test',
            onOpen: () => _open(RealtimeTestPage(
              sensor: widget.sensor,
              session: _session,
              store: widget.store,
              feed: widget.feed,
              requireSensor: widget.requireSensor,
            )),
          ),
          _ToolCard(
            icon: Icons.timer_outlined,
            title: 'Latency test',
            text: 'How long the app takes to show a change, on this phone: '
                'once you are steady, press the button and change straight '
                'away; it measures from your press until the new activity or '
                'social signal is shown. For the report\'s communication '
                'latency.',
            buttonKey: const ValueKey('open-latency-test'),
            button: 'Open latency test',
            onOpen: () => _open(LatencyTestPage(
              sensor: widget.sensor,
              session: _session,
              feed: widget.feed ?? liveFeed,
              requireSensor: widget.requireSensor ?? true,
            )),
          ),
          _ToolCard(
            icon: Icons.bluetooth_searching,
            title: 'Sensor-to-app delay test',
            text: 'The time from the RESpeck finishing a packet (measuring its '
                'last sample) to that packet arriving in the app. Hold the '
                'RESpeck against the back of the phone and flick both '
                'together: the phone\'s own accelerometer times each flick, '
                'and the RESpeck\'s copy arrives later over Bluetooth.',
            buttonKey: const ValueKey('open-ble-delay-test'),
            button: 'Open sensor-to-app delay test',
            onOpen: () => _open(BleDelayTestPage(
              sensor: widget.sensor,
              session: _session,
              requireSensor: widget.requireSensor ?? true,
            )),
          ),
          _ToolCard(
            icon: Icons.fiber_manual_record_outlined,
            title: 'Free recording',
            trailing:
                freeRecording ? const Pill('REC', color: Colors.red) : null,
            text: 'Record raw accelerometer data with no time limit, labelled '
                'with the activity and social signal being performed (e.g. '
                'new training data). Files go to '
                '${_session.username ?? '<user>'}/raw/. Keeps recording if '
                'you leave the page.',
            buttonKey: const ValueKey('open-free-recording'),
            button: 'Open free recording',
            onOpen: () => _open(
                FreeRecordingPage(sensor: widget.sensor, session: _session)),
          ),
        ],
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.title,
    required this.text,
    required this.button,
    required this.buttonKey,
    required this.onOpen,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String text;
  final String button;
  final Key buttonKey;
  final VoidCallback onOpen;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      icon: icon,
      title: title,
      trailing: trailing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: buttonKey,
            onPressed: onOpen,
            icon: Icon(icon),
            label: Text(button),
          ),
        ],
      ),
    );
  }
}
