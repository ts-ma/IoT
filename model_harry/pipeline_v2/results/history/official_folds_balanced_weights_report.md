# Official-fold evaluation: HAR `harry_cnn`, Social `harry_rnn`

Generated 2026-11-09 09:10 by `model_harry/eval_official_folds.py`. All numbers are %.
Targets (CW3): static ≥ 90, dynamic ≥ 85, every social class ≥ 75.

## Part 1 – official 10-fold CV (how the models are marked)

Folds run: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] · total compute 2.2 h. Each fold trains the architecture from scratch on the other folds. *Fold mean* = mean over folds of per-class recall (as Lab 3 B9); *pooled* = all test windows together.

### HAR (harry_cnn)

| | sittingStanding | lyingBack | lyingLeft | lyingRight | lyingStomach | normalWalking | shuffleWalking | ascending | descending | running | miscMovement | STATIC | DYNAMIC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fold mean | 97.4 | 99.4 | 100.0 | 100.0 | 99.6 | 89.5 | 88.2 | 94.0 | 92.8 | 96.7 | 81.6 | **99.3** | **90.5** |
| pooled | 97.3 | 99.4 | 100.0 | 100.0 | 99.6 | 89.4 | 88.2 | 94.0 | 92.8 | 96.7 | 81.7 | 99.3 | 90.5 |

Per fold (static / dynamic): 0: 99.9/88.4, 1: 99.3/90.9, 2: 100.0/89.7, 3: 100.0/87.0, 4: 100.0/92.0, 5: 98.5/89.8, 6: 98.6/90.0, 7: 98.6/90.6, 8: 100.0/93.5, 9: 97.9/92.8

### Social (harry_rnn) and the stationary gate

| | | breathingNormally | coughing | hyperventilation | other | BALANCED | MIN |
|---|---|---|---|---|---|---|---|
| fold mean | no gate (graded number) | 90.3 | 85.5 | 82.7 | 73.0 | 82.9 | 73.0 |
| fold mean | gate = not moving, end-to-end | 89.3 | 56.9 | 75.9 | 68.3 | 72.6 | 56.9 |
| fold mean |   …share of windows enabled | 98.5 | 67.4 | 91.2 | 92.3 | 87.4 | 67.4 |
| fold mean |   …recall when shown | 90.7 | 84.3 | 83.2 | 74.0 | 83.1 | 74.0 |
| fold mean | gate = sitting/standing only, end-to-end | 28.8 | 7.2 | 21.8 | 25.2 | 20.7 | 7.2 |
| fold mean |   …share of windows enabled | 32.8 | 9.1 | 24.9 | 33.2 | 25.0 | 9.1 |
| fold mean |   …recall when shown | 87.8 | 79.2 | 87.5 | 76.0 | 82.6 | 76.0 |

Per fold, no gate (balanced / weakest class): 0: 80.3/75.3, 1: 83.4/71.2, 2: 82.0/71.2, 3: 84.1/71.6, 4: 82.8/74.7, 5: 83.7/72.3, 6: 85.4/74.5, 7: 83.0/74.5, 8: 82.3/74.1, 9: 81.7/70.2

### Social would wrongly run while moving (HAR calls a dynamic window static)

| normalWalking | shuffleWalking | ascending | descending | running | miscMovement | all dynamic |
|---|---|---|---|---|---|---|
| 0.0 | 0.0 | 0.0 | 0.1 | 0.0 | 1.9 | 0.3 |

### Confusion matrices (pooled windows)

HAR:

```
pred             sittingStanding  lyingBack  lyingLeft  lyingRight  lyingStomach  normalWalking  shuffleWalking  ascending  descending  running  miscMovement
true                                                                                                                                                         
sittingStanding             4702          7          2           0            11             12              15          0           0        0            85
lyingBack                     12       2137          0           0             0              0               0          0           0        0             0
lyingLeft                      0          0       1621           0             0              0               0          0           0        0             0
lyingRight                     0          0          0        1561             0              0               0          0           0        0             0
lyingStomach                   0          0          9           0          2378              0               1          0           0        0             0
normalWalking                  1          0          0           0             0           2059             115         37          33        1            58
shuffleWalking                 0          0          0           0             0             96            2005          4          48       36            84
ascending                      0          0          0           0             0             40               9       2132          68        0            19
descending                     1          0          0           0             0             24              26         35        1878       12            47
running                        0          0          0           0             0              0              24          2          15     2247            36
miscMovement                  39          0          0           0             4             29             246         18          19       61          1853
```

Social (no gate):

```
pred               breathingNormally  coughing  hyperventilation  other
true                                                                   
breathingNormally              11359        34               225    955
coughing                          16      9910               727    933
hyperventilation                 543       769             10048    793
other                           5433      3319              2147  29406
```

## Part 2 – exported models on an unseen person (s2952925)

The `.tflite` files (trained on all of Jan2026 + Harry's recordings) streamed like the app: a result every 12 samples, raw (no smoothing).

| sittingStanding | lyingBack | lyingLeft | lyingRight | lyingStomach | normalWalking | shuffleWalking | ascending | descending | running | miscMovement | STATIC | DYNAMIC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 99.7 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 96.4 | 100.0 | 100.0 | 100.0 | 92.6 | **99.9** | **98.2** |

Social would wrongly run while moving: 0.0 of dynamic results (normalWalking 0.0, shuffleWalking 0.0, ascending 0.0, descending 0.0, running 0.0, miscMovement 0.0).

| postures | | breathingNormally | coughing | hyperventilation | other | BALANCED | MIN |
|---|---|---|---|---|---|---|---|
| all stationary | no gate (graded number) | 84.3 | 66.9 | 78.6 | 76.9 | 76.7 | 66.9 |
| all stationary | gate = not moving, end-to-end | 84.3 | 66.9 | 77.9 | 76.9 | 76.5 | 66.9 |
| all stationary |   …share of windows enabled | 100.0 | 100.0 | 99.3 | 100.0 | 99.8 | 99.3 |
| all stationary |   …recall when shown | 84.3 | 66.9 | 78.4 | 76.9 | 76.6 | 66.9 |
| all stationary | gate = sitting/standing only, end-to-end | 34.3 | 18.0 | 26.4 | 28.5 | 26.8 | 18.0 |
| all stationary |   …share of windows enabled | 34.3 | 33.8 | 33.6 | 40.9 | 35.6 | 33.6 |
| all stationary |   …recall when shown | 100.0 | 53.2 | 78.7 | 69.6 | 75.4 | 53.2 |
| sitting/standing | no gate (graded number) | 100.0 | 53.2 | 79.2 | 69.6 | 75.5 | 53.2 |
| sitting/standing | gate = not moving, end-to-end | 100.0 | 53.2 | 77.1 | 69.6 | 75.0 | 53.2 |
| sitting/standing |   …share of windows enabled | 100.0 | 100.0 | 97.9 | 100.0 | 99.5 | 97.9 |
| sitting/standing |   …recall when shown | 100.0 | 53.2 | 78.7 | 69.6 | 75.4 | 53.2 |
| sitting/standing | gate = sitting/standing only, end-to-end | 100.0 | 53.2 | 77.1 | 69.6 | 75.0 | 53.2 |
| sitting/standing |   …share of windows enabled | 100.0 | 100.0 | 97.9 | 100.0 | 99.5 | 97.9 |
| sitting/standing |   …recall when shown | 100.0 | 53.2 | 78.7 | 69.6 | 75.4 | 53.2 |
| lying | no gate (graded number) | 76.1 | 73.9 | 78.3 | 81.9 | 77.5 | 73.9 |
| lying | gate = not moving, end-to-end | 76.1 | 73.9 | 78.3 | 81.9 | 77.5 | 73.9 |
| lying |   …share of windows enabled | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 |
| lying |   …recall when shown | 76.1 | 73.9 | 78.3 | 81.9 | 77.5 | 73.9 |
| lying | gate = sitting/standing only, end-to-end | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| lying |   …share of windows enabled | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| lying |   …recall when shown | – | – | – | – | – | – |

## How to read the gate rows

- **no gate**: the social model alone on every social test window. This is what the marking scores.
- **end-to-end**: what the user sees. A window where HAR says *moving* (or, for the strict gate, anything but sitting/standing) shows no social result and counts as a miss.
- **share enabled**: how often the gate let social run. Social data is all stationary, so ideally 100 for the *not moving* gate. For the *sitting/standing* gate it is roughly the share of recordings made sitting or standing.
- **recall when shown**: accuracy of the social results the user actually sees.
