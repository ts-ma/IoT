import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'utils.dart';

/// Scans the QR code label on the back of the RESpeck and returns its ID to
/// the caller (Home's sensor card) when the user goes back.
class ScanningPage extends StatefulWidget {
  const ScanningPage({super.key});

  @override
  State<ScanningPage> createState() => _ScanningPageState();
}

class _ScanningPageState extends State<ScanningPage> {
  String? _qrCode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('Scan QR code'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        // Going back returns the scanned code. PopScope (not WillPopScope)
        // also works with the Android predictive back gesture
        // (android:enableOnBackInvokedCallback in AndroidManifest.xml).
        body: PopScope<String?>(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, String? result) {
            if (didPop) return;
            Navigator.pop(context, _qrCode);
          },
          child: MobileScanner(
            onDetect: (result) {
              // A capture can contain no barcodes, and a barcode can have no
              // decodable text, so neither may be assumed to be present.
              if (result.barcodes.isEmpty) return;
              final String? rawValue = result.barcodes.first.rawValue;
              if (rawValue == null || rawValue.isEmpty) return;

              if (_qrCode != rawValue) {
                showToast(rawValue);
                _qrCode = rawValue;
              }
            },
          ),
        ));
  }
}
