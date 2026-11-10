# HAR on real people

Generated 2026-11-09 10:09 by `model_harry/eval_real_people_har.py`. All numbers are %.
**Jan2026 only**: harry_cnn trained on all listed datasetJan2026 daily_activity recordings (Jan recipe, 32 epochs); no real data in training, so both people are unseen. **Shipped**: the app's model, fine-tuned on s2503795 (its s2503795 numbers are not a fair test). A result every 12 samples from the last 4 s, no smoothing.

| person | model | sittingStanding | lyingBack | lyingLeft | lyingRight | lyingStomach | normalWalking | shuffleWalking | ascending | descending | running | miscMovement | STATIC | DYNAMIC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| s2503795 | Jan2026 only (new) | 92.6 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 89.3 | **98.5** | **98.2** |
| s2503795 | shipped (Jan + s2503795 fine-tune) | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | **100.0** | **100.0** |
| s2952925 | Jan2026 only (new) | 88.7 | 100.0 | 96.3 | 100.0 | 100.0 | 100.0 | 85.7 | 100.0 | 100.0 | 100.0 | 96.3 | **97.0** | **97.0** |
| s2952925 | shipped (Jan + s2503795 fine-tune) | 99.7 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 96.4 | 100.0 | 100.0 | 100.0 | 92.6 | **99.9** | **98.2** |

## The "social only when stationary" rule

*Social hidden*: stationary windows that HAR calls moving (the social result would be hidden), by what the person was doing. *Social leaks*: moving windows that HAR calls stationary.

| person | model | hidden: breathingNormally | hidden: coughing | hidden: hyperventilation | hidden: other | leaks: moving |
|---|---|---|---|---|---|---|
| s2503795 | Jan2026 only (new) | 0.0 | 10.1 | 5.4 | 0.5 | 0.6 |
| s2503795 | shipped (Jan + s2503795 fine-tune) | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| s2952925 | Jan2026 only (new) | 0.0 | 5.5 | 17.7 | 2.2 | 0.0 |
| s2952925 | shipped (Jan + s2503795 fine-tune) | 0.0 | 0.0 | 0.6 | 0.0 | 0.0 |

## Most common mistakes (windows)

- s2503795, Jan2026 only (new): sittingStanding → shuffleWalking (17), sittingStanding → normalWalking (11), miscMovement → normalWalking (2), miscMovement → lyingLeft (1), sittingStanding → miscMovement (1)
- s2503795, shipped (Jan + s2503795 fine-tune): none
- s2952925, Jan2026 only (new): sittingStanding → normalWalking (25), sittingStanding → shuffleWalking (19), lyingLeft → miscMovement (6), shuffleWalking → descending (4), miscMovement → running (1)
- s2952925, shipped (Jan + s2503795 fine-tune): miscMovement → running (2), shuffleWalking → descending (1), sittingStanding → normalWalking (1)
