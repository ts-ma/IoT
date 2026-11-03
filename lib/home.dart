import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'activity_catalog.dart';
import 'evaluation.dart';
import 'performance.dart';
import 'settings.dart';
import 'summary.dart';
import 'utils.dart';
import 'ble.dart';
import 'globals.dart';
import 'har.dart';
import 'history.dart';
import 'services/live_feed.dart';
import 'services/prediction_history_writer.dart';
import 'services/prediction_smoother.dart';
import 'services/social_sample_processor.dart';
import 'dart:io';

// The home page is the live dashboard: sensor connection, the current
// activity and social signal, totals for this session, shortcuts to the
// summary/evaluation/performance tools, and the original CSV recording
// controls used for data collection.

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.title,
    this.historyWriter,
    this.socialProcessor,
  });

  final PredictionHistoryWriter? historyWriter;
  final SocialSampleProcessor? socialProcessor;

  final String title;

  @override
  State<MyHomePage> createState() => MyHomePageState();
}

class MyHomePageState extends State<MyHomePage> {
  String accel = "";
  String batt_level = "";
  String recording_info = "Not recording";
  // Latest raw live activity prediction, e.g. "normalWalking (87%)". Kept for
  // logging/compatibility; the card below shows the formatted version.
  String activity = "";

  // What the activity card shows (smoothed when enabled), the raw model
  // output it came from, and when it arrived.
  HarPrediction? _harShown;
  HarPrediction? _harRaw;
  DateTime? _harUpdatedAt;
  final PredictionSmoother _smoother = PredictionSmoother(size: 3);

  @override
  void initState() {
    super.initState();
    widget.socialProcessor?.addListener(_socialChanged);
  }

  @override
  void didUpdateWidget(covariant MyHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.socialProcessor != widget.socialProcessor) {
      oldWidget.socialProcessor?.removeListener(_socialChanged);
      widget.socialProcessor?.addListener(_socialChanged);
    }
  }

  void _socialChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.socialProcessor?.removeListener(_socialChanged);
    super.dispose();
  }

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

  void _open(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Daily summary',
            onPressed: () => _open(const DailySummaryPage()),
            icon: const Icon(Icons.insights),
          ),
          TextButton.icon(
            onPressed: () => _open(const HistoryPage()),
            icon: const Icon(Icons.history),
            label: const Text('History'),
          ),
        ],
      ),
      // Scrollable, so that every card stays reachable on short screens.
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _connectionCard(context),
            _harCard(context),
            _socialResult(),
            _sessionCard(context),
            _toolsCard(context),
            _recordingCard(context),
            const SizedBox(height: 8),
            Center(
              child: ElevatedButton(
                onPressed: () => _open(const SettingsPage()),
                child: const _IconLabel(Icons.settings, 'Settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- cards --

  Widget _connectionCard(BuildContext context) {
    final streaming = respeckStreaming;
    final paired = respeckUUID != null && respeckUUID!.isNotEmpty;
    IconData icon;
    Color color;
    String status;
    if (connecting) {
      icon = Icons.bluetooth_searching;
      color = Colors.amber.shade700;
      status = 'Connecting…';
    } else if (streaming) {
      icon = Icons.bluetooth_connected;
      color = Colors.green.shade600;
      status = 'Streaming live data';
    } else {
      icon = Icons.bluetooth_disabled;
      color = Colors.grey.shade600;
      status = paired ? 'Not connected' : 'No RESpeck paired';
    }
    final textTheme = Theme.of(context).textTheme;
    return _Section(
      icon: Icons.sensors,
      title: 'Sensor',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(status,
                        key: const ValueKey('connection-status'),
                        style: textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      paired
                          ? 'RESpeck $respeckUUID'
                          : 'Scan the QR code on the sensor in Settings',
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (batt_level.isNotEmpty || accel.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (batt_level.isNotEmpty)
                  Chip(
                    avatar: Icon(
                        batt_level.contains('charging')
                            ? Icons.battery_charging_full
                            : Icons.battery_std,
                        size: 18),
                    label: Text(batt_level),
                    visualDensity: VisualDensity.compact,
                  ),
                if (accel.isNotEmpty)
                  Chip(
                    avatar: const Icon(Icons.vibration, size: 18),
                    label: Text(accel),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          if (!streaming && !connecting) ...[
            const SizedBox(height: 8),
            Text(
              'Wake the RESpeck by shaking it (green light), then press Connect.',
              style: textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                onPressed: connect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
                child: const _IconLabel(Icons.bluetooth, 'Connect'),
              ),
              const SizedBox(width: 8),
              if (respeck != null && (streaming || respeckConnected))
                TextButton(
                  onPressed: _disconnect,
                  child: const Text('Disconnect'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _harCard(BuildContext context) {
    final shown = _harShown;
    final raw = _harRaw;
    final textTheme = Theme.of(context).textTheme;
    Widget body;
    if (harClassifier == null) {
      body = const Text('Classifier not available');
    } else if (shown == null) {
      body = Text(
        respeckStreaming
            ? 'Collecting data… the first result appears about 4 s after '
                'data starts, then every 2 s.'
            : 'Connect the RESpeck to start live activity recognition.',
        style: textTheme.bodyMedium,
      );
    } else {
      final updated = _harUpdatedAt == null
          ? ''
          : 'Updated ${DateFormat('HH:mm:ss').format(_harUpdatedAt!.toLocal())}';
      final smoothing =
          smoothHarPredictions ? ' · majority of last 3 results' : '';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PredictionDisplay(
            label: shown.label,
            confidence: shown.confidence,
            confidenceText:
                'Confidence: ${(shown.confidence * 100).toStringAsFixed(0)}%',
            labelKey: const ValueKey('har-prediction-label'),
            confidenceKey: const ValueKey('har-prediction-confidence'),
          ),
          const SizedBox(height: 8),
          Text('$updated$smoothing', style: textTheme.bodySmall),
          if (raw != null && raw.label != shown.label)
            Text(
              'Latest raw result: ${displayName(raw.label)} '
              '(${(raw.confidence * 100).toStringAsFixed(0)}%)',
              style: textTheme.bodySmall,
            ),
        ],
      );
    }
    return _Section(
      icon: Icons.directions_run,
      title: 'Detected activity',
      trailing: shown == null
          ? null
          : _GroupChip(labelInfo(shown.label).group.shortTitle),
      child: body,
    );
  }

  Widget _socialResult() {
    final processor = widget.socialProcessor;
    final status = processor?.status ?? SocialPredictionStatus.unavailable;
    final event = processor?.latestPrediction;
    final statusText = switch (status) {
      SocialPredictionStatus.unavailable => 'Social model unavailable',
      SocialPredictionStatus.disconnected => 'Disconnected',
      SocialPredictionStatus.collecting => 'Collecting data...',
      SocialPredictionStatus.ready => 'Live prediction',
      SocialPredictionStatus.error =>
        'Social inference error — reconnect to retry',
    };
    final statusColor = switch (status) {
      SocialPredictionStatus.ready => Colors.green.shade600,
      SocialPredictionStatus.collecting => Colors.amber.shade700,
      SocialPredictionStatus.error => Colors.red.shade600,
      _ => Colors.grey.shade600,
    };
    final label = event?.prediction.label;
    final probabilities = event?.prediction.probabilities ?? const <double>[];
    final moving = _harShown != null &&
        labelInfo(_harShown!.label).group == LabelGroup.dynamicActivity;
    final textTheme = Theme.of(context).textTheme;
    return _Section(
      key: const ValueKey('social-signal-result'),
      icon: Icons.graphic_eq,
      title: 'Social Signal',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: statusColor),
              const SizedBox(width: 6),
              Flexible(
                child: Text(statusText,
                    key: const ValueKey('social-prediction-status')),
              ),
            ],
          ),
          if (event != null &&
              label != null &&
              socialClassOrder.contains(label)) ...[
            const SizedBox(height: 12),
            _PredictionDisplay(
              label: label,
              confidence: event.prediction.confidence,
              confidenceText: 'Confidence: '
                  '${(event.prediction.confidence * 100).toStringAsFixed(1)}%',
              labelKey: const ValueKey('social-prediction-label'),
              confidenceKey: const ValueKey('social-prediction-confidence'),
            ),
            if (probabilities.length == socialClassOrder.length) ...[
              const SizedBox(height: 12),
              for (var i = 0; i < socialClassOrder.length; i++)
                _ProbabilityRow(socialClassOrder[i], probabilities[i]),
            ],
          ],
          if (moving && event != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.warning_amber, size: 16, color: Colors.amber.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'You are moving - this result may be less reliable.',
                    style: textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Social predictions are most reliable for stationary activities.',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sessionCard(BuildContext context) {
    final session = liveFeed.session;
    final textTheme = Theme.of(context).textTheme;
    final hasData = session.harPredictions > 0 || session.socialPredictions > 0;
    return _Section(
      icon: Icons.timelapse,
      title: 'This session',
      trailing: TextButton(
        onPressed: () => _open(const DailySummaryPage()),
        child: const Text('Daily summary'),
      ),
      child: !hasData
          ? Text(
              'Totals since the app was opened appear here once live results '
              'arrive. Every result is saved; see the daily summary.',
              style: textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _StatTile(
                        value: formatDuration(session.monitoredTime),
                        caption: 'monitored',
                      ),
                    ),
                    Expanded(
                      child: _StatTile(
                        value: '${session.coughEpisodes}',
                        caption: 'cough bouts',
                      ),
                    ),
                    Expanded(
                      child: _StatTile(
                        value: '${session.harPredictions}',
                        caption: 'activity results',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in session.topActivities.take(4))
                      Chip(
                        avatar: Icon(labelInfo(entry.key).icon,
                            size: 18, color: labelInfo(entry.key).color),
                        label: Text('${displayName(entry.key)} · '
                            '${formatDuration(durationForPredictions(entry.value))}'),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _toolsCard(BuildContext context) {
    return _Section(
      icon: Icons.handyman_outlined,
      title: 'Tools',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonal(
            onPressed: () => _open(const EvaluationPage()),
            child: const _IconLabel(Icons.fact_check_outlined, 'Real-time test'),
          ),
          FilledButton.tonal(
            onPressed: () => _open(PerformancePage(
              historyWriter: widget.historyWriter,
            )),
            child: const _IconLabel(Icons.speed, 'Performance'),
          ),
        ],
      ),
    );
  }

  Widget _recordingCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return _Section(
      icon: Icons.fiber_manual_record,
      title: 'Data collection',
      trailing: recording
          ? const _GroupChip('REC', color: Colors.red)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Record raw accelerometer data to a CSV file, labelled with the '
            'activity and social signal being performed.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          const Text('Activity', style: TextStyle(fontWeight: FontWeight.bold)),
          DropdownButton<String>(
            isExpanded: true,
            value: selected_activity,
            items: activities.map((String items) {
              return DropdownMenuItem<String>(value: items, child: Text(items));
            }).toList(),
            onChanged: recording
                ? null
                : (String? newValue) {
                    setState(() {
                      selected_activity = newValue!;
                    });
                  },
          ),
          const SizedBox(height: 8),
          const Text('Social signal',
              style: TextStyle(fontWeight: FontWeight.bold)),
          DropdownButton<String>(
            isExpanded: true,
            value: selected_signal,
            items: social_signals.map((String items) {
              return DropdownMenuItem<String>(value: items, child: Text(items));
            }).toList(),
            onChanged: recording
                ? null
                : (String? newValue) {
                    setState(() {
                      selected_signal = newValue!;
                    });
                  },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: record,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade100,
                      foregroundColor: Colors.green.shade900),
                  child: const _IconLabel(
                      Icons.play_arrow, 'Start recording'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  // Called through a closure because stopRecording takes an
                  // optional argument, and onPressed wants a plain callback
                  onPressed: () => stopRecording(),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade100,
                      foregroundColor: Colors.red.shade900),
                  child: const _IconLabel(Icons.stop, 'Stop recording'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            "Recording status",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(recording_info),
          if (filename.isNotEmpty)
            Text(filename, style: textTheme.bodySmall),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- actions --

  /// Called by ble.dart whenever the connection state changes, so the
  /// connection card and the activity card never show a stale state.
  void connectionChanged() {
    if (!respeckConnected) {
      _smoother.reset();
      _harShown = null;
      _harRaw = null;
      _harUpdatedAt = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> _disconnect() async {
    try {
      await disconnect();
    } catch (e) {
      print("Disconnect failed: $e");
    }
    if (!mounted) return;
    setState(() {
      accel = "";
      batt_level = "";
    });
    showToast("Disconnected");
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
    if (respeckStreaming) {
      showToast("Already connected");
      return;
    }

    setState(() => connecting = true);
    try {
      // Release a stale link before scanning; a connected sensor may no
      // longer advertise and would otherwise never appear in scan results.
      ui = this;
      if (respeck != null) await disconnect();
      await scanForRespeck(this);
      if (respeck == null) {
        showLongToast("Respeck $respeckUUID not found - is it awake?");
        return;
      }
      await connectToRespeck(
        onPrediction: (prediction) {
          // Raw result: persisted to history and published to live screens.
          widget.historyWriter?.capture(prediction);
          liveFeed.addHar(prediction);
        },
        socialProcessor: widget.socialProcessor,
      );
    } catch (e) {
      print("Connect failed: $e");
      showLongToast(
          "Could not receive Respeck data - wake it and press Connect again");
    } finally {
      if (mounted) {
        setState(() => connecting = false);
      } else {
        connecting = false;
      }
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
      // Without a new prediction the previous one stays on screen.
      if (prediction != null) {
        _harRaw = prediction;
        _harShown =
            smoothHarPredictions ? _smoother.add(prediction) : prediction;
        _harUpdatedAt = packetReceivedTs;
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
    if (!received_packet || !respeckStreaming) {
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

// ------------------------------------------------------------- widgets --

/// A titled card used for every section of the home page.
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Icon + label for buttons. A plain Row keeps the button's runtime type
/// (e.g. ElevatedButton) unchanged, which the widget tests rely on.
class _IconLabel extends StatelessWidget {
  const _IconLabel(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Flexible(child: Text(label)),
      ],
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

/// Large icon, readable class name and a confidence bar.
class _PredictionDisplay extends StatelessWidget {
  const _PredictionDisplay({
    required this.label,
    required this.confidence,
    required this.confidenceText,
    required this.labelKey,
    required this.confidenceKey,
  });

  final String label;
  final double confidence;
  final String confidenceText;
  final Key labelKey;
  final Key confidenceKey;

  @override
  Widget build(BuildContext context) {
    final info = labelInfo(label);
    final textTheme = Theme.of(context).textTheme;
    final low = confidence < 0.5;
    return Row(
      children: [
        LabelAvatar(label, radius: 30),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.displayName,
                key: labelKey,
                style: textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: confidence.clamp(0.0, 1.0),
                  minHeight: 8,
                  color: info.color,
                  backgroundColor: info.color.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(confidenceText,
                      key: confidenceKey, style: textTheme.bodySmall),
                  if (low) ...[
                    const SizedBox(width: 8),
                    Text('· uncertain',
                        style: textTheme.bodySmall
                            ?.copyWith(color: Colors.amber.shade800)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One class probability as a thin bar, for the full Social output.
class _ProbabilityRow extends StatelessWidget {
  const _ProbabilityRow(this.label, this.probability);

  final String label;
  final double probability;

  @override
  Widget build(BuildContext context) {
    final info = labelInfo(label);
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(info.displayName,
                style: style, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: probability.clamp(0.0, 1.0),
                minHeight: 6,
                color: info.color,
                backgroundColor: info.color.withValues(alpha: 0.12),
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('${(probability * 100).toStringAsFixed(0)}%',
                style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.caption});

  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(value,
            style:
                textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center),
        Text(caption, style: textTheme.bodySmall, textAlign: TextAlign.center),
      ],
    );
  }
}
