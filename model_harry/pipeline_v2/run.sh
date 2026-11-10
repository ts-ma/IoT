#!/usr/bin/env bash
# Pipeline v2: everything the report needs about Harry's models, in one go. Double-click RUN_PIPELINE_V2.command
# (it runs this file in Terminal), or run ./run.sh [options] inside model_harry/pipeline_v2/.
#
#   ./run.sh               full run -> results/ and models/ (resumes if stopped: finished jobs are kept)
#   ./run.sh --smoke       end-to-end test -> results_smoke/, models_smoke/
#   ./run.sh --report-only rebuild tables, figures, write-up and knowledge base from the jobs finished so far
#   PY=/path/to/python ./run.sh   use a specific Python (needs tensorflow, pandas, scikit-learn, scipy, matplotlib)
#
# Needs social_window_study/ (./run_social_window_study.sh) to choose the social window; waits for it if it is running.
# Start with results/KNOWLEDGE.md. Figures: results/index.html. Models: models/ (not copied into the app).
set -uo pipefail
cd "$(dirname "$0")"

if [[ -z "${PY:-}" ]]; then
  for c in ../.venv/bin/python "$HOME/miniconda3/envs/lerobot/bin/python" python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import tensorflow, pandas, sklearn, scipy, matplotlib" >/dev/null 2>&1; then
      PY="$c"; break
    fi
  done
fi
if [[ -z "${PY:-}" ]]; then
  echo "No Python with tensorflow, pandas, scikit-learn, scipy and matplotlib found." >&2
  echo "Create one (in model_harry/):  python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi
echo "Python: $PY"
echo "Started $(date). Progress is printed below and saved in results/run.log. Closing this window stops the run;"
echo "running it again continues where it stopped."
caffeinate -dimsu "$PY" -u run_pipeline_v2.py "$@" 2>&1 | grep --line-buffered -v -E "WARNING|warnings.warn|XNNPACK|oneDNN"
status=${PIPESTATUS[0]}
echo
if [[ $status -eq 0 ]]; then echo "Finished $(date)."; else echo "Stopped with an error (exit $status) - see results/run.log."; fi
