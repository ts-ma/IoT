import 'dart:io';

import 'package:flutter/material.dart';

import 'har.dart';
import 'services/app_metrics.dart';
import 'services/app_settings.dart';
import 'services/perf_sampler.dart';
import 'services/prediction_history_writer.dart';
import 'services/sensor_controller.dart';
import 'services/user_session.dart';
import 'social.dart' show socialWindowSeconds;
import 'widgets/common.dart';
import 'widgets/live_chart.dart';

/// Performance tab: live graphs of what the report's "Mobile app
/// performance" section asks for (CPU, memory, power, latency) plus the
/// sensor stream, model timing and storage, and a 1 s CSV log of all of it.
class PerformancePage extends StatefulWidget {
  const PerformancePage({
    super.key,
    this.historyWriter,
    this.metrics,
    this.sensor,
    this.sampler,
    this.session,
  });

  final UserSession? session;
  final PredictionHistoryWriter? historyWriter;
  final AppMetrics? metrics;
  final SensorController? sensor;
  final PerfSampler? sampler;

  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  AppMetrics get _m => widget.metrics ?? appMetrics;

  static const _cpuColor = Color(0xFF00E5FF);
  static const _memColor = Color(0xFFB388FF);
  static const _phoneColor = Color(0xFF69F0AE);
  static const _powerColor = Color(0xFFFFD740);
  static const _respeckColor = Color(0xFF40C4FF);
  static const _harColor = Color(0xFFFF6E40);
  static const _socialColor = Color(0xFFFF4081);
  static const _rateColor = Color(0xFF76FF03);
  static const _storageColor = Color(0xFFFFAB40);

  static String _ms(Duration d) =>
      '${(d.inMicroseconds / 1000).toStringAsFixed(2)} ms';

  static String _s(Duration d) => d == Duration.zero
      ? '–'
      : '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';

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

  Future<void> _toggleLog(PerfSampler sampler, bool on) async {
    final error = await sampler.setLogging(on);
    if (error != null) {
      _snack(error);
    } else if (on) {
      _snack('Logging every second to performance/'
          '${sampler.logFile?.uri.pathSegments.last}');
    } else {
      _snack('Performance log saved');
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
    final latest = sampler?.latest;
    final cores = Platform.numberOfProcessors;
    final hasPower = samples.any((s) => s.phonePowerMw != null);
    final m = _m;
    final har = harClassifier;
    final step = appSettings.stepSamples.value;
    final interval = step / sensorHz;
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
                  'app running with the sensor connected to measure it.',
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
            footnote: '% of one core · $cores cores · ${sampler.cpuSource}',
          ),
          LiveLineChart(
            title: 'Memory (RSS)',
            unit: 'MB',
            series: [ChartSeries('RAM', _memColor, pick((s) => s.rssMb))],
            capacity: cap,
            minRange: 50,
            digits: 0,
          ),
          LiveLineChart(
            title: 'Phone battery',
            unit: '%',
            series: [
              ChartSeries(
                  'Phone', _phoneColor, pick((s) => s.phoneLevel?.toDouble()))
            ],
            capacity: cap,
            maxY: 100,
            digits: 0,
            footnote: _drainText(sampler.phoneDrainPerHour,
                latest?.phoneCharging == true ? 'charging' : null),
          ),
          if (hasPower || !Platform.isIOS)
            LiveLineChart(
              title: 'Phone power draw',
              unit: 'mW',
              series: [
                ChartSeries('Power', _powerColor, pick((s) => s.phonePowerMw))
              ],
              capacity: cap,
              minRange: 500,
              digits: 0,
              footnote: hasPower
                  ? 'whole phone · ${latest?.phoneCurrentMa?.toStringAsFixed(0) ?? '–'} mA'
                  : 'waiting for the battery current…',
            ),
          LiveLineChart(
            title: 'RESpeck battery',
            unit: '%',
            series: [
              ChartSeries('RESpeck', _respeckColor,
                  pick((s) => s.respeckLevel?.toDouble()))
            ],
            capacity: cap,
            maxY: 100,
            digits: 0,
            footnote: _drainText(sampler.respeckDrainPerHour, null,
                empty: 'connect a v6 RESpeck'),
          ),
          LiveLineChart(
            title: 'Model inference time',
            unit: 'ms',
            series: [
              ChartSeries('HAR', _harColor, pick((s) => s.harMs)),
              ChartSeries('Social', _socialColor, pick((s) => s.socialMs)),
            ],
            capacity: cap,
            minRange: 2,
            digits: 2,
            footnote: 'time inside the TFLite call',
          ),
          LiveLineChart(
            title: 'Sensor sample rate',
            unit: 'Hz',
            series: [
              ChartSeries('Rate', _rateColor, pick((s) => s.sampleRateHz))
            ],
            capacity: cap,
            minRange: 15,
            footnote: 'nominal 12.5 Hz · ${m.lostPackets} packets lost',
          ),
          LiveLineChart(
            title: 'Storage used',
            unit: 'MB',
            series: [
              ChartSeries('Storage', _storageColor, pick((s) => s.storageMb))
            ],
            capacity: cap,
            minRange: 1,
            digits: 2,
            footnote: 'your folder (updated every 15 s)',
          ),
        ],
        SectionCard(
          icon: Icons.timer_outlined,
          title: 'Response time',
          child: Column(
            children: [
              _row('Update interval (Settings)',
                  '${interval.toStringAsFixed(2)} s ($step samples)'),
              _row('HAR window',
                  '${((har?.window.length ?? 50) / sensorHz).toStringAsFixed(0)} s'),
              _row('Social window',
                  '${socialWindowSeconds.toStringAsFixed(0)} s'),
              _row('HAR inference (last / mean / max)',
                  '${_ms(m.harInference.last)} / ${_ms(m.harInference.mean)} / ${_ms(m.harInference.max)}'),
              _row('Social inference (last / mean / max)',
                  '${_ms(m.socialInference.last)} / ${_ms(m.socialInference.mean)} / ${_ms(m.socialInference.max)}'),
              _row('HAR result interval (mean / max)',
                  '${_s(m.harUpdateInterval.mean)} / ${_s(m.harUpdateInterval.max)}'),
              _row('Social result interval (mean / max)',
                  '${_s(m.socialUpdateInterval.mean)} / ${_s(m.socialUpdateInterval.max)}'),
              const SizedBox(height: 6),
              Text(
                'Time until a new activity is shown ≈ time for most of the '
                'window to hold the new activity (about 4 s for HAR, 6-8 s '
                'for Social) + up to one update interval '
                '(${interval.toStringAsFixed(1)} s) + inference (a few ms). '
                'Inference runs on the phone, so there is no network delay. '
                'The real-time test in Tools measures the observed latency.',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
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
              _row(
                  'Last packet',
                  m.lastPacketAt == null
                      ? '–'
                      : '${DateTime.now().difference(m.lastPacketAt!).inMilliseconds} ms ago'),
              _row(
                  'RESpeck battery',
                  widget.sensor?.respeckBattery == null
                      ? '–'
                      : '${widget.sensor!.respeckBattery}%'),
            ],
          ),
        ),
        if (sampler != null)
          SectionCard(
            icon: Icons.battery_charging_full,
            title: 'Power',
            child: Column(
              children: [
                _row(
                    'Phone battery',
                    latest?.phoneLevel == null
                        ? '–'
                        : '${latest!.phoneLevel}%'
                            '${latest.phoneCharging == true ? ' (charging)' : ''}'),
                _row(
                    'Phone drain', _drainText(sampler.phoneDrainPerHour, null)),
                _row(
                    'Battery current',
                    latest?.phoneCurrentMa == null
                        ? 'n/a on this phone'
                        : '${latest!.phoneCurrentMa!.toStringAsFixed(0)} mA'),
                _row(
                    'Power draw (whole phone)',
                    latest?.phonePowerMw == null
                        ? 'n/a on this phone'
                        : '${latest!.phonePowerMw!.toStringAsFixed(0)} mW'),
                _row('RESpeck drain',
                    _drainText(sampler.respeckDrainPerHour, null)),
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
        if (widget.historyWriter != null)
          SectionCard(
            icon: Icons.storage,
            title: 'History writer',
            child: Column(
              children: [
                _row('Pending writes', '${widget.historyWriter!.pendingCount}'),
                _row('Write errors', '${widget.historyWriter!.errorCount}'),
                _row('Dropped records',
                    '${widget.historyWriter!.droppedRecordCount}'),
              ],
            ),
          ),
        SectionCard(
          icon: Icons.info_outline,
          title: 'How each number is measured',
          child: Text(
            '• CPU: CPU time of the whole app process (all threads) from '
            'getrusage(), on Android and iOS; % of one core per second.\n'
            '• Memory: resident memory (RSS) of the app process.\n'
            '• Phone battery: Android BatteryManager gives level, current and '
            'voltage (power = current × voltage, whole phone incl. screen); '
            'iOS only gives the level, so use Xcode Instruments (Energy Log) '
            'for power there.\n'
            '• RESpeck battery: reported in every packet (v6 firmware).\n'
            '• Inference: time inside each TFLite call, measured in the app.\n'
            '• For the report, compare with Android Studio Profiler or Xcode '
            'Instruments, and state the phone, run time and that inference '
            'runs on the device.',
            style: textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  String _drainText(double? perHour, String? state, {String? empty}) {
    if (state != null) return state;
    if (perHour == null) {
      return empty ?? 'drain shown after 10 min and a 1 % drop';
    }
    return '${perHour.toStringAsFixed(1)} %/h';
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
