import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'globals.dart';
import 'har.dart';
import 'services/app_metrics.dart';
import 'services/packet_feed.dart';
import 'services/sensor_controller.dart';
import 'services/social_sample_processor.dart';
import 'utils.dart';

// Bluetooth LE code: scan for the paired RESpeck, connect, subscribe to its
// acceleration characteristic and decode each packet into x, y, z samples in
// g (plus the battery level on v6 sensors). Every sample goes to both
// classifiers and, while a recording runs, to the raw CSV; the
// SensorController is updated once per packet.

BluetoothDevice? respeck;
late SensorController ui;
StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
StreamSubscription<List<int>>? _packetSubscription;
DateTime? _lastPacketAt;
SocialSampleProcessor? _activeSocialProcessor;

/// Feeds one decoded x, y, z sample (in g) to both models. A new HAR result
/// is passed to [onPrediction] straight away, before the social model sees
/// the sample. Nothing is awaited here (history writes are queued).
HarPrediction? processDecodedSample(
  double x,
  double y,
  double z, {
  void Function(HarPrediction)? onPrediction,
  SocialSampleProcessor? socialProcessor,
}) {
  final newPrediction = harClassifier?.addSample(x, y, z);
  if (newPrediction != null) {
    onPrediction?.call(newPrediction);
  }
  socialProcessor?.addSample(x, y, z);
  return newPrediction;
}

/// Empty both model windows, e.g. after lost packets, so no window mixes data
/// from before and after a gap in the stream.
void resetModelWindows(SocialSampleProcessor? socialProcessor) {
  harClassifier?.reset();
  socialProcessor?.resetStream();
}

/// Connected and a packet arrived within the last 10 s (a connection flag
/// alone cannot tell whether data is flowing).
bool get respeckStreaming =>
    respeckConnected &&
    respeck?.isConnected == true &&
    _lastPacketAt != null &&
    DateTime.now().difference(_lastPacketAt!) < const Duration(seconds: 10);

/// 0 until a supported RESpeck has been found by a scan.
int respeckVersion = 0;

// Packet layout: 4-byte timestamp, 2-byte sequence number, then (RESpeck
// v6 only) 1-byte battery level and 1-byte charging flag, then the
// acceleration samples, 6 bytes each (x, y, z as big-endian int16).
const int sampleBytes = 6;

// The samples start at byte 8 for both RESpeck versions. If v5 packets turn
// out to have no battery bytes, change this to `respeckVersion == 6 ? 8 : 6`
// (not yet checked against a v5 sensor).
const int sampleDataOffset = 8;

/// Scans for up to 15 s for the paired RESpeck ([respeckUUID]) and stores it
/// in [respeck] (null if not found).
Future<void> scanForRespeck(SensorController controller) async {
  ui = controller;

  showToast('Searching for RESpeck $respeckUUID…');

  // Forget any device found by a previous scan, so that a failed scan cannot
  // leave us connecting to a stale device.
  respeck = null;
  respeckVersion = 0;

  var subscription = FlutterBluePlus.scanResults.listen(
    (results) {
      if (results.isNotEmpty) {
        for (ScanResult r in results) {
          if (Platform.isAndroid) {
            if (r.device.remoteId.str == respeckUUID) {
              if (r.advertisementData.advName == "Res6AL") {
                respeck = r.device;
                respeckVersion = 6;
                fwString = "6AL";
              } else if (r.advertisementData.advName == "Res6AM") {
                respeck = r.device;
                respeckVersion = 6;
                fwString = "6AM";
              } else if (r.advertisementData.advName == "ResV5i") {
                respeck = r.device;
                respeckVersion = 5;
                fwString = "5i";
              } else {
                showToast('RESpeck firmware is too old');
              }
            }
          } else if (Platform.isIOS) {
            // On iOS the remote id is randomised per phone, so the RESpeck is
            // identified by the id advertised in its service data instead.
            final serviceData =
                r.advertisementData.serviceData; // Map<Guid, List<int>>
            final feedUuid = Guid('0000feed-0000-1000-8000-00805f9b34fb');
            final bytes = serviceData[feedUuid];
            if (bytes != null && bytes.isNotEmpty) {
              final hex = bytes
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .toList();
              final hexStr = hex.join(':').toUpperCase();
              if (hexStr == respeckUUID) {
                if (r.advertisementData.advName == "Res6AM") {
                  respeck = r.device;
                  respeckVersion = 6;
                  fwString = "6AM";
                } else {
                  // Only complain about the firmware of *our* RESpeck, not
                  // about every other BLE device in the room.
                  showToast('RESpeck firmware is too old');
                }
              }
            }
          }

          // Stop scanning as soon as our RESpeck has been found.
          if (respeck != null) {
            FlutterBluePlus.stopScan();
            debugPrint('RESpeck found, scan stopped');
            break;
          }
        }
      }
    },
    onError: (e) => debugPrint('Scan error: $e'),
  );

  // Cancel the listener when the scan ends.
  FlutterBluePlus.cancelWhenScanComplete(subscription);

  // Wait until Bluetooth is on (and permission granted).
  await FlutterBluePlus.adapterState
      .where((val) => val == BluetoothAdapterState.on)
      .first;

  // The timeout matters: without it a scan that never finds the RESpeck
  // never finishes, and the caller waits forever.
  await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

  // Wait for the scan to stop (found, or timed out).
  await FlutterBluePlus.isScanning.where((val) => val == false).first;
  debugPrint('Scan finished');
}

/// Finds the RESpeck's acceleration characteristic, subscribes to it and
/// decodes every packet. Returns once the first usable packet has arrived;
/// throws if the characteristic is missing or no packet comes within 10 s.

Future<void> notify({
  void Function(HarPrediction)? onPrediction,
  SocialSampleProcessor? socialProcessor,
}) async {
  final firstPacket = Completer<void>();
  BluetoothService? ser;
  BluetoothCharacteristic? cha;

  if (respeck == null) {
    throw StateError('No RESpeck selected');
  }

  // Services must be discovered again after every (re)connection.
  List<BluetoothService> services = await respeck!.discoverServices();
  for (BluetoothService s in services) {
    if (s.serviceUuid.str == "00001523-1212-efde-1523-785feabcd125") {
      ser = s;
      break;
    }
  }

  // The acceleration characteristic of the RESpeck service.
  if (ser != null) {
    for (BluetoothCharacteristic c in ser.characteristics) {
      if (c.characteristicUuid.str == "00001524-1212-efde-1523-785feabcd125") {
        cha = c;
        break;
      }
    }
  }

  if (cha != null) {
    await _packetSubscription?.cancel();
    _activeSocialProcessor?.endSession();
    _activeSocialProcessor = socialProcessor;
    socialProcessor?.startSession();
    // One call per notification, i.e. per RESpeck packet.
    final subscription = cha.onValueReceived.listen((value) {
      // When this packet was received, on the phone clock.
      DateTime packetReceivedTs = DateTime.now();

      Uint8List ul = Uint8List.fromList(value);
      ByteData bd = ul.buffer.asByteData();

      // A truncated packet would make the header reads below throw.
      if (bd.lengthInBytes < sampleDataOffset + sampleBytes) {
        debugPrint('Ignoring short packet of ${bd.lengthInBytes} bytes');
        return;
      }

      _lastPacketAt = packetReceivedTs;
      ui.receivedPacket = true;
      if (!firstPacket.isCompleted) firstPacket.complete();

      // Timestamp from the RESpeck clock, in ms.
      int ts = bd.getUint32(0);
      ts = (ts * 197 * 1000 / 32768).toInt();

      // The sequence number shows lost packets.
      int packetSeqNumber = bd.getUint16(4);

      // Lost packets: checked BEFORE any sample reaches the models. Without
      // this, both model windows would join the samples from either side of
      // the missing 2.56 s as if they were one continuous movement. Both
      // windows start afresh instead (the next results come once they are
      // full again); recordPacket below still counts the loss.
      if (appMetrics.packetGap(packetSeqNumber) > 0) {
        resetModelWindows(socialProcessor);
      }

      // Battery status (RESpeck v6 only).
      int? battLevel;
      bool charging = false;

      if (respeckVersion == 6) {
        battLevel = bd.getUint8(6);

        if (bd.getUint8(7) == 1) {
          charging = true;
        }
      }

      // A packet holds 32 samples; each becomes one CSV line while recording.
      StringBuffer csv = StringBuffer();
      int seqNumInPacket = 0;
      // Raw samples for the sensor-to-app delay test, only while it listens.
      final packetSamples = respeckPacketFeed.hasListener
          ? <({double x, double y, double z})>[]
          : null;
      int samplesWritten = 0;
      double x = 0, y = 0, z = 0;
      // The newest activity prediction made while decoding this packet, or
      // null if no sample in this packet completed a classification window.
      HarPrediction? prediction;

      // Take a single snapshot of the recording flag, so that a recording
      // started or stopped part way through this packet cannot leave the
      // sample count and the file contents disagreeing.
      final recorder = ui.recorder;
      final bool isRecording = recorder.active;

      // Only whole 6-byte samples are read, so a packet with trailing bytes
      // cannot be read past its end.
      for (int i = sampleDataOffset;
          i + sampleBytes <= bd.lengthInBytes;
          i += sampleBytes) {
        int b1 = bd.getInt8(i);
        int b2 = bd.getInt8(i + 1);
        x = combineAccelBytes(b1, b2);
        int b3 = bd.getInt8(i + 2);
        int b4 = bd.getInt8(i + 3);
        y = combineAccelBytes(b3, b4);
        int b5 = bd.getInt8(i + 4);
        int b6 = bd.getInt8(i + 5);
        z = combineAccelBytes(b5, b6);

        if (isRecording) {
          csv.write(
              "${packetReceivedTs.millisecondsSinceEpoch},$ts,$packetSeqNumber,$seqNumInPacket,$x,$y,$z\n");
          samplesWritten++;
        }

        // Live HAR: pass every sample to the activity classifier, whether or
        // not we are recording. addSample() returns null for most samples and
        // a prediction only when a new window has been classified. Emit each
        // raw result once, while retaining the latest result for packet UI.
        final newPrediction = processDecodedSample(
          x,
          y,
          z,
          onPrediction: onPrediction,
          socialProcessor: socialProcessor,
        );
        if (newPrediction != null) {
          prediction = newPrediction;
        }

        packetSamples?.add((x: x, y: y, z: z));
        seqNumInPacket++;
      }
      if (packetSamples != null && packetSamples.isNotEmpty) {
        respeckPacketFeed.add(RespeckPacket(
          receivedAt: packetReceivedTs,
          sequence: packetSeqNumber,
          samples: packetSamples,
        ));
      }

      appMetrics.recordPacket(
          packetSeqNumber, seqNumInPacket, packetReceivedTs);

      // All appends go through one open sink, so they stay in order.
      if (csv.isNotEmpty) recorder.write(csv.toString(), samplesWritten);

      // Update the screens once per packet, not once per sample (that would
      // rebuild them 32 times per packet for nothing).
      String? accelText;
      if (seqNumInPacket > 0) {
        accelText =
            "x=${x.toStringAsFixed(3)}, y=${y.toStringAsFixed(3)}, z=${z.toStringAsFixed(3)}";
      }

      ui.updateFromPacket(
        accel: accelText,
        battery: battLevel,
        charging: charging,
        receivedAt: packetReceivedTs,
        // SensorController.connect's onPrediction has already shown every
        // result of this packet as it was made; only a caller without that
        // callback relies on this one.
        prediction: onPrediction == null ? prediction : null,
      );
    }, onError: (Object error, StackTrace stack) {
      // A notification error means data was interrupted, but not how many
      // samples were lost: the social window starts afresh.
      socialProcessor?.resetStream();
    }, onDone: () {
      socialProcessor?.endSession();
    });
    _packetSubscription = subscription;

    // Cancel the listener when the RESpeck disconnects.
    respeck!.cancelWhenDisconnected(subscription);

    await Future.delayed(const Duration(seconds: 3));

    // Turn notifications on: the RESpeck starts sending packets.
    await cha.setNotifyValue(true);
    await firstPacket.future.timeout(const Duration(seconds: 10));
  } else {
    throw StateError('Acceleration characteristic not found');
  }
}

/// Connects to the scanned [respeck] and starts the packet stream. Returns
/// once data arrives; on failure it disconnects again and rethrows.
Future<void> connectToRespeck({
  void Function(HarPrediction)? onPrediction,
  SocialSampleProcessor? socialProcessor,
}) async {
  // Nothing to connect to unless a scan found the RESpeck.
  if (respeck == null) {
    return;
  }

  // Drop any listener left over from a previous connection attempt, otherwise
  // each press of Connect adds another listener, and every packet then gets
  // decoded and written to the CSV once per listener.
  await _connectionSubscription?.cancel();
  _connectionSubscription = null;

  // React to the link dropping. Reconnecting is manual (Connect on Home).
  _connectionSubscription =
      respeck!.connectionState.listen((BluetoothConnectionState state) async {
    if (state == BluetoothConnectionState.disconnected) {
      debugPrint('Disconnected: ${respeck?.disconnectReason?.code} '
          '${respeck?.disconnectReason?.description}');
      respeckConnected = false;
      _lastPacketAt = null;
      // Empty the classifier's window, so that after a reconnect it waits
      // for a full window of fresh samples instead of classifying a window
      // that spans the gap in the data.
      harClassifier?.reset();
      socialProcessor?.endSession();
      appMetrics.endStream();
      // Require a fresh packet before a new recording can be started
      ui.receivedPacket = false;
      ui.connectionChanged();

      // No more samples will arrive: close a running recording properly
      // and tell the user, instead of leaving it open and silently cut short.
      final bool wasRecording = ui.recorder.active;
      if (wasRecording) {
        await ui.stopRecording(
            message: 'RESpeck disconnected - recording stopped');
      }

      // Without autoConnect the link is not re-established on its own, so
      // say what to do. A stopped recording has already reported the
      // disconnect, so it is not announced twice.
      if (!wasRecording &&
          respeck?.disconnectReason?.code != null &&
          respeck?.disconnectReason?.code != 0) {
        showLongToast('RESpeck disconnected - press Connect to reconnect');
      }
    }
  });

  // autoConnect is deliberately false: with it, connect() only queues a
  // background connection and returns at once, usually before the sensor is
  // reachable (and the scan has just stopped, so on Android nothing happens
  // until the RESpeck advertises again). A direct connection returns only
  // once the RESpeck is connected, or throws if it cannot be reached, so the
  // caller's "connecting" guard covers the whole attempt.
  try {
    await respeck!
        .connect(license: License.nonprofit, autoConnect: false, mtu: null);
    // Keep the caller's connecting guard active through service discovery,
    // notification setup, and receipt of the first usable acceleration packet.
    await notify(onPrediction: onPrediction, socialProcessor: socialProcessor);
    if (respeck?.isConnected != true || _lastPacketAt == null) {
      throw StateError('RESpeck disconnected during setup');
    }
    respeckConnected = true;
    // Home shows "Connected to RESpeck …" itself.
    ui.connectionChanged();
  } catch (_) {
    await disconnect();
    rethrow;
  }
}

/// Ends the stream and the connection, closing a running recording first.
Future<void> disconnect() async {
  respeckConnected = false;
  _lastPacketAt = null;
  ui.receivedPacket = false;
  harClassifier?.reset();
  _activeSocialProcessor?.endSession();
  _activeSocialProcessor = null;
  appMetrics.endStream();
  // Close the recording cleanly first, so that buffered samples reach the file.
  if (ui.recorder.active) {
    await ui.stopRecording(message: 'RESpeck disconnected - recording stopped');
  }
  await _packetSubscription?.cancel();
  _packetSubscription = null;

  // Cancel to prevent duplicate listeners.
  await _connectionSubscription?.cancel();
  _connectionSubscription = null;
  await respeck?.disconnect();
  ui.connectionChanged();
}
