#!/usr/bin/env bash
# Official-fold evaluation of the recommended models (HAR harry_cnn, Social harry_rnn) with the
# "social only when stationary" gate. Details: eval_official_folds.py (top of file).
#
#   ./run_official_eval.sh                 full run: 10 folds x 32 epochs (~1 h on an M1 Pro, 8 cores)
#   ./run_official_eval.sh --folds 0-4     only some folds (re-run later with 0-9: finished folds are kept)
#   ./run_official_eval.sh --skip-cv       only part 2: the exported .tflite files on data/s2952925 (seconds)
#   ./run_official_eval.sh --workers 3     more parallel training processes
#   PY=/path/to/python ./run_official_eval.sh   use a specific Python (needs tensorflow, pandas, scikit-learn)
#
# Output: results/official_folds/report.md (+ summary.json, folds/*.log). Ctrl-C stops; running again resumes.
# The Mac is kept awake (caffeinate) until the run ends.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${PY:-}" ]]; then
  for c in .venv/bin/python "$HOME/miniconda3/envs/lerobot/bin/python" python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import tensorflow, pandas, sklearn" >/dev/null 2>&1; then
      PY="$c"; break
    fi
  done
fi
if [[ -z "${PY:-}" ]]; then
  echo "No Python with tensorflow + pandas + scikit-learn found." >&2
  echo "Create one:  python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi
echo "Python: $PY"

mkdir -p results/official_folds
caffeinate -i "$PY" eval_official_folds.py "$@" 2>&1 | grep --line-buffered -v -E "WARNING|warnings.warn|XNNPACK" \
  | tee -a results/official_folds/run.log
