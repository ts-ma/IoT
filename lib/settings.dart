import 'package:flutter/material.dart';

import 'globals.dart';
import 'har.dart';
import 'services/app_settings.dart';
import 'services/user_session.dart';
import 'social.dart';
import 'widgets/common.dart';

/// Settings (the gear at the top left): how often results update, display
/// smoothing, the installed models and where the user's files are. Sensor
/// pairing lives on the Home sensor card.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.session});

  final UserSession? session;

  @override
  Widget build(BuildContext context) {
    final s = session ?? userSession;
    final textTheme = Theme.of(context).textTheme;
    final har = harClassifier;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            appSettings.stepSamples,
            appSettings.smoothHar,
            appSettings.reminders,
            s
          ]),
          builder: (context, _) {
            final step = appSettings.stepSamples.value;
            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                SectionCard(
                  icon: Icons.update,
                  title: 'Update interval',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<int>(
                        key: const ValueKey('step-setting'),
                        segments: [
                          for (final c in stepChoices)
                            ButtonSegment(value: c, label: Text(stepLabel(c))),
                        ],
                        selected: {step},
                        showSelectedIcon: false,
                        onSelectionChanged: (v) =>
                            appSettings.setStepSamples(v.single),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'How often both models give a new result. Each result '
                        'still looks at the last 4 s (activity) or '
                        '${socialWindowSeconds.toStringAsFixed(0)} s '
                        '(social signal), so accuracy is the same; shorter '
                        'intervals show changes up to one interval sooner and '
                        'run the models more often (a few ms each). The models '
                        'were trained with 2 s. The RESpeck sends its data in '
                        'packets of 2.56 s, so the screen changes at most once '
                        'per packet whatever the interval.',
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  icon: Icons.tune,
                  title: 'Display',
                  child: SwitchListTile(
                    key: const ValueKey('smooth-setting'),
                    contentPadding: EdgeInsets.zero,
                    value: appSettings.smoothHar.value,
                    onChanged: appSettings.setSmoothHar,
                    title: const Text('Smooth activity results'),
                    subtitle: Text('Show the most common of the last 3 results '
                        '(${(3 * step / sensorHz).toStringAsFixed(1)} s) to stop '
                        'the display flickering. History and tests always use '
                        'the raw results.'),
                  ),
                ),
                _remindersCard(context),
                SectionCard(
                  icon: Icons.memory,
                  title: 'Models',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.directions_run),
                        title:
                            Text('Activity: ${harModelAsset.split('/').last}'),
                        subtitle: Text(har == null
                            ? 'Not loaded'
                            : 'Multi-branch CNN · ${har.classes.length} classes · '
                                '${har.window.length}-sample window '
                                '(${(har.window.length / sensorHz).toStringAsFixed(0)} s), '
                                'new result every ${har.window.step} samples.\n'
                                'Trained on datasetJan2026 and both group '
                                'members\' recordings, mixed, to answer from '
                                'the most recent seconds. Official 10-fold '
                                'cross-validation: static 99.4 %, dynamic '
                                '89.6 % (targets 90 % and 85 %).'),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.graphic_eq),
                        title:
                            Text('Social: ${socialModelAsset.split('/').last}'),
                        subtitle: Text('Conv-GRU · ${socialLabels.length} classes · '
                            '$socialWindowSamples-sample window '
                            '(${socialWindowSeconds.toStringAsFixed(0)} s), new '
                            'result every $step samples while you are still; '
                            'paused while the activity is walking, stairs, '
                            'running, shuffling or other movement.\n'
                            'Trained on datasetJan2026 and both group '
                            'members\' recordings, mixed. Official 10-fold '
                            'cross-validation: 81.7 % mean of the 4 classes, '
                            'each class at least 78 % (target 75 %).'),
                      ),
                      Text(
                        'Both models run on the phone with TensorFlow Lite; '
                        'no data leaves the device.',
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  icon: Icons.folder_outlined,
                  title: 'Storage',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.userDir?.path ??
                          (s.root == null
                              ? 'Not available on this device'
                              : '${s.root!.path} (log in to use your folder)')),
                      const SizedBox(height: 4),
                      Text(
                        'Your history, real-time test results, raw recordings '
                        '(raw/), exports and performance logs are kept here.',
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  icon: Icons.info_outline,
                  title: 'About',
                  child: Text('App version $appVersionName'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _remindersCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final wake = appSettings.wakeMinuteOfDay.value;
    final wakeText = MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay(hour: wake ~/ 60, minute: wake % 60),
        alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat);
    return SectionCard(
      icon: Icons.notifications_active_outlined,
      title: 'Reminders',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const ValueKey('move-reminder-setting'),
            contentPadding: EdgeInsets.zero,
            value: appSettings.moveReminder.value,
            onChanged: appSettings.setMoveReminder,
            title: const Text('Move reminder'),
            subtitle: Text('Notify me to walk for 5 minutes after sitting or '
                'standing for ${appSettings.sitMinutes.value} minutes (counted '
                'over the last ${appSettings.sitMinutes.value + 10} minutes, '
                'so short breaks or misreads do not restart it). Lying down '
                'does not count.'),
          ),
          if (appSettings.moveReminder.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SegmentedButton<int>(
                key: const ValueKey('sit-minutes-setting'),
                segments: [
                  for (final m in sitMinuteChoices)
                    ButtonSegment(value: m, label: Text('$m min')),
                ],
                selected: {appSettings.sitMinutes.value},
                showSelectedIcon: false,
                onSelectionChanged: (v) => appSettings.setSitMinutes(v.single),
              ),
            ),
          SwitchListTile(
            key: const ValueKey('wake-alarm-setting'),
            contentPadding: EdgeInsets.zero,
            value: appSettings.wakeAlarm.value,
            onChanged: appSettings.setWakeAlarm,
            title: const Text('Wake-up alarm'),
            subtitle: Text('After $wakeText, notify me every 5 minutes while '
                'I am still lying down, until I get up.'),
          ),
          if (appSettings.wakeAlarm.value)
            OutlinedButton.icon(
              key: const ValueKey('wake-time-setting'),
              icon: const Icon(Icons.alarm),
              label: Text('Alarm time: $wakeText'),
              onPressed: () async {
                final t = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay(hour: wake ~/ 60, minute: wake % 60),
                );
                if (t != null) {
                  await appSettings.setWakeMinuteOfDay(t.hour * 60 + t.minute);
                }
              },
            ),
          const SizedBox(height: 4),
          Text(
            'Reminders need the RESpeck connected. The app keeps running in '
            'the background and with the screen off while it is connected '
            '(Android shows a "PDIoT is monitoring" notification). Closing '
            'the app from the app switcher stops it.',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
