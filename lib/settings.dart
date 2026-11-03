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
          listenable: Listenable.merge(
              [appSettings.stepSamples, appSettings.smoothHar, s]),
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
                        'still looks at the last 4 s (activity) or 8 s '
                        '(social signal), so accuracy is the same; shorter '
                        'intervals show changes up to one interval sooner and '
                        'run the models more often (a few ms each). The models '
                        'were trained with 2 s.',
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
                        '(${(3 * step / sensorHz).toStringAsFixed(0)} s) to stop '
                        'the display flickering. History and tests always use '
                        'the raw results.'),
                  ),
                ),
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
                            : '${har.classes.length} classes · '
                                '${har.window.length}-sample window '
                                '(${(har.window.length / sensorHz).toStringAsFixed(0)} s), '
                                'new result every ${har.window.step} samples'),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.graphic_eq),
                        title:
                            Text('Social: ${socialModelAsset.split('/').last}'),
                        subtitle: Text('${socialLabels.length} classes · '
                            '$socialWindowSamples-sample window '
                            '(${socialWindowSeconds.toStringAsFixed(0)} s), new '
                            'result every $step samples'),
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
}
