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
| **Home** | **Sensor card.** If no sensor is paired: *Scan QR code* or *Enter ID*. Once paired: *Connect* / *Disconnect*, the RESpeck battery, live acceleration, and *Change* / *Forget sensor*.<br>**Detected activity:** icon, name, confidence and smoothing note.<br>**Social signal:** class, confidence and all four probabilities while you are still; *Paused while you are moving* (with the detected activity) while walking, on stairs, running, shuffling or moving about.<br>**Today:** monitored time, active time, times coughed and the day timeline. |
| **Tools** | **Real-time test:** timed, scored trials per participant, activity and social signal, with a warm-up skip, the latency to the first correct result and to the right class being *shown* (after smoothing); social is fixed to *not assessed* for moving activities; **Latency test:** the phone cues a change (vibration + beep) and times until the new class is first correct, shown and steady, with CSV export; a per-class / per-group accuracy table; CSV export. Each trial also saves its **raw sensor CSV** to `<user>/raw/`.<br>**Free recording:** raw data with labels and no time limit, also to `raw/`. |
| **Performance** | **Live moving graphs (last 5 min):** CPU, memory, phone battery, phone power (Android), RESpeck battery, HAR / Social inference time, sensor sample rate, storage.<br>**Figures:** response time, sensor stream, power and storage breakdown.<br>**Record performance log:** a 1 s CSV saved to `<user>/performance/` (with streaming state, shown activity and social status per second) plus a `.conditions.json` with platform, OS, app version, settings, models and duration. |
| **History** | The activity **and** the social signal of the same moment side by side, for any day.<br>**Episodes:** runs where neither label changed, with start–end, duration and mean confidence.<br>**Every result:** each activity result with its paired social result (±¾ of the update interval), paginated. |
| **Chart** | The **day timeline**: a strip coloured by activity, a social-signal strip, tap for details, and *Monitored hours* or *24 h*. Below it: time per activity, static vs active time, times coughed, time per social signal, the share of the day, and a **7-day trend**. Export the day as CSV, or delete it. |
| **Settings** (gear) | **Update interval** (2 s / 1 s / 0.5 s), activity smoothing, **reminders** (move after 30–90 min of sitting/standing; wake-up alarm while still lying after a set time), installed models, the user's folder, version. |

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
| 1 s | 12 samples | |
| 0.5 s | 6 samples | default |

The windows and models stay the same, so per-window accuracy does not change.

### Durations

- Each saved result stores the interval it stands for (`interval_ms`, schema v2).
- Durations are sums of those intervals, so they stay correct when the setting changes.
- Rows from before v2 count as 2 s.

### Times coughed and smoothing

- **Times coughed** counts each time coughing is detected: `coughing` results less than 5 s apart are one time (so one misread window in between does not split it), a lone result is ignored, and a longer gap (or a disconnect) starts a new time.
- **Smoothing** (on by default) only changes what Home shows: the most common of the last 3 HAR results (every result counts, so it spans 3 update intervals). History, charts and the real-time test always use raw results.

### Reminders

- **Move reminder:** sitting/standing for N minutes (default 60) within the last N + 10 minutes → "walk for 5 minutes". Repeats every 30 min; 5 min of movement restarts the count; lying down is not counted.
- **Wake-up alarm:** after the set time, while you are still lying down, a reminder every 5 min until you get up.
- Reminders only work while the app is open with the RESpeck connected: the app does not run in the background (no data, history or reminders with the screen off). Notification permission is asked on the first connect.

### Social signals only while still

Social signals are defined for stationary activities only (CW3 task 2, course feedback). When the shown activity is dynamic (walking, shuffle walking, stairs, running, miscellaneous movement), the social model is paused: nothing is classified, shown, saved to history or sent to the real-time test. Samples keep filling its window, so the first result after you stop arrives straight away. The shown (smoothed) activity drives the pause, so one misread window during a cough does not hide the cough.

### Update speed vs. accuracy

See `progress.md`, *Task 7*. In short:
- **The RESpeck sends 32 samples (2.56 s) per BLE packet**, so the app can only change the screen once per packet, on average 1.3 s after something happens (up to 2.56 s).
- **Activity:** shown about 4 s after a change (simulated mean 3.8–4.3 s on both members' recordings, at 0.5 s with smoothing). Before the 2026-11-09 fix the smoother only saw one result per packet, which added about 2 s.
- **Social:** about 6–6.5 s on average (p90 ~9–10 s), because the 8 s window must be about half full of the new signal. Faster social needs a shorter or recency-trained social model; `model_harry/social_window_study.py` measures what that costs in CV accuracy.

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
| Latency to show an activity | *Tools → Real-time test*: time from trial start to the first correct result and until the class is shown (CSV: `har_latency_s`, `har_shown_latency_s`, `social_latency_s`) | same |
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
