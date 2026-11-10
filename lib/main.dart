import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'app_shell.dart';
import 'globals.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'har.dart';
import 'social.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:async';
import 'services/app_metrics.dart';
import 'services/app_settings.dart';
import 'services/live_feed.dart';
import 'services/notifications.dart';
import 'services/perf_sampler.dart';
import 'services/prediction_history_writer.dart';
import 'services/reminders.dart';
import 'services/sensor_controller.dart';
import 'services/social_sample_processor.dart';
import 'services/user_session.dart';

// This file starts the app: settings, storage, the logged-in user, the models,
// and the shell with its five tabs.

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

  // Update interval and display smoothing (Settings).
  await appSettings.load();

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

  // <storage>/PDIoT/ and the last logged-in user (if their folder exists).
  // Their profile holds the paired RESpeck.
  await userSession.init();
  print("user:${userSession.username} respeck:$respeckUUID");

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

  // Model parity check (Lab 4, Step 5.1), debug builds only: feed the
  // example window saved by the training notebook through the app's own
  // classifier and print both answers. Matching class and probability prove
  // the app passes data to the model exactly as Python did.
  if (kDebugMode && harClassifier != null) {
    try {
      // <name>.tflite -> <name>_example.json, as written by the notebook.
      final example = jsonDecode(await rootBundle.loadString(
          harModelAsset.replaceFirst(RegExp(r'\.tflite$'), '_example.json')));
      HarPrediction? p;
      for (final s in example['input_window']) {
        p = harClassifier!.addSample(
          (s[0] as num).toDouble(),
          (s[1] as num).toDouble(),
          (s[2] as num).toDouble(),
        );
      }
      final expected = (example['expected_probabilities'] as List)
          .reduce((a, b) => a > b ? a : b);
      print("EXAMPLE app: ${p?.label} ${p?.confidence.toStringAsFixed(4)} | "
          "Lab 3: ${example['expected_class']} "
          "${(expected as num).toStringAsFixed(4)}");
    } catch (e) {
      print("HAR example check skipped: $e");
    } finally {
      // Clear the test window before receiving live data, and do not count
      // the check in the performance figures.
      harClassifier!.reset();
      appMetrics.reset();
    }
  }

  // Independent of HAR and its example check. The app owns one Social session
  // and supplies it to the decoded-sample processor for live BLE inference.
  final socialSession = SocialClassifierSession();
  try {
    await socialSession.load();
  } catch (e) {
    debugPrint('Could not load Social model: $e');
  }

  // Move reminder / wake-up alarm notifications. Permission is asked when the
  // RESpeck is first connected.
  final notifications = AppNotifications();
  await notifications.init();

  runApp(MyApp(
    socialSession: socialSession,
    notifications: notifications,
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
    this.session,
    this.startPerfSampler = true,
    this.notifications,
  });

  /// Reminder notifications; null in tests (no notifications).
  final AppNotifications? notifications;

  final SocialClassifierSession? socialSession;
  final void Function(SocialPredictionEvent)? onSocialPrediction;

  /// Optional factory for tests. The app owns and disposes the returned writer.
  final PredictionHistoryWriter Function()? createHistoryWriter;

  /// The user session (tests inject one with a temporary folder).
  final UserSession? session;

  /// Sample CPU, memory and batteries for the Performance tab.
  final bool startPerfSampler;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late final PredictionHistoryWriter _historyWriter;
  late final SocialSampleProcessor _socialProcessor;
  late final SensorController _sensor;
  late final PerfSampler _sampler;
  ActivityReminders? _reminders;

  UserSession get _session => widget.session ?? userSession;

  @override
  void initState() {
    super.initState();
    // Created after main's example comparison. Opens the logged-in user's
    // SQLite file lazily on the first live result, using a connection
    // independent of the History screen.
    _historyWriter = (widget.createHistoryWriter?.call() ??
        PredictionHistoryWriter(openRepository: _session.openRepository))
      ..addListener(_reportHistoryError);
    _socialProcessor = SocialSampleProcessor(
      classifier: () => widget.socialSession?.classifier,
      onPrediction: (event) {
        // Single Social persistence owner: the raw new-inference callback,
        // never Home notifications, cached predictions, or startup examples.
        _historyWriter.captureSocial(event);
        appMetrics.recordSocialInference(
            event.processingDuration, event.completedAt);
        liveFeed.addSocial(event);
        widget.onSocialPrediction?.call(event);
      },
    );
    final notifications = widget.notifications;
    if (notifications != null) {
      _reminders = ActivityReminders(
        notifier: notifications,
        config: () => ReminderConfig(
          moveEnabled: appSettings.moveReminder.value,
          sitMinutes: appSettings.sitMinutes.value,
          wakeEnabled: appSettings.wakeAlarm.value,
          wakeMinuteOfDay: appSettings.wakeMinuteOfDay.value,
        ),
      );
      appSettings.reminders.addListener(_resetReminders);
    }
    _sensor = SensorController(
      historyWriter: _historyWriter,
      socialProcessor: _socialProcessor,
      reminders: _reminders,
      notifications: notifications,
      session: _session,
    );
    _sampler = PerfSampler(sensor: _sensor, session: _session)
      ..describeSettings = () => {
            'app_version': '$appVersionName+$appVersionCode',
            'update_interval_samples': appSettings.stepSamples.value,
            'update_interval_s': appSettings.resultIntervalSeconds,
            'activity_smoothing': appSettings.smoothHar.value,
            'har_model': harModelAsset.split('/').last,
            'har_window_samples': harClassifier?.window.length,
            'social_model': socialModelAsset.split('/').last,
            'social_window_samples': socialWindowSamples,
            'social_paused_while_moving': true,
            'respeck': respeckUUID,
            'user': _session.username,
          };
    if (widget.startPerfSampler) _sampler.start();
    // Before another user logs in (or this one logs out): close the raw file,
    // drop the sensor link and the database, so nothing reaches the wrong
    // folder.
    _session.onBeforeSwitch = () async {
      await _sensor.recorder.stop();
      if (_sensor.connected || _sensor.streaming) await _sensor.disconnect();
      await _sampler.setLogging(false);
      await _historyWriter.reopen();
      _reminders?.reset();
    };
    // Update interval from Settings, applied to both models now and on change.
    appSettings.stepSamples.addListener(_applyStep);
    _applyStep();
    WidgetsBinding.instance.addObserver(this);
  }

  // A changed reminder setting starts the counts afresh.
  void _resetReminders() => _reminders?.reset();

  void _applyStep() {
    final step = appSettings.stepSamples.value;
    harClassifier?.window.step = step;
    widget.socialSession?.classifier?.step = step;
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
    appSettings.stepSamples.removeListener(_applyStep);
    if (_reminders != null) {
      appSettings.reminders.removeListener(_resetReminders);
    }
    if (_session.onBeforeSwitch != null) _session.onBeforeSwitch = null;
    _sampler.dispose();
    _sensor.dispose();
    _historyWriter.dispose();
    _socialProcessor.dispose();
    widget.socialSession?.dispose();
    super.dispose();
  }

  static const Color _seed = Color(0xFF00796B);

  // Floating messages ("Connected…", "Logged in as…") appear above the round
  // Home button. Fixed (full-width) ones would push the docked button up and
  // squeeze in between it and the bottom bar.
  static const SnackBarThemeData _snackBars =
      SnackBarThemeData(behavior: SnackBarBehavior.floating);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDIoT',
      debugShowCheckedModeBanner: false,
      // One seed colour for the whole app; Material 3 derives a consistent
      // light and dark palette from it, and the phone setting picks one.
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        useMaterial3: true,
        snackBarTheme: _snackBars,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: _seed, brightness: Brightness.dark),
        useMaterial3: true,
        snackBarTheme: _snackBars,
      ),
      themeMode: ThemeMode.system,
      home: AppShell(
        sensor: _sensor,
        historyWriter: _historyWriter,
        socialProcessor: _socialProcessor,
        sampler: _sampler,
        session: _session,
      ),
    );
  }
}
