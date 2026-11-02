# model_harry

Harry's rework of the HAR and social-signal models. It is trained on the **real** recordings in `IoT/data/`.
The teammate's `model/` folder and `Lab3_trained.ipynb` are not modified.

- `PLAN.md`: every problem found in the original models, the correction goals, the TODO checklist and the
  progress log.
- `RESULTS.md`: comparison against the original models, with conclusions and limitations.

## Layout
```
harry/data.py      real-data loader, labels, CV fold schemes, datasetJan2026 check-set loader
harry/layers.py    TFLite-safe in-model preprocessing (gravity split, |x|, jerk, fixed-DFT band power)
harry/models.py    teammate CNN replica (control) + multi-branch models; CANDIDATES list
harry/train.py     training recipes (teammate vs harry) + per-epoch augmentation
harry/metrics.py   per-class recall, static/dynamic/social group means (mirrors the CW3 marking)
harry/cv.py        CV runner, rotation-robustness probe
harry/export.py    TFLite export in the Lab 4 contract (+ _meta.json, _example.json), TFLite runner
check_data.py      data and fold sanity checks          -> results/data_check.md
run_cv.py          CV for every candidate x 3 seeds     -> results/cv_<task>.json
train_final.py     select best candidate, train on all real data, export -> models/harry_<task>.tflite
compare.py         her .tflite vs mine on the real CV folds + datasetJan2026 casual check -> results/tables.md
```

## Reproduce
```bash
cd model_harry
python3.13 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python check_data.py
.venv/bin/python run_cv.py --task har
.venv/bin/python run_cv.py --task social
.venv/bin/python train_final.py
.venv/bin/python compare.py
```
To add more people, drop their cleaned 44-file folder into `IoT/data/<uun>/`. CV then switches to
leave-one-subject-out automatically. Delete `results/cv_*.json` first so old runs are not mixed in.

## Using the exported models in the app
Copy `models/harry_<task>.tflite`, `_meta.json` and `_example.json` into `assets/models/`, exactly as
`Lab4_Guide` Part 4 describes. Input is `[1, W, 3]` raw g (float32) and the output is softmax. Normalisation
and features are inside the model. `window_samples` is read from the meta file, so an 8 s social window needs
no code change.
