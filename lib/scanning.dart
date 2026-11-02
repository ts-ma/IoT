import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'utils.dart';

// This page is used to scan the QR code label on the back of your respeck

class ScanningPage extends StatefulWidget {
  const ScanningPage({super.key});

  @override
  State<ScanningPage> createState() => _ScanningPageState();
}

class _ScanningPageState extends State<ScanningPage> {
  String? qr_code;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('Scan QR code'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        // PopScope replaces the deprecated WillPopScope. WillPopScope is
        // ignored when the app opts in to the Android predictive back gesture
        // (see android:enableOnBackInvokedCallback in AndroidManifest.xml), so
        // the scanned code was never handed back to the settings page.
        body: PopScope<String?>(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, String? result) {
            if (didPop) return;
            Navigator.pop(context, qr_code);
          },
          child: MobileScanner(
            onDetect: (result) {
              // A capture can contain no barcodes, and a barcode can have no
              // decodable text, so neither may be assumed to be present
              if (result.barcodes.isEmpty) return;
              final String? rawValue = result.barcodes.first.rawValue;
              if (rawValue == null || rawValue.isEmpty) return;

              print("QR:$rawValue");
              if (qr_code != rawValue) {
                showToast(rawValue);
                qr_code = rawValue;
              }
            },
          ),
        ));
  }
}
