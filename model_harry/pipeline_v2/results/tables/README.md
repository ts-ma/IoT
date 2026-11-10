# Data dictionary (tables/)

Every CSV in this folder, what one row is, and what every column means. Percentages are stored as fractions (0–1) unless the column name says otherwise.

## architectures.csv

per architecture: window, parameters, size, speed, layer files — 8 rows.

| column | meaning | example |
|---|---|---|
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_cnn |
| `name` |  | Multi-branch CNN |
| `window_samples` |  | 50 |
| `window_s` |  | 4.0 |
| `params` | trainable + non-trainable parameters | 26112 |
| `tflite_kb` |  | 130.8 |
| `ms_per_window_mac_1thread` |  | 0.0252500030910596 |
| `deployed` |  | True |
| `summary_file` |  | architectures/har_harry_cnn_w50.txt |
| `layers_file` |  | architectures/har_harry_cnn_w50.json |

## calibration_bins.csv

deployed models, seed 0: accuracy and confidence per confidence bin — 200 rows.

| column | meaning | example |
|---|---|---|
| `id` | job id (see jobs_index.csv) | main_har_mixed_s0_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | main |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_cnn |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0.0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `bin` |  | 0 |
| `lo` |  | 0.0 |
| `hi` |  | 0.1 |
| `n` | windows | 0 |
| `acc` |  | 0.0 |
| `conf` | mean confidence | 0.2685122191905975 |

## class_weights.csv

per job × class: the class weight applied — 1075 rows.

| column | meaning | example |
|---|---|---|
| `job` | job id | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `class` | class name (model output order) | sittingStanding |
| `weight` | class weight applied in training (normalised to mean 1 over the training windows) | 0.434383 |

## confusion_long.csv

per job × scope (all, jan) × true × predicted: window counts — 17720 rows.

| column | meaning | example |
|---|---|---|
| `id` | job id (see jobs_index.csv) | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0.0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `true` | true class | sittingStanding |
| `pred` | predicted class | sittingStanding |
| `count` | windows | 475 |

## data_composition.csv

datasetJan2026 recordings per task, listed/unlisted, class — 29 rows.

| column | meaning | example |
|---|---|---|
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `set` | listed (in the fold CSV) / unlisted | listed |
| `class` | class name (model output order) | ascending |
| `recordings` | number of recordings | 163 |
| `samples` |  | 61808 |
| `hours` | hours of data | 1.3735111111111111 |
| `len_mean_s` | mean recording length | 30.335214723926377 |
| `len_min_s` | shortest | 28.0 |
| `len_max_s` | longest | 32.0 |
| `windows_test_step` | test windows at the 2 s step | 2268 |

## deploy.csv

deployment cost per architecture and final models — 10 rows.

| column | meaning | example |
|---|---|---|
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_cnn |
| `tflite` |  | True |
| `builtin_ops_only` |  | True |
| `size_kb` | TFLite file size | 130.796875 |
| `params` | trainable + non-trainable parameters | 26112 |
| `ms_per_window` | median single-window TFLite inference, 1 thread, development Mac | 0.0252500030910596 |
| `ms_p90` | 90th percentile of the same | 0.02641699538799 |
| `window` | input window (samples) | 50 |
| `parity_argmax_agreement` | share of group-recording windows where Keras and TFLite agree | 1.0 |
| `parity_max_abs_dprob` | largest probability difference Keras vs TFLite | 8.642673492431641e-07 |

## duplicates_har_social.csv

static activity files that are byte copies of social recordings, with both folds — 899 rows.

| column | meaning | example |
|---|---|---|
| `har_class` |  | sittingStanding |
| `har_file` |  | N_0.csv |
| `har_fold` |  | 4 |
| `social_class` |  | breathingNormally |
| `social_fold` |  | 9 |

## epochs.csv

per job × epoch: training and held-out monitoring curves — 5184 rows.

| column | meaning | example |
|---|---|---|
| `id` | job id (see jobs_index.csv) | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0.0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `epoch` | epoch (1–32) | 1 |
| `train_loss` | training loss (with augmentation, label smoothing, class weights) | 1.283157467842102 |
| `train_acc` | training accuracy | 0.7009020447731018 |
| `test/loss` | held-out-fold loss (monitor only) | 0.5541232824325562 |
| `test/acc` | held-out-fold accuracy (monitor only) | 0.8526986506746627 |
| `test/score` | held-out-fold group score (HAR: mean of static and dynamic means; social: balanced) | 0.859841956491052 |
| `seconds` | wall time | 1.61 |
| `stage` | train | train |

## fold_composition.csv

official folds: recordings per class and fold — 150 rows.

| column | meaning | example |
|---|---|---|
| `activity` | class folder / activity | ascending |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0 |
| `recordings` | number of recordings | 17 |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |

## fold_scores.csv

per job × scope: group scores and other metrics for that fold — 384 rows.

| column | meaning | example |
|---|---|---|
| `id` | job id (see jobs_index.csv) | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0.0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `static` | mean recall over the 5 static classes | 0.9979166666666668 |
| `dynamic` | mean recall over the 6 dynamic classes | 0.7862466775805871 |
| `balanced_acc` | mean of the per-class recalls | 0.8824603089833508 |
| `window_acc` | share of all test windows correct | 0.8871814092953523 |
| `macro_f1` | mean F1 over classes | 0.8824009768240306 |
| `macro_auc` | mean one-vs-rest ROC AUC | 0.9867336997583156 |
| `recording_vote_acc` | share of test recordings whose majority window prediction is correct | 0.932642487046632 |
| `log_loss` | mean negative log probability of the true class | 0.4184265732765198 |
| `ece` | expected calibration error (15 bins) | 0.0795572028904483 |
| `mean_conf` | mean top probability | 0.8078078627586365 |
| `n_test_windows` | test windows scored | 2668 |
| `n_test_recordings` | test recordings scored | 193 |
| `social` | mean recall over the 4 social classes (balanced accuracy) | 0.7865563697203489 |
| `social_min` | lowest of the 4 social recalls | 0.7557494052339413 |

## fold_test_data.csv

per job × source × class: test windows — 1272 rows.

| column | meaning | example |
|---|---|---|
| `job` | job id | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `test_set` | name of the test set inside the job (cv) | cv |
| `source` | datasetJan2026, a group member, or 'group members' (training) | datasetJan2026 |
| `class` | class name (model output order) | sittingStanding |
| `windows` | number of windows | 480 |

## fold_training_data.csv

per job × source × class: training windows actually used — 2165 rows.

| column | meaning | example |
|---|---|---|
| `job` | job id | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `source` | datasetJan2026, a group member, or 'group members' (training) | datasetJan2026 |
| `class` | class name (model output order) | sittingStanding |
| `windows` | number of windows | 4354 |

## group_folds.csv

the group members' recordings / test windows per class and assigned fold — 30 rows.

| column | meaning | example |
|---|---|---|
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `person` | group member id | s2503795 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 8 |
| `class` | class name (model output order) | ascending |
| `recordings` | number of recordings | 1 |
| `windows_test_step` | test windows at the 2 s step | 14 |

## jan_gravity.csv

datasetJan2026 static recordings: mean gravity vector — 1869 rows.

| column | meaning | example |
|---|---|---|
| `class` | class name (model output order) | sittingStanding |
| `gx` |  | -0.3218917 |
| `gy` |  | -0.8411486 |
| `gz` |  | 0.46532497 |
| `dyn_std_g` |  | 0.0062217535451054 |

## jobs_index.csv

one row per job: settings, status, time, parameters, training windows — 170 rows.

| column | meaning | example |
|---|---|---|
| `id` | job id (see jobs_index.csv) | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0.0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `person` | group member id |  |
| `status` |  | ok |
| `seconds` | wall time | 23.7 |
| `params` | trainable + non-trainable parameters | 5009 |
| `train_windows` |  | 28158.0 |
| `train_seconds` |  | 23.065351963043213 |
| `predict_seconds` |  | 0.0341529846191406 |

## per_fold_class.csv

per job × scope × class: recall, precision, F1, support (recompute any marked number from here) — 2544 rows.

| column | meaning | example |
|---|---|---|
| `id` | job id (see jobs_index.csv) | base_har_harry_feat_mixed_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0.0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `class` | class name (model output order) | sittingStanding |
| `recall` | share of the class's test windows predicted as that class (the marked accuracy) | 0.9895833333333334 |
| `precision` | share of windows predicted as the class that truly are | 0.9713701431492844 |
| `f1` | harmonic mean of precision and recall | 0.9803921568627452 |
| `support` | test windows of the class | 480 |
| `predicted` | test windows predicted as the class | 489 |

## person_per_class.csv

each group member's own fold (unseen-person result), per class — 30 rows.

| column | meaning | example |
|---|---|---|
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `person` | group member id | s2503795 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 8.0 |
| `class` | class name (model output order) | ascending |
| `recall` | share of the class's test windows predicted as that class (the marked accuracy) | 1.0 |
| `recall_seed_sd` |  | 0.0 |
| `support` | test windows of the class | 14 |

## person_postures.csv

group members' social result split by posture (seed 0) — 4 rows.

| column | meaning | example |
|---|---|---|
| `person` | group member id | s2503795 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 8.0 |
| `postures` | all / lying / sitting/standing | all |
| `balanced` |  | 0.9253205128205128 |
| `breathingNormally` | value for class breathingNormally | 0.9102564102564102 |
| `coughing` | value for class coughing | 0.935897435897436 |
| `hyperventilation` | value for class hyperventilation | 0.9743589743589745 |
| `other` | value for class other | 0.8807692307692307 |

## real_data_quality.csv

group recordings: sampling rate, gaps, flat runs, clipping, gravity angle vs Jan2026 class mean, flags — 88 rows.

| column | meaning | example |
|---|---|---|
| `person` | group member id | s2503795 |
| `file` | recording file name | PDIOT_s2503795_AscendingStairs_Normal_05 |
| `activity` | class folder / activity | ascendingstairs |
| `sub` |  | normal |
| `har` |  | ascending |
| `har_y` |  | 7 |
| `stationary` |  | False |
| `posture` |  | back |
| `social` | mean recall over the 4 social classes (balanced accuracy) | coughing |
| `social_y` |  | -1 |
| `n` | windows | 375 |
| `n_raw` |  | 375 |
| `nan_rows` |  | 0 |
| `duration_s` |  | 38.613 |
| `fs_est` |  | 9.685857094760832 |
| `md5` |  | c52b019122df1149e9c8d52f5069e057 |
| `gx` |  | 0.21102343 |
| `gy` |  | -0.95414764 |
| `gz` |  | -0.31503305 |
| `g_norm` |  | 1.026729941368103 |
| `angle_to_jan_class_deg` |  | 17.561338424682617 |
| `dyn_std_g` |  | 0.1146116703748703 |
| `longest_flat_run` |  | 1 |
| `clipped` |  | 0 |
| `flag` |  |  |

## recipes.csv

every training / evaluation setting — 19 rows.

| column | meaning | example |
|---|---|---|
| `setting` |  | optimiser |
| `value` |  | AdamW |
| `notes` |  | keras.optimizers.AdamW |

## recording_level.csv

deployed models, all windows: one row per test recording — 25419 rows.

| column | meaning | example |
|---|---|---|
| `r` | recording key (source:index) | jan:102 |
| `y` | true class index | 0 |
| `n` | windows | 14 |
| `frac_correct` | share of the recording's windows correct | 1.0 |
| `conf` | mean confidence | 0.9390535 |
| `vote_correct` | majority vote correct | True |
| `source` | datasetJan2026, a group member, or 'group members' (training) | datasetJan2026 |
| `file` | recording file name | N_194.csv |
| `class` | class name (model output order) | sittingStanding |
| `id` | job id (see jobs_index.csv) | main_har_mixed_s0_f0 |
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | main |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_cnn |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `seed` | training seed (0, 1, 2) | 0 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0.0 |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |

## social_window_study_per_fold_recall.csv

the window study: per fold and candidate class recalls — 50 rows.

| column | meaning | example |
|---|---|---|
| `cand` | social window candidate (w100 = 8 s, w75 = 6 s, w62 = 5 s, w50 = 4 s, w100rec = 8 s recency-trained) | w100 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0 |
| `breathingNormally` | value for class breathingNormally | 0.8078149920255183 |
| `coughing` | value for class coughing | 0.823731728288908 |
| `hyperventilation` | value for class hyperventilation | 0.7656631407648494 |
| `other` | value for class other | 0.8117123795404003 |

## social_window_study_streams.csv

the window study: one row per replayed change — 8000 rows.

| column | meaning | example |
|---|---|---|
| `cand` | social window candidate (w100 = 8 s, w75 = 6 s, w62 = 5 s, w50 = 4 s, w100rec = 8 s recency-trained) | w100 |
| `fold` | official fold 0–9 (the group members are in folds given by decisions.json) | 0 |
| `stream` | jan = pairs of fold-k test recordings; real = same-posture changes in the group members' recordings | jan |
| `person` | group member id | jan |
| `target` | class changed to | other |
| `steady_acc` | accuracy over the last 12 s after the change | 0.2066666666666666 |
| `lat_s6` | seconds from a change until the new class is shown and kept 4 s (app replay, 0.5 s step) | 6.720000000000001 |
| `miss_s6` | share of replays where the new class was never shown steadily | 0.5 |
| `lat_s12` | same with a 1 s step | 6.720000000000001 |
| `miss_s12` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 0.5 |

## social_window_study_summary.csv

the window study: per candidate class recalls and latency statistics — 5 rows.

| column | meaning | example |
|---|---|---|
| `cand` | social window candidate (w100 = 8 s, w75 = 6 s, w62 = 5 s, w50 = 4 s, w100rec = 8 s recency-trained) | w100 |
| `breathingNormally` | value for class breathingNormally | 87.6 |
| `coughing` | value for class coughing | 82.25 |
| `hyperventilation` | value for class hyperventilation | 81.58 |
| `other` | value for class other | 80.03 |
| `mean` | mean over seeds of the fold-mean (the reported number) | 82.87 |
| `min_class` |  | 80.03 |
| `folds` |  | 10 |
| `worst_fold_min_class` |  | 75.9 |
| `lat_med_jan` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 6.08 |
| `lat_med_real` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 6.08 |
| `lat_mean_jan` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 7.12 |
| `lat_mean_real` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 6.57 |
| `lat_p90_jan` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 13.76 |
| `lat_p90_real` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 9.28 |
| `miss_jan` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 0.11 |
| `miss_real` | window study latency statistic (median/mean/p90 of seconds until shown, or share never shown), per stream | 0.03 |
| `steady_jan` |  | 0.75 |
| `steady_real` |  | 0.91 |

## stat_tests.csv

paired Wilcoxon tests over folds — 40 rows.

| column | meaning | example |
|---|---|---|
| `comparison` | A vs B | har: Multi-branch CNN vs Spectral-featur |
| `scope` | scoring scope (as 'variant') | all |
| `metric` | compared metric | static |
| `n_folds` | folds | 10 |
| `mean_a` | mean of A over folds | 0.9940221767083396 |
| `mean_b` | mean of B over folds | 0.9933366177130006 |
| `mean_diff` | mean of A − B | 0.0006855589953392 |
| `folds_a_better` | folds where A > B | 4 |
| `p_wilcoxon` | two-sided Wilcoxon signed-rank p over the paired folds | 0.3125 |

## summary_per_class.csv

per experiment × scope × class: fold-mean over seeds (reported), spreads, CI — 380 rows.

| column | meaning | example |
|---|---|---|
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `class` | class name (model output order) | ascending |
| `mean` | mean over seeds of the fold-mean (the reported number) | 0.7756160484066312 |
| `seed_std` | sd over seeds of the fold-mean | 0.0027748906214321 |
| `fold_std` | sd over folds (seed 0) | 0.0806739647192752 |
| `fold_min` | worst fold (seed 0) | 0.6846846846846847 |
| `fold_max` | best fold (seed 0) | 0.8865546218487395 |
| `ci95` | half-width of the 95 % t-interval over folds | 0.0577106777939672 |
| `n_seeds` | seeds | 1 |
| `n_folds` | folds | 10 |
| `precision` | share of windows predicted as the class that truly are | 0.7807680442810389 |
| `f1` | harmonic mean of precision and recall | 0.7738321091461687 |

## summary_scores.csv

per experiment × scope: group scores, mean and sd over seeds (columns <metric>_mean / <metric>_std) — 60 rows.

| column | meaning | example |
|---|---|---|
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `model` | architecture id (harry_cnn, harry_rnn, harry_mlp, harry_feat; see architectures.csv) | harry_feat |
| `variant` | scoring scope: all = every test window of the fold; jan = only its datasetJan2026 windows (as CW3 marks); group = only the group members' windows; s2503795 / s2952925 = that member's windows | all |
| `power` | social class-weight exponent (balanced^power); empty for activities | 0.6 |
| `static_mean` | mean recall over the 5 static classes – mean over seeds | 0.9933366177130004 |
| `static_std` | mean recall over the 5 static classes – sd over seeds | 0.0008236751140574 |
| `dynamic_mean` | mean recall over the 6 dynamic classes – mean over seeds | 0.8079693381224169 |
| `dynamic_std` | mean recall over the 6 dynamic classes – sd over seeds | 0.0018834500018455 |
| `social_mean` | mean recall over the 4 social classes (balanced accuracy) – mean over seeds | 0.8159824570643709 |
| `social_std` | mean recall over the 4 social classes (balanced accuracy) – sd over seeds | 0.0005942388817823 |
| `social_min_mean` | lowest of the 4 social recalls – mean over seeds | 0.7796781462855272 |
| `social_min_std` | lowest of the 4 social recalls – sd over seeds | 0.0023707945773866 |
| `balanced_acc_mean` | mean of the per-class recalls – mean over seeds | 0.8922271924817732 |
| `balanced_acc_std` | mean of the per-class recalls – sd over seeds | 0.0007023622078833 |
| `window_acc_mean` | share of all test windows correct – mean over seeds | 0.8979034234010799 |
| `window_acc_std` | share of all test windows correct – sd over seeds | 0.0006786278889137 |
| `macro_f1_mean` | mean F1 over classes – mean over seeds | 0.8905687421524526 |
| `macro_f1_std` | mean F1 over classes – sd over seeds | 0.0008766614006654 |
| `macro_auc_mean` | mean one-vs-rest ROC AUC – mean over seeds | 0.989845863245932 |
| `macro_auc_std` | mean one-vs-rest ROC AUC – sd over seeds | 0.0001860944482146 |
| `recording_vote_acc_mean` | share of test recordings whose majority window prediction is correct – mean over seeds | 0.933697782060574 |
| `recording_vote_acc_std` | share of test recordings whose majority window prediction is correct – sd over seeds | 0.0042978637613362 |
| `log_loss_mean` | mean negative log probability of the true class – mean over seeds | 0.3854791104793548 |
| `log_loss_std` | mean negative log probability of the true class – sd over seeds | 0.0033163278705959 |
| `ece_mean` | expected calibration error (15 bins) – mean over seeds | 0.0897126966520864 |
| `ece_std` | expected calibration error (15 bins) – sd over seeds | 0.0005946217175219 |
| `mean_conf_mean` | mean top probability – mean over seeds | 0.8091702938079834 |
| `mean_conf_std` | mean top probability – sd over seeds | 0.0004782731085458 |

## timing.csv

compute per job group — 5 rows.

| column | meaning | example |
|---|---|---|
| `group` | job group: main (deployed architecture, 3 seeds), baseline (other architectures), sweep (social class-weight power), deploy (untrained cost benchmark), final (trained on everything, exported) | baseline |
| `count` | windows | 60 |
| `sum` |  | 13488.2 |
| `mean` | mean over seeds of the fold-mean (the reported number) | 224.80333333333337 |

## tsne.csv

2-D embedding of fold-0 test windows (deployed models) — 5000 rows.

| column | meaning | example |
|---|---|---|
| `task` | har = physical activity (11 classes), social = social signal (4 classes) | har |
| `x` |  | 14.852338 |
| `y` | true class index | 3.4103968 |
| `true` | true class | lyingLeft |
| `pred` | predicted class | lyingLeft |
| `source` | datasetJan2026, a group member, or 'group members' (training) | jan_har |

## system.json

```json
{
 "machine": "Apple M1 Pro",
 "cpus": 8,
 "os": "macOS-26.5.2-arm64-arm-64bit",
 "python": "3.12.14",
 "tensorflow": "2.21.0",
 "keras": "3.15.1",
 "sklearn": "1.9.1",
 "numpy": "2.2.6",
 "date": "2026-11-10 03:20"
}
```

## data_facts.json

```json
{
 "har_copies_of_social": 899,
 "same_fold": 90,
 "by_har_class": {
  "sittingStanding": 342,
  "lyingStomach": 172,
  "lyingBack": 155,
  "lyingLeft": 117,
  "lyingRight": 113
 },
 "by_social_class": {
  "breathingNormally": 899
 },
 "within_task_duplicate_groups": {
  "har": 4,
  "social": 8
 },
 "person_fold": {
  "s2503795": 8,
  "s2952925": 9
 }
}
```
