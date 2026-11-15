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
| **Home** | **Sensor card.** If no sensor is paired: *Scan QR code* or *Enter ID*. Once paired: *Connect* / *Disconnect*, the RESpeck battery, live acceleration, and *Change* / *Forget sensor*.<br>**Detected activity:** icon, name, confidence and a probability bar for every class (the latest model result).<br>**Social signal:** class, confidence and all four probabilities while you are still; *Paused while you are moving* (with the detected activity) while walking, on stairs, running, shuffling or moving about.<br>**Today:** monitored time, active time, coughing episodes and the day timeline. |
| **Tools** | One card per tool; each opens on its own page.<br>**Real-time test:** timed, scored trials per participant, activity and social signal, with a warm-up skip and the latency to the first correct result and to the right class being *shown*; social is fixed to *not assessed* for moving activities; a per-class / per-group accuracy table with the classes tested per group (a tested class with no result counts as 0 %); **Open dashboard:** every dynamic activity and every static activity + social signal pair, per participant; CSV export. Each trial also saves its **raw sensor CSV** to `<user>/raw/`. You cannot leave the page while a trial runs.<br>**Latency test:** once you are steady, press the button and change; it times from the press until the new class is first correct, shown and steady, with CSV export.<br>**Sensor-to-app delay test:** the time from the RESpeck finishing a packet (measuring its last sample) to that packet arriving in the app: waiting for a Bluetooth slot, transmission and the phone's Bluetooth stack, plus any small processing inside the RESpeck (the 2.56 s packet filling comes before it and is not included). Hold the RESpeck flat against the back of the phone and flick both together when prompted; the phone's own accelerometer times each flick, and the delay at which the RESpeck's copy lines up best is the result. Median, mean, range and SD; CSV export of every flick and sample.<br>**Free recording:** raw data with labels and no time limit, also to `raw/`; keeps recording if you leave the page. |
| **Performance** | **Live moving graphs (last 5 min):** CPU and memory of the app, HAR / Social inference time, packet interval.<br>**Response time:** one model at a time (drop-down: activity or social signal): file, architecture, classes, window, update interval, training data, official 10-fold CV, the mean and median time to show a change from your latency tests, and inference time on this phone.<br>**Figures:** sensor stream and storage breakdown. Power is not shown: measure it with Xcode Instruments or Android Studio.<br>**Record performance log:** a 1 s CSV saved to `<user>/performance/` (with streaming state, shown activity and social status per second) plus a `.conditions.json` with platform, OS, app version, settings, models and duration. |
| **History** | The activity **and** the social signal of the same moment side by side, for any day.<br>**Episodes:** runs where neither label changed, with start–end, duration and mean confidence.<br>**Every result:** each activity result with its paired social result (±¾ of the update interval), paginated. |
| **Chart** | The **day timeline**: a strip coloured by activity, a social-signal strip, tap for details, and *Monitored hours* or *24 h*. Below it: time per activity, static vs active time, coughing episodes, time per social signal, the share of the day, and the **last 7 days** with a drop-down: static/dynamic time and coughing episodes per day, or each day's timeline. Export the day as CSV, or delete it. |
| **Settings** (gear) | **Reminders** (move after 30–90 min of sitting/standing; wake-up alarm while still lying after a set time) and the user's folder. The models are described on Performance › Response time. |

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
    latency_tests.json      latency test changes
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
                            ├──► HarClassifier (har.dart)        50-sample window ─► result every 0.5 s
                            ├──► SocialSampleProcessor ─► SocialClassifier (social.dart)  75-sample window ─► result every 0.5 s
                            └──► RawRecorder ─► <user>/raw/*.csv (only while recording)
results ─► PredictionHistoryWriter ─► <user>/history.db ─► History / Chart / Home timeline
        ─► LivePredictionFeed (real-time test)
PerfSampler (1 s) ─► CPU, memory, model timing, storage ─► Performance tab (+ CSV log, which also keeps battery readings)
```

### Model input and output

- Both models take a `[1, window, 3]` window of raw acceleration in g; normalisation happens inside the model.
- Both output softmax probabilities.
- HAR uses a 4 s window (50 samples). Social uses a 6 s window (75 samples), long enough to contain whole breaths.
- Both models were trained to favour the most recent seconds of their window, so they react to a change sooner.
- **Lost packets:** each packet carries a sequence number. If one or more packets are missing, both windows are emptied before the new samples go in, so no window joins data from either side of the gap.
- Inference runs on the device, so there is no network latency and no data leaves the phone.

### Update interval

Both models give a new result every **0.5 s** (6 samples; 0.48 s exactly). This is fixed; there is no setting. The window each result looks at (4 s / 6 s) does not depend on it, so accuracy per result is the same as with the 2 s step used in training. The RESpeck sends 32 samples (2.56 s) per packet and all of a packet's results are made when it arrives, so the screen changes once per packet; the small step only makes the last result of each packet as fresh as possible (its window ends at most 0.4 s before the newest sample, instead of up to 1.9 s with a 2 s step). It costs about 2 + 2 model runs per second, a few ms of CPU.

### Durations

- Each saved result stores the interval it stands for (`interval_ms`, schema v2).
- Durations are sums of those intervals, so they stay correct when the setting changes. They are estimates: time lost to Bluetooth gaps (and the window refilling after one) is not counted. The app says so under the charts.
- Rows from before v2 count as 2 s.

### Coughing episodes

- A **coughing episode** is counted once coughing adds up to at least 4 s within any 5 s (each result counts its update interval). It lasts until 5 s pass without a coughing result, so one episode holds every cough of a coughing fit, and a single cough or stray result is not an episode.
- There is **no smoothing**: the activity card shows each model result as it is.

### Reminders

- **Move reminder:** sitting/standing for N minutes (default 60) within the last N + 10 minutes → "walk for 5 minutes". Repeats every 30 min; 5 min of movement restarts the count; lying down is not counted.
- **Wake-up alarm:** after the set time, while you are still lying down, a reminder every 5 min until you get up.
- While the RESpeck is connected the app keeps running in the background and with the screen off: Android runs a foreground service (ongoing "PDIoT is monitoring" notification), iOS uses the `bluetooth-central` background mode. Data, history and reminders continue; closing the app from the app switcher stops it. Notification permission is asked on the first connect.

### Social signals only while still

Social signals are defined for stationary activities only (CW3 task 2, course feedback). When the shown activity is dynamic (walking, shuffle walking, stairs, running, miscellaneous movement), the social model is paused: nothing is classified, shown, saved to history or sent to the real-time test. Samples keep filling its window, so the first result after you stop arrives straight away (that first window still holds some movement). The shown activity drives the pause.

### Update speed vs. accuracy

See `progress.md`, *Task 7*. In short:
- **The RESpeck sends 32 samples (2.56 s) per BLE packet**, so the app can only change the screen once per packet, on average 1.3 s after something happens (up to 2.56 s).
- **Activity:** a change is shown after a median of about 3.0 s (replaying recordings through the app logic, pipeline v3). Measure it on the phone with *Tools → Latency test*.
- **Social:** a median of about 4.3 s (pipeline v4 replay), for the 6 s window trained to favour the most recent seconds.

## Live recognition models

| Task | Bundled asset (`assets/models/`) | Architecture | Window | Classes |
|---|---|---|---|---|
| HAR | `harry_har_cnn.tflite` | multi-branch CNN (gravity + dilated CNN + spectral), trained to favour the most recent seconds | 50 samples (4 s) | 11 |
| Social | `harry_social_cnn.tflite` | multi-branch CNN, trained to favour the most recent seconds | 75 samples (6 s) | 4 |

- **Training:** both were trained on datasetJan2026 and both group members' recordings, mixed (IoT-Models repo: HAR from `model_harry/pipeline_v3`, social from `model_harry/pipeline_v4`, candidate `cnn_w75rec`).
- **Official 10-fold CV:** HAR static 99.4 %, dynamic 89.5 %; social breathing 89.3 %, coughing 78.0 %, hyperventilation 79.2 %, other 76.6 % (social CV trained on datasetJan2026 only). Details: `assets/models/INSTALL.md`.
- **Metadata:**
  - each `.tflite` has a matching `*_meta.json` (window, training step, class order) and `*_example.json` (parity-check window) next to it;
  - the `.keras` training copies are in `model/` and are not bundled.

## Measuring performance for the report

| Metric | Android | iOS |
|---|---|---|
| CPU | `getrusage(RUSAGE_SELF)` through `dart:ffi` (whole app process, all threads); fallback `/proc/self/stat` | `getrusage(RUSAGE_SELF)` through `dart:ffi` |
| Memory | total PSS (`Debug.MemoryInfo`, as `adb shell dumpsys meminfo`) + `ProcessInfo.currentRss` | `phys_footprint` (what Xcode's memory gauge shows) + `ProcessInfo.currentRss` |
| Power | not shown in the app; Android Studio Energy Profiler / `dumpsys batterystats`. The CSV log keeps the whole-phone battery current and voltage | not shown in the app; Xcode Instruments → **Power Profiler**, Settings › Battery |
| Model response | time inside each TFLite call (HAR and social measured the same way) | same |
| Latency to show a change | *Tools → Latency test*: from the button press to the new class first correct, shown and steady. *Tools → Real-time test*: from trial start to the first correct / shown result | same |
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
| `lib/realtime_test_page.dart`, `lib/realtime_dashboard_page.dart`, `lib/latency_page.dart`, `lib/ble_delay_page.dart`, `lib/free_recording_page.dart` | The tools (each opened from Tools) and the real-time accuracy dashboard. |
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
- `app_settings` — the fixed update interval (0.5 s) and reminders;
- `prediction_repository` / `prediction_history_writer` — SQLite;
- `timeline` — day bins;
- `perf_sampler` / `device_stats` — CPU, memory, battery (CSV log only), storage;
- `app_metrics` — model and stream counters;
- `evaluation` — real-time test scoring;
- the Social stream processor and live feed.

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
4. The first activity result appears about 5 s later and the first social result about 8 s later (each window must fill, then the next 2.56 s packet arrives). After that, a new result is made every 0.5 s and the screen changes once per RESpeck packet (2.56 s).
5. For the report:
   - run trials in **Tools** (raw data is saved automatically);
   - record a performance log in **Performance**;
   - export the day from **Chart**.

**Uninstalling the app deletes the PDIoT folder on most phones.** Copy `<storage>/PDIoT/` off the phone first.
