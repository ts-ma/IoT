# Pipeline v2 — Harry's models, all data in the folds

Everything of this pipeline lives in this folder; nothing here is shared with the previous run (`../final_run/`) except
the read-only model library `../harry/` and the raw data in `IoT/data/`.

**Double-click `RUN_PIPELINE_V2.command`** (or `./run.sh`; `--smoke` for a quick test, `--report-only` to rebuild the
reports). Resumable: running it again continues where it stopped.

| folder / file | what |
|---|---|
| `results/KNOWLEDGE.md` | **start here**: the whole project (data, method, CV, decisions and reasons, history, results, question → file map) |
| `results/WRITEUP.md`, `results/index.html` | long-form report text; figure gallery |
| `results/tables/` (+ `README.md`) | every number; data dictionary |
| `results/figures/` | every figure, PNG + PDF |
| `results/jobs/` | every training/testing job: settings, per-epoch history, test predictions, logs, per-fold Keras models |
| `results/history/`, `results/context/`, `results/code/` | earlier experiments (Harry's models), CW3 brief, window study, code snapshot |
| `models/` | **the exported app models** (`harry_har_cnn.*`, `harry_social_rnn.*`, `INSTALL.md`) — not copied into the app |
| `social_window_study/` | how the social window was chosen (accuracy vs app latency); `./run_social_window_study.sh` |
| `cache/` | the recordings packed for fast loading (rebuilt from `IoT/data/` if deleted) |
| `run_pipeline_v2.py`, `fullrun2/` | the pipeline code |
| `social_window_study.py`, `app_latency_sim.py` | the window study and the app-latency replay |

What it does, step by step: see the docstring of `run_pipeline_v2.py` and `results/KNOWLEDGE.md` §6.
