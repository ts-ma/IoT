import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'globals.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'home.dart';
import 'har.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

// This file starts the app and displays the home screen.

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read app version information. This must be awaited, otherwise the settings
  // page can be built before the real version has arrived and will show the
  // "0.0.0" default instead.
  try {
    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    appVersionName = packageInfo.version; // App version
    appVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0; // Build number
  } catch (e) {
    // A missing version is not worth blocking startup for
    print("Could not read package info: $e");
  }

  // Read pairing information form shared preferences
  respeckUUID = await asyncPrefs.getString('rid');
  print("respeckUUID:${respeckUUID}");

  subjectID = await asyncPrefs.getString('sid');
  print("subjectID:${subjectID}");

  // get storage folder - must be accessible to the user for PDIoT
  try {
    if (Platform.isAndroid) {
      storageFolder = await getDownloadsDirectory();
    } else {
      storageFolder = await getApplicationDocumentsDirectory();
    }
  } catch (e) {
    print("Could not get storage folder: $e");
  }

  // Fall back to the app documents directory if the downloads folder was not
  // available, so that recording still works (the files are just harder to
  // reach over USB)
  if (storageFolder == null) {
    try {
      storageFolder = await getApplicationDocumentsDirectory();
    } catch (e) {
      print("Could not get fallback storage folder: $e");
    }
  }
  print("storageFolder:${storageFolder?.path}");

  // Load the activity recognition model and its metadata from the app's
  // assets (see har.dart). This is done once at startup, before the UI is
  // built, so that the classifier is ready as soon as data arrives. If the
  // model cannot be loaded, harClassifier stays null: the error is logged, the
  // home page shows "Classifier not available", and recording still works.
  try {
    harClassifier = await HarClassifier.load();
  } catch (e) {
    print("Could not load HAR model: $e");
  }

  
  // TEMPORARY: Lab 4 - Step 5.1
  // Compare the Android prediction with Lab 3.

  if (harClassifier != null) {

    final example = jsonDecode(
      await rootBundle.loadString(
        'assets/models/har_cnn_example.json'
      )
    );

    HarPrediction? p;

    // Feed samples one by one into the classifier.
    for (final s in example['input_window']) {
      p = harClassifier!.addSample(
        s[0].toDouble(),
        s[1].toDouble(),
        s[2].toDouble(),
      );
    }

    // Find the largest probability saved by Lab 3.
    final expected =
        (example['expected_probabilities'] as List)
            .reduce((a, b) => a > b ? a : b);

    print(
      "EXAMPLE app: ${p?.label} "
      "${p?.confidence.toStringAsFixed(4)} | "
      "Lab 3: ${example['expected_class']} "
      "${expected.toStringAsFixed(4)}"
    );

    // Clear the test window before receiving live data.
    harClassifier!.reset();
  }


  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'pdiot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.lightBlue),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: "PDIoT"),
    );
  }
}
