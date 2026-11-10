#!/usr/bin/env bash
# Double-click me (Finder opens .command files in Terminal). Runs run_everything.sh: the PREVIOUS model pipeline (v1). The current one is pipeline_v2/RUN_PIPELINE_V2.command.
cd "$(dirname "$0")"
./run_everything.sh "$@"
echo
read -r -p "Press Enter to close this window."
