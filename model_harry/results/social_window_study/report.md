# Social window study

Official 10-fold CV on datasetJan2026 (listed recordings), harry_rnn, class weights balanced^0.6, seed 0. Latency = app replay with 32-sample packets (2.56 s) and a 0.5 s update step: seconds from the change until the new class is shown and kept for 4 s (`miss` = never reached within 24 s).

| candidate | window | breathing | coughing | hyperv. | other | mean | min class | worst fold min | folds | latency median (Jan / ours) | mean (Jan / ours) | p90 (Jan / ours) | miss % (Jan / ours) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w100 | 8 s | 87.6 | 82.2 | 81.6 | 80.0 | 82.9 | 80.0 | 75.9 | 10 | 6.1 / 6.1 | 7.1 / 6.6 | 13.8 / 9.3 | 11 / 3 |
| w75 | 6 s | 86.2 | 81.8 | 79.3 | 77.8 | 81.3 | 77.8 | 73.6 | 10 | 5.4 / 5.4 | 6.5 / 5.6 | 12.4 / 8.6 | 10 / 3 |
| w62 | 5 s | 86.3 | 82.1 | 78.6 | 76.2 | 80.8 | 76.2 | 73.9 | 10 | 5.4 / 4.8 | 6.1 / 5.0 | 11.8 / 8.0 | 11 / 4 |
| w50 | 4 s | 86.3 | 79.8 | 78.1 | 74.2 | 79.6 | 74.2 | 72.5 | 10 | 4.8 / 4.2 | 5.9 / 4.9 | 13.1 / 8.6 | 11 / 4 |
| w100rec | 8 s + recency | 87.9 | 82.9 | 81.3 | 77.3 | 82.4 | 77.3 | 75.0 | 10 | 4.8 / 5.4 | 6.1 / 5.8 | 12.5 / 9.3 | 11 / 2 |

Median latency on our recordings by the class switched to (s):

| candidate | breathingNormally | coughing | hyperventilation | other |
|---|---|---|---|---|
| w100 | 9.0 | 6.7 | 6.1 | 4.8 |
| w75 | 7.4 | 5.4 | 5.4 | 3.5 |
| w62 | 6.1 | 4.8 | 4.8 | 3.5 |
| w50 | 5.4 | 4.2 | 4.2 | 3.5 |
| w100rec | 7.4 | 5.4 | 5.4 | 4.2 |

Pass mark: every class >= 75 %. Our recordings were never used for training in this study, so their latency (and steady accuracy) is an unseen-person test.
