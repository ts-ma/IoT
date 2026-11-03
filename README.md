# PDIoT – live activity & social-signal recognition

Flutter app for PDIoT Coursework 3 (2026/27). It connects to a RESpeck
accelerometer over Bluetooth LE, classifies the wearer's **physical activity**
(11 classes) and **social signal** (4 classes) on the phone with TensorFlow
Lite, saves every result, and shows live, daily and weekly views of them.

## Features

| Screen | What it does |
|---|---|
| **Home (live dashboard)** | Sensor card (connection state, RESpeck battery, live acceleration, Connect / Disconnect). *Detected activity* card with icon, readable name, confidence bar, update time and optional smoothing. *Social signal* card with the predicted class, confidence and the full probability distribution, plus a warning when the wearer is moving. *This session* totals (time monitored, cough bouts, time per activity). The original CSV *Data collection* controls stay at the bottom. |
| **Daily summary** | For any day: time spent in each activity, static vs. active time, number of separate coughing bouts and time per social signal, a share-of-day bar and a 7-day trend chart (tap a bar to open that day). Export the day as CSV or delete it. |
| **History** | Every saved result, newest first, filterable by HAR / Social, paginated. |
| **Real-time test** | Guided real-time accuracy test for the report: choose participant, true activity and true social signal, run a 15/30/60 s trial; every live result is scored (first 4 s optional warm-up skip), latency to the first correct result is measured, and a per-class / per-group accuracy table builds up across trials and group members. Exports `PDIoT_realtime_trials_*.csv` and `PDIoT_realtime_summary_*.csv`. |
| **Performance** | Live sample rate, lost BLE packets, HAR and Social inference time (last/mean/max), interval between results, history-database health. |
| **Settings** | Subject / RESpeck pairing (QR scan), smoothing preference, installed model info, storage folder, version. |

Light and dark themes follow the phone setting.

## How it works

```
RESpeck ──BLE 12.5 Hz──► ble.dart (decode x,y,z in g)
                            │ every sample
                            ├──► HarClassifier (har.dart)      50-sample window, step 25 ─► HAR result every 2 s
                            ├──► SocialSampleProcessor ─► SocialClassifier (social.dart)   ─► Social result every 2 s
                            └──► CSV recording (only while recording)
results ─► PredictionHistoryWriter ─► SQLite (prediction_history.db) ─► History / Daily summary
        ─► LivePredictionFeed (session totals, Real-time test)
        ─► Home page cards
```

* Both models take a `[1, 50, 3]` window of raw acceleration in g (normalisation
  is inside the model) and output softmax probabilities. Inference runs
  on-device, so there is no network latency and no data leaves the phone.
* Each result represents one step (25 samples = 2 s), so time per activity =
  number of results × 2 s. The step is read from the HAR model's metadata at
  start-up, so a model with a different step still reports correct durations.
* A *cough bout* is a run of consecutive `coughing` results (a gap of more than
  6 s, e.g. a disconnect, also ends a bout).
* Smoothing (on by default) only changes what the home screen shows: the most
  common of the last 3 HAR results. History, summaries and the real-time test
  always use raw results.

## Code layout

| Path | Role |
|---|---|
| `lib/main.dart` | Start-up: preferences, storage folder, model loading, debug-only model parity check, app wiring and theme. |
| `lib/ble.dart` | RESpeck scanning, connection, packet decoding; feeds samples to both classifiers and the metrics. |
| `lib/har.dart` / `lib/social.dart` | TFLite classifiers with sliding windows. |
| `lib/home.dart` | Live dashboard and CSV recording. |
| `lib/summary.dart`, `lib/history.dart` | Daily summary / 7-day trend, raw history list. |
| `lib/evaluation.dart`, `lib/services/evaluation.dart` | Real-time test UI; trial scoring, persistence and CSV export. |
| `lib/performance.dart`, `lib/services/app_metrics.dart` | Performance page and counters. |
| `lib/activity_catalog.dart` | Readable names, icons, colours and coursework groups for every class. |
| `lib/services/` | History database (`prediction_repository.dart`), background writer, Social stream processor, live feed, smoother. |
| `test/` | Unit and widget tests (`flutter test`). |

## Swapping in a new model

1. Export `<name>.tflite`, `<name>_meta.json` and `<name>_example.json` from the
   training notebook (same `[1, window, 3]` raw-g float32 input, softmax output).
2. Copy them into `assets/models/` and list them under `assets:` in `pubspec.yaml`.
3. Point `harModelAsset` / `harMetaAsset` in `lib/har.dart` at them (for the
   Social model: `socialModelAsset` / `socialMetaAsset` in `lib/social.dart`;
   its metadata check in `_validateMetadata` expects the current contract).
4. Do a full rebuild. In a debug build the console prints an `EXAMPLE app:` line
   comparing the app's prediction for the example window with the notebook's –
   class and probability should match.

Class names are mapped to readable names in `lib/activity_catalog.dart`; unknown
names are still shown (raw), so a model with new classes works without changes.

## Measuring performance for the report

* **Real-time accuracy & latency** – use *Real-time test*: every group member
  performs every activity and social signal; export both CSVs.
* **Communication latency** – the trial's "latency" column is the time from the
  start of an activity to the first correct result on screen. The *Performance*
  page gives its components (inference time, interval between results).
* **CPU / memory / energy** – Android Studio → *Profiler* (CPU, Memory, Energy)
  on a `flutter run --profile` build, or Xcode Instruments on iPhone; note the
  phone model, run time and that inference is on-device.

## Build / run

```
flutter pub get
flutter test
flutter run            # or: flutter run --profile for measurements
```

Android 10+ (or iOS 16+) is needed for Bluetooth. A smaller release APK:
`flutter build apk --release --split-per-abi`.

## Using the app

1. *Settings* → scan the QR code on the RESpeck (or type its ID) and enter the
   subject ID → *Save settings*.
2. Wake the RESpeck by shaking it, press *Connect*. Acceleration appears, the
   first activity / social result about 4 s later, then every 2 s.
3. To record raw data for training, choose the activity and social signal under
   *Data collection* and press *Start recording*. CSVs (and all exports) go to
   the storage folder shown in Settings (Downloads on Android).

**Uninstalling the app deletes recorded data and history** – copy CSVs off the
phone first.
