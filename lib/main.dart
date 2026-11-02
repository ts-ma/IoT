import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'globals.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'home.dart';
import 'har.dart';
import 'social.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:async';
import 'services/prediction_history_writer.dart';
import 'services/social_sample_processor.dart';

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


  // Independent of HAR and its example check. The app owns one Social session
  // and supplies it to the decoded-sample processor for live BLE inference.
  final socialSession = SocialClassifierSession();
  try {
    await socialSession.load();
  } catch (e) {
    debugPrint('Could not load Social model: $e');
  }

  runApp(MyApp(
    socialSession: socialSession,
    onSocialPrediction: (event) {
      // Debug-only, once per completed inference, never per acceleration sample.
      if (kDebugMode) {
        debugPrint('Social: ${event.prediction.label} '
            'confidence=${event.prediction.confidence.toStringAsFixed(4)} '
            'completed=${event.completedAt.toIso8601String()} '
            'processingUs=${event.processingDuration.inMicroseconds}');
      }
    },
  ));
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    this.socialSession,
    this.onSocialPrediction,
    this.createHistoryWriter,
  });

  final SocialClassifierSession? socialSession;
  final void Function(SocialPredictionEvent)? onSocialPrediction;

  /// Optional factory for tests. The app owns and disposes the returned writer.
  final PredictionHistoryWriter Function()? createHistoryWriter;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late final PredictionHistoryWriter _historyWriter;
  late final SocialSampleProcessor _socialProcessor;

  @override
  void initState() {
    super.initState();
    // Created after main's example comparison. Opens SQLite lazily on the first
    // live result, using a connection independent of the History screen.
    _historyWriter =
        (widget.createHistoryWriter?.call() ?? PredictionHistoryWriter())
      ..addListener(_reportHistoryError);
    _socialProcessor = SocialSampleProcessor(
      classifier: () => widget.socialSession?.classifier,
      onPrediction: (event) {
        // Single Social persistence owner: the raw new-inference callback,
        // never Home notifications, cached predictions, or startup examples.
        _historyWriter.captureSocial(event);
        widget.onSocialPrediction?.call(event);
      },
    );
    WidgetsBinding.instance.addObserver(this);
  }

  void _reportHistoryError() {
    debugPrint('History persistence: errors=${_historyWriter.errorCount}, '
        'dropped=${_historyWriter.droppedRecordCount}, '
        'lastError=${_historyWriter.lastError}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_historyWriter.flush());
    } else if (state == AppLifecycleState.detached) {
      unawaited(_historyWriter.shutdown());
      _socialProcessor.endSession();
      widget.socialSession?.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _historyWriter.dispose();
    _socialProcessor.dispose();
    widget.socialSession?.dispose();
    super.dispose();
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'pdiot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.lightBlue),
        useMaterial3: true,
      ),
      home: MyHomePage(
        title: "PDIoT",
        historyWriter: _historyWriter,
        socialProcessor: _socialProcessor,
      ),
    );
  }
}
