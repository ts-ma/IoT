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
