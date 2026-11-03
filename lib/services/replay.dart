import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

// Replay of recorded RESpeck data for the demonstration (Coursework 3: "a
// combination of live and recorded data, the latter for activities that would
// be difficult to demonstrate live, such as ascending or descending stairs").
//
// A recording is streamed sample by sample at the RESpeck's own rate
// (12.5 Hz, or faster on request) into exactly the same pipeline as live BLE
// data: the HAR and Social classifiers, the history writer and the home cards.
// Nothing about the models changes; only where the samples come from.

/// Sampling rate of the RESpeck and of every recording.
const double replaySampleRate = 12.5;

/// Ground truth read from a recording's file name, as model class names.
/// [social] is null for moving activities, which have no social label.
class RecordingLabels {
  const RecordingLabels({this.har, this.social});
  final String? har;
  final String? social;
}

// Activity part of a file name, lower-cased with any "on" removed: covers both
// the app's raw names (lyingDownOnLeft) and the cleaned CW2 names
// (LyingDownLeft).
const Map<String, String> _activityToHar = {
  'sitting': 'sittingStanding',
  'standing': 'sittingStanding',
  'lyingdownback': 'lyingBack',
  'lyingdownleft': 'lyingLeft',
  'lyingdownright': 'lyingRight',
  'lyingdownstomach': 'lyingStomach',
  'normalwalking': 'normalWalking',
  'shufflewalking': 'shuffleWalking',
  'ascendingstairs': 'ascending',
  'descendingstairs': 'descending',
  'running': 'running',
  'miscellaneousmovements': 'miscMovement',
};

const Map<String, String> _signalToSocial = {
  'normal': 'breathingNormally',
  'coughing': 'coughing',
  'hyperventilating': 'hyperventilation',
  'talking': 'other',
  'eating': 'other',
  'singing': 'other',
  'laughing': 'other',
};

const Set<String> _staticHar = {
  'sittingStanding',
  'lyingBack',
  'lyingLeft',
  'lyingRight',
  'lyingStomach',
};

/// Labels from `PDIOT_<id>_<Activity>_<Signal>_...csv` (cleaned CW2 files) or
/// `PDIoT_<id>_<activity>_<signal>_...csv` (raw app recordings). Unknown parts
/// give null labels; the file can still be replayed.
RecordingLabels labelsFromFileName(String fileName) {
  final parts = p.basenameWithoutExtension(fileName).split('_');
  if (parts.length < 4 || parts.first.toLowerCase() != 'pdiot') {
    return const RecordingLabels();
  }
  final activity = parts[2].toLowerCase().replaceAll('on', '');
  final har = _activityToHar[activity];
  final social = har != null && _staticHar.contains(har)
      ? _signalToSocial[parts[3].toLowerCase()]
      : null;
  return RecordingLabels(har: har, social: social);
}

/// Reads x, y, z (g) from a recording. Accepts the app's raw CSV
/// (receivedPhoneTimestamp,...,accelX,accelY,accelZ), the cleaned CW2 format
/// (timestamp,accelX,accelY,accelZ) and headerless files (last three columns).
/// Rows that are not three finite numbers are skipped.
List<List<double>> parseAccelCsv(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return [];
  final header = lines.first.split(',').map((c) => c.trim()).toList();
  final lower = header.map((c) => c.toLowerCase()).toList();
  var columns = [
    lower.indexOf('accelx'),
    lower.indexOf('accely'),
    lower.indexOf('accelz'),
  ];
  var body = lines.skip(1);
  if (columns.contains(-1)) {
    // No usable header: use the last three columns of every row, and keep
    // the first row too if it is numeric.
    final n = header.length;
    if (n < 3) return [];
    columns = [n - 3, n - 2, n - 1];
    if (double.tryParse(header[n - 1]) != null) body = lines;
  }
  final samples = <List<double>>[];
  for (final line in body) {
    final cells = line.split(',');
    if (cells.length <= columns.reduce((a, b) => a > b ? a : b)) continue;
    final xyz = [for (final c in columns) double.tryParse(cells[c].trim())];
    if (xyz.any((v) => v == null || !v.isFinite)) continue;
    samples.add([xyz[0]!, xyz[1]!, xyz[2]!]);
  }
  return samples;
}

/// One recording that can be replayed.
class ReplaySource {
  ReplaySource({
    required this.fileName,
    required this.read,
    this.bundled = false,
  }) : labels = labelsFromFileName(fileName);

  final String fileName;
  final RecordingLabels labels;
  final bool bundled;
  final Future<String> Function() read;
}

/// Asset folder of the recordings bundled with the app (see pubspec.yaml).
const String demoAssetFolder = 'assets/demo/';

/// The recordings bundled with the app, sorted by file name.
Future<List<ReplaySource>> bundledRecordings({AssetBundle? bundle}) async {
  final b = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  final paths = manifest
      .listAssets()
      .where((a) => a.startsWith(demoAssetFolder) && a.endsWith('.csv'))
      .toList()
    ..sort();
  return [
    for (final path in paths)
      ReplaySource(
        fileName: p.basename(path),
        read: () => b.loadString(path),
        bundled: true,
      ),
  ];
}

/// CSV files in [folder] (the app's storage folder, where Data collection
/// saves its recordings and where files can be copied over USB), newest first.
Future<List<ReplaySource>> folderRecordings(Directory? folder) async {
  if (folder == null || !await folder.exists()) return [];
  final files = <File>[];
  await for (final e in folder.list()) {
    if (e is File &&
        e.path.toLowerCase().endsWith('.csv') &&
        p.basename(e.path).toLowerCase().startsWith('pdiot_') &&
        !p.basename(e.path).toLowerCase().startsWith('pdiot_realtime')) {
      files.add(e);
    }
  }
  files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return [
    for (final f in files)
      ReplaySource(fileName: p.basename(f.path), read: f.readAsString),
  ];
}

/// The demo tour: one bundled recording per scene, played back to back so
/// activity changes happen as they would in real life. Each entry is matched
/// against the bundled file names (activity_signal, case-insensitive).
const List<String> demoTourScenes = [
  'standing_normal',
  'normalwalking_normal',
  'ascendingstairs_normal',
  'descendingstairs_normal',
  'running_normal',
  'shufflewalking_normal',
  'lyingdownback_normal',
  'sitting_coughing',
  'standing_hyperventilating',
  'sitting_talking',
];

List<ReplaySource> demoTour(List<ReplaySource> bundled) {
  final tour = <ReplaySource>[];
  for (final scene in demoTourScenes) {
    for (final s in bundled) {
      final parts = s.fileName.split('_');
      if (parts.length > 3 &&
          '${parts[2]}_${parts[3]}'.toLowerCase() == scene) {
        tour.add(s);
        break;
      }
    }
  }
  return tour;
}

enum ReplayState { idle, loading, playing, paused, finished }

class _Loaded {
  _Loaded(this.source, this.samples);
  final ReplaySource source;
  final List<List<double>> samples;
}

/// Streams one or more recordings, sample by sample, into [onSample].
///
/// [onStart] is called once before the first sample (reset classifiers, start
/// a Social session) and [onStop] once after the last one or on [stop].
/// Playback is driven by a timer every 80 ms that delivers [speed] samples,
/// i.e. exactly 12.5 Hz at 1x; tests call [advance] directly instead.
class ReplayController extends ChangeNotifier {
  ReplayController({
    required this.onSample,
    this.onStart,
    this.onStop,
    this.onTick,
  });

  final void Function(double x, double y, double z) onSample;
  final VoidCallback? onStart;
  final VoidCallback? onStop;

  /// Called after each batch of samples (for UI updates that should not
  /// happen for every single sample).
  final VoidCallback? onTick;

  ReplayState _state = ReplayState.idle;
  List<_Loaded> _items = [];
  int _item = 0;
  int _pos = 0;
  int _speed = 1;
  Timer? _timer;
  Object? lastError;
  List<double>? lastSample;

  ReplayState get state => _state;
  bool get active =>
      _state == ReplayState.playing ||
      _state == ReplayState.paused ||
      _state == ReplayState.loading;
  int get speed => _speed;
  int get itemCount => _items.length;
  int get itemIndex => _item;
  ReplaySource? get current =>
      _items.isEmpty ? null : _items[_item.clamp(0, _items.length - 1)].source;

  int get totalSamples => _items.fold(0, (n, i) => n + i.samples.length);
  int get playedSamples =>
      _items.take(_item).fold(0, (n, i) => n + i.samples.length) + _pos;
  double get progress => totalSamples == 0 ? 0 : playedSamples / totalSamples;
  Duration get elapsed => _toDuration(playedSamples);
  Duration get total => _toDuration(totalSamples);

  /// Position inside the current recording.
  Duration get itemElapsed => _toDuration(_pos);
  Duration get itemTotal =>
      _items.isEmpty ? Duration.zero : _toDuration(_items[_item].samples.length);

  static Duration _toDuration(int samples) =>
      Duration(milliseconds: (samples * 1000 / replaySampleRate).round());

  set speed(int value) {
    if (value < 1) throw ArgumentError.value(value, 'speed');
    _speed = value;
    if (_state == ReplayState.playing) _startTimer();
    notifyListeners();
  }

  /// Loads every source, then starts playing (unless [autoStart] is false).
  /// Throws (and stays idle) if a file cannot be read or has no samples.
  Future<void> play(List<ReplaySource> sources, {bool autoStart = true}) async {
    if (sources.isEmpty) throw ArgumentError('Nothing to replay');
    await stop();
    _state = ReplayState.loading;
    lastError = null;
    notifyListeners();
    try {
      final loaded = <_Loaded>[];
      for (final s in sources) {
        final samples = parseAccelCsv(await s.read());
        if (samples.isEmpty) {
          throw FormatException('${s.fileName} contains no accelX/Y/Z samples');
        }
        loaded.add(_Loaded(s, samples));
      }
      if (_state != ReplayState.loading) return; // stopped while loading
      _items = loaded;
      _item = 0;
      _pos = 0;
    } catch (e) {
      lastError = e;
      _state = ReplayState.idle;
      notifyListeners();
      rethrow;
    }
    onStart?.call();
    _state = ReplayState.paused;
    if (autoStart) {
      resume();
    } else {
      notifyListeners();
    }
  }

  void pause() {
    if (_state != ReplayState.playing) return;
    _timer?.cancel();
    _timer = null;
    _state = ReplayState.paused;
    notifyListeners();
  }

  void resume() {
    if (_state != ReplayState.paused) return;
    _state = ReplayState.playing;
    _startTimer();
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 / replaySampleRate).round()),
      (_) => advance(_speed),
    );
  }

  /// Delivers the next [count] samples (crossing into the next recording when
  /// one ends). Finishes playback after the last sample.
  void advance(int count) {
    if (_state != ReplayState.playing && _state != ReplayState.paused) return;
    for (var i = 0; i < count; i++) {
      if (_item >= _items.length) break;
      final samples = _items[_item].samples;
      final s = samples[_pos];
      lastSample = s;
      onSample(s[0], s[1], s[2]);
      _pos++;
      if (_pos >= samples.length) {
        _item++;
        _pos = 0;
      }
    }
    onTick?.call();
    if (_item >= _items.length) {
      _item = _items.length - 1;
      _pos = _items.isEmpty ? 0 : _items.last.samples.length;
      _finish(ReplayState.finished);
    } else {
      notifyListeners();
    }
  }

  /// Stops playback. [onStop] is called if a replay was in progress.
  Future<void> stop() async {
    if (_state == ReplayState.loading) {
      // Nothing was fed yet, so there is no session to end.
      _state = ReplayState.idle;
      notifyListeners();
      return;
    }
    if (_state == ReplayState.idle || _state == ReplayState.finished) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _finish(ReplayState.idle);
  }

  void _finish(ReplayState end) {
    _timer?.cancel();
    _timer = null;
    final wasRunning = _state != ReplayState.idle;
    _state = end;
    if (wasRunning) onStop?.call();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
