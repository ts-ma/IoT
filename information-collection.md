# CW3 report — information collection checklist

What has to be measured, computed or captured for the 4,000-word report (and the
18 Nov demo), taken line by line from *Coursework 3 Instructions.pdf* (7 pages).
Part A is the checklist. Part B gives a step-by-step guide for every item, for
**iOS and Android**. Part C is shared set-up (building, getting files off the
phones, fair-measurement rules).

## Hard deadlines

| Date | What | Consequence |
|---|---|---|
| **Mon 16 Nov 2026** | Slides submitted to Learn (must contain everything for the demo, incl. videos) | Run from one shared laptop |
| **Wed 18 Nov 2026, 10:00** | Live demo; **RESpeck returned afterwards** | Every item marked 📟 must be finished before this |
| **Fri 15 Jan 2027, 12:00** | `[GroupName]_FinalReport.pdf` on Learn (one member submits) | Items marked 🖥 can be done until then |

Legend: **[CW3]** = explicitly asked for in the instructions (quote given) ·
📟 = needs the RESpeck/phones · 🖥 = offline (laptop only) ·
📱 = the app records it for you.

Suggested order (5 days of device time left):

| Day | Do |
|---|---|
| Wed 11 | C1–C4: install the measurement build on both phones, smoke test, freeze the app version |
| Thu 12 | N9 real-time accuracy test – member 1 · N10 latency – member 1 |
| Fri 13 | N9 + N10 – member 2 · N11 performance logs on iPhone |
| Sat 14 | N11 on Android incl. profilers · X5 video latency · N13 history day |
| Sun 15 | Slides (N14), fill any gaps |
| Mon 16 | Submit slides |
| Tue 17 | Buffer: re-run anything that failed for a *technical* reason (see C5) |
| Wed 18 | Demo, hand back the RESpeck |
| Nov–Jan | 🖥 items: N8, N12, X1–X4, X9–X12, writing |

---

# Part A — Checklist

## A1. Necessary (asked for by CW3)

**Title page / admin**
- [ ] **N1** Group name (for the file name), project title, both names, matriculation numbers (s2503795, s2952925) 🖥

**Methodology**
- [ ] **N2** System overview facts + system diagram (device, models, app, no server) [CW3] 🖥
- [ ] **N3** Physical activity recognition: preprocessing, features, model, training set-up, references [CW3] 🖥
- [ ] **N4** Social signal classification: the same, for social signals [CW3] 🖥
- [ ] **N5** Mobile app: tools/frameworks, functions/features, UI design + screenshots on **both** platforms [CW3] 📟
- [ ] **N6** Software organisation: architecture, key modules, sizes [CW3] 🖥
- [ ] **N7** Testing: unit tests, model-conversion checks, user/device testing on both platforms [CW3] 📟🖥

**Results and discussion**
- [ ] **N8** Cross-validation accuracy with the official Learn folds: each class averaged over 10 folds + mean of static, dynamic, social [CW3] 🖥
- [ ] **N9** Real-time accuracy test: all 11 activities + 4 social signals, **every member**, procedure + justification, table, final % [CW3] 📟📱
- [ ] **N10** Communication latency (seconds from performing the activity to the result on screen) [CW3] 📟📱
- [ ] **N11** Power, CPU and memory: values, **how** measured, **conditions** (device, platform, duration, on-device classification), both platforms, as **graphs** [CW3] 📟📱
- [ ] **N12** Critical-analysis inputs: why methods differ, most confused classes, real-time vs CV, limitations [CW3] 🖥
- [ ] **N13** Evidence of the daily history ("on Oct 17 … 1 h walking, coughed 30 times") [CW3 task 3] 📟📱

**Demo (5 marks, and the performance numbers must already be in it)**
- [ ] **N14** Slides: annotated block diagram, algorithms, app design/features, performance (accuracy, latency, power, CPU, memory); stairs shown as recorded video; submitted Mon 16 Nov [CW3] 📟

## A2. Additional (to score higher in "Analysis" and "critical analysis … quantitative … graphs")

- [ ] **X1** Baselines on the same folds: logistic regression + random forest on hand-crafted features (also asked for in the L1 formative feedback) 🖥
- [ ] **X2** Model comparison with statistics: CNN vs Conv-GRU vs MLP vs feature net, fold mean ± SD, paired test across folds 🖥
- [ ] **X3** Window-length trade-off: accuracy vs response time (social study done; add HAR 2 s / 3 s / 4 s) 🖥
- [ ] **X4** Effect of adding the members' recordings: Jan2026-only vs Jan2026 + members 🖥
- [ ] **X5** Video-verified latency (slow-motion video, no reaction time) on a subset 📟
- [ ] **X6** Cross-platform comparison: same tests on iPhone and Android 📟📱
- [ ] **X7** Long run (≥ 60 min): memory flat (no leak), lost packets, battery drain, screen-off/background 📟📱
- [ ] **X8** Power breakdown: phone idle vs app idle vs app classifying; screen on vs off; RESpeck battery drain 📟📱
- [ ] **X9** Model footprint: parameters, TFLite size, inference time per phone; optional float16/int8 quantisation trade-off 🖥📱
- [ ] **X10** Confidence analysis: confidence of correct vs wrong results (real-time) and calibration (CV) 🖥📱
- [ ] **X11** Social accuracy by posture (sitting/standing vs lying) and per-subject spread 🖥
- [ ] **X12** Smoothing and update-step ablation: shown vs raw accuracy, step 6/12/25 latency and CPU 📟📱🖥
- [ ] **X13** Small usability study (System Usability Scale) for the UI marks 📟

---

# Part B — Step-by-step guides

> Before any 📟 item, do **Part C** (C1–C5) once.

## N1 — Title page facts 🖥

1. Find the assigned group name on Learn (it is needed in the file name, e.g. `A1_FinalReport.pdf`).
2. Agree on the project title.
3. Write both names and matriculation numbers (s2503795, s2952925).
4. Title page must say **"PDIoT Coursework 3 (2026-27)"** and include the **Abstract**.

## N2 — System overview 🖥

Collect these facts (each one is a sentence or a diagram label):

1. **Sensor:** RESpeck, 3-axis accelerometer, 12.5 Hz, worn on the chest; Bluetooth LE; one packet = 32 samples = 2.56 s (`lib/ble.dart`, header comment).
2. **Phone side:** Flutter app, both models run **on the phone** with TensorFlow Lite; **no server**. Versions:
   ```bash
   cd ~/IoT
   flutter --version            # Flutter + Dart versions
   grep -A2 "tflite_flutter:\|flutter_blue_plus:\|sqflite:\|flutter_local_notifications:" pubspec.lock
   ```
3. **Models:** file names, window lengths, classes:
   ```bash
   cat assets/models/harry_har_cnn_meta.json assets/models/harry_social_rnn_meta.json
   ls -l assets/models/*.tflite
   ```
4. **Data path for the diagram:** RESpeck → BLE packet → decode → both models fed every sample (HAR 50-sample window, social 75-sample window, new result every 6 samples) → HAR smoothing (majority of 3) → social shown only while the shown activity is static → screen + SQLite history + notifications.
5. Draw the diagram (draw.io / PowerPoint). Re-use it in the slides (N14).

## N3 / N4 — Model methodology 🖥

From the model repo (`pipeline_v2/`, now in its own repository; start with `results/KNOWLEDGE.md`):

1. **Data:** datasetJan2026 + both members' recordings; class merges required by CW3 (sitting + standing; all stationary × breathing; talking/eating/singing/laughing → "other").
2. **Preprocessing:** window length and overlap used in training (`step_samples` in the meta files = 25), normalisation (inside the model), any filtering.
3. **Model:** architecture (HAR multi-branch CNN; social Conv-GRU), layer list and parameter count:
   ```bash
   ~/miniconda3/envs/lerobot/bin/python -c "
   import keras
   for f in ['assets/models/harry_har_cnn.keras','assets/models/harry_social_rnn.keras']:
       m = keras.models.load_model(f); print(f, m.count_params()); m.summary()"
   ```
4. **Training:** optimiser, learning rate, epochs/early stopping, batch size, class weights (social: balanced^0.6), seed — from the pipeline config.
5. **References:** at least one per design choice (1-D CNN for HAR, GRU, class weighting, subject-wise CV). Keep a BibTeX list.

## N5 — App implementation + screenshots 📟

1. Write the feature list from the app: Home (live activity + social, confidence), History, Chart (day timeline, week), Tools (real-time test, latency test, free recording), Performance, Settings, user accounts, reminders/notifications, background running, CSV export.
2. **Screenshots on both phones** (same data on screen if possible):
   - iOS: press **Side button + Volume Up**; photos go to Photos → AirDrop to the Mac.
   - Android: press **Power + Volume Down**; photos in Google Photos/Files → `adb pull /sdcard/Pictures/Screenshots ~/Desktop/shots_android` or share to the Mac.
   - Capture: Home while classifying, Home with "paused while moving", History, Chart day summary, Tools trial running, Tools results table, Performance charts, Settings, the background notification (Android) and a reminder notification.
3. Note UI design choices (colours per class, icons, confidence display, why social is paused while moving).

## N6 — Software organisation 🖥

```bash
cd ~/IoT
find lib -name '*.dart' | xargs wc -l | sort -n | tail -30   # module sizes
ls lib lib/services lib/widgets
```
Describe the layers: BLE (`ble.dart`) → models (`har.dart`, `social.dart`, `services/social_sample_processor.dart`) → state (`services/sensor_controller.dart`) → storage (`services/prediction_*`) → screens. Add the same for the model repo (pipeline scripts).

## N7 — Testing 🖥📟

1. Unit/widget tests:
   ```bash
   cd ~/IoT && flutter test 2>&1 | tail -1      # currently: 196 passed, 1 skipped
   ```
   Note what they cover (window logic, model contract, smoothing, scoring, history, latency test).
2. Model conversion check: the tests compare the TFLite output with the example in `*_example.json` (the Keras result).
3. Device testing table: for each phone (model, OS) — connects, classifies, history saved, background running, notifications. Fill it in during C3.
4. User testing = N9 + X13.

## N8 — Cross-validation accuracy (official folds) 🖥

What CW3 wants: for **each class**, accuracy averaged across all 10 folds; plus the mean of the **static** classes, **dynamic** classes and the **social** classes. Folds from Learn (`folds_daily_activity.csv`, `folds_social_signal.csv`); a subject never in train and test of the same fold.

1. In the model repo, open `pipeline_v2/results/KNOWLEDGE.md` and the tables folder. You need:
   - per-fold, per-class accuracy (recall) for the deployed HAR CNN and social Conv-GRU;
   - fold mean per class, fold mean of group means, and the SD across folds.
2. Check the "as marked" numbers are computed on **Jan2026 test windows only** with the official folds (the members were extra subjects in folds 8–9; state this).
3. **Honesty note (important):** v2 trains with the members' recordings mixed in. That is allowed ("continue improving … offline"), but the report must say so. Also report the **Jan2026-only** result of the same recipe (from v1 / X4) so the marker can compare like with like.
4. If any table is missing after the move, re-run `pipeline_v2/RUN_PIPELINE_V2.command` (several hours) — check first.
5. Table for the report: rows = 11 activities + 4 social classes, columns = fold 0…9, mean, SD; then 3 group-mean rows.

## N9 — Real-time accuracy test 📟📱

**What CW3 asks:** "each of your group members can perform each activity a number of times and report how many times the correct classification result is **shown on your app** in terms of percentage"; "cover all physical activities and social signals … involve every group member … how many times … how long each trial lasted … how you decided whether a classification was correct … table … final accuracy as a percentage."

**What the app records (📱 Tools → Real-time test):**
- *Shown*: what the screen displayed after every RESpeck packet (every 2.56 s), i.e. exactly what the user saw. Main figure.
- *Raw*: every model result (every 0.48 s) before smoothing. Secondary (for X12).
- Confidence of every result, the warm-up excluded (HAR 4 s, social 6 s), shown-latency, the settings in force, the platform and the raw accelerometer file.
- Social shown as "paused" (because the shown activity was a movement) **counts as wrong**.
- Export → 3 CSVs: per trial, per class summary, confusion matrices (shown and raw).

**Protocol (decide before starting, do not change mid-way):**

| Block | Classes | Trials per member | Length | "True social" field |
|---|---|---|---|---|
| Activity | all 11 activities | 3 each = 33 | 30 s (stairs: whole flight, ≥ 15 s) | **Not assessed** (breathe normally) |
| Social | 4 social signals | 4 each = 16 | 30 s | the social signal |

- Social trials rotate the posture: trial 1 sitting, 2 standing, 3 lying on back, 4 lying on left side — set "True activity" to that posture.
- "Other" uses a different sub-activity each trial: talking, eating, singing, laughing.
- Correct = the class on screen equals the true class. Per class: shown-correct / shown updates. Group = mean of the class accuracies (same as the CW3 marking). Also report trials whose majority was correct.
- With 2 members: ≈ 60 scored screen updates per activity class and ≈ 75 per social class.

**Steps (identical on iOS and Android):**
1. Same app build for everyone (C4). One phone runs the test, the other member performs.
2. Wear the RESpeck exactly as during data collection (same side, same orientation, same tape).
3. Home → connect → wait until results appear.
4. Tools → Real-time test: type the participant ID (s2503795 / s2952925), choose the true activity and (social block only) the true social signal, duration 30 s, keep **Ignore warm-up** and **Save raw sensor data** on.
5. Participant starts the activity; press **Start trial** at the same moment. Do not touch the phone until it finishes.
6. Repeat for all trials in a random order within each location (room / corridor / stairs / outdoors). Write the order down beforehand.
7. Never delete a trial because the result was bad. Cancel only for technical reasons (lost connection, sensor fell off, wrong label chosen) and write the reason in a log (C5).
8. Tools → download icon → files in `exports/` (`PDIoT_realtime_trials_*.csv`, `…_summary_*.csv`, `…_confusion_*.csv`). Copy them off the phone (C2).
9. In the report: one table of all classes with trials, screen updates, shown correct, shown %, raw %; group means; final %. Describe the procedure and justification above.

## N10 — Communication latency 📟📱

CW3: "How long (in seconds) does it take for the classification output to be shown on your mobile app after performing the activity?"

**App method (📱 Tools → Latency test):** the phone cues the change (vibration + sound), times *first correct model result*, *shown on screen*, and *stable for 3 s*. Includes the participant's reaction to the cue (≈ 0.2–0.4 s; state it; X5 measures it).

1. Changes to test (5 repeats each, both members if time allows):
   - Activity: sitting → walking, walking → sitting, sitting → lying back, lying back → lying left, standing → running (outdoors).
   - Social (stay seated): breathing → coughing, breathing → hyperventilating, breathing → talking ("other"), coughing → breathing.
2. Tools → Latency test → choose task, participant, From, Change to, Repeats = 5 → Start. Do the FROM activity until the screen shows it; change the moment the cue comes.
3. Export (download icon) → `exports/` → copy off (C2).
4. Also from the Performance log (N11): packet interval (should be 2.56 s), lost packets, extra BLE delay (jitter).
5. Report: mean, median, min, max per change; a box plot; explain the budget: window fill (4 s / 6 s) + wait for the next 2.56 s packet + smoothing.

## N11 — Power, CPU, memory 📟📱

CW3: "Measure and report your app's communication latency, power consumption, CPU usage, and memory usage. Describe how you took each measurement (e.g. Flutter DevTools, Android Studio Profiler, Xcode Instruments) and the conditions … device and platform … how long the app was running … on the device or a server. If you tested on both platforms, report the results for each."

### N11.0 Fair conditions (both phones, write them down)
- Measurement build (`--profile` or `--release`, never debug; C1).
- Battery between 90 % and 40 %, **not charging, no USB cable** (use wireless debugging when a profiler is needed).
- Brightness fixed (auto-brightness off, e.g. 50 %), Low Power Mode / Battery Saver **off**, Wi-Fi on, other apps closed, Bluetooth on, same room.
- Duration ≥ 30 min per condition. Classification runs on the phone (no server) — say so.
- The app writes a `perf_*.conditions.json` with platform, OS, phone model, app version, settings and, at the end, averages split by *streaming* / *idle*.

### N11.1 App performance log (📱, both platforms)
1. Performance tab → **Record performance log** ON.
2. Go to the **Home** tab (the Performance charts redraw every second and add CPU).
3. Condition A "app idle": RESpeck **disconnected**, screen on, 15 min.
4. Condition B "classifying": connect the RESpeck, sit still or work normally, screen on, 30 min.
5. Condition C "background": lock the screen, 30 min (Android shows "PDIoT is monitoring"). *iOS may pause the 1-s sampler while locked — check the time column for gaps; use Settings › Battery for iOS screen-off power instead.*
6. Performance → log OFF. Copy `performance/perf_*.csv` and `perf_*.conditions.json` (C2).
7. The CSV has per second: CPU (% of one core), RSS, platform memory (iOS footprint / Android total PSS), battery %, current and power (Android), inference ms, packet interval, lost packets, streaming state.

### N11.2 CPU — profiler cross-check (required tool named by CW3 for Android)

**Android — Android Studio Profiler**
1. Start the profile build over wireless debugging (C1).
2. Android Studio → **View → Tool Windows → Profiler** → **+** → choose the phone → process `com.specknet.pdiot` (works because the manifest is now `profileable`).
3. In the live telemetry view note **CPU %** over 2–5 min while classifying (Android Studio shows % of **all** cores; the app shows % of **one** core → divide the app value by the number of cores to compare).
4. **Find CPU Hotspots** (sampled call stacks) for 30 s → screenshot the flame chart (shows TFLite + Flutter threads).
5. Command-line check:
   ```bash
   adb shell pidof com.specknet.pdiot
   adb shell top -b -d 1 -n 60 -p <PID> > ~/Desktop/android_top.txt   # %CPU per second (one core = 100)
   ```

**iOS — Xcode**
1. Open `ios/Runner.xcworkspace` in Xcode, choose the iPhone, **Product → Scheme → Edit Scheme → Run → Build Configuration = Profile**, then **Run** (or `flutter run --profile`).
2. **Debug navigator (⌘7) → CPU** gauge: note % while classifying (100 % = one core, like the app).
3. **Product → Profile (⌘I)** → template **Activity Monitor** (CPU % and memory per process) or **Time Profiler** (hot spots) → Record 2–5 min → screenshot.
4. Instruments can also attach to the running app: target menu → your iPhone → *Pdiot*.

**Both — Flutter DevTools (optional)**: `flutter run --profile` prints a DevTools URL → **CPU Profiler** (Dart code) and **Performance** (frame times = UI smoothness).

### N11.3 Memory — profiler cross-check
- The app's *platform memory* column equals:
  - Android: `TOTAL PSS` of
    ```bash
    adb shell dumpsys meminfo com.specknet.pdiot | grep -E "TOTAL PSS|TOTAL:"
    ```
    Run it 3× during condition B and compare with the log at the same minute.
  - iOS: Xcode **Debug navigator → Memory** gauge (footprint). Compare once.
- Android Studio Profiler → **Track Memory Consumption** / memory telemetry (Java, Native, Graphics, Code…) → screenshot.
- iOS Instruments → **Allocations** or **Leaks** template during a 10-min run → screenshot (no leak).

### N11.4 Power / battery
**Android**
1. App log: whole-phone power (mW) per second. App cost ≈ mean power in condition B − condition A (same screen state); background cost from condition C vs a phone-idle baseline.
2. Per-app estimate from Android itself:
   ```bash
   adb shell dumpsys batterystats --reset          # with the phone unplugged, wireless adb
   # … run condition B for 30 min …
   adb shell dumpsys batterystats com.specknet.pdiot > ~/Desktop/batterystats_pdiot.txt
   ```
   Look for "Estimated power use (mAh)" and the uid line for the app.
3. Android Studio **Power Profiler** (only on phones with power rails, e.g. Pixel 6 or newer): Profiler → **System Trace** with power rails → screenshot.
4. Settings → Battery → Battery usage → *pdiot*: % and minutes → screenshot.

**iOS** (no public API for current)
1. App log: battery % over time → %/hour (needs ≥ 10 min and ≥ 1 % drop; longer runs are better).
2. After the runs: **Settings → Battery** → choose the last 24 h → *Pdiot*: % of battery and screen-on / background minutes → screenshot.
3. Xcode: Debug navigator → **Energy Impact** gauge (Low/High/Very High) → screenshot. If your Xcode has the **Power Profiler** template in Instruments, record 5 min while classifying and screenshot.

**RESpeck battery:** the log has `respeck_battery_pct`; report %/hour over the long run (X7).

### N11.5 Report output
Per platform: table (mean / max CPU, memory, power, battery %/h, inference ms, latency) + graphs (CPU and memory over time, power per condition, latency box plot), with the conditions and the tool used for each number.

## N12 — Critical-analysis inputs 🖥

1. **Most confused classes:** CV confusion matrices (pipeline `confusion_long.csv`, summed over folds) + the real-time confusion CSV from N9. List the top 3 confusions per task and why (e.g. shuffle vs walking, misc vs walking, "other" vs breathing when posture changes).
2. **Why methods differ:** X1 + X2 numbers.
3. **Real-time vs CV:** put N8 and N9 per class side by side. Explanations to check with data: warm-up/transitions, smoothing, members were in the training data (real-time is not subject-independent), sensor placement, the "paused" social results.
4. **Limitations / improvements:** window length vs latency (X3), packet granularity 2.56 s, social pauses while moving, small number of real-time subjects.

## N13 — Daily history evidence 📟📱

1. One member wears the RESpeck for ≥ 2 h of normal life (desk work, a walk, stairs, a meal, a few coughs), app connected (background allowed).
2. Chart tab → today → screenshot the day summary (time per activity, coughs) on both phones if possible.
3. Chart → **Export day as CSV** → copy off (C2).
4. In the report: show that the app answers "on 17 Nov they spent X h sitting, Y min walking, coughed N times".

## N14 — Demo slides 📟

1. Slides: block diagram (N2), algorithms (N3/N4), app design + features (N5), performance: real-time accuracy (N9), latency (N10), power/CPU/memory (N11).
2. **Recorded data for stairs:** record the phone screen while one member walks up and down stairs with the app running:
   - iOS: Control Centre → **Screen Recording**; film the person with the other phone at the same time.
   - Android: Quick Settings → **Screen record**.
   Put both videos side by side in the slides (embedded, not linked — one laptop runs everything).
3. Practise sharing the phone screen: iOS → QuickTime Player → File → New Movie Recording → camera = iPhone (USB); Android → `scrcpy` (`brew install scrcpy`, then `scrcpy`) or Android Studio *Running Devices* mirroring.
4. Upload to Learn by **Mon 16 Nov**.

---

## X1 — Baselines (logistic regression, random forest) 🖥
1. Features per window (same windows as the CNN): mean, SD, min, max, range, median, IQR, energy per axis + magnitude; correlations between axes; FFT band energies.
2. scikit-learn `LogisticRegression(max_iter=2000, class_weight='balanced')` with standardisation, and `RandomForestClassifier(n_estimators=300, class_weight='balanced')`.
3. Same official folds, same per-class-then-group scoring as N8. Report next to the deep models.
4. (Install scikit-learn into the TF env: `~/miniconda3/envs/lerobot/bin/pip install scikit-learn`.)

## X2 — Model comparison with statistics 🖥
From the v2 per-fold tables: mean ± SD over folds for each architecture; paired Wilcoxon signed-rank test (10 folds) between the best and the others; a bar chart with error bars.

## X3 — Window-length trade-off 🖥
Social: use `social_window_study` (8/6/5/4 s). HAR: same script idea with 2, 3, 4 s windows. Plot accuracy (y) vs expected time-to-show (x) for both tasks.

## X4 — Effect of the members' data 🖥
Same recipe trained on Jan2026 only vs Jan2026 + members; scored on the official Jan2026 test folds, and on the held-out member.

## X5 — Video-verified latency 📟
1. Second phone films at 240 fps (iPhone: Camera → **Slo-Mo**; Android: Camera → **Slow motion**) with both the participant and the app screen in view.
2. Do 10 changes (e.g. sit → walk, breathing → coughing).
3. On the Mac, step frame by frame (QuickTime: arrow keys) and note the frame where movement starts and where the screen changes. Latency = frames / 240.
4. Compare with the app's latency test minus reaction time.

## X6 — Cross-platform comparison 📟📱
Run N11 on both phones under the same conditions, and at least a few N9 trials on the second phone. Compare inference ms, CPU, memory, power in one table.

## X7 — Long run 📟📱
Performance log for ≥ 60 min while classifying (screen on and off). Plot memory over time (flat = no leak), lost packets, phone and RESpeck battery %.

## X8 — Power breakdown 📟📱
Use conditions A/B/C from N11.1 plus a phone-only baseline (app closed, same screen state). Bar chart: baseline, app idle, app classifying (screen on), app classifying (screen off).

## X9 — Model footprint 🖥📱
Parameter count (N3 command), `.tflite` size, inference mean/max per phone (Performance tab rows, or the log). Optional: convert with float16 / dynamic-range int8 and re-score on the folds (accuracy vs size vs speed).

## X10 — Confidence 🖥📱
Real-time: the trials CSV has a confidence for every result → histogram for correct vs wrong. CV: reliability diagram / expected calibration error from the fold predictions.

## X11 — Accuracy by posture and per subject 🖥
Fix the posture lookup in `pipeline_v2/analyze.py` first (it checks `startswith("lying")`, but posture tags are back/left/right/stomach, so every recording is counted as sitting/standing). Then social accuracy by posture, and the distribution of per-subject accuracy (how many subjects below 75 %).

## X12 — Smoothing and update step 📟📱🖥
- Shown vs raw accuracy is already in the N9 export (no extra work).
- Step: Settings → update interval 25 / 12 / 6 samples; run 10-min performance logs and 5 latency repeats for each. Plot CPU and latency vs step.

## X13 — Usability (SUS) 📟
5–8 people use the app for 5 min (connect, read the live result, open history, export). They fill the 10-question System Usability Scale; score 0–100. Report n, mean, and the main comments. Be honest about the small sample.

---

# Part C — Shared set-up

## C1 — Build the measurement version

**iOS**
1. iPhone: Settings → Privacy & Security → **Developer Mode** on; connect by USB once and Trust the Mac.
2. `cd ~/IoT && flutter devices` → note the iPhone id.
3. `flutter run --profile -d <iPhone id>` (profile = release speed + profiler support). For the accuracy tests `--release` is also fine; **never measure on a debug build** (it is several times slower).
4. Wireless: Xcode → Window → **Devices and Simulators** → iPhone → **Connect via network**; then unplug.

**Android** (not built on this Mac yet — no Android SDK here)
1. Install **Android Studio** (stable). Open it → **More Actions → SDK Manager**: install an Android SDK Platform, *Android SDK Build-Tools*, *Platform-Tools*, *Command-line Tools*.
2. Android Studio → Settings → Plugins → install **Flutter** (Dart comes with it).
3. Terminal:
   ```bash
   flutter config --android-sdk ~/Library/Android/sdk
   flutter doctor --android-licenses     # accept all
   flutter doctor                        # Android toolchain must be ✓
   ```
4. Phone: Settings → About phone → tap **Build number** 7× → Developer options → **USB debugging** on (and **Wireless debugging** on, Android 11+).
5. `flutter devices` → `flutter run --profile -d <android id>`. If the first Android build fails, paste the error to Claude.
6. Wireless adb: Developer options → Wireless debugging → **Pair device with pairing code** → `adb pair <ip:port>` → `adb connect <ip:port>`; or Android Studio → Device Manager → **Pair Devices Using Wi-Fi**.

## C2 — Getting the files off the phones

The app folder is `PDIoT/<user>/` with `exports/`, `performance/`, `raw/`, `realtime_trials.json`, `latency_tests.json`, `history.db`.

- **iOS:** Files app → On My iPhone → **Pdiot** → PDIoT → <user> → select → Share → AirDrop to the Mac. Or Finder → iPhone → **Files** tab → drag the *Pdiot* folder to the Mac.
- **Android:**
  ```bash
  adb shell ls /sdcard/Android/data/com.specknet.pdiot/files/
  adb pull /sdcard/Android/data/com.specknet.pdiot/files/ ~/Desktop/pdiot_android/
  ```
  Or Android Studio → View → Tool Windows → **Device Explorer** → `sdcard/Android/data/com.specknet.pdiot/files` → right-click → Save As.

Keep everything in one folder per phone and date, e.g. `cw3_data/2026-11-12_iphone/`.

## C3 — Smoke test before measuring (each phone)
Connect, see activity and social results, stop and start moving (social pauses), lock the phone for 2 min (Android notification; results continue), run a 15-s trial and a 1-rep latency test, export both, copy them off. Fill in the device table for N7.

## C4 — Freeze the app version
```bash
cd ~/IoT && git rev-parse --short HEAD     # write this down; commit first if needed
```
Use the same build for every measurement. If the app or models change, earlier real-time results no longer describe the submitted app — re-run or state it.

## C5 — Honesty rules (CW3 "true, accurate, no cheating")
- Decide the protocol, trial counts and order **before** testing; keep a paper/notes log (date, phone, participant, trial, anything unusual).
- Never drop or repeat a trial because the result was poor. Cancel only for technical faults and record why.
- The same models and settings for everyone; record the step (6) and smoothing (on) — the app stores them per trial.
- Report CV exactly as CW3 defines it (official folds, per class over 10 folds, group means) and say what extra data was in training.
- Say what each tool measures (whole-phone vs app-only power, % of one core vs all cores, PSS/footprint vs RSS).
- Keep all raw files (they are the evidence).
