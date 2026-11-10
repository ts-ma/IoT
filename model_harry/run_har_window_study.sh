#!/bin/bash
# Activity window study (see har_window_study.py): CV accuracy vs. app latency for 2/3/4 s windows and a
# recency-trained 4 s model. Resumable. ~30-40 min on the M1 Pro. Output: results/har_window_study/report.md
cd "$(dirname "$0")"
PY="${PY:-$HOME/miniconda3/envs/lerobot/bin/python}"
# wait for the other long jobs (they would compete for the CPU)
while pgrep -f "run_full_pipeline.py|social_window_study.py" >/dev/null; do sleep 60; done
mkdir -p results/har_window_study
caffeinate -dimsu "$PY" -u har_window_study.py "$@" 2>&1 | grep --line-buffered -v -i "warning" | tee -a results/har_window_study/run.log
