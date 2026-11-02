import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'utils.dart';
import 'home.dart';
import 'globals.dart';
import 'har.dart';

// This file contains the BLE code to scan for and connect to a respeck sensor.
// Once connected, we notify the acceleration characteristic and decode the
// stream of packets to obtain x,y,z acceleration in g and battery level.
// Each sample is written to a CSV file, fed to the live activity classifier,
// and the UI is updated with the latest values.

BluetoothDevice? respeck;
late MyHomePageState ui;
StreamSubscription<BluetoothConnectionState>? subscription2;

// 0 until a supported respeck has been identified during scanning
int respeckVersion = 0;

// Packet layout: 4 byte timestamp, 2 byte sequence number, then (respeck
// version 6 only) 1 byte battery level and 1 byte charging flag, then the
// acceleration samples, 6 bytes each (x, y, z as big endian int16).
const int sampleBytes = 6;

// NOTE: this offset has always been 8 for both respeck versions. If version 5
// packets turn out to omit the two battery bytes, this is the single place
// that needs to change (to `respeckVersion == 6 ? 8 : 6`) - see the note in
// the review, it needs checking against a v5 sensor.
const int sampleDataOffset = 8;

Future<void> scanForRespeck(MyHomePageState _ui) async {
  ui = _ui;
  // listen to scan results
  // Note: `onScanResults` clears the results between scans. You should use
  //  `scanResults` if you want the current scan results *or* the results from the previous scan.

  showToast("Searching for Respeck $respeckUUID...");

  // Forget any device found by a previous scan, so that a failed scan cannot
  // leave us connecting to a stale device
  respeck = null;
  respeckVersion = 0;

  var subscription = FlutterBluePlus.scanResults.listen(
    (results) {
      if (results.isNotEmpty) {
        for (ScanResult r in results) {
          //print('${r.device.remoteId}: "${r.advertisementData.advName}" found!');
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
                showToast("Respeck firmware is too old");
              }
            }
          } else if (Platform.isIOS) {
            // On iOS the remote id is randomised per phone, so the respeck is
            // identified by the id advertised in its service data instead
            final serviceData =
                r.advertisementData.serviceData; // Map<Guid, List<int>>
            final feedUuid = Guid('0000feed-0000-1000-8000-00805f9b34fb');
            final bytes = serviceData[feedUuid];
            if (bytes != null && bytes.isNotEmpty) {
              final hex = bytes
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .toList();
              final hex_str = hex.join(':').toUpperCase();
              //print('Found service data: GAP UUID: $hex_str');
              if (hex_str == respeckUUID) {
                if (r.advertisementData.advName == "Res6AM") {
                  respeck = r.device;
                  respeckVersion = 6;
                  fwString = "6AM";
                } else {
                  // Only complain about the firmware of *our* respeck, not
                  // about every other BLE device in the room
                  showToast("Respeck firmware is too old");
                }
              }
            }
          }

          // Stop scanning only once our respeck has actually been found.
          // These two statements used to sit outside the checks above, which
          // ended the scan after looking at the first device reported,
          // whatever it was.
          if (respeck != null) {
            FlutterBluePlus.stopScan();
            print("STOP SCANNING");
            break;
          }
        }
      }
    },
    onError: (e) => print(e),
  );

  // cleanup: cancel subscription when scanning stops
  FlutterBluePlus.cancelWhenScanComplete(subscription);

  // Wait for Bluetooth enabled & permission granted
  // In your real app you should use `FlutterBluePlus.adapterState.listen` to handle all states
  await FlutterBluePlus.adapterState
      .where((val) => val == BluetoothAdapterState.on)
      .first;

  // Start scanning w/ timeout. The timeout matters: without it a scan that
  // never finds the respeck never finishes, and the caller waits forever.
  await FlutterBluePlus.startScan(
    //withServices: [Guid("180D")], // match any of the specified services
    //withNames: ["Bluno"], // *or* any of the specified names
    timeout: const Duration(seconds: 15),
  );

  // wait for scanning to stop
  await FlutterBluePlus.isScanning.where((val) => val == false).first;
  print("end of scanning");
}

Future<void> notify() async {
  BluetoothService? ser;
  BluetoothCharacteristic? cha;

  if (respeck == null) {
    return;
  }

  // Service discovery
  // Note: You must call discoverServices after every re-connection!
  List<BluetoothService> services = await respeck!.discoverServices();
  //services.forEach((service) {
  for (BluetoothService s in services) {
    if (s.serviceUuid.str == "00001523-1212-efde-1523-785feabcd125") {
      ser = s;
      break;
    }
    // Reads all characteristics
  }

  // Read all characteristics provided by this service and choose the
  // acceleration characteristic

  if (ser != null) {
    var characteristics = ser.characteristics;
    for (BluetoothCharacteristic c in characteristics) {
      if (c.characteristicUuid.str == "00001524-1212-efde-1523-785feabcd125") {
        print("found accel characteristic");
        cha = c;
        break;
      }
    }
  }

  // Subscribe to acceleration values
  if (cha != null) {
    final subscription3 = cha.onValueReceived.listen((value) {
      ui.received_packet = true;
      // onValueReceived is updated:
      //   - anytime read() is called
      //   - anytime a notification arrives (if subscribed)

      //print("RECEIVED packet:");
      //print(value);

      // Decode packet:
      //https://stackoverflow.com/questions/59627795/parse-int-and-float-values-from-uint8list-dart
      //https://stackoverflow.com/questions/72418830/how-to-target-specific-int-bits-in-an-int-array-into-uint16-or-32

      // Timestamp when this packet was received, according to the phone clock
      DateTime packet_received_ts = DateTime.now();

      Uint8List ul = Uint8List.fromList(value);
      ByteData bd = ul.buffer.asByteData();

      // A truncated packet would make the header reads below throw
      if (bd.lengthInBytes < sampleDataOffset) {
        print("Ignoring short packet of ${bd.lengthInBytes} bytes");
        return;
      }

      int ts = bd.getUint32(0);
      ts = (ts * 197 * 1000 / 32768)
          .toInt(); // timestamp from the respeck clock, in ms
      //print(ts);

      // Sequence number can be used to detect dropped packets
      int packetSeqNumber = bd.getUint16(4);
      //print(packetSeqNumber);

      // Battery status (respeck version 6 only)
      int? battLevel;
      bool charging = false;

      if (respeckVersion == 6) {
        battLevel = bd.getUint8(6);

        if (bd.getUint8(7) == 1) {
          charging = true;
        }
      }

      // NOTE: The respeck sends multiple samples per packet, for efficiency
      // For each sample in this packet, append a line to the CSV file,

      StringBuffer csv = StringBuffer();
      int seqNumInPacket = 0;
      int samplesWritten = 0;
      double x = 0, y = 0, z = 0;
      // The newest activity prediction made while decoding this packet, or
      // null if no sample in this packet completed a classification window
      HarPrediction? prediction;

      // Take a single snapshot of the recording flag, so that a recording
      // started or stopped part way through this packet cannot leave the
      // sample count and the file contents disagreeing
      final bool isRecording = ui.recording;

      // The loop condition tests `i + sampleBytes <= length`: the old
      // `i < length` entered the body whenever a single byte was left and
      // then read five bytes past the end of the packet
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
              "${packet_received_ts.millisecondsSinceEpoch},$ts,$packetSeqNumber,$seqNumInPacket,$x,$y,$z\n");
          samplesWritten++;
        }

        // Live HAR: pass every sample to the activity classifier, whether or
        // not we are recording. addSample() returns null for most samples and
        // a prediction only when a new window has been classified (every 25
        // samples for the dummy model). `?? prediction` keeps an earlier
        // prediction from this packet rather than overwriting it with null.
        // If the model failed to load, harClassifier is null and this line
        // does nothing.
        prediction = harClassifier?.addSample(x, y, z) ?? prediction;

        seqNumInPacket++;
      }

      ui.recorded_samples += samplesWritten;

      // write to the CSV file. All appends go through one open sink, so they
      // stay in order - reopening the file per packet let concurrent writes
      // interleave
      if (csv.isNotEmpty) {
        try {
          csvSink?.write(csv.toString());
        } catch (e) {
          print("Error writing to CSV file: $e");
        }
      }

      // Update the UI to show the latest data. This is done once per packet:
      // calling setState for every sample rebuilt the whole page ~25 times
      // per packet for no benefit.
      String? accelText;
      if (seqNumInPacket > 0) {
        accelText =
            "x=${x.toStringAsFixed(3)}, y=${y.toStringAsFixed(3)}, z=${z.toStringAsFixed(3)}";
      }

      String battText = "";
      if (respeckVersion == 6) {
        if (charging) {
          battText = "Battery: $battLevel% (charging)";
        } else {
          battText = "Battery: $battLevel%";
        }
      }

      ui.updateFromPacket(
        accelText: accelText,
        battText: battText,
        isRecording: isRecording,
        packetReceivedTs: packet_received_ts,
        // Only non-null when this packet produced a new prediction, so the
        // display only changes when there is something new to show
        prediction: prediction,
      );
    });

    // cleanup: cancel subscription when disconnected
    respeck!.cancelWhenDisconnected(subscription3);

    await Future.delayed(const Duration(seconds: 3));

    // subscribe
    // Note: If a characteristic supports both **notifications** and **indications**,
    // it will default to **notifications**. This matches how CoreBluetooth works on iOS.
    await cha.setNotifyValue(true);
  } else {
    print("Acceleration characteristic not found");
    showLongToast("This Respeck did not offer any acceleration data");
  }
}

Future<void> connectToRespeck() async {
  // Nothing to connect to unless a scan found the respeck. This check has to
  // come before the first use of `respeck` below, not after it.
  if (respeck == null) {
    return;
  }

  // Drop any listener left over from a previous connection attempt, otherwise
  // each press of Connect adds another listener, and every packet then gets
  // decoded and written to the CSV once per listener
  await subscription2?.cancel();
  subscription2 = null;

  // listen for disconnection
  subscription2 =
      respeck!.connectionState.listen((BluetoothConnectionState state) async {
    if (state == BluetoothConnectionState.connected) {
      print("CONNECTED to Respeck $respeckUUID");
      respeckConnected = true;
      showToast("Connected to Respeck $respeckUUID");
      try {
        await notify();
      } catch (e) {
        print("Could not subscribe to acceleration data: $e");
        showLongToast("Could not read data from the Respeck");
      }
    }

    if (state == BluetoothConnectionState.disconnected) {
      // 1. typically, start a periodic timer that tries to
      //    reconnect, or just call connect() again right now
      // 2. you must always re-discover services after disconnection!
      print(
          "DISCONNECT: ${respeck?.disconnectReason?.code} ${respeck?.disconnectReason?.description}");
      respeckConnected = false;
      // Empty the classifier's window, so that after a reconnect it waits
      // for a full window of fresh samples instead of classifying a window
      // that spans the gap in the data
      harClassifier?.reset();
      // Require a fresh packet before a new recording can be started
      ui.received_packet = false;

      // A disconnect in the middle of a recording used to leave `recording`
      // true and the CSV sink open. No further samples arrive, the elapsed
      // counter stays frozen at the value from the last packet and the file
      // is never closed, so the recording truncated without saying so. Close
      // it properly and tell the user instead.
      final bool wasRecording = ui.recording;
      if (wasRecording) {
        await ui.stopRecording(
            message: "Respeck disconnected - recording stopped");
      }

      // Without autoConnect the platform does not re-establish the link on
      // its own, so say what actually has to happen rather than promising a
      // reconnect that will never arrive. A stopped recording has already
      // reported the disconnect, so it is not announced twice.
      if (!wasRecording &&
          respeck?.disconnectReason?.code != null &&
          respeck?.disconnectReason?.code != 0) {
        showLongToast("Respeck disconnected - press Connect to reconnect");
      }
    }
  });

  // Now connect to the respeck.
  //  - autoConnect is deliberately false. With autoConnect the platform only
  //    queues a background connection and connect() returns straight away,
  //    typically before the sensor is reachable at all - and we have just
  //    stopped the scan, so on Android nothing happens until the respeck
  //    advertises again. That is what made the first press of Connect look
  //    like it did nothing while a second press worked.
  //  - awaiting a direct connection instead means this call returns only once
  //    the respeck is actually connected, or throws if it cannot be reached,
  //    so the caller's "connecting" guard covers the whole attempt and a
  //    failure reaches its catch block.
  //  - note: autoConnect is incompatible with mtu argument, so you must call requestMtu yourself
  await respeck!
      .connect(license: License.nonprofit, autoConnect: false, mtu: null);

  // The connectionState listener above receives the connected event and calls
  // notify() from there, so there is nothing more to do here.
}

Future<void> disconnect() async {
  // Close the recording cleanly first, so that buffered samples reach the file
  final IOSink? sink = csvSink;
  csvSink = null;
  try {
    await sink?.flush();
    await sink?.close();
  } catch (e) {
    print("Error closing CSV file: $e");
  }
  csvFile = null;

  await respeck?.disconnect();
  // cancel to prevent duplicate listeners
  await subscription2?.cancel();
  subscription2 = null;
  respeckConnected = false;
}
