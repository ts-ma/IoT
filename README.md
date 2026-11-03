# PDIoT – live activity & social-signal recognition

Flutter app for PDIoT Coursework 3 (2026/27).

- It connects to a RESpeck accelerometer over Bluetooth LE.
- On the phone, with TensorFlow Lite, it classifies the wearer's **physical activity** (11 classes) and **social signal** (4 classes).
- It saves every result in the logged-in user's own folder.
- It shows live, daily and weekly views of the results, plus live performance graphs for the report.

## Navigation

```
 [user ●][⚙]           <tab title>            <tab actions>
 ┌──────────────────────────────────────────────────────┐
 │                       tab page                       │
 └──────────────────────────────────────────────────────┘
   Tools   Performance    ( HOME )    History    Chart
```

- **Top left, on every tab:** the round **user** button (create, log in, log out) and the **Settings** gear.
- **Bottom bar:** Home is the large round button in the middle. The tabs stay alive when you switch, so a running real-time trial or the live graphs keep going.

| Tab | What it does |
|---|---|
| **Home** | **Sensor card.** If no sensor is paired: *Scan QR code* or *Enter ID*. Once paired: *Connect* / *Disconnect*, the RESpeck battery, live acceleration, and *Change* / *Forget sensor*.<br>**Detected activity:** icon, name, confidence and smoothing note.<br>**Social signal:** class, confidence, all four probabilities, and a warning while moving.<br>**Today:** monitored time, active time, cough bouts and the day timeline. |
| **Tools** | **Real-time test:** timed, scored trials per participant, activity and social signal, with a warm-up skip and the latency to the first correct result; a per-class / per-group accuracy table; CSV export. Each trial also saves its **raw sensor CSV** to `<user>/raw/`.<br>**Free recording:** raw data with labels and no time limit, also to `raw/`. |
| **Performance** | **Live moving graphs (last 5 min):** CPU, memory, phone battery, phone power (Android), RESpeck battery, HAR / Social inference time, sensor sample rate, storage.<br>**Figures:** response time, sensor stream, power and storage breakdown.<br>**Record performance log:** a 1 s CSV saved to `<user>/performance/`. |
| **History** | The activity **and** the social signal of the same moment side by side, for any day.<br>**Episodes:** runs where neither label changed, with start–end, duration and mean confidence.<br>**Every result:** each activity result with its paired social result (±¾ of the update interval), paginated. |
| **Chart** | The **day timeline**: a strip coloured by activity, a social-signal strip, tap for details, and *Monitored hours* or *24 h*. Below it: time per activity, static vs active time, cough bouts, time per social signal, the share of the day, and a **7-day trend**. Export the day as CSV, or delete it. |
| **Settings** (gear) | **Update interval** (2 s / 1 s / 0.5 s), activity smoothing, installed models, the user's folder, version. |

Light and dark themes follow the phone setting.

## Users and storage

A user is a folder. Names are 1–32 letters, digits, `_` or `-`.

- **Create:** the name must not exist yet, ignoring case.
- **Log in:** the folder must exist; otherwise the app suggests *Create user*.

The last user is logged in again at start-up. The app only reads and writes the logged-in user's folder:

```
<storage>/PDIoT/<user>/
    profile.json            user name, created, paired RESpeck ID
    history.db              every saved result (SQLite, schema v2)
    realtime_trials.json    real-time test trials
    raw/                    raw sensor CSVs (real-time test, free recording)
    exports/                daily-summary and real-time-test CSV exports
    performance/            performance logs (Performance tab)
```

`<storage>` is the app's Downloads folder on Android (reachable over USB) and its Documents folder on iOS (visible in the Files app).

**Switching user:** the app first stops any recording, disconnects the sensor and closes the previous user's database.

## How it works

```
RESpeck ──BLE 12.5 Hz──► ble.dart (decode x,y,z in g) ──► SensorController (shared state)
                            │ every sample
                            ├──► HarClassifier (har.dart)        50-sample window ─► result every <step>
                            ├──► SocialSampleProcessor ─► SocialClassifier (social.dart) 100-sample window ─► result every <step>
                            └──► RawRecorder ─► <user>/raw/*.csv (only while recording)
results ─► PredictionHistoryWriter ─► <user>/history.db ─► History / Chart / Home timeline
        ─► LivePredictionFeed (real-time test)
PerfSampler (1 s) ─► CPU, memory, batteries, model timing, storage ─► Performance tab (+ CSV log)
```

### Model input and output

- Both models take a `[1, window, 3]` window of raw acceleration in g; normalisation happens inside the model.
- Both output softmax probabilities.
- HAR uses a 4 s window (50 samples). Social uses an 8 s window (100 samples), long enough to contain whole breaths.
- Inference runs on the device, so there is no network latency and no data leaves the phone.

### Update interval

The update interval is the step between windows. It is set in Settings:

| Setting | Step | Note |
|---|---|---|
| 2 s | 25 samples | the step used in training |
| 1 s | 12 samples | default |
| 0.5 s | 6 samples | |

The windows and models stay the same, so per-window accuracy does not change.

### Durations

- Each saved result stores the interval it stands for (`interval_ms`, schema v2).
- Durations are sums of those intervals, so they stay correct when the setting changes.
- Rows from before v2 count as 2 s.

### Cough bouts and smoothing

- A **cough bout** is a run of consecutive `coughing` results. A gap of more than 6 s (e.g. a disconnect) also ends a bout.
- **Smoothing** (on by default) only changes what Home shows: the most common of the last 3 HAR results. History, charts and the real-time test always use raw results.

### Update speed vs. accuracy

The 44 recorded sessions were streamed through the real models (`progress.md`, *Model update-speed evaluation*):

- Results update every 2 s, 1 s or 0.5 s.
- A new activity is shown about 4 s after it starts (median, all steps), because HAR needs most of its 4 s window filled with the new activity.
- Detection in about 2 s would need a 2 s window. That means retraining, with lower accuracy: in our CV, the Social 4 s window lost 4.5 points balanced accuracy, and coughing dropped from 82.4 % to 75.2 %.

## Live recognition models

| Task | Bundled asset (`assets/models/`) | Architecture | Window | Classes |
|---|---|---|---|---|
| HAR | `harry_har_cnn.tflite` | multi-branch CNN (gravity + dilated CNN + spectral) | 50 samples (4 s) | 11 |
| Social | `harry_social_rnn.tflite` | gravity-split front end + conv stem + GRU + spectral | 100 samples (8 s) | 4 |

- **Training:** both were pre-trained on datasetJan2026 and fine-tuned on our real RESpeck recordings (`model_harry/run_pipeline.py`; scores in `model_harry/models/README.md`).
- **Metadata:**
  - each `.tflite` has a matching `*_meta.json` (window, training step, class order) and `*_example.json` (parity-check window) next to it;
  - the `.keras` training copies are in `model/` and are not bundled.

## Measuring performance for the report

| Metric | Android | iOS |
|---|---|---|
| CPU | `getrusage(RUSAGE_SELF)` through `dart:ffi` (whole app process, all threads); fallback `/proc/self/stat` | `getrusage(RUSAGE_SELF)` through `dart:ffi` |
| Memory | `ProcessInfo.currentRss` (resident memory) | `ProcessInfo.currentRss` |
| Phone battery / power | `BatteryManager` via the `pdiot/power` channel (`MainActivity.kt`): level, charging, current (µA), voltage (mV). Power = current × voltage for the whole phone, screen included | `UIDevice` via `pdiot/power` (`AppDelegate.swift`): level and charging only. iOS has no public current API, so use Xcode Instruments → Energy Log |
| RESpeck battery | sent in every packet (v6 firmware) | same |
| Model response | time inside each TFLite call; interval between results | same |
| Latency to show an activity | *Tools → Real-time test*: time from trial start to the first correct result | same |
| Storage | file sizes in the user's folder (DB, `raw/`, `exports/`, logs) | same |

### For the report

1. Turn on *Record performance log*.
2. Connect the sensor and use the app normally, or run trials, for a fixed time.
3. Use the CSV in `<user>/performance/` for the graphs.
4. State:
   - the phone model and OS;
   - how long the app ran;
   - that inference runs on the device.
5. Cross-check against Android Studio Profiler or Xcode Instruments.

## Code layout

| Path | Role |
|---|---|
| `lib/main.dart` | Start-up: settings, storage, last user, model loading, debug-only parity check, app wiring, theme. |
| `lib/app_shell.dart` | Bottom bar and the five tabs (IndexedStack, rebuilt on user change). |
| `lib/home.dart`, `lib/tools_page.dart`, `lib/performance.dart`, `lib/history.dart`, `lib/chart_page.dart` | The tabs. |
| `lib/settings.dart`, `lib/user_page.dart`, `lib/scanning.dart` | Settings, user, and the QR scanner page. |
| `lib/ble.dart` | RESpeck scanning, connection and packet decoding. Feeds both classifiers, the raw recorder and the metrics. |
| `lib/har.dart` / `lib/social.dart` | TFLite classifiers with sliding windows (adjustable step). |
| `lib/services/` | Building blocks below the screens. |
| `lib/widgets/` | Shared card / app-bar widgets, `DayTimeline`, `LiveLineChart`. |
| `lib/activity_catalog.dart` | Readable names, icons, colours and coursework groups for every class. |
| `test/` | Unit and widget tests (`flutter test`). |

What `lib/services/` contains:

- `user_session` — users and folders;
- `sensor_controller` — shared live sensor state;
- `raw_recorder` — raw CSVs;
- `app_settings` — update interval and smoothing;
- `prediction_repository` / `prediction_history_writer` — SQLite;
- `timeline` — day bins;
- `perf_sampler` / `device_stats` — CPU, memory, battery, storage;
- `app_metrics` — model and stream counters;
- `evaluation` — real-time test scoring;
- the Social stream processor, live feed and smoother.

## Swapping in a new model

1. Export `<name>.tflite`, `<name>_meta.json` and `<name>_example.json` from the training notebook. Keep the same `[1, window, 3]` raw-g float32 input and softmax output.
2. Copy them into `assets/models/` and list them under `assets:` in `pubspec.yaml`.
3. Point `harModelAsset` / `harMetaAsset` in `lib/har.dart` at them. For the Social model, use `socialModelAsset` / `socialMetaAsset` in `lib/social.dart`; its metadata check in `_validateMetadata` expects the current contract.
4. Do a full rebuild.
5. In a debug build, the console prints an `EXAMPLE app:` line comparing the app's prediction for the example window with the notebook's. The class and probability should match.

## Build / run

```
flutter pub get
flutter test
flutter run            # or: flutter run --profile for measurements
```

- Android 10+ or iOS 16+ is needed for Bluetooth.
- **iOS:** needs CocoaPods (`pod install` in `ios/`) and your own signing team in Xcode.
- **Smaller release APK:** `flutter build apk --release --split-per-abi`.

## Using the app

1. Tap the round user button at the top left, type a name, then **Create user**.
2. On **Home**, press **Scan QR code** and scan the label on the back of the RESpeck. You can also press **Enter ID**.
3. Wake the RESpeck by shaking it (green light), then press **Connect**.
4. The first activity result appears about 4 s later and the first social result about 8 s later. After that, results arrive every update interval.
5. For the report:
   - run trials in **Tools** (raw data is saved automatically);
   - record a performance log in **Performance**;
   - export the day from **Chart**.

**Uninstalling the app deletes the PDIoT folder on most phones.** Copy `<storage>/PDIoT/` off the phone first.
