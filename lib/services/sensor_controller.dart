import 'dart:async';

import 'package:flutter/foundation.dart';

import '../activity_catalog.dart';
import '../ble.dart' as ble;
import '../globals.dart';
import '../har.dart';
import '../utils.dart';
import 'app_settings.dart';
import 'live_feed.dart';
import 'notifications.dart';
import 'prediction_history_writer.dart';
import 'raw_recorder.dart';
import 'reminders.dart';
import 'social_sample_processor.dart';
import 'user_session.dart';

/// Connection and live-display state of the RESpeck, shared by every tab.
///
/// ble.dart decodes packets and reports them here; screens listen and
/// rebuild, and the raw recorder receives samples while a recording runs.
class SensorController extends ChangeNotifier {
  SensorController({
    this.historyWriter,
    this.socialProcessor,
    this.reminders,
    this.notifications,
    UserSession? session,
    RawRecorder? recorder,
  })  : session = session ?? userSession,
        recorder = recorder ?? RawRecorder() {
    ble.ui = this;
  }

  final PredictionHistoryWriter? historyWriter;
  final SocialSampleProcessor? socialProcessor;

  /// Move reminder and wake-up alarm, fed with every shown activity result.
  final ActivityReminders? reminders;

  /// Notification permission and (Android) the monitoring foreground service.
  final AppNotifications? notifications;

  final UserSession session;
  final RawRecorder recorder;

  /// A connection attempt is in flight (Connect cannot be pressed twice).
  bool connecting = false;

  /// At least one packet arrived on the current connection.
  bool receivedPacket = false;

  /// Latest acceleration as text, e.g. "x=0.012, y=-0.981, z=0.104".
  String accelText = '';

  /// RESpeck battery (v6 firmware only), null if unknown.
  int? respeckBattery;
  bool respeckCharging = false;

  // What the activity card shows (the latest model result, with every
  // class probability) and when it arrived.
  HarPrediction? harShown;
  DateTime? harUpdatedAt;

  bool _disposed = false;

  bool get streaming => ble.respeckStreaming;
  bool get connected => respeckConnected;
  bool get paired => respeckUUID != null && respeckUUID!.isNotEmpty;

  /// Values decoded from one packet. [accel] is null for a packet without
  /// samples (the last reading stays). [prediction] is for callers that did
  /// not already report the packet's results through [addHarResult]; the live
  /// BLE path reports every result there and passes null here.
  void updateFromPacket({
    required String? accel,
    required int? battery,
    required bool charging,
    required DateTime receivedAt,
    HarPrediction? prediction,
  }) {
    if (accel != null) accelText = accel;
    respeckBattery = battery;
    respeckCharging = charging;
    if (prediction != null) addHarResult(prediction, at: receivedAt);
    _notify();
  }

  /// One activity result, as soon as the model produced it (about five per
  /// RESpeck packet: a packet carries 32 samples = 2.56 s and the step is
  /// 0.48 s). The activity card shows each result as it is.
  ///
  /// The shown activity also switches social signals on and off: they are
  /// only classified while the wearer is still.
  /// Does not notify: the packet's [updateFromPacket] does, once.
  HarPrediction addHarResult(HarPrediction prediction, {DateTime? at}) {
    harShown = prediction;
    harUpdatedAt = at ?? DateTime.now();
    socialProcessor?.setPaused(isMoving(prediction.label));
    reminders?.onActivity(prediction.label, harUpdatedAt!, updateInterval);
    return prediction;
  }

  /// Dynamic activities (walking, stairs, running, shuffling, misc.).
  static bool isMoving(String harLabel) =>
      labelInfo(harLabel).group == LabelGroup.dynamicActivity;

  /// Called by ble.dart whenever the connection state changes, so no screen
  /// shows a stale state.
  void connectionChanged() {
    if (!respeckConnected) {
      unawaited(notifications?.stopMonitoring());
      _resetDisplay();
      return;
    }
    _notify();
  }

  void _resetDisplay() {
    harShown = null;
    harUpdatedAt = null;
    socialProcessor?.setPaused(false);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Scans for the paired RESpeck and connects. Returns an error message for
  /// the screen, or null when connected (or already connecting).
  Future<String?> connect() async {
    if (!session.loggedIn) return 'Log in first';
    if (!paired) return 'Pair a RESpeck first';
    if (connecting) return null;
    if (streaming) return null;
    connecting = true;
    _notify();
    try {
      // Release a stale link before scanning; a connected sensor may no
      // longer advertise and would otherwise never appear in scan results.
      ble.ui = this;
      if (ble.respeck != null) await ble.disconnect();
      await ble.scanForRespeck(this);
      if (ble.respeck == null) {
        return 'RESpeck $respeckUUID not found - is it awake (green light)?';
      }
      await ble.connectToRespeck(
        onPrediction: (prediction) {
          // Each result: shown on Home, saved to history and published to
          // the live tools (real-time and latency tests).
          final shown = addHarResult(prediction);
          historyWriter?.capture(prediction);
          liveFeed.addHar(prediction, shown: shown);
        },
        socialProcessor: socialProcessor,
      );
      // Keep running in the background / with the screen off (Android
      // foreground service; iOS uses the bluetooth-central background mode)
      // so the stream, history and reminders go on.
      await notifications?.requestPermission();
      await notifications?.startMonitoring(respeckUUID);
      return null;
    } catch (e) {
      debugPrint('Connect failed: $e');
      return 'Could not receive RESpeck data - wake it and press Connect again';
    } finally {
      connecting = false;
      _notify();
    }
  }

  Future<void> disconnect() async {
    unawaited(notifications?.stopMonitoring());
    try {
      await ble.disconnect();
    } catch (e) {
      debugPrint('Disconnect failed: $e');
    }
    accelText = '';
    respeckBattery = null;
    respeckCharging = false;
    _resetDisplay();
  }

  /// Called by ble.dart when the link drops in the middle of a recording.
  Future<void> stopRecording({String? message}) async {
    if (!recorder.active) return;
    await recorder.stop();
    if (message != null) showToast(message);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
