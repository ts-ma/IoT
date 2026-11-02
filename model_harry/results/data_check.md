# Real-data check (G5.1)

Recordings: 44 · subjects: ['s2503795']

- Exact duplicate recordings: **0**
- Lengths (samples): min 375, max 375

| file | posture | mean X | mean Y | mean Z | dominant ok |
|---|---|---|---|---|---|
| LyingDownBack_Coughing_05-10-2026_1 | back | -0.44 | -0.36 | +0.77 | yes |
| LyingDownBack_Hyperventilating_05-1 | back | -0.36 | -0.39 | +0.79 | yes |
| LyingDownBack_Laughing_05-10-2026_1 | back | -0.47 | -0.30 | +0.77 | yes |
| LyingDownBack_Normal_05-10-2026_14- | back | -0.46 | -0.39 | +0.75 | yes |
| LyingDownBack_Singing_05-10-2026_16 | back | -0.53 | -0.35 | +0.73 | yes |
| LyingDownBack_Talking_05-10-2026_15 | back | -0.47 | -0.43 | +0.72 | yes |
| LyingDownLeft_Coughing_05-10-2026_1 | left | -0.88 | -0.24 | -0.51 | yes |
| LyingDownLeft_Hyperventilating_05-1 | left | -0.89 | -0.23 | -0.51 | yes |
| LyingDownLeft_Laughing_05-10-2026_1 | left | -0.95 | -0.13 | -0.42 | yes |
| LyingDownLeft_Normal_05-10-2026_14- | left | -0.95 | -0.16 | -0.42 | yes |
| LyingDownLeft_Singing_05-10-2026_16 | left | -0.96 | -0.11 | -0.42 | yes |
| LyingDownLeft_Talking_05-10-2026_15 | left | -0.96 | -0.08 | -0.42 | yes |
| LyingDownRight_Coughing_05-10-2026_ | right | +0.91 | +0.19 | +0.08 | yes |
| LyingDownRight_Hyperventilating_05- | right | +0.90 | +0.15 | +0.17 | yes |
| LyingDownRight_Laughing_05-10-2026_ | right | +0.87 | +0.01 | +0.33 | yes |
| LyingDownRight_Normal_05-10-2026_14 | right | +0.75 | -0.04 | +0.53 | yes |
| LyingDownRight_Singing_05-10-2026_1 | right | +0.81 | -0.03 | +0.43 | yes |
| LyingDownRight_Talking_05-10-2026_1 | right | +0.90 | +0.02 | +0.24 | yes |
| LyingDownStomach_Coughing_05-10-202 | stomach | +0.34 | +0.21 | -0.93 | yes |
| LyingDownStomach_Hyperventilating_0 | stomach | +0.28 | +0.23 | -0.95 | yes |
| LyingDownStomach_Laughing_05-10-202 | stomach | +0.30 | +0.20 | -0.95 | yes |
| LyingDownStomach_Normal_05-10-2026_ | stomach | +0.06 | +0.28 | -0.99 | yes |
| LyingDownStomach_Singing_05-10-2026 | stomach | +0.27 | +0.28 | -0.94 | yes |
| LyingDownStomach_Talking_05-10-2026 | stomach | +0.22 | +0.26 | -0.96 | yes |
| Sitting_Coughing_05-10-2026_15-08-5 | sitting | -0.06 | -1.03 | -0.01 | yes |
| Sitting_Eating_05-10-2026_14-49-56. | sitting | +0.24 | -0.95 | -0.31 | yes |
| Sitting_Hyperventilating_05-10-2026 | sitting | -0.04 | -1.03 | -0.02 | yes |
| Sitting_Laughing_05-10-2026_15-17-0 | sitting | -0.08 | -1.02 | +0.04 | yes |
| Sitting_Normal_05-10-2026_14-27-10. | sitting | +0.21 | -0.99 | -0.13 | yes |
| Sitting_Singing_05-10-2026_16-32-09 | sitting | +0.05 | -1.02 | +0.04 | yes |
| Sitting_Talking_05-10-2026_15-14-21 | sitting | -0.09 | -1.03 | +0.01 | yes |
| Standing_Coughing_05-10-2026_15-19- | standing | +0.01 | -1.02 | -0.11 | yes |
| Standing_Eating_05-10-2026_14-06-56 | standing | -0.14 | -1.02 | -0.07 | yes |
| Standing_Hyperventilating_05-10-202 | standing | +0.07 | -1.00 | -0.27 | yes |
| Standing_Laughing_05-10-2026_14-10- | standing | -0.03 | -1.03 | +0.01 | yes |
| Standing_Normal_05-10-2026_14-16-26 | standing | -0.02 | -1.03 | -0.07 | yes |
| Standing_Singing_05-10-2026_16-34-0 | standing | -0.08 | -1.03 | -0.01 | yes |
| Standing_Talking_05-10-2026_14-13-0 | standing | -0.03 | -1.03 | -0.10 | yes |

## Label counts

HAR recordings: sittingStanding=14, lyingBack=6, lyingLeft=6, lyingRight=6, lyingStomach=6, normalWalking=1, shuffleWalking=1, ascending=1, descending=1, running=1, miscMovement=1

Social recordings: breathingNormally=6, coughing=6, hyperventilation=6, other=20

## har folds (window 50, train step 25 / test step 12)

| fold | train windows | test windows | classes missing in test | classes missing in train |
|---|---|---|---|---|
| block/behaviour=0 | 514 | 186 | - | - |
| block/behaviour=1 | 508 | 186 | - | - |
| block/behaviour=2 | 508 | 186 | - | - |
| block/behaviour=3 | 480 | 242 | - | - |
| block/behaviour=4 | 430 | 354 | - | - |

## social folds (window 50, train step 25 / test step 12)

| fold | train windows | test windows | classes missing in test | classes missing in train |
|---|---|---|---|---|
| posture=sitting | 434 | 196 | - | - |
| posture=standing | 434 | 196 | - | - |
| posture=back | 448 | 168 | - | - |
| posture=left | 448 | 168 | - | - |
| posture=right | 448 | 168 | - | - |
| posture=stomach | 448 | 168 | - | - |
