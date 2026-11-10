# Code that produced these results (snapshot)

Folder layout of the original: `model_harry/pipeline_v2/` (this code, `cache/`, `social_window_study/`, `results/`, `models/`); the model library `harry/` is shared with the previous pipeline in `model_harry/harry/`.

| file | role |
|---|---|
| `run_pipeline_v2.py` | orchestrator: decisions, activity check, jobs, analysis, figures, write-up, knowledge base |
| `fullrun2/config.py` | every constant and frozen decision (windows, folds of the group members, seeds, targets) |
| `fullrun2/data.py` | reading recordings, label mapping, fold selection, windowing, data audit |
| `fullrun2/jobs.py` | the job plan (which models are trained on what) and the worker that trains / tests / exports |
| `fullrun2/analyze.py` | scoring every job (scopes, per-class recall, metrics, statistics) into tables |
| `fullrun2/plots.py`, `writeup.py`, `knowledge.py` | figures, WRITEUP.md, this knowledge base |
| `harry/zoo.py` | the four architectures (`build`) |
| `harry/layers.py` | in-model preprocessing layers (gravity, dynamic channels, band power, log-std) |
| `harry/augment.py` | training-time augmentation layer |
| `harry/runner.py` | training recipe (`RECIPES`) and the fit loop (`_fit`, class weights) |
| `harry/export.py` | TFLite export + Keras/TFLite parity check + app metadata |
| `harry/metrics.py` | per-class recall and group scores |
| `social_window_study.py` | the study that chose the social window (accuracy vs latency) |
| `app_latency_sim.py` | replay of the app's live logic (packets, step, smoothing, social pause) |
