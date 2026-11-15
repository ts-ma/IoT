import 'package:flutter/material.dart';

import 'services/app_settings.dart';
import 'services/user_session.dart';
import 'widgets/common.dart';

/// Settings (the gear at the top left): reminders and where the user's files
/// are. The models are described on the Performance tab (Response time). Sensor
/// pairing lives on the Home sensor card.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.session});

  final UserSession? session;

  @override
  Widget build(BuildContext context) {
    final s = session ?? userSession;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            appSettings.reminders,
            s
          ]),
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                _remindersCard(context),
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
                        'Your history, real-time and latency test results, raw '
                        'recordings (raw/), exports and performance logs are '
                        'kept here.',
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
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
