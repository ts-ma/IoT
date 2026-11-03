import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

// Subject and Respeck IDs are stored in shared preferences
final SharedPreferencesAsync asyncPrefs = SharedPreferencesAsync();
String? respeckUUID;
String? subjectID;
String? fwString;
bool respeckConnected = false;

// The folder and CSV file where sensor data is written.
// storageFolder is null until main() has resolved it, and can stay null if the
// platform provides no suitable directory, so every use must be null checked.
Directory? storageFolder;
File? csvFile;

// A single sink is kept open for the duration of a recording. Writing through
// one sink keeps the appends in order - reopening the file for every packet
// allows concurrent writes to interleave and corrupt the CSV.
IOSink? csvSink;

// Read later from pubspec.yaml
String appVersionName = "0.0.0";
int appVersionCode = 0;

// Display preference (Settings): show the majority of the last 3 activity
// predictions instead of each raw prediction. Persisted under 'smooth_har'.
bool smoothHarPredictions = true;

// True while a recorded file is being replayed through the models (demo mode).
// Replayed results are saved as "replay" and never scored by the real-time test.
bool replayActive = false;
