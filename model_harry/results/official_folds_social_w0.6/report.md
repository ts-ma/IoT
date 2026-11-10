# Official-fold evaluation: HAR `harry_cnn`, Social `harry_rnn`

Generated 2026-11-09 09:52 by `model_harry/eval_official_folds.py`. All numbers are %.
Targets (CW3): static ≥ 90, dynamic ≥ 85, every social class ≥ 75.
Social class weights: balanced^0.6 (1 = fully balanced).

## Part 1 – official 10-fold CV (how the models are marked)

Folds run: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] · total compute 2.3 h. Each fold trains the architecture from scratch on the other folds. *Fold mean* = mean over folds of per-class recall (as Lab 3 B9); *pooled* = all test windows together.

### HAR (harry_cnn)

| | sittingStanding | lyingBack | lyingLeft | lyingRight | lyingStomach | normalWalking | shuffleWalking | ascending | descending | running | miscMovement | STATIC | DYNAMIC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fold mean | 97.4 | 99.4 | 100.0 | 100.0 | 99.6 | 89.5 | 88.2 | 94.0 | 92.8 | 96.7 | 81.6 | **99.3** | **90.5** |
| pooled | 97.3 | 99.4 | 100.0 | 100.0 | 99.6 | 89.4 | 88.2 | 94.0 | 92.8 | 96.7 | 81.7 | 99.3 | 90.5 |

Per fold (static / dynamic): 0: 99.9/88.4, 1: 99.3/90.9, 2: 100.0/89.7, 3: 100.0/87.0, 4: 100.0/92.0, 5: 98.5/89.8, 6: 98.6/90.0, 7: 98.6/90.6, 8: 100.0/93.5, 9: 97.9/92.8

### Social (harry_rnn) and the stationary gate

| | | breathingNormally | coughing | hyperventilation | other | BALANCED | MIN |
|---|---|---|---|---|---|---|---|
| fold mean | no gate (graded number) | 87.2 | 82.3 | 80.8 | 80.3 | 82.7 | 80.3 |
| fold mean | gate = not moving, end-to-end | 86.2 | 54.5 | 74.0 | 75.1 | 72.4 | 54.5 |
| fold mean |   …share of windows enabled | 98.5 | 67.4 | 91.2 | 92.3 | 87.4 | 67.4 |
| fold mean |   …recall when shown | 87.5 | 80.8 | 81.1 | 81.3 | 82.7 | 80.8 |
| fold mean | gate = sitting/standing only, end-to-end | 27.2 | 6.7 | 21.1 | 27.4 | 20.6 | 6.7 |
| fold mean |   …share of windows enabled | 32.8 | 9.1 | 24.9 | 33.2 | 25.0 | 9.1 |
| fold mean |   …recall when shown | 82.9 | 74.6 | 84.5 | 82.5 | 81.1 | 74.6 |

Per fold, no gate (balanced / weakest class): 0: 80.2/77.8, 1: 82.5/78.1, 2: 80.9/76.5, 3: 84.2/79.3, 4: 82.9/79.1, 5: 83.5/80.0, 6: 85.0/79.9, 7: 82.8/79.9, 8: 82.1/77.1, 9: 82.4/78.5

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
breathingNormally              10970        19               185   1399
coughing                           7      9536               643   1400
hyperventilation                 503       679              9823   1148
other                           3915      2510              1521  32359
```

## How to read the gate rows

- **no gate**: the social model alone on every social test window. This is what the marking scores.
- **end-to-end**: what the user sees. A window where HAR says *moving* (or, for the strict gate, anything but sitting/standing) shows no social result and counts as a miss.
- **share enabled**: how often the gate let social run. Social data is all stationary, so ideally 100 for the *not moving* gate. For the *sitting/standing* gate it is roughly the share of recordings made sitting or standing.
- **recall when shown**: accuracy of the social results the user actually sees.
