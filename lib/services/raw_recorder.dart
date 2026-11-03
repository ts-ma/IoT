import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

/// Header of every raw sensor CSV, one line per acceleration sample.
const String rawCsvHeader =
    'receivedPhoneTimestamp,respeckTimestamp,packetSeqNum,sampleSeqNum,'
    'accelX,accelY,accelZ';

/// `PDIoT_<user>_<activity>_<signal>_<yyyy-MM-ddTHHmmssZ>_<respeck>.csv`, the
/// naming used for the coursework recordings. HH is the 0-23 clock (kk would
/// put midnight as hour 24).
String rawFileName({
  required String user,
  required String activity,
  required String signal,
  required DateTime at,
  String? respeckId,
}) {
  final t = at.toUtc();
  final stamp =
      '${DateFormat('yyyy-MM-dd').format(t)}T${DateFormat('HHmmss').format(t)}Z';
  final sensor = (respeckId ?? '').replaceAll(':', '');
  return 'PDIoT_${user}_${activity}_${signal}_$stamp'
      '${sensor.isEmpty ? '' : '_$sensor'}.csv';
}

/// Writes raw RESpeck samples to one CSV at a time. ble.dart hands it every
/// decoded packet while [active]; a single open sink keeps appends in order.
class RawRecorder extends ChangeNotifier {
  IOSink? _sink;
  File? _file;
  DateTime? _startedAt;
  int _samples = 0;
  String? _purpose;

  bool get active => _sink != null;
  File? get file => _file;
  String? get fileName => _file == null ? null : p.basename(_file!.path);
  DateTime? get startedAt => _startedAt;
  int get samples => _samples;

  /// What started the recording ("trial" or "free"), so one tool cannot stop
  /// the other's file.
  String? get purpose => _purpose;

  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// Opens [folder]/[fileName] and writes the header. Throws if a recording is
  /// already running or the file cannot be created.
  Future<File> start({
    required Directory folder,
    required String fileName,
    required String purpose,
  }) async {
    if (active) throw StateError('Already recording $fileName');
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, fileName));
    final sink = file.openWrite(mode: FileMode.writeOnly);
    // openWrite is lazy: a bad path or full disk surfaces on done.
    sink.done.catchError((Object e) {
      debugPrint('Error writing $fileName: $e');
    });
    sink.writeln(rawCsvHeader);
    _sink = sink;
    _file = file;
    _startedAt = DateTime.now();
    _samples = 0;
    _purpose = purpose;
    notifyListeners();
    return file;
  }

  /// Appends already formatted CSV lines for [sampleCount] samples.
  void write(String lines, int sampleCount) {
    final sink = _sink;
    if (sink == null || lines.isEmpty) return;
    try {
      sink.write(lines);
      _samples += sampleCount;
    } catch (e) {
      debugPrint('Error writing raw CSV: $e');
    }
  }

  /// Flushes and closes the file. Returns it, or null if nothing was running.
  Future<File?> stop() async {
    final sink = _sink;
    final file = _file;
    if (sink == null) return null;
    // Clear first, so a packet arriving during the close cannot write to it.
    _sink = null;
    _purpose = null;
    notifyListeners();
    try {
      await sink.flush();
      await sink.close();
    } catch (e) {
      debugPrint('Error closing raw CSV: $e');
    }
    return file;
  }
}
