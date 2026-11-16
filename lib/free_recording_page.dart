import 'dart:async';

import 'package:flutter/material.dart';

import 'services/raw_recorder.dart';
import 'services/sensor_controller.dart';
import 'services/user_session.dart';
import 'utils.dart' show sentenceToCamelCase;
import 'widgets/common.dart';

/// Tools › Free recording: raw sensor data to the user's raw/ folder with
/// chosen labels and no time limit (the original data-collection tool). The
/// recording keeps going if you leave this page; Tools shows "REC" while it
/// runs.
class FreeRecordingPage extends StatefulWidget {
  const FreeRecordingPage({super.key, required this.sensor, this.session});

  final SensorController sensor;
  final UserSession? session;

  @override
  State<FreeRecordingPage> createState() => _FreeRecordingPageState();
}

class _FreeRecordingPageState extends State<FreeRecordingPage> {
  UserSession get _session => widget.session ?? userSession;
  RawRecorder get _recorder => widget.sensor.recorder;

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

  bool get _freeRecording => _recorder.active && _recorder.purpose == 'free';

  /// A real-time trial is saving its raw data: no free recording meanwhile.
  bool get _trialRecording => _recorder.active && _recorder.purpose == 'trial';

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_changed);
    widget.sensor.addListener(_changed);
    if (_freeRecording) {
      _freeTicker =
          Timer.periodic(const Duration(seconds: 1), (_) => _changed());
    }
  }

  @override
  void dispose() {
    _recorder.removeListener(_changed);
    widget.sensor.removeListener(_changed);
    _freeTicker?.cancel();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Free recording'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: !_session.loggedIn
          ? LoginPrompt(session: _session, what: 'record raw data')
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [_freeRecordingCard(context)],
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
                        onPressed: _trialRecording ? null : _startFree,
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
