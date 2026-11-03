import 'dart:async';

import 'package:flutter/material.dart';

import 'ble.dart' show respeckStreaming;
import 'har.dart';
import 'services/app_metrics.dart';
import 'services/prediction_history_writer.dart';

/// Live performance figures for the report's "Mobile app performance"
/// section: data rate and packet loss, model inference time and how often
/// each result is refreshed. CPU, memory and battery use are measured with
/// Android Studio's Profiler (or Xcode Instruments) while this page is
/// closed, so the measurement itself does not add load.
class PerformancePage extends StatefulWidget {
  const PerformancePage({super.key, this.historyWriter, this.metrics});

  final PredictionHistoryWriter? historyWriter;
  final AppMetrics? metrics;

  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  Timer? _refresh;

  AppMetrics get _m => widget.metrics ?? appMetrics;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  static String _ms(Duration d) =>
      '${(d.inMicroseconds / 1000).toStringAsFixed(2)} ms';

  static String _s(Duration d) =>
      d == Duration.zero ? '–' : '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';

  static String _uptime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    final writer = widget.historyWriter;
    final har = harClassifier;
    final lastPacket = m.lastPacketAt;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Performance'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Reset counters',
            onPressed: () => setState(m.reset),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            _section(context, 'Sensor stream', Icons.sensors, [
              _row('Status', respeckStreaming ? 'Streaming' : 'Not streaming'),
              _row('Stream uptime', _uptime(m.streamUptime)),
              _row('Packets received', '${m.packets}'),
              _row('Samples received', '${m.samples}'),
              _row('Measured sample rate',
                  '${m.sampleRateHz.toStringAsFixed(2)} Hz (nominal 12.5 Hz)'),
              _row('Lost packets',
                  '${m.lostPackets} (${m.packetLossPercent.toStringAsFixed(2)}%)'),
              _row(
                  'Last packet',
                  lastPacket == null
                      ? '–'
                      : '${DateTime.now().difference(lastPacket).inMilliseconds} ms ago'),
            ]),
            _section(context, 'Activity model (HAR)', Icons.directions_run, [
              _row('Model', harClassifier == null ? 'Not loaded' : harModelAsset.split('/').last),
              if (har != null)
                _row('Window / step',
                    '${har.window.length} / ${har.window.step} samples '
                    '(${(har.window.length / 12.5).toStringAsFixed(1)} s / '
                    '${(har.window.step / 12.5).toStringAsFixed(1)} s)'),
              _row('Inferences', '${m.harInference.count}'),
              _row('Inference time (last)', _ms(m.harInference.last)),
              _row('Inference time (mean)', _ms(m.harInference.mean)),
              _row('Inference time (max)', _ms(m.harInference.max)),
              _row('Result interval (mean)', _s(m.harUpdateInterval.mean)),
              _row('Result interval (max)', _s(m.harUpdateInterval.max)),
            ]),
            _section(context, 'Social signal model', Icons.graphic_eq, [
              _row('Inferences', '${m.socialInference.count}'),
              _row('Inference time (last)', _ms(m.socialInference.last)),
              _row('Inference time (mean)', _ms(m.socialInference.mean)),
              _row('Inference time (max)', _ms(m.socialInference.max)),
              _row('Result interval (mean)', _s(m.socialUpdateInterval.mean)),
              _row('Result interval (max)', _s(m.socialUpdateInterval.max)),
            ]),
            if (writer != null)
              _section(context, 'History database', Icons.storage, [
                _row('Pending writes', '${writer.pendingCount}'),
                _row('Write errors', '${writer.errorCount}'),
                _row('Dropped records', '${writer.droppedRecordCount}'),
              ]),
            _section(context, 'How to read these numbers', Icons.info_outline, [
              Text(
                'End-to-end latency ≈ time for the window to fill with the new '
                'activity (up to 4 s for HAR, 8 s for Social) + result interval '
                '(2 s) + inference time. '
                'Inference runs on the phone, so no network delay is added. '
                'Use the Real-time test page to measure the observed latency, '
                'and Android Studio Profiler (CPU, Memory, Energy) or Xcode '
                'Instruments for CPU, RAM and battery use.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _row(String name, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: Text(name)),
          Expanded(
            flex: 6,
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _section(
      BuildContext context, String title, IconData icon, List<Widget> rows) {
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
            const SizedBox(height: 8),
            ...rows,
          ],
        ),
      ),
    );
  }
}
