#!/usr/bin/env bash
# Double-click me (Finder opens .command files in Terminal). Runs run.sh: pipeline v2 (Harry's four models, all data in
# the folds). Results: results/ (start with results/KNOWLEDGE.md), exported models: models/.
cd "$(dirname "$0")"
./run.sh "$@"
echo
read -r -p "Press Enter to close this window."
