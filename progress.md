# UI enhancement v2.0: progress tracker

Branch: `ui-enhancement-v2.0-harry` (from `main` @ `c25c030`, after PR #1).

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[-]` dropped (reason given)

## Decisions (from Harry, 2026-11-03)

| Topic | Decision |
|---|---|
| Faster results | Make the update interval a **setting**: 2 s / 1 s / 0.5 s (step 25 / 12 / 6 samples). The default is 1 s. The model windows stay as they are (HAR 4 s, Social 8 s). |
| Bottom bar | **Tools · Performance · (Home) · History · Chart**. Home is the large round button in the middle. |
| Settings | Removed from the bottom bar. It becomes a **gear icon at the top left, next to the user button**. |
| User button | A round avatar at the **top left** of every tab. Tapping it opens the User page (create / log in / log out). |
| Replay | **Removed.** The demo's "recorded data" part will be a pre-recorded screen video. |

## Model update-speed evaluation (before task 1)

I streamed the 44 bundled recordings through the real TFLite models (LiteRT), using 120 activity changes and 216 social-signal changes. The script is `scratchpad/latency/sim.py`. **Latency** is the time from the change until the display shows the new class and keeps it for 4 s.

| Update step | Update interval | HAR latency, median / p90 | Social latency, median / p90 | Inferences per second |
|---|---|---|---|---|
| 25 (now) | 2.0 s | 4.2 / 5.5 s | 6.2 / 8.9 s | 0.5 + 0.5 |
| 12 | 0.96 s | 4.0 / 4.6 s | 5.6 / 8.2 s | 1 + 1 |
| 6 | 0.48 s | 3.8 / 4.2 s | 5.5 / 8.0 s | 2 + 2 |

- **Smoothing** (a majority vote over about 6 s) adds about 1.5 s to HAR latency. With a fixed vote of the last 3 results, a shorter step also shortens this lag: 3 results span 3 s at 1 s updates.
- **Inference cost:** about 0.04 ms (HAR) and 0.11 ms (Social) per call on the Mac. Expect about 1–3 ms on a phone, so even 0.5 s updates use less than 1 % CPU.
- **The floor is the window length.** HAR needs most of its 4 s window filled with the new activity. Detection in about 2 s would need a 2 s window, which means retraining.
- **Shorter Social windows cost accuracy.** The earlier CV in `model_harry/RESULTS.md` gives:
  - 4 s window: 79.0 % balanced;
  - 8 s window: 83.5 % balanced;
  - coughing drops from 82.4 to 75.2 %, right at the 75 % mark.
- **Decision:** keep the windows and make the step configurable.
- **Caveat:** the bundled recordings were also used in training, so accuracy and flicker here are optimistic. The latency mechanics are still valid.

---

## Task 0: Update interval setting — done

- [x] 0.1 `SampleWindow.step` is mutable (validated ≥ 1), with `SocialClassifier.step`. `lib/har.dart`, `lib/social.dart`.
- [x] 0.2 `appSettings.stepSamples` (prefs `step_samples`, default 12). `MyApp` applies it to both models at start-up and on change. `lib/services/app_settings.dart`, `lib/main.dart`.
- [x] 0.3 Durations:
  - [x] each record stores `interval_ms` (schema v2 migration: `ALTER TABLE ADD COLUMN`);
  - [x] `durationByLabel` sums the intervals, and NULL rows count as 2000 ms;
  - [x] the Chart / daily summary uses durations.
- [x] 0.4 Settings: a 2 s / 1 s / 0.5 s segmented control, with an explanation.
- [x] 0.5 Texts use the live interval: the Home activity card, Settings (models, smoothing span) and Performance (response time). The Summary "every 2 s" text was removed.
- [x] 0.6 Tests:
  - step change (`widget_test`);
  - v2 interval, durations, timeline bins, v1 → v2 upgrade (`prediction_repository_test`);
  - the writer stamps the interval (`prediction_history_writer_test`).

## Task 1: Sensor pairing on the Home sensor card — done

- [x] 1.1 Not paired: "Pair your RESpeck", with **Scan QR code** (the existing scanner page) and **Enter ID** (a dialog widget that owns its controller; a bug found by the test was fixed).
- [x] 1.2 Paired: the ID, **Connect** / **Disconnect**, and a ⋮ menu with *Change sensor* and *Forget sensor*. Pairing while connected disconnects first.
- [x] 1.3 The pairing is in the user's `profile.json`, loaded into `respeckUUID` at log-in.
- [x] 1.4 The pairing card is gone from Settings. The subject ID is replaced by the user name (file names, trial participant).
- [x] 1.5 Logged out: the sensor card shows "Log in to use a sensor", and a Welcome card links to the User page.
- [x] 1.6 Tests: `app_flow_test` "Home: pair with an ID, then Connect; forget returns to pairing".

## Task 2: Remove replay — done

- [x] 2.1 Deleted `lib/services/replay.dart`, `test/replay_test.dart` and `assets/demo/` (44 CSVs), and the pubspec entry.
- [x] 2.2 Removed `replayActive`, the replay card and callbacks, and the guards in the real-time test.
- [x] 2.3 `PredictionSource` is `{live}` only. The schema v1 CHECK is unchanged.
- [x] 2.4 The History source text and the README demo section are gone.

## Task 3: Performance tab — done

- [x] 3.1 `PerfSampler`: 1 s timer started by `MyApp`, a 300-sample ring buffer. `lib/services/perf_sampler.dart`.
- [x] 3.2 **CPU:** `getrusage(RUSAGE_SELF)` via `dart:ffi` (iOS: `DynamicLibrary.process()`, Android: `libc.so`), with `/proc/self/stat` as the fallback. Shown as % of one core. `lib/services/device_stats.dart`.
- [x] 3.3 **Memory:** `ProcessInfo.currentRss`.
- [x] 3.4 **Phone battery:** channel `pdiot/power`.
  - Android, `MainActivity.kt`: level, charging, current µA, voltage mV, so mW.
  - iOS, `AppDelegate.swift`: level and charging.
  - Drain in %/h, shown after 10 min and a 1 % drop.
- [x] 3.5 **RESpeck battery:** graph and drain.
- [x] 3.6 **Model response:** inference-time graph (HAR + Social), last / mean / max, result intervals, and an expected-latency explanation.
- [x] 3.7 **Storage:** user-folder breakdown (DB, raw files, exports, logs, total) and the expected raw MB per hour.
- [x] 3.8 `LiveLineChart`: CustomPainter in a dark "gaming overlay" style, with glow line, filled area, current value, min / avg / max. `lib/widgets/live_chart.dart`.
- [x] 3.9 Graphs: CPU, memory, phone battery, phone power (hidden on iOS), RESpeck battery, inference, sample rate, storage.
- [x] 3.10 **Record performance log:** a switch that writes a 1 s CSV to `<user>/performance/perf_<time>.csv`.
- [x] 3.11 Kept: the stream, packets and lost packets, intervals, writer health, and the reset button (counters and graphs).
- [x] 3.12 "How each number is measured" on the page and an Android / iOS table in the README.
- [x] 3.13 Tests (`perf_test`):
  - `/proc` parser;
  - a real `getrusage` reading on macOS (same Darwin layout as iOS);
  - power maths;
  - the sampler with a mocked channel, plus the log;
  - chart and page rendering.

## Task 4: Day timeline — done

- [x] 4.1 `PredictionRepository.timelineBins` (one SQL GROUP BY) and `timeRange`.
- [x] 4.2 `DayTimeline`:
  - an activity strip shaded by coverage, a social strip faded while moving, and hour ticks;
  - tap or drag for details, and a legend;
  - the range is *Monitored hours* or *24 h*, with the bin size picked automatically (≤ 144 bins).
- [x] 4.3 Home "Today" card: monitored, active, cough bouts, the compact timeline and *Open Chart*. Refreshes every 20 s while Home is visible and when Home is shown.
- [x] 4.4 Chart tab: a timeline card with the range toggle, above the summary cards.
- [x] 4.5 Tests (`app_flow_test`): bin sizes, loading from a real DB, and the widget's tap details.

## Task 5: Bottom navigation and pages — done

- [x] 5.1 `AppShell`:
  - a BottomAppBar with a notch, and a 72 px round Home FAB in the centre;
  - Tools · Performance · Home · History · Chart;
  - an IndexedStack keyed by user name;
  - tabs reload when shown (`shellTab`).
- [x] 5.2 `TabLeading` (avatar + gear) on every tab via `tabAppBar`.
- [x] 5.3 `SensorController` holds the connection and display state. `ble.dart` reports to it instead of a widget State. `HomePage` is a tab.
- [x] 5.4 **(a) Home:** sensor, activity, social and Today.
- [x] 5.5 **(b) Tools:**
  - the real-time test, with a *Save raw sensor data* switch (on): `PDIoT_<user>_<activity>_<social>_<time>_<respeck>.csv` in `raw/`, `rawFile` stored with the trial and in the CSV export, the file deleted if the trial is cancelled;
  - a **Free recording** card (the old Data collection) into `raw/`.
- [x] 5.6 **(c) Chart:** the day timeline plus the full daily summary and 7-day trend, with export to `exports/` and delete.
- [x] 5.7 **(d) History:** both views and a day navigator.
  - Pairing: each activity result is joined with the social result nearest in time (within ¾ of its interval, at least 300 ms).
  - **Episodes:** runs where neither label changes; a gap of more than 6 s also splits.
  - **Every result:** paginated.
  - Social results while moving are shown faded.
- [x] 5.8 **(e) Settings:** update interval, smoothing, models, user folder, about. No pairing.
- [x] 5.9 Tab actions:
  - History: refresh;
  - Chart: export, delete;
  - Tools: export, delete all;
  - Performance: reset.
- [x] 5.10 Tests:
  - `widget_test` shell: tab order, Home in the middle, user and gear at top left, Settings and User open;
  - social UI tests updated for `HomePage` and tab navigation.

## Task 6: Users and per-user storage — done

- [x] 6.1 `UserSession`: root `<storage>/PDIoT/`, user folder `<root>/<name>/`.
- [x] 6.2 **Create:** validated name, unique ignoring case (folder check); creates `raw/` and `profile.json`; then logs in.
- [x] 6.3 **Log in:** the folder must exist, otherwise "No user … create the user first" and the page suggests *Create user*. The last user is remembered (prefs `current_user`).
- [x] 6.4 `onBeforeSwitch`: stop the recorder, disconnect, stop the perf log, `writer.reopen()`. The shell rebuilds by key.
- [x] 6.5 Per-user `history.db`, `realtime_trials.json`, `raw/`, `exports/`, `performance/` and `profile.json`.
- [x] 6.6 `PredictionHistoryWriter.reopen()`. Results are dropped and counted if nobody is logged in; you can't connect without a user anyway.
- [x] 6.7 User page: big avatar, name, paired sensor, folder, Log out, and the Log in / Create user field with inline errors.
- [x] 6.8 Logged out: Tools, History and Chart show a "Log in…" prompt. Home shows the Welcome card, and the sensor card is locked.
- [x] 6.9 Tests (`user_session_test`):
  - names, case-insensitive uniqueness, login errors, hand-made folders;
  - per-user pairing, the switch hook, DB isolation between two users;
  - the User page flow.

## Wrap-up — done

- [x] W.1 Old tests rewritten or adjusted. Tests that pin the trained 25-sample step set `appSettings.stepSamples.value = 25`.
- [x] W.2 `flutter analyze`: no errors or warnings (19 older style infos in `ble.dart`, `main.dart` and `scanning.dart`). `flutter test`: **166 pass, 1 skipped** (native TFLite is not available on the Mac).
- [x] W.3 Screenshot check of every tab at iPhone size with sample data. This fixed chart text rendering, a title wrap, footnote truncation, noisy early battery drain, and threading the session through the top-bar buttons.
- [x] W.4 `flutter build ios --no-codesign --debug` succeeded (Swift channel + FFI). The Android Kotlin channel was reviewed by hand, but **not compiled** because there's no Android SDK here.
- [x] W.5 README rewritten: navigation, users and storage, update speed, measurement table, code layout.

## Task 7: Social only while still + faster display (2026-11-09) — done

### Why the screen reacts slowly (measured)
Replay of the app's exact live logic on **both members' recordings** with the shipped TFLite models: 32-sample packets, the step, smoothing, the pause. There were 120 activity changes, 120 same-posture social changes and 80 walk → still changes, each at 4 packet phases. Latency = time from the change until the screen shows the new class and keeps it for 4 s. Values are s2503795 / s2952925. Script: `IoT/model_harry/app_latency_sim.py` (`python app_latency_sim.py app` → `results/app_latency_app.csv`).

| | before (1 s, smoother fed once per packet) | after (0.5 s, every result smoothed) | 0.5 s, smoothing off |
|---|---|---|---|
| Activity: median | 6.1 / 6.1 s | 4.5 / 3.8 s | 4.2 / 3.5 s |
| Activity: mean | 6.5 / 5.8 s | 4.3 / 3.8 s | 4.0 / 3.4 s |
| Activity: p90 | 7.4 / 7.4 s | 4.9 / 4.8 s | 4.8 / 4.8 s |
| Social (same posture): mean | 6.5 / 6.2 s | 6.3 / 6.2 s | – |
| Social (same posture): p90 | 8.7 / 10.1 s | 8.7 / 10.8 s | – |
| Social after walk → still (with the pause): mean | – | 7.8 / 10.4 s | – |

- **The RESpeck packet sets a floor.** One packet carries 32 samples = 2.56 s, so the screen can only change once per packet, on average 1.3 s after the event (up to 2.56 s).
- **The smoothing bug cost about 2 s.** The smoother received only the last result of each packet, so "majority of 3" spanned 3 packets (7.7 s). Now every result counts: 3 × 0.5 s.
- **Social is limited by the 8 s window.** The model changes its answer once about half the window holds the new signal (~4 s), plus the packet wait. App-side changes cannot get it under ~5–6 s.
  - Tiling the last 4–5 s to fill the window was tried. It saves ~2 s at the median, but the steady accuracy on the teammate fell (77 → 71 %) and p90 rose. It was rejected.
  - Faster social needs a shorter or recency-trained model: see `model_harry/social_window_study.py` (official folds, accuracy vs latency).
  - A normal breath lasts ~4 s, so "breathing normally" in under 4 s is close to impossible to detect from breathing motion.

### Changes
- [x] 7.1 `SocialSampleProcessor.setPaused` and status `pausedMoving`.
  - While the **shown** activity is dynamic, samples are only buffered (`SocialClassifier.addSample(infer: false)`, `SampleWindow.push`).
  - No inference runs and nothing is shown, saved or fed to the real-time test. The last result is cleared.
  - On resume, the next sample is classified at once.
- [x] 7.2 `SensorController.addHarResult`: called for every raw HAR result (from `connect`'s `onPrediction`). It feeds the smoother, updates `harShown` and sets the social pause. `updateFromPacket(prediction:)` remains only for callers without that callback, such as tests.
- [x] 7.3 Default update interval: 0.5 s (`defaultStepSamples = 6`). A phone that already saved 1 s in Settings keeps it until it is changed there.
- [x] 7.4 Home social card: "Paused while you are moving" with the activity icon and "resume as soon as you sit, stand or lie still". The old "may be less reliable" warning is gone.
- [x] 7.5 Real-time test:
  - each trial now also stores `harShownLatency` (time until Home *showed* the true activity); the CSVs gain `har_shown_latency_s` / `mean_shown_latency_s`, and the table gains a *Shown* column;
  - a dynamic true activity forces social to *Not assessed*.
- [x] 7.6 Performance log:
  - new columns `streaming, activity_shown, social_status`;
  - `<log>.conditions.json` records platform, OS, cores, CPU source, app version, interval, smoothing, models, windows, the pause rule, RESpeck, user, start, end and duration. The phone model must be noted by hand.
- [x] 7.7 Texts: Settings (interval and packets, smoothing span to 0.1 s, social pause), Performance (latency breakdown), README.
- [x] 7.8 Tests: `social_ui_test` (pause → resume, immediate inference after the pause); `responsiveness_test` (every result smoothed, smoothing off, shown event, trial JSON/CSV with shown latency, old trials still load); `perf_test` (column count, conditions file). `flutter analyze`: no errors or warnings. `flutter test`: **172 pass, 1 skipped**.

### Still to check on a real phone
- [ ] Walk → sit: the social card shows *Paused*, then a result within a packet of the activity turning static.
- [ ] Time a few changes by hand against the real-time test's *Shown* latency.

## Task 8: times coughed, on-phone latency test, reminders (2026-11-09) — done

Decisions (Harry):
- coughing results less than 5 s apart are one time, and a lone result is not counted;
- both phones;
- move reminder for sit/stand only;
- lying down drives a wake-up alarm;
- latency is measured on the phone;
- an activity window study runs as well.

- [x] 8.1 **Times coughed.** `countLabelEpisodes(maxGap 5 s, minResults 2)`.
  - One misread window in between no longer splits a cough, a lone stray result is ignored, and a longer gap or a disconnect starts a new time.
  - UI: "times coughed" (Home Today card, Chart), "Coughed N times", "c = times coughed" in the 7-day trend.
- [x] 8.2 **Latency test** (Tools → *Open latency test*, `lib/latency_page.dart`, `lib/services/latency_test.dart`).
  - Flow: pick Activity or Social, FROM → TO, and 3/5/10 repeats. Do FROM until the screen shows it steadily for 3 s. After a random 2–5 s the phone vibrates and beeps and shows "NOW: TO".
  - Each change times, from the cue: **first correct** raw result, **shown** (what Home displays, after smoothing) and **steady** (shown and kept for 3 s). There is a 30 s timeout, and a FROM that was never reached is flagged.
  - Results: a table per change, saved to `<user>/latency_tests.json`, with CSV export `PDIoT_latency_changes_*.csv` and `PDIoT_latency_summary_*.csv` (mean / median per change and per task).
  - The times include the participant's reaction to the cue (~0.3 s) and the packet wait.
- [x] 8.3 **Reminders** (`lib/services/reminders.dart`, Settings → *Reminders*).
  - *Move reminder* (default on): sitting or standing for 30/45/**60**/90 min within the last N + 10 min. It repeats every 30 min, and 5 min of movement within 10 min restarts the count. Lying is not counted.
  - *Wake-up alarm* (default off, time picker): after the alarm time, if you are lying for most of the last 2 min, it notifies every 5 min until you have been up for most of 2 min. It is then done for the day, or 6 h after the alarm time.
- [x] 8.4 **Notifications** (`lib/services/notifications.dart`, `flutter_local_notifications` **22.3.3**). v23 needs AGP 9.1 / compileSdk 37, more than this project has.
  - Permission is asked on the first connect.
  - **No background running** (removed at Harry's request): reminders only fire while the app is open with the RESpeck connected.
- [x] 8.5 Native changes:
  - `ios/Runner/AppDelegate.swift`: the notification-centre delegate, so reminders show while the app is open;
  - `android/app/build.gradle`: core library desugaring `desugar_jdk_libs:2.1.4`, Java/Kotlin target 17, multidex (required by the plugin).
  - The iOS background mode and the Android foreground service were added, then removed.
- [x] 8.6 Tests:
  - `reminders_test` (8): 60 min + 30 min repeat, a walk restarts the count, short breaks or misreads do not, lying excluded, custom minutes, wake every 5 min until up, already up, next day;
  - `latency_test_test` (5);
  - cough rule tests updated.
  - `flutter analyze` is clean, and **185 pass, 1 skipped**.
- [x] 8.7 Models: `model_harry/har_window_study.py` (2 s / 3 s / 4 s windows and a 4 s recency model, official folds + replay latency) runs after the social study.

### Still to check on a real phone (Task 8)
- [ ] **Android build**: not compiled here (no Android SDK). The first `flutter run` on Android checks the Gradle changes (desugaring, Java 17).
- [ ] Android 13+ and iOS: the notification prompt on the first connect; a reminder appears while the app is open.
- [ ] Move reminder: set 30 min and sit; wake alarm: set a time 2 min ahead and lie down.
- [ ] Latency test: the vibration and beep are noticeable. On iOS the system "alert" sound may be silent when the ring switch is off; the vibration and orange screen still cue.

## Still to check on a real phone (can't be done here)

- [ ] BLE connect / stream / disconnect through the new `SensorController` (the logic moved, not changed).
- [ ] Android: that `MainActivity.kt` compiles, the battery current sign and units on the test phone, and that `getrusage` via `libc.so` works (the `/proc` fallback exists).
- [ ] iOS: battery level in the Performance tab, and the PDIoT folder visible in the Files app.
- [ ] That real-time trial raw CSVs and performance logs appear in `<user>/raw/` and `<user>/performance/`.
- [ ] Note: history saved by earlier builds (in the app's private DB) is not moved into a user folder.

## Change log

- 2026-11-03: tracker created; evaluation done; decisions recorded.
- 2026-11-03: Tasks 0–6 implemented, tests and docs updated (see above).
- 2026-11-03: messages (snackbars) now float above the Home button instead of pushing it up (`main.dart` theme); regression test in `widget_test`.
- 2026-11-09: Task 7 (social paused while moving, smoothing fix, 0.5 s default, shown latency, performance-log conditions).
- 2026-11-09: Task 8 (times coughed, latency test, reminders, HAR window study).
- 2026-11-09: background running removed (no iOS background mode, no Android foreground service).
