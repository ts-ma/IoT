# Social recipe on real people (unseen by training)

Generated 2026-11-09 10:02 by `model_harry/eval_real_people.py`. All numbers are %.
Each model: harry_rnn trained on **all listed datasetJan2026 social recordings** (Jan recipe, 32 epochs), class weights balanced^power. Test: each person's stationary recordings, a result every 12 samples (as the app), no smoothing. Gate = social only when the app's HAR model says not moving (that HAR model was fine-tuned on s2503795, so the gate is optimistic for s2503795).

| person | postures | weights | breathingNormally | coughing | hyperventilation | other | BALANCED | MIN | gated BALANCED |
|---|---|---|---|---|---|---|---|---|---|
| s2503795 | all stationary | balanced^1 | 93.5 | 98.6 | 95.7 | 83.3 | **92.7** | 83.3 | 92.7 |
| s2503795 | sitting/standing | balanced^1 | 87.0 | 95.7 | 87.0 | 83.7 | **88.3** | 83.7 | 88.3 |
| s2503795 | lying | balanced^1 | 96.7 | 100.0 | 100.0 | 83.0 | **94.9** | 83.0 | 94.9 |
| s2503795 | all stationary | balanced^0.6 | 94.2 | 96.4 | 98.6 | 91.1 | **95.1** | 91.1 | 95.1 |
| s2503795 | sitting/standing | balanced^0.6 | 82.6 | 95.7 | 95.7 | 89.7 | **90.9** | 82.6 | 90.9 |
| s2503795 | lying | balanced^0.6 | 100.0 | 96.7 | 100.0 | 92.0 | **97.2** | 92.0 | 97.2 |
| s2952925 | all stationary | balanced^1 | 100.0 | 100.0 | 97.9 | 78.4 | **94.1** | 78.4 | 93.9 |
| s2952925 | sitting/standing | balanced^1 | 100.0 | 100.0 | 100.0 | 70.2 | **92.5** | 70.2 | 92.0 |
| s2952925 | lying | balanced^1 | 100.0 | 100.0 | 96.7 | 84.1 | **95.2** | 84.1 | 95.2 |
| s2952925 | all stationary | balanced^0.6 | 100.0 | 97.8 | 78.6 | 81.8 | **89.6** | 78.6 | 89.4 |
| s2952925 | sitting/standing | balanced^0.6 | 100.0 | 93.6 | 100.0 | 71.7 | **91.3** | 71.7 | 90.8 |
| s2952925 | lying | balanced^0.6 | 100.0 | 100.0 | 67.4 | 88.8 | **89.0** | 67.4 | 89.0 |
