import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'services/ble_delay_test.dart';
import 'services/packet_feed.dart';
import 'services/sensor_controller.dart';
import 'services/user_session.dart';
import 'widgets/common.dart';

/// Tools › Sensor-to-app delay test: times how long a RESpeck packet takes to
/// reach the app (see services/ble_delay_test.dart for the method).
class BleDelayTestPage extends StatefulWidget {
  const BleDelayTestPage({
    super.key,
    required this.sensor,
    this.session,
    this.packets,
    this.phoneMotion,
    this.requireSensor = true,
    this.flickPeriod = const Duration(seconds: 4),
  });

  final SensorController sensor;
  final UserSession? session;

  /// RESpeck packets (default: the app's feed from ble.dart).
  final Stream<RespeckPacket>? packets;

  /// Phone motion (default: the phone's accelerometer, gravity removed).
  final Stream<PhoneMotion> Function()? phoneMotion;

  /// Only start while the RESpeck is streaming.
  final bool requireSensor;

  /// Time per flick: hold still, flick, hold still.
  final Duration flickPeriod;

  @override
  State<BleDelayTestPage> createState() => _BleDelayTestPageState();
}

enum _Phase { idle, running, done }

class _BleDelayTestPageState extends State<BleDelayTestPage> {
  UserSession get _session => widget.session ?? userSession;

  int _reps = 10;
  _Phase _phase = _Phase.idle;
  DateTime? _startedAt;
  Timer? _ticker;
  StreamSubscription<RespeckPacket>? _packetSub;
  StreamSubscription<PhoneMotion>? _phoneSub;
  final List<PhoneMotion> _phone = [];
  final List<RespeckMotion> _respeck = [];
  int _packets = 0;
  List<FlickResult> _results = [];
  bool _flickNow = false;
  int _currentFlick = 0;

  /// Time after the last flick, so its packet (up to 2.56 s later) arrives.
  static const _tail = Duration(seconds: 3);

  /// The first prompt comes after this much stillness.
  static const _lead = Duration(milliseconds: 2500);

  Duration get _total => _lead + widget.flickPeriod * _reps + _tail;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Stream<PhoneMotion> _defaultPhoneMotion() => userAccelerometerEventStream(
          samplingPeriod: SensorInterval.fastestInterval)
      .map((e) => PhoneMotion(
          e.timestamp, math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z) / 9.80665));

  void _start() {
    if (widget.requireSensor && !widget.sensor.streaming) {
      _snack('Connect the RESpeck on Home first - no live data is arriving');
      return;
    }
    _phone.clear();
    _respeck.clear();
    _packets = 0;
    _results = [];
    _currentFlick = 0;
    _flickNow = false;
    _packetSub = (widget.packets ?? respeckPacketFeed.packets).listen((p) {
      _packets++;
      _respeck.addAll(respeckMotionOf(p));
    });
    try {
      _phoneSub = (widget.phoneMotion ?? _defaultPhoneMotion)().listen(
          _phone.add,
          onError: (Object e) => _snack('Phone accelerometer error: $e'));
    } catch (e) {
      _stop();
      _snack('The phone accelerometer is not available: $e');
      return;
    }
    setState(() {
      _phase = _Phase.running;
      _startedAt = DateTime.now();
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _tick() {
    final start = _startedAt;
    if (start == null || !mounted) return;
    final elapsed = DateTime.now().difference(start);
    if (elapsed >= _total) {
      _finish();
      return;
    }
    // Each period: hold still, then 1 s "flick now", then hold still.
    final sinceLead = elapsed - _lead;
    var flick = false;
    var index = 0;
    if (!sinceLead.isNegative && sinceLead < widget.flickPeriod * _reps) {
      index = sinceLead.inMilliseconds ~/ widget.flickPeriod.inMilliseconds;
      final inPeriod =
          sinceLead.inMilliseconds % widget.flickPeriod.inMilliseconds;
      flick = inPeriod < 1000;
    }
    if (flick && !_flickNow) unawaited(HapticFeedback.heavyImpact());
    setState(() {
      _flickNow = flick;
      if (flick) _currentFlick = index + 1;
    });
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    unawaited(_packetSub?.cancel());
    unawaited(_phoneSub?.cancel());
    _packetSub = null;
    _phoneSub = null;
  }

  void _finish() {
    _stop();
    final results = BleDelayAnalysis().analyse(_phone, _respeck);
    setState(() {
      _results = results;
      _phase = _Phase.done;
      _flickNow = false;
    });
  }

  void _cancel() {
    _stop();
    setState(() {
      _phase = _Phase.idle;
      _flickNow = false;
    });
  }

  Future<void> _export() async {
    final folder = _session.exportsDir;
    if (folder == null) {
      _snack('Log in to export');
      return;
    }
    try {
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final flicksName = 'PDIoT_sensor_to_app_delay_$stamp.csv';
      final samplesName = 'PDIoT_sensor_to_app_delay_samples_$stamp.csv';
      await (await UserSession.fileIn(folder, flicksName))
          .writeAsString(flicksToCsv(_results));
      await (await UserSession.fileIn(folder, samplesName))
          .writeAsString(bleDelaySamplesToCsv(_phone, _respeck));
      _snack('Saved exports/$flicksName and $samplesName');
    } catch (e) {
      debugPrint('Sensor-to-app delay export failed: $e');
      _snack('Export failed');
    }
  }

  /// Phone accelerometer rate during the run (Hz), for the resolution.
  double? get _phoneHz {
    if (_phone.length < 2) return null;
    final s = _phone.last.at.difference(_phone.first.at).inMilliseconds / 1000;
    return s <= 0 ? null : (_phone.length - 1) / s;
  }

  @override
  Widget build(BuildContext context) {
    final running = _phase == _Phase.running;
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _snack('Cancel the test first');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sensor-to-app delay test'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            IconButton(
              tooltip: 'Export results as CSV',
              onPressed: _phase == _Phase.done ? _export : null,
              icon: const Icon(Icons.download),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              if (running) _runningCard(context) else _setupCard(context),
              if (_phase == _Phase.done) _resultsCard(context),
              _methodCard(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _setupCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      icon: Icons.bluetooth_searching,
      title: 'Time the sensor-to-app delay',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The phone\'s own accelerometer times each flick; the RESpeck\'s '
            'copy of the same flick arrives later over Bluetooth. For that, '
            'the two must move exactly together.',
            style: textTheme.bodyMedium,
          ),
          const _Heading('1. Get ready'),
          const _Step('Connect the RESpeck on Home (green light) and come '
              'back here.'),
          const _Heading('2. Position'),
          const _Step('Hold the phone in one hand, upright, screen facing '
              'you, so you can see the prompt.'),
          const _Step('Put the RESpeck flat on the middle of the back of the '
              'phone. Which way round does not matter.'),
          const _Step('Press it firmly with two fingers of the same hand, or '
              'fix it with a strip of tape. It must not slide, tilt or '
              'rattle: phone and RESpeck have to move as one block.'),
          const _Step('Keep your elbow against your side and hold the phone '
              'still.'),
          const _Heading('3. The flick'),
          const _Step('When the screen turns green, says FLICK and the phone '
              'vibrates: move the phone straight down about 10 cm, fast, '
              'and stop sharply. One movement, about a quarter of a second, '
              'like shaking down a thermometer once.'),
          const _Step('Then hold completely still until the next FLICK '
              '(about 3 s). The stillness before and after each flick '
              'matters as much as the flick.'),
          const _Heading('Avoid'),
          const _Step(
              'Tapping the RESpeck or the phone: a tap is too short '
              'for the RESpeck, which measures only 12.5 times a second.',
              bullet: '✕'),
          const _Step(
              'Twisting or tilting the phone, several small shakes, '
              'or flicking before the prompt.',
              bullet: '✕'),
          const _Step(
              'Letting the RESpeck lift off the phone during the '
              'flick.',
              bullet: '✕'),
          const SizedBox(height: 4),
          Text(
            'If many flicks say "the RESpeck hardly moved", press it harder '
            'or tape it and flick more firmly. "The two motions did not '
            'match" usually means the RESpeck slipped or there were two '
            'movements.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          const Text('Flicks', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            key: const ValueKey('ble-reps'),
            segments: const [
              ButtonSegment(value: 5, label: Text('5')),
              ButtonSegment(value: 10, label: Text('10')),
              ButtonSegment(value: 20, label: Text('20')),
            ],
            selected: {_reps},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _reps = v.single),
          ),
          const SizedBox(height: 4),
          Text(
              'Takes about ${_total.inSeconds} s '
              '(${widget.flickPeriod.inSeconds} s per flick).',
              style: textTheme.bodySmall),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('ble-start'),
              onPressed: _start,
              icon: const Icon(Icons.play_arrow),
              label: Text(_phase == _Phase.done ? 'Run again' : 'Start'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _runningCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final elapsed = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    final afterFlicks = elapsed >= _lead + widget.flickPeriod * _reps;
    return SectionCard(
      icon: Icons.bluetooth_searching,
      title: 'Test running',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: const ValueKey('ble-prompt'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: _flickNow
                  ? Colors.green.shade400
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  _flickNow ? 'FLICK' : 'Hold still',
                  style: textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _flickNow ? Colors.white : null),
                ),
                const SizedBox(height: 4),
                Text(
                  afterFlicks
                      ? 'Waiting for the last packets…'
                      : _flickNow
                          ? 'Down fast and stop · flick '
                              '${math.max(_currentFlick, 1)} of $_reps'
                          : 'Keep the RESpeck pressed to the phone · next: '
                              'flick ${math.min(_currentFlick + 1, _reps)} of $_reps',
                  style: textTheme.bodyMedium
                      ?.copyWith(color: _flickNow ? Colors.white : null),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: (elapsed.inMilliseconds / _total.inMilliseconds)
                .clamp(0.0, 1.0),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 8),
          Text('Phone samples: ${_phone.length} · RESpeck packets: $_packets',
              style: textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
        ],
      ),
    );
  }

  Widget _resultsCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final s = BleDelaySummary(_results);
    String ms(double? v) => v == null ? '–' : '${v.toStringAsFixed(0)} ms';
    final hz = _phoneHz;
    return SectionCard(
      key: const ValueKey('ble-results'),
      icon: Icons.analytics_outlined,
      title: 'Results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_results.isEmpty)
            Text(
              'No flick was felt by the phone. Flick more sharply when the '
              'screen says FLICK, then run it again.',
              style: textTheme.bodyMedium,
            )
          else ...[
            Row(
              children: [
                _Big('Median', ms(s.median)),
                _Big('Mean', ms(s.mean)),
                _Big(
                    'Range',
                    s.valid == 0
                        ? '–'
                        : '${s.min!.toStringAsFixed(0)}–${s.max!.toStringAsFixed(0)} ms'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${s.valid} of ${s.flicks} flicks timed'
              '${s.sd == null ? '' : ' · SD ${s.sd!.toStringAsFixed(0)} ms'}'
              '${hz == null ? '' : ' · phone accelerometer ${hz.toStringAsFixed(0)} Hz'}',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _results.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(width: 28, child: Text('${i + 1}')),
                    Expanded(
                      child: Text(
                        _results[i].valid
                            ? '${ms(_results[i].delay!.inMicroseconds / 1000)}'
                                '  (match ${_results[i].correlation!.toStringAsFixed(2)})'
                            : 'not timed: ${_results[i].reason}',
                        style: _results[i].valid
                            ? null
                            : textTheme.bodySmall?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _methodCard(BuildContext context) {
    return SectionCard(
      icon: Icons.info_outline,
      title: 'What is measured',
      child: Text(
        'Sensor-to-app delay = the time from the RESpeck finishing a packet '
        '(measuring its last sample) to that packet arriving in the app. It '
        'includes waiting for a Bluetooth slot, transmission (and any '
        'retries) and the phone\'s Bluetooth stack, plus any small '
        'processing inside the RESpeck. The two clocks are not synchronised, so '
        'the phone\'s accelerometer is used as the reference: for each flick '
        'the test finds the delay at which the RESpeck\'s motion lines up '
        'best with the phone\'s (match = correlation, 1 is perfect; below '
        '0.6 the flick is not timed). Each flick is good to about one phone '
        'accelerometer sample; use the median of 10 or more.\n'
        'Not included: the wait while the RESpeck fills the 32-sample '
        '(2.56 s) packet, which comes before it: a sample waits up to 2.48 s '
        '(1.24 s on average) and this is calculated separately. Export saves every flick and every '
        'sample as CSV.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big(this.caption, this.value);
  final String caption;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style:
                  textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          Text(caption, style: textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      );
}

/// One instruction line with a bullet.
class _Step extends StatelessWidget {
  const _Step(this.text, {this.bullet = '•'});
  final String text;
  final String bullet;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 20, child: Text(bullet, style: style)),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
