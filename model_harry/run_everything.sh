#!/usr/bin/env bash
# PREVIOUS pipeline (v1, finished 2026-11-09): everything about the models in one go (~8-10 h on an M1 Pro).
# The current pipeline is model_harry/pipeline_v2/ (double-click pipeline_v2/RUN_PIPELINE_V2.command).
#
#   ./run_everything.sh               full run -> final_run/ (resumes if stopped: finished jobs are kept)
#   ./run_everything.sh --smoke       5-10 min end-to-end test -> final_run_smoke/
#   ./run_everything.sh --report-only rebuild tables, figures and the write-up from the jobs finished so far
#   PY=/path/to/python ./run_everything.sh   use a specific Python (needs tensorflow, pandas, scikit-learn, scipy, matplotlib)
#
# Results: final_run/WRITEUP.md, final_run/index.html (all figures), final_run/tables/*.csv,
#          final_run/final_models/ (app-ready .tflite), final_run/run.log. The Mac is kept awake until it ends.
set -uo pipefail
cd "$(dirname "$0")"

if [[ -z "${PY:-}" ]]; then
  for c in .venv/bin/python "$HOME/miniconda3/envs/lerobot/bin/python" python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import tensorflow, pandas, sklearn, scipy, matplotlib" >/dev/null 2>&1; then
      PY="$c"; break
    fi
  done
fi
if [[ -z "${PY:-}" ]]; then
  echo "No Python with tensorflow, pandas, scikit-learn, scipy and matplotlib found." >&2
  echo "Create one:  python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi
echo "Python: $PY"
echo "Started $(date). Progress is printed below and saved in final_run/run.log. Closing this window stops the run;"
echo "running it again continues where it stopped."
caffeinate -dimsu "$PY" -u run_full_pipeline.py "$@" 2>&1 | grep --line-buffered -v -E "WARNING|warnings.warn|XNNPACK|oneDNN"
status=${PIPESTATUS[0]}
echo
if [[ $status -eq 0 ]]; then echo "Finished $(date)."; else echo "Stopped with an error (exit $status) - see final_run/run.log."; fi
