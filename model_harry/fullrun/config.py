"""Paths, constants and the experiment plan (which jobs exist). Everything the pipeline does is defined here."""
import os
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]            # model_harry/
ROOT = HERE.parent                                     # IoT/
JAN_DIR = ROOT / "data/datasetJan2026"
FOLD_DIR = ROOT / "data/fold_assignments"
PEOPLE = {"s2503795": "Subject A (s2503795)", "s2952925": "Subject B (s2952925)"}
OUT = Path(os.environ.get("FULLRUN_OUT") or HERE / "final_run")     # smoke tests use another folder

FS = 12.5
W = {"har": 50, "social": 100}
TEST_STEP = 25                 # window step for every CV / LOPO test set (2 s), as in Lab 3 B9
REAL_TRAIN_STEP = 6            # real recordings are few -> denser windows when they are added to training
APP_STEPS = [25, 12, 6]        # update intervals offered by the app (2 s / 1 s / 0.5 s)
APP_DEFAULT_STEP = 12

FINAL = {"har": "harry_cnn", "social": "harry_rnn"}
SOCIAL_POWER = 0.6             # social class weights = balanced ** 0.6 (decided 2026-11-09)
TARGETS = {"static": 0.90, "dynamic": 0.85, "social": 0.75}

# How real data joins training (decided from the 2026-11-09 checks; LOPO re-tests every option):
#   har    : train on Jan2026, then fine-tune on the real recordings (adds stationary postures *with* coughing etc.)
#   social : mix real recordings into the Jan2026 training set (fine-tuning on one person over-fitted)
REAL_STRATEGY = {"har": "finetune", "social": "mix"}

BASELINES = {                  # architecture comparison on the official folds (Jan2026 only, seed 0)
    "har": ["her_mlp", "her_cnn", "her_lstm", "her_logreg", "harry_mlp", "harry_feat", "harry_rnn"],
    "social": ["her_mlp", "her_cnn", "her_lstm", "her_logreg", "harry_mlp", "harry_feat", "harry_cnn"],
}
POWER_SWEEP = [0.0, 0.3, 0.8, 1.0]       # + SOCIAL_POWER from the main runs
SEEDS = [0, 1, 2]
FOLDS = list(range(10))
VARIANTS = ["jan", "jan+real"]           # CV training data; jan+real is the headline (decided 2026-11-09)
HEADLINE = "jan+real"

MODEL_NAMES = {
    "harry_cnn": "Multi-branch CNN (ours)", "harry_rnn": "Conv-GRU (ours)", "harry_mlp": "Gravity-split MLP (ours)",
    "harry_feat": "Spectral-feature net (ours)", "her_mlp": "MLP (Lab 3)", "her_cnn": "CNN (Lab 3)",
    "her_lstm": "LSTM (Lab 3)", "her_logreg": "Logistic regression on statistics (Lab 3)",
    "her_cnn_bn": "CNN + BatchNorm (Lab 3)", "her_cnn_k3": "CNN kernel 3 (Lab 3)", "her_cnn_3conv": "CNN 3 conv (Lab 3)",
}
APP_FILES = {"har": "harry_har_cnn", "social": "harry_social_rnn"}   # names the app loads
