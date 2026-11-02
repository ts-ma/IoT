import 'package:flutter/material.dart';
import 'globals.dart';
import 'scanning.dart';
import 'utils.dart';

// The settings page shows the app version and allows the app to be paired
//// with a subject and respeck.

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            const Text(
              'App version',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              appVersionName,
            ),
            const SizedBox(height: 10),
            const Text(
              'Current pairing',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              'Subject=$subjectID, Respeck=$respeckUUID',
            ),
            const SizedBox(height: 10),
            const Text(
              'Storage folder',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Text(
                storageFolder?.path ?? "Not available on this device",
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'New pairing',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            TextField(
              controller: subjectController,
              decoration: const InputDecoration(hintText: 'Subject ID'),
            ),
            TextField(
              controller: respeckController,
              decoration: const InputDecoration(hintText: 'Respeck UUID'),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceEvenly, // Align buttons evenly
              children: [
                ElevatedButton(
                    onPressed: () {
                      _scanQRCode(context);
                    },
                    child: const Text('Scan QR code')),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: () async {
                    // Store the new subject and respeck IDs in shared preferences
                    // to survive app restarts
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
                  },
                  child: const Text('Save settings'),
                ),
              ],
            )
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
