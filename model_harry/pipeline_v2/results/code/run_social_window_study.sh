#!/bin/bash
# Social window study (see social_window_study.py): CV accuracy vs. app latency for 4/5/6/8 s windows
# and a recency-trained 8 s model. Resumable. ~2-3 h on the M1 Pro. Output: pipeline_v2/social_window_study/report.md
cd "$(dirname "$0")"
PY="${PY:-$HOME/miniconda3/envs/lerobot/bin/python}"
# wait for the full report pipeline if it is still running (they would compete for the CPU)
while pgrep -f run_full_pipeline.py >/dev/null; do sleep 60; done
mkdir -p social_window_study
caffeinate -dimsu "$PY" -u social_window_study.py "$@" 2>&1 | grep --line-buffered -v -i "warning" | tee -a social_window_study/run.log
