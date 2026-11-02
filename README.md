# pdiot

A flutter app for the 2025/26 PDIoT course.

## Purpose

The app is used to record acceleration data from the Respeck sensor to CSV files. It is required for the data collectrespeck-pdiot-HAR-classifiergition part of the course.

You can also use this source code as a starting point for your own app, which will be developed during Coursework 3.

## Requirements
A reasonably up-to-date flutter and android development environment
https://docs.flutter.dev/get-started/install

For full functionality, an Android phone running at least Android 10.

## Build/run

Once you have installed the flutter and android SDKs, you should be able to run the app as follows:
flutter pub get
flutter run

The UI will display on a linux desktop machine, but for the BLE functionality (provided by flutter blue plus library), you should connect an Android phone.

On android, debug builds can be quite large. You can make a smaller, more efficient release APK by running:
flutter build apk --release --split-per-abi

## Layout

main.dart contains code to start the app.
home.dart defines the UI for the home page.
ble.dart handles BLE connumication with the respeck and decoding of sensor data.

Additional files define the settings page, QR code scanner, global variables and utility functions.

## How to use the app

First, enter your subject ID and Respeck ID on the settings page. You can scan the QR code on the back of the respeck to make this easier.

Wake up your respeck by shaking it (the light should blink green, or orange/red if the battery is low).
Now press the connect button - the respeck should blink blue and acceleration values will appear on the screen.

You can now make recodrings of the acceleration data by selecting an activity and social signal type, and pressing "start recording".
You will see the number of samples recorded, the capture time, and the CSV filename.
Stop recording by pressing "Stop recording".

To diconnect from the respeck, please close the app by swiping it away in the Android task screen. If you wish to pair the app with a different respeck, but you are already connected to a sensor, please restart the app first and then re-pair in the settings screen.

Recorded files can be found in the folder displayed on the settings page. You can copy these to a computer for analysis via USB.

## Uninstalling

***IMPORTANT***
Uninstalling the app from your phone will delete any recorded data, so please ensure you have copied this elsewhere first!

