import 'package:flutter/material.dart';
import 'globals.dart';
import 'har.dart';
import 'scanning.dart';
import 'social.dart';
import 'utils.dart';

// The settings page pairs the app with a subject and RESpeck, holds display
// preferences, and shows which models are installed.

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // Both fields are backed by controllers that start out holding the current
  // pairing. Saving writes back whatever is in the fields, so pre-filling them
  // is what stops an edit to one field from wiping the other.
  final TextEditingController subjectController = TextEditingController();
  final TextEditingController respeckController = TextEditingController();

  @override
  void initState() {
    super.initState();
    subjectController.text = subjectID ?? "";
    respeckController.text = respeckUUID ?? "";
  }

  @override
  void dispose() {
    subjectController.dispose();
    respeckController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // Store the new subject and respeck IDs in shared preferences to survive
    // app restarts
    final String newSubject = subjectController.text.trim();
    final String newRespeck = respeckController.text.trim();

    await asyncPrefs.setString('rid', newRespeck);
    await asyncPrefs.setString('sid', newSubject);

    if (!mounted) return;
    setState(() {
      respeckUUID = newRespeck;
      subjectID = newSubject;
    });
    showToast("Settings saved");
  }

  Future<void> _setSmoothing(bool value) async {
    setState(() => smoothHarPredictions = value);
    try {
      await asyncPrefs.setBool('smooth_har', value);
    } catch (e) {
      print("Could not save smoothing preference: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final har = harClassifier;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: <Widget>[
            _card(context, 'Pairing', Icons.link, [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: const Text('Current pairing'),
                subtitle: Text(
                    'Subject: ${subjectID?.isNotEmpty == true ? subjectID : '–'}\n'
                    'RESpeck: ${respeckUUID?.isNotEmpty == true ? respeckUUID : '–'}'),
                isThreeLine: true,
              ),
              TextField(
                controller: subjectController,
                decoration: const InputDecoration(
                  labelText: 'Subject ID',
                  hintText: 'Subject ID',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: respeckController,
                decoration: const InputDecoration(
                  labelText: 'Respeck UUID',
                  hintText: 'Respeck UUID',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                        onPressed: () {
                          _scanQRCode(context);
                        },
                        child: const Text('Scan QR code')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _save,
                      child: const Text('Save settings'),
                    ),
                  ),
                ],
              ),
            ]),
            _card(context, 'Display', Icons.tune, [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: smoothHarPredictions,
                onChanged: _setSmoothing,
                title: const Text('Smooth activity results'),
                subtitle: const Text(
                    'Show the most common of the last 3 results (6 s) to stop '
                    'the display flickering. History and tests always use the '
                    'raw results.'),
              ),
            ]),
            _card(context, 'Models', Icons.memory, [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.directions_run),
                title: Text('Activity: ${harModelAsset.split('/').last}'),
                subtitle: Text(har == null
                    ? 'Not loaded'
                    : '${har.classes.length} classes · '
                        '${har.window.length}-sample window, new result every '
                        '${har.window.step} samples'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.graphic_eq),
                title: Text('Social: ${socialModelAsset.split('/').last}'),
                subtitle: Text('${socialLabels.length} classes · 50-sample '
                    'window, new result every 25 samples'),
              ),
              Text(
                'Both models run on the phone with TensorFlow Lite; no data '
                'leaves the device.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
            _card(context, 'Storage', Icons.folder_outlined, [
              Text(
                storageFolder?.path ?? "Not available on this device",
              ),
              const SizedBox(height: 4),
              Text(
                'CSV recordings and exports are written here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
            _card(context, 'About', Icons.info_outline, [
              Text('App version $appVersionName'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _card(
      BuildContext context, String title, IconData icon, List<Widget> children) {
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  // Launch the QR code scanner, which appears in a new page
  Future<void> _scanQRCode(BuildContext context) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ScanningPage()),
    );

    // When a BuildContext is used from a StatefulWidget, the mounted property
    // must be checked after an asynchronous gap.
    if (!context.mounted) return;

    // The scanner returns null if the user backed out without scanning
    // anything, so the result cannot be assigned to the field unchecked
    if (result is! String || result.isEmpty) {
      showToast("No QR code scanned");
      return;
    }

    respeckController.text = result;
  }
}
