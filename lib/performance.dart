import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'har.dart';
import 'services/app_metrics.dart';
import 'services/app_settings.dart';
import 'services/latency_test.dart';
import 'services/perf_sampler.dart';
import 'services/sensor_controller.dart';
import 'services/user_session.dart';
import 'social.dart'
    show socialLabels, socialModelAsset, socialWindowSamples;
import 'widgets/common.dart';
import 'widgets/live_chart.dart';

/// Performance tab: live graphs of what the report's "Mobile app
/// performance" section asks for (CPU, memory, latency) plus the sensor
/// stream, model timing and storage, and a 1 s CSV log of all of it. Power is
/// measured outside the app (Xcode Instruments / Android Studio).
class PerformancePage extends StatefulWidget {
  const PerformancePage({
    super.key,
    this.metrics,
    this.sensor,
    this.sampler,
    this.session,
  });

  final UserSession? session;
  final AppMetrics? metrics;
  final SensorController? sensor;
  final PerfSampler? sampler;

  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  AppMetrics get _m => widget.metrics ?? appMetrics;

  /// The model shown in the Response time card.
  _Model _model = _Model.har;

  /// Saved latency tests (Tools › Latency test), reloaded at most every 10 s
  /// while the page is shown, so new tests appear without a restart.
  List<LatencyRep> _latency = const [];
  DateTime? _latencyLoadedAt;
  bool _latencyLoading = false;

  UserSession get _session => widget.session ?? userSession;

  void _refreshLatency() {
    final loaded = _latencyLoadedAt;
    if (_latencyLoading ||
        (loaded != null &&
            DateTime.now().difference(loaded) < const Duration(seconds: 10))) {
      return;
    }
    _latencyLoading = true;
    _latencyLoadedAt = DateTime.now();
    unawaited(() async {
      // Never change state while the page is being drawn.
      await Future<void>.value();
      var reps = const <LatencyRep>[];
      try {
        final file = _session.latencyFile;
        if (file != null) reps = await LatencyStore(() async => file).load();
      } catch (e) {
        debugPrint('Could not read latency tests: $e');
      }
      _latencyLoading = false;
      if (mounted) setState(() => _latency = reps);
    }());
  }

  /// "Shown" times (s) of the latency tests for [task]: button-started
  /// changes that were shown, leaving out those started too early.
  List<double> _shownSeconds(LatencyTask task) => [
        for (final r in _latency)
          if (r.task == task &&
              r.start == 'button' &&
              r.shown != null &&
              !r.changingAtStart)
            r.shown!.inMilliseconds / 1000,
      ]..sort();



  static const _cpuColor = Color(0xFF00E5FF);
  static const _memColor = Color(0xFFB388FF);
  static const _harColor = Color(0xFFFF6E40);
  static const _socialColor = Color(0xFFFF4081);
  static const _rateColor = Color(0xFF76FF03);

  static String _ms(Duration d) =>
      '${(d.inMicroseconds / 1000).toStringAsFixed(2)} ms';

  static String _statS(DurationStat d) {
    if (d.count == 0) return '–';
    String f(Duration x) => (x.inMilliseconds / 1000).toStringAsFixed(2);
    return '${f(d.last)} / ${f(d.min)} / ${f(d.mean)} / ${f(d.max)} s';
  }

  static String _uptime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String _mb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  static String _deviceText(Map<String, Object?>? d) {
    if (d == null) return '';
    final name = [d['manufacturer'], d['model']]
        .whereType<String>()
        .where((t) => t.isNotEmpty)
        .join(' ');
    return '\nPhone: $name · ${Platform.isIOS ? 'iOS' : 'Android'} '
        '${d['osVersion'] ?? ''}';
  }

  Future<void> _toggleLog(PerfSampler sampler, bool on) async {
    final error = await sampler.setLogging(on);
    if (error != null) {
      _snack(error);
    } else if (on) {
      _snack('Logging every second to performance/'
          '${sampler.logFile?.uri.pathSegments.last}');
    } else {
      _snack('Performance log saved · averages per state (streaming / idle) '
          'are in its .conditions.json');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sampler = widget.sampler;
    return Scaffold(
      appBar:
          tabAppBar(context, 'Performance', session: widget.session, actions: [
        IconButton(
          tooltip: 'Reset counters and graphs',
          onPressed: () {
            _m.reset();
            sampler?.resetHistory();
            setState(() {});
          },
          icon: const Icon(Icons.restart_alt),
        ),
      ]),
      body: sampler == null
          ? _body(context, null)
          : ListenableBuilder(
              listenable: sampler,
              builder: (context, _) => _body(context, sampler),
            ),
    );
  }

  Widget _body(BuildContext context, PerfSampler? sampler) {
    final textTheme = Theme.of(context).textTheme;
    final samples = sampler?.samples ?? const <PerfSample>[];
    final cap = sampler?.capacity ?? 300;
    List<double?> pick(double? Function(PerfSample) f) =>
        [for (final s in samples) f(s)];
    final cores = Platform.numberOfProcessors;
    final m = _m;
    final storage = sampler?.storage;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (sampler != null)
          SectionCard(
            icon: Icons.monitor_heart_outlined,
            title: 'Live monitor',
            trailing:
                sampler.logging ? const Pill('LOG', color: Colors.red) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sampled every second, last ${cap ~/ 60} minutes. Leave the '
                  'app running with the sensor connected to measure it.'
                  '${_deviceText(sampler.device)}',
                  style: textTheme.bodySmall,
                ),
                SwitchListTile(
                  key: const ValueKey('perf-log'),
                  contentPadding: EdgeInsets.zero,
                  value: sampler.logging,
                  onChanged: (v) => _toggleLog(sampler, v),
                  title: const Text('Record performance log'),
                  subtitle: Text(sampler.logging
                      ? 'Writing ${sampler.logFile?.uri.pathSegments.last}'
                      : 'Save every sample to performance/ as CSV, for the '
                          'report\'s graphs'),
                ),
              ],
            ),
          ),
        if (sampler != null) ...[
          LiveLineChart(
            title: 'CPU',
            unit: '%',
            series: [ChartSeries('CPU', _cpuColor, pick((s) => s.cpuPercent))],
            capacity: cap,
            minRange: 10,
            footnote: 'this app only · 100 % = one core fully busy '
                '(this phone has $cores, so up to ${cores * 100} %)',
          ),
          LiveLineChart(
            title: 'Memory',
            unit: 'MB',
            series: [
              if (sampler.platformMemory != null)
                ChartSeries(sampler.platformMemory!.label, _memColor,
                    pick((s) => s.platformMemMb),
                    connectGaps: true),
              ChartSeries(
                  'RSS',
                  sampler.platformMemory != null ? _cpuColor : _memColor,
                  pick((s) => s.rssMb)),
            ],
            capacity: cap,
            minRange: 50,
            digits: 0,
            fill: sampler.platformMemory == null,
            footnote: sampler.platformMemory == null
                ? 'resident set size (RSS) of the app'
                : Platform.isIOS
                    ? 'Footprint = what Xcode\'s memory gauge shows (read every '
                        '5 s) · RSS also counts shared pages'
                    : 'Total PSS = "TOTAL PSS" of adb dumpsys meminfo (read '
                        'every 5 s) · RSS also counts shared libraries',
          ),
          LiveLineChart(
            title: 'Model inference time',
            unit: 'ms',
            series: [
              ChartSeries('HAR', _harColor, pick((s) => s.harMs),
                  connectGaps: true),
              ChartSeries('Social', _socialColor, pick((s) => s.socialMs),
                  connectGaps: true),
            ],
            capacity: cap,
            minRange: 2,
            digits: 2,
            fill: false,
            dots: true,
            footnote: 'time inside the TFLite call · the models run when a '
                'RESpeck packet arrives (every 2.56 s)',
          ),
        ],
        if (sampler != null) ...[
          LiveLineChart(
            title: 'Packet interval',
            unit: 's',
            series: [
              ChartSeries(
                  'Interval', _rateColor, pick((s) => s.packetIntervalS),
                  connectGaps: true)
            ],
            capacity: cap,
            minRange: 3,
            digits: 2,
            dots: true,
            footnote: 'time between packets on the phone · nominal 2.56 s '
                '(32 samples at 12.5 Hz)',
          ),
        ],
        _modelCard(context, m),
        SectionCard(
          icon: Icons.sensors,
          title: 'Sensor stream',
          child: Column(
            children: [
              _row(
                  'Status',
                  widget.sensor?.streaming == true
                      ? 'Streaming'
                      : 'Not streaming'),
              _row('Stream uptime', _uptime(m.streamUptime)),
              _row('Packets / samples', '${m.packets} / ${m.samples}'),
              _row('Measured sample rate',
                  '${m.sampleRateHz.toStringAsFixed(2)} Hz (nominal 12.5 Hz)'),
              _row('Lost packets',
                  '${m.lostPackets} (${m.packetLossPercent.toStringAsFixed(2)}%)'),
              _row('Packet interval (last / min / avg / max)',
                  _statS(m.packetInterval)),
            ],
          ),
        ),
        if (storage != null)
          SectionCard(
            icon: Icons.sd_storage_outlined,
            title: 'Storage',
            child: Column(
              children: [
                _row('History database', _mb(storage.database)),
                _row('Raw recordings (raw/)',
                    '${_mb(storage.raw)} · ${storage.rawFiles} files'),
                _row('Exports (exports/)', _mb(storage.exports)),
                _row('Performance logs', _mb(storage.performance)),
                _row('Other', _mb(storage.other)),
                const Divider(),
                _row('Total in your folder', _mb(storage.total)),
                const SizedBox(height: 6),
                Text(
                  'Raw data is about ${(12.5 * 3600 * 60 / (1024 * 1024)).toStringAsFixed(1)} '
                  'MB per recorded hour (≈60 bytes per sample at 12.5 Hz); '
                  'each saved result adds a small database row.',
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        SectionCard(
          icon: Icons.info_outline,
          title: 'How each number is measured',
          child: Text(
            '• Live monitor: everything below is sampled once a second; the '
            'graphs show the last ${cap ~/ 60} minutes. Record performance '
            'log writes one CSV row per second to performance/, plus a '
            '.conditions.json with the phone, settings, models and run time.\n'
            '• CPU: CPU time used by this app\'s own process (all its '
            'threads), from getrusage(), once a second. 100 % = one core fully '
            'busy, so a phone with $cores cores can reach ${cores * 100} %.\n'
            '• Memory: the app\'s memory as the system counts it, every 5 s: '
            'on iOS the footprint (what Xcode\'s memory gauge shows), on '
            'Android the total PSS (as adb shell dumpsys meminfo). RSS is also '
            'drawn; it counts shared pages too, so it reads higher.\n'
            '• Model inference time: time inside each TFLite model call only '
            '(the same for both models), averaged per second. The models run '
            'when a RESpeck packet arrives (every 2.56 s).\n'
            '• Packet interval: time between two packets arriving on the '
            'phone. It averages 2.56 s (32 samples at 12.5 Hz); a late packet '
            'makes one interval longer and the next one shorter.\n'
            '• Response time: one model at a time (drop-down). Model details '
            'and the official 10-fold cross-validation come from training. '
            'Time to show a change = mean and median of your latency tests '
            '(Tools › Latency test) for that model: from the button press to '
            'the new class on screen, leaving out changes started too early '
            'and changes never shown. Inference is measured in the app.\n'
            '• Sensor stream: the sample rate counts this connection only; '
            'lost packets come from the RESpeck\'s packet numbers (after a '
            'loss both model windows start afresh); the packet interval is '
            'as above.\n'
            '• Storage: sizes of the files in your folder, updated every 15 s.',
            style: textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// Response time card: everything about one model at a time (chosen in
  /// the drop-down): what it is, how it was trained and scored, how quickly
  /// it shows a change, and its measured inference time on this phone.
  Widget _modelCard(BuildContext context, AppMetrics m) {
    final textTheme = Theme.of(context).textTheme;
    final isHar = _model == _Model.har;
    final har = harClassifier;
    _refreshLatency();
    final shown =
        _shownSeconds(isHar ? LatencyTask.activity : LatencyTask.social);
    final n = shown.length;
    final mean = n == 0 ? null : shown.reduce((a, b) => a + b) / n;
    final median = n == 0
        ? null
        : n.isOdd
            ? shown[n ~/ 2]
            : (shown[n ~/ 2 - 1] + shown[n ~/ 2]) / 2;
    String secs(double? v) => v == null
        ? '– (no latency tests yet)'
        : '${v.toStringAsFixed(2)} s ($n change${n == 1 ? '' : 's'})';
    final stat = isHar ? m.harInference : m.socialInference;
    final windowSamples =
        isHar ? (har?.window.length ?? 50) : socialWindowSamples;
    final classes = isHar ? (har?.classes.length ?? 11) : socialLabels.length;
    final file = (isHar ? harModelAsset : socialModelAsset).split('/').last;
    return SectionCard(
      icon: Icons.timer_outlined,
      title: 'Response time',
      trailing: DropdownButton<_Model>(
        key: const ValueKey('model-select'),
        value: _model,
        underline: const SizedBox.shrink(),
        onChanged: (v) => setState(() => _model = v ?? _model),
        items: const [
          DropdownMenuItem(value: _Model.har, child: Text('Activity (HAR)')),
          DropdownMenuItem(value: _Model.social, child: Text('Social signal')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Model file', file),
          _row('Architecture', 'Multi-branch CNN'),
          _row('Classes', '$classes'),
          _row('Window',
              '$windowSamples samples (${(windowSamples / sensorHz).toStringAsFixed(0)} s)'),
          _row('New result every',
              '${(updateInterval.inMilliseconds / 1000).toStringAsFixed(2)} s '
                  '($updateStepSamples samples)'),
          if (!isHar) _row('Runs', 'only while you are still'),
          _row('Runs on', 'this phone (TensorFlow Lite), no server'),
          _row('Trained on',
              'datasetJan2026 + both members\' recordings, mixed; favours '
                  'the most recent seconds'),
          if (isHar)
            _row('Official 10-fold CV',
                'static 99.4 % · dynamic 89.5 % (targets 90 % / 85 %)')
          else
            _row(
                'Official 10-fold CV',
                'breathing 89.3 % · coughing 78.0 % · hyperventilation '
                    '79.2 % · other 76.6 % (target 75 % each)'),
          _row('Time to show a change, mean (latency test)', secs(mean)),
          _row('Time to show a change, median (latency test)', secs(median)),
          _row('Inference (last / mean / max)',
              stat.count == 0
                  ? '–'
                  : '${_ms(stat.last)} / ${_ms(stat.mean)} / ${_ms(stat.max)}'),
          _row('Inferences on this phone', '${stat.count}'),
          const SizedBox(height: 6),
          Text(
            'Time to show a change ≈ wait for the RESpeck packet holding it '
            '(32 samples = 2.56 s, 1.3 s on average) + time for the model to '
            'see enough of the new ${isHar ? 'activity' : 'signal'} (it '
            'favours the most recent seconds of its '
            '${(windowSamples / sensorHz).toStringAsFixed(0)} s window) + '
            'inference (a few ms). Mean and median are from your saved latency '
            'tests (Tools › Latency test) for this model, from the button press '
            'to the new class on screen; changes started too early or never '
            'shown are left out.${isHar ? '' : ' Social signals are paused while you move.'}',
            style: textTheme.bodySmall,
          ),
        ],
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
}

enum _Model { har, social }
