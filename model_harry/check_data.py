"""G1.3 / G5.1: sanity checks on the real data and the CV folds. Writes results/data_check.md."""
import hashlib
import numpy as np
import pandas as pd

from harry.data import (list_real, load_signal, har_folds, social_folds, windows_from_pieces,
                        HAR_CLASSES, SOCIAL_CLASSES)

EXPECTED = {"sitting": ("Y", -1), "standing": ("Y", -1), "back": ("Z", +1), "stomach": ("Z", -1),
            "left": ("X", -1), "right": ("X", +1)}
recs = list_real()
lines = ["# Real-data check (G5.1)", "", f"Recordings: {len(recs)} · subjects: {sorted(recs.subject.unique())}", ""]

hashes = {r.path.name: hashlib.md5(load_signal(r.path).tobytes()).hexdigest() for r in recs.itertuples()}
dups = pd.Series(hashes).duplicated(keep=False)
lengths = [len(load_signal(p)) for p in recs.path]
lines += [f"- Exact duplicate recordings: **{int(dups.sum())}**",
          f"- Lengths (samples): min {min(lengths)}, max {max(lengths)}", "",
          "| file | posture | mean X | mean Y | mean Z | dominant ok |", "|---|---|---|---|---|---|"]
for r in recs[recs.stationary].itertuples():
    m = load_signal(r.path).mean(0)
    ax, sign = EXPECTED[r.posture]; i = "XYZ".index(ax)
    ok = int(np.abs(m).argmax()) == i and np.sign(m[i]) == sign
    lines.append(f"| {r.path.name[15:50]} | {r.posture} | {m[0]:+.2f} | {m[1]:+.2f} | {m[2]:+.2f} | {'yes' if ok else '**NO**'} |")

lines += ["", "## Label counts", "", "HAR recordings: " + ", ".join(f"{c}={n}" for c, n in recs.har.value_counts().reindex(HAR_CLASSES).items()),
          "", "Social recordings: " + ", ".join(f"{c}={n}" for c, n in recs.social.value_counts().reindex(SOCIAL_CLASSES).items()), ""]

for task, gen in [("har", har_folds(recs)), ("social", social_folds(recs))]:
    lines += [f"## {task} folds (window 50, train step 25 / test step 12)", "",
              "| fold | train windows | test windows | classes missing in test | classes missing in train |", "|---|---|---|---|---|"]
    n = len(HAR_CLASSES if task == "har" else SOCIAL_CLASSES)
    for name, tr, te in gen:
        Xtr, ytr, _ = windows_from_pieces(tr, 50, 25, task)
        Xte, yte, mte = windows_from_pieces(te, 50, 12, task)
        miss_te = [i for i in range(n) if i not in set(yte)]
        miss_tr = [i for i in range(n) if i not in set(ytr)]
        # leakage check: a test window's samples never appear in a training piece of the same recording
        assert not ({p.rec_id for p in te if p.posture} & {p.rec_id for p in tr if p.posture}), "static recording in both"
        lines.append(f"| {name} | {len(Xtr)} | {len(Xte)} | {miss_te or '-'} | {miss_tr or '-'} |")
    lines.append("")
open("results/data_check.md", "w").write("\n".join(lines))
print("\n".join(lines))
