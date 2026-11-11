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

  static String _statMs(DurationStat d, {int digits = 0}) {
    if (d.count == 0) return '–';
    String f(Duration x) => (x.inMicroseconds / 1000).toStringAsFixed(digits);
    return '${f(d.last)} / ${f(d.min)} / ${f(d.mean)} / ${f(d.max)} ms';
  }

  static String _statS(DurationStat d) {
    if (d.count == 0) return '–';
    String f(Duration x) => (x.inMilliseconds / 1000).toStringAsFixed(2);
    return '${f(d.last)} / ${f(d.min)} / ${f(d.mean)} / ${f(d.max)} s';
  }

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
            footnote: '% of one core · $cores cores · ${sampler.cpuSource}',
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
        if (sampler != null)
          LiveLineChart(
            title: 'Packet → display update',
            unit: 'ms',
            series: [
              ChartSeries(
                  'Processing', _storageColor, pick((s) => s.packetToDisplayMs),
                  connectGaps: true)
            ],
            capacity: cap,
            minRange: 5,
            digits: 1,
            dots: true,
            footnote: 'each packet: decoding + every model check in it + '
                'smoothing, until the result is handed to the screen',
          ),
        if (sampler != null) ...[
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
            title: 'RESpeck → phone extra delay',
            unit: 'ms',
            series: [
              ChartSeries('Delay', _respeckColor, pick((s) => s.packetDelayMs),
                  connectGaps: true)
            ],
            capacity: cap,
            minRange: 50,
            digits: 0,
            dots: true,
            footnote: 'how much later each packet arrived than the fastest of '
                'the last ${AppMetrics.delayWindow} · the fixed BLE delay is '
                'not measurable (the clocks are not synchronised) · samples '
                'also wait up to 2.56 s in the RESpeck to fill a packet',
          ),
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
              _row('Activity change shown (last / min / avg / max)',
                  _statS(m.activityChange)),
              _row('Social change shown (last / min / avg / max)',
                  _statS(m.socialChange)),
              _row('Switches without a clear signal change',
                  'activity ${m.activityUnclear} · social ${m.socialUnclear}'),
              _row('Packet → display (last / min / avg / max)',
                  _statMs(m.packetToDisplay, digits: 1)),
              const SizedBox(height: 6),
              Text(
                'Time until a change is shown ≈ wait for the RESpeck packet '
                'holding it (32 samples = 2.56 s, so 1.3 s on average) + time '
                'for enough of the window to hold the new activity (about 2 s '
                'of the 4 s HAR window, ${(socialWindowSeconds / 2).toStringAsFixed(0)} s '
                'of the ${socialWindowSeconds.toStringAsFixed(0)} s Social window) + up to '
                'one update interval (${interval.toStringAsFixed(1)} s) + '
                'smoothing (about one interval) + inference (a few ms). '
                'Inference runs on the phone, so there is no network delay. '
                'Social signals are paused while you move. The real-time test '
                'in Tools measures the observed latency.',
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
              _row('Packet interval (last / min / avg / max)',
                  _statS(m.packetInterval)),
              _row('Extra RESpeck → phone delay (last / min / avg / max)',
                  _statMs(m.packetExtraDelay)),
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
            '• Memory: Android total PSS (Debug.MemoryInfo, the "TOTAL PSS" of '
            'adb shell dumpsys meminfo) / iOS phys_footprint (TASK_VM_INFO, '
            'what Xcode\'s memory gauge shows), every 5 s; plus the resident '
            'set size (RSS), which also counts shared pages.\n'
            '• Phone battery: Android BatteryManager gives level, current and '
            'voltage (power = current × voltage, whole phone incl. screen); '
            'iOS only gives the level, so use Xcode Instruments (Power Profiler) '
            'or Settings › Battery for power there.\n'
            '• RESpeck battery: reported in every packet (v6 firmware).\n'
            '• Inference: time inside each TFLite call, measured in the app.\n'
            '• Time to show a change (live): the models re-check the last 4 s '
            '(activity) / 6 s (social) at every update; after you change, the '
            'window fills with the new movement and the screen switches. At '
            'each switch the app looks back 12 s / 14 s in the raw data, finds '
            'where the signal changed (best single split by per-axis '
            'variance, of the jerk or, for posture, the raw values) and times '
            'from there. Switches with no clear change are not counted. '
            'Checked offline on our recordings: 95-98 % within 1 s.\n'
            '• Packet → display: from a packet arriving to its results being '
            'handed to the screen (decoding, every model check, smoothing).\n'
            '• RESpeck → phone: each packet carries the RESpeck clock time. '
            'The clocks are not synchronised, so the app shows the delay '
            'above the fastest recent packet (variation, not the absolute '
            'BLE delay) and the time between packets.\n'
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
