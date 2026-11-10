"""Paths, constants and decisions of the v2 pipeline (decided with Harry, 2026-11-09):

  * only Harry's four architectures are trained: multi-branch CNN, Conv-GRU, gravity-split MLP, spectral-feature net
  * ONE way of using the data: datasetJan2026 + both group members, mixed together, and the group members take part in
    the folds as two extra subjects (each person's recordings form part of one test fold, never of its training set)
  * every result is scored on all test windows of a fold (headline) and on its datasetJan2026 windows only (= the
    number the CW3 marking computes); each group member's fold gives the unseen-person result
  * social window: the fastest candidate of results/social_window_study whose every class keeps >= 77 % (fold mean)
  * activity: the 'mixed' recipe, checked once: if its datasetJan2026 dynamic mean falls below 85 %, activities are
    trained on datasetJan2026 only (the group members stay in the test folds)

Decisions that depend on data or results are frozen in <OUT>/decisions.json the first time they are made, so a
resumed run keeps using the same ones.
"""
import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]            # model_harry/pipeline_v2/  (everything of v2 lives here)
LIB = HERE.parent                                      # model_harry/  (shared model library harry/, v1 outputs for history)
ROOT = LIB.parent                                      # IoT/  (data/)
JAN_DIR = ROOT / "data/datasetJan2026"
FOLD_DIR = ROOT / "data/fold_assignments"
PEOPLE = {"s2503795": "Subject A (s2503795)", "s2952925": "Subject B (s2952925)"}
OUT = Path(os.environ.get("FULLRUN_OUT") or HERE / "results")          # results, figures, tables, jobs, knowledge base
MODELS = Path(os.environ.get("FULLRUN_MODELS") or HERE / "models")     # exported app models
CACHE_SRC = HERE / "cache"                             # v2's own signal cache (built from IoT/data if missing)
STUDY = HERE / "social_window_study"                   # the social window study (accuracy vs latency)
STUDY_OLD = LIB / "results" / "social_window_study"    # where the first run of the study wrote (copied in once)

FS = 12.5
TEST_STEP = 25                 # window step of every test set (2 s), as in Lab 3 B9
REAL_TRAIN_STEP = 6            # group recordings are few -> denser windows when they are used for training
APP_STEPS = [25, 12, 6]
APP_DEFAULT_STEP = 6

ARCHS = {                      # Harry's four architectures; the first one per task is deployed
    "har": ["harry_cnn", "harry_rnn", "harry_mlp", "harry_feat"],
    "social": ["harry_rnn", "harry_cnn", "harry_mlp", "harry_feat"],
}
FINAL = {t: a[0] for t, a in ARCHS.items()}
SOCIAL_POWER = 0.6             # social class weights = balanced ** 0.6
POWER_SWEEP = [0.0, 0.3, 0.8, 1.0]
TARGETS = {"static": 0.90, "dynamic": 0.85, "social": 0.75}
MIN_CLASS_RULE = 0.77          # social window choice: every class >= 77 % (2 points above the mark)
SEEDS = [0, 1, 2]
FOLDS = list(range(10))

# Scoring scopes of every CV job (stored in the 'variant' column of the tables):
SCOPES = ["all", "jan"]        # + "group" and one per person
HEADLINE = "all"
SCOPE_LABEL = {"all": "all test windows (Jan2026 + group)", "jan": "Jan2026 test windows (as marked)",
               "group": "group members' test windows", **{p: f"{lab} test windows" for p, lab in PEOPLE.items()}}

MODEL_NAMES = {
    "harry_cnn": "Multi-branch CNN", "harry_rnn": "Conv-GRU", "harry_mlp": "Gravity-split MLP",
    "harry_feat": "Spectral-feature net",
}
APP_FILES = {"har": "harry_har_cnn", "social": "harry_social_rnn"}   # names the app loads

# ───────────────────────── frozen decisions (written by run_pipeline_v2.py)
DECISIONS = OUT / "decisions.json"
W = {"har": 50, "social": 100}
SOCIAL_RECENCY = False
SOCIAL_CANDIDATE = "w100"
HAR_RECIPE = "mixed"
PERSON_FOLD = {}


def apply_decisions():
    global SOCIAL_RECENCY, SOCIAL_CANDIDATE, HAR_RECIPE, PERSON_FOLD
    if not DECISIONS.exists():
        return {}
    d = json.loads(DECISIONS.read_text())
    if "social" in d:
        W["social"] = int(d["social"]["window"])
        SOCIAL_RECENCY = bool(d["social"]["recency"])
        SOCIAL_CANDIDATE = d["social"]["candidate"]
    HAR_RECIPE = d.get("har_recipe", HAR_RECIPE)
    PERSON_FOLD = d.get("person_fold", PERSON_FOLD)
    return d


def recipe(task):
    """'mixed' = group members' training-fold recordings added to datasetJan2026; 'jan' = datasetJan2026 only."""
    return HAR_RECIPE if task == "har" else "mixed"


apply_decisions()
