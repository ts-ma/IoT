import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// What the phone itself can tell us about the app, on Android and iOS.
//
// | Metric        | Android                                  | iOS                               |
// |---------------|------------------------------------------|-----------------------------------|
// | CPU time      | getrusage(RUSAGE_SELF) via dart:ffi      | getrusage(RUSAGE_SELF) via dart:ffi |
// |               | (fallback: /proc/self/stat utime+stime)  |                                   |
// | Memory        | ProcessInfo.currentRss (resident set)    | ProcessInfo.currentRss            |
// | Phone battery | BatteryManager (channel "pdiot/power"):  | UIDevice (channel "pdiot/power"): |
// |               | level, charging, current µA, voltage mV  | level and charging only (no       |
// |               |                                          | public API for current draw)      |
// | Storage       | file sizes in the user's folder          | file sizes in the user's folder   |
//
// CPU % = CPU time used / wall time between two readings. 100 % is one full
// core; the phone has Platform.numberOfProcessors cores.

/// `struct timeval` is 16 bytes on 64-bit Android and iOS: an 8-byte seconds
/// field and a microseconds field (4 bytes + padding on iOS, 8 on Android;
/// the value is < 1e6, so reading the low 4 bytes is correct on both, as
/// both are little-endian).
final class _TimeVal extends Struct {
  @Int64()
  external int seconds;
  @Int32()
  external int micros;
  @Int32()
  external int pad;
}

/// `struct rusage`: user time, system time, then 14 longs we do not need.
final class _RUsage extends Struct {
  external _TimeVal user;
  external _TimeVal system;
  @Array(14)
  external Array<Int64> rest;
}

typedef _GetRUsageC = Int32 Function(Int32 who, Pointer<_RUsage> usage);
typedef _GetRUsageDart = int Function(int who, Pointer<_RUsage> usage);

/// Reads the CPU time this process has used so far (all threads: UI, raster,
/// platform, BLE callbacks, TFLite).
class CpuClock {
  CpuClock._(this._getrusage);

  final _GetRUsageDart? _getrusage;

  static CpuClock? _instance;
  static CpuClock get instance => _instance ??= CpuClock._(_lookup());

  static _GetRUsageDart? _lookup() {
    try {
      final lib = Platform.isAndroid
          ? DynamicLibrary.open('libc.so')
          : DynamicLibrary.process();
      return lib.lookupFunction<_GetRUsageC, _GetRUsageDart>('getrusage');
    } catch (e) {
      debugPrint('getrusage unavailable: $e');
      return null;
    }
  }

  /// Where the last reading came from: "getrusage", "/proc" or "none".
  String source = 'none';

  /// CPU time in seconds, or null if the platform offers no way to read it.
  double? read() {
    final fn = _getrusage;
    if (fn != null) {
      final usage = calloc<_RUsage>();
      try {
        if (fn(0 /* RUSAGE_SELF */, usage) == 0) {
          final r = usage.ref;
          source = 'getrusage';
          return r.user.seconds +
              r.user.micros / 1e6 +
              r.system.seconds +
              r.system.micros / 1e6;
        }
      } finally {
        calloc.free(usage);
      }
    }
    if (Platform.isAndroid || Platform.isLinux) {
      try {
        final t =
            parseProcStatCpuSeconds(File('/proc/self/stat').readAsStringSync());
        if (t != null) source = '/proc';
        return t;
      } catch (_) {}
    }
    source = 'none';
    return null;
  }
}

/// utime + stime from a /proc/<pid>/stat line, in seconds (clock ticks of
/// 1/100 s, the value on Android and Linux). The command name in field 2 may
/// contain spaces, so fields are counted after its closing parenthesis.
double? parseProcStatCpuSeconds(String stat, {int ticksPerSecond = 100}) {
  final close = stat.lastIndexOf(')');
  if (close < 0) return null;
  final fields = stat.substring(close + 2).trim().split(RegExp(r'\s+'));
  // fields[0] is field 3 (state), so utime (14) and stime (15) are 11 and 12.
  if (fields.length < 13) return null;
  final utime = int.tryParse(fields[11]);
  final stime = int.tryParse(fields[12]);
  if (utime == null || stime == null) return null;
  return (utime + stime) / ticksPerSecond;
}

/// Resident memory of the app in bytes (Android and iOS), or null.
int? currentRssBytes() {
  try {
    final rss = ProcessInfo.currentRss;
    return rss > 0 ? rss : null;
  } catch (_) {
    return null;
  }
}

/// One phone battery reading. [currentMicroA] and [voltageMilliV] are Android
/// only (iOS has no public API for them).
class PhoneBattery {
  const PhoneBattery({
    this.level,
    this.charging,
    this.currentMicroA,
    this.voltageMilliV,
  });

  /// 0-100, or null if unknown (e.g. iOS simulator).
  final int? level;
  final bool? charging;

  /// Instantaneous battery current. Sign conventions differ by phone maker,
  /// so the magnitude is used. Covers the whole phone (screen included).
  final int? currentMicroA;
  final int? voltageMilliV;

  /// Whole-phone power draw in milliwatts, if current and voltage are known.
  double? get powerMilliW {
    final i = currentMicroA, v = voltageMilliV;
    if (i == null || v == null || i == 0 || v <= 0) return null;
    // µA × mV = nW → /1e6 = mW.
    return i.abs() * v / 1e6;
  }

  static PhoneBattery fromMap(Map<Object?, Object?> m) {
    int? asInt(Object? v) => v is num && v.toInt() >= 0 ? v.toInt() : null;
    int? signed(Object? v) =>
        v is num && v.toInt() != -2147483648 ? v.toInt() : null;
    return PhoneBattery(
      level: asInt(m['level']),
      charging: m['charging'] as bool?,
      currentMicroA: signed(m['currentMicroA']),
      voltageMilliV: asInt(m['voltageMilliV']),
    );
  }
}

/// Native battery reader (MainActivity.kt / AppDelegate.swift).
class PowerChannel {
  PowerChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('pdiot/power');

  final MethodChannel _channel;
  bool _missing = false;

  /// Null if the platform side is missing (tests, desktop).
  Future<PhoneBattery?> read() async {
    if (_missing) return null;
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('battery');
      return m == null ? null : PhoneBattery.fromMap(m);
    } on MissingPluginException {
      _missing = true;
      return null;
    } catch (e) {
      debugPrint('Battery read failed: $e');
      return null;
    }
  }
}
