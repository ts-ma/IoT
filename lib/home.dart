import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'settings.dart';
import 'utils.dart';
import 'ble.dart';
import 'globals.dart';
import 'har.dart';
import 'dart:io';

// The home page includes buttons to connect to the respeck, enter capture
// metadata and start recording.

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => MyHomePageState();
}

class MyHomePageState extends State<MyHomePage> {
  //String _counter = "---";
  String accel = "";
  String batt_level = "";
  String recording_info = "Not recording";
  // Latest live activity prediction, e.g. "normalWalking (87%)". Empty until
  // the first full window of samples has been classified.
  String activity = "";

  var activities = [
    'Standing',
    'Lying down on left',
    'Lying down right',
    'Lying down back',
    'Lying down on stomach',
    'Normal walking',
    'Ascending stairs',
    'Descending stairs',
    'Shuffle walking',
    'Running',
    'Miscellaneous movements'
  ];
  String selected_activity = "Standing";

  var social_signals = [
    'Normal',
    'Coughing',
    'Hyperventilating',
    'Talking',
    'Eating',
    'Singing',
    'Laughing'
  ];
  String selected_signal = "Normal";

  bool recording = false;
  bool received_packet = false;

  // Set while a connection attempt is in flight, so that repeatedly pressing
  // Connect cannot set up a second set of BLE listeners
  bool connecting = false;

  int recorded_samples = 0;
  DateTime? start_timestamp;

  String filename = "";

  // The UI for the main screen of the app is defined below. Unlike traditional
  // android code, there is no additional XML layout file.

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called to update the UI.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      // Scrollable, so that the controls stay reachable on short screens.
      // The "Detected activity" lines made the page taller than some screens.
      body: SingleChildScrollView(
        child: Center(
          // Center is a layout widget. It takes a single child and positions it
          // in the middle of the parent.
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 10),
              ElevatedButton(
                  onPressed: connect,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.lightBlue),
                  child: const Text('Connect')),
              const SizedBox(height: 10),
              const Text(
                'Acceleration (g)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                accel,
              ),
              Text(
                batt_level,
              ),
              const SizedBox(height: 10),
              // Live activity recognition result. Shows a message instead if
              // the model could not be loaded at startup.
              const Text(
                'Detected activity',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                harClassifier == null ? "Classifier not available" : activity,
              ),
              const SizedBox(height: 10),
              const Text(
                'Activity',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              DropdownButton(
                // Initial Value
                value: selected_activity,
                items: activities.map((String items) {
                  return DropdownMenuItem(value: items, child: Text(items));
                }).toList(),
                // After selecting the desired option,it will
                // change button value to selected value
                onChanged: (String? newValue) {
                  setState(() {
                    selected_activity = newValue!;
                  });
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Social signal',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              DropdownButton(
                // Initial Value
                value: selected_signal,
                items: social_signals.map((String items) {
                  return DropdownMenuItem(value: items, child: Text(items));
                }).toList(),
                // After selecting the desired option,it will
                // change button value to selected value
                onChanged: (String? newValue) {
                  setState(() {
                    selected_signal = newValue!;
                  });
                },
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                  onPressed: record,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.lightGreen),
                  child: const Text('Start recording')),
              const SizedBox(height: 10),
              const Text(
                "Recording status",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                recording_info,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10.0),
                child: Text(
                  filename,
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                  // Called through a closure because stopRecording now takes an
                  // optional argument, and onPressed wants a plain no-argument
                  // callback
                  onPressed: () => stopRecording(),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[200]!),
                  child: const Text('Stop recording')),
              const SizedBox(height: 10),
              ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const SettingsPage()),
                    );
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.grey),
                  child: const Text('Settings')),
            ],
          ),
        ),
      ),
    );
  }

  // Scan for the paired respeck and connect to it
  void connect() async {
    if (respeckUUID == null || respeckUUID == "") {
      showToast("Please pair with a Respeck first");
      return;
    }
    if (connecting) {
      showToast("Already connecting...");
      return;
    }
    if (respeckConnected) {
      showToast("Already connected");
      return;
    }

    connecting = true;
    try {
      await scanForRespeck(this);
      if (respeck == null) {
        showLongToast("Respeck $respeckUUID not found - is it awake?");
        return;
      }
      await connectToRespeck();
    } catch (e) {
      print("Connect failed: $e");
      showLongToast("Could not connect to the Respeck");
    } finally {
      connecting = false;
    }
  }

  // Apply the values decoded from one packet to the display. setState is
  // protected, so the BLE code asks the State to update itself through this
  // method rather than reaching in and calling setState on it from outside.
  // `accelText` is null for a packet that carried no samples, which leaves the
  // last reading on screen instead of blanking it. Likewise `prediction` is
  // null unless the packet completed a new classification window.
  void updateFromPacket({
    required String? accelText,
    required String battText,
    required bool isRecording,
    required DateTime packetReceivedTs,
    HarPrediction? prediction,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (accelText != null) {
        accel = accelText;
      }
      batt_level = battText;
      // Show the predicted activity and the model's confidence in it as a
      // percentage. Without a new prediction the previous one stays on screen.
      if (prediction != null) {
        activity =
            "${prediction.label} (${(prediction.confidence * 100).toStringAsFixed(0)}%)";
      }

      // update elapsed time counter if recording
      if (isRecording && start_timestamp != null) {
        int elapsed_secs =
            packetReceivedTs.difference(start_timestamp!).inSeconds;

        recording_info =
            "Written $recorded_samples samples ($elapsed_secs seconds)";
      }
    });
  }

  // Start recording respeck data to CSV
  void record() async {
    if (!received_packet) {
      showToast("Please connect to a Respeck first");
      return;
    }
    if (recording) {
      showToast("Already recording");
      return;
    }
    if (storageFolder == null) {
      showLongToast("No storage folder available - cannot record");
      return;
    }

    recorded_samples = 0;
    DateTime now =
        DateTime.now().toUtc(); //use current UTC timestamp for filename
    start_timestamp = now;
    // Note: HH is the 0-23 hour clock. kk is the 1-24 clock, which formats
    // midnight as hour 24 and so puts the wrong hour in the filename.
    String formattedDate =
        '${DateFormat('yyyy-MM-dd').format(now)}T${DateFormat('HHmmss').format(now)}Z';
    String newFilename =
        'PDIoT_${subjectID}_${sentenceToCamelCase(selected_activity)}_${sentenceToCamelCase(selected_signal)}_${formattedDate}_${respeckUUID?.replaceAll(":", "")}.csv';
    print(newFilename);

    // Close any sink left open by a previous recording that did not shut down
    // cleanly, so that files cannot be left half written
    final IOSink? stale = csvSink;
    csvSink = null;
    if (stale != null) {
      try {
        await stale.flush();
        await stale.close();
      } catch (e) {
        print("Error closing previous CSV file: $e");
      }
    }

    // create file and write CSV header row
    try {
      csvFile = File('${storageFolder!.path}/$newFilename');
      final IOSink sink = csvFile!.openWrite(mode: FileMode.writeOnly);
      // openWrite is lazy, so a bad path or a full disk surfaces on done
      // rather than being thrown here. Without this handler that would become
      // an unhandled async error.
      sink.done.catchError((e) {
        print("Error writing $newFilename: $e");
        showLongToast("Error writing the recording file");
      });
      csvSink = sink;
      sink.write(
          "receivedPhoneTimestamp,respeckTimestamp,packetSeqNum,sampleSeqNum,accelX,accelY,accelZ\n");
    } catch (e) {
      print("Could not open $newFilename for writing: $e");
      showLongToast("Could not create the recording file");
      csvSink = null;
      csvFile = null;
      return;
    }

    showToast("Recording started..");
    if (!mounted) return;
    setState(() {
      filename = newFilename;
      recording_info = "Written 0 samples (0 seconds)";
      recording = true;
    });
  }

  // Stop recording and close the CSV file. `message` lets a caller that is
  // stopping the recording for its own reason - a disconnect, say - explain
  // why, instead of the plain "Recording stopped" of the Stop button.
  Future<void> stopRecording({String message = "Recording stopped"}) async {
    if (!recording) {
      return;
    }

    // Clear the sink before closing it, so that a packet arriving during the
    // close cannot write to a half closed file
    final IOSink? sink = csvSink;
    csvSink = null;

    if (mounted) {
      setState(() {
        recording = false;
        recording_info = "Not recording";
      });
    } else {
      recording = false;
    }

    try {
      await sink?.flush();
      await sink?.close();
    } catch (e) {
      print("Error closing CSV file: $e");
    }

    showToast(message);
  }
}
