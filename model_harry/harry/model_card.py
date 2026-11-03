"""After a run: write <export_dir>/README.md (model card), manifest.json and copy the recommended model per task
into <export_dir>/recommended/<task>/.

Recommendation rule (fixed): among TFLite-deployable models, the highest mean score over the scenarios listed in
pipeline.yaml export.recommend_by (default D = other people, Lab3 B9 protocol; E = Harry's real data with
Jan2026 pre-training — together "works on strangers and on the real device"). Missing scenarios are skipped.
"""
import json
import shutil
import time
from pathlib import Path

import numpy as np
import pandas as pd

from . import tables as T
from .zoo import ZOO


def write(out_dir, export_dir, recommend_by=("D", "E")):
    out_dir, export_dir = Path(out_dir), Path(export_dir)
    jobs = list(T._jobs(out_dir))
    ex = [j for j in jobs if j["scenario"] == "EXPORT" and j.get("status") == "ok" and "export" in j]
    if not ex:
        return None
    tb = T.from_jobs(out_dir)
    runs = tb["runs"]
    manifest, lines = {"exported": time.strftime("%Y-%m-%d %H:%M"), "run": str(out_dir), "tasks": {}}, []
    lines += ["# Final models (`model_harry/models`)", "",
              f"Exported {manifest['exported']} by `run_pipeline.py` from `{out_dir.name}`. Every architecture, hers and",
              "mine, was trained the same final way on all available data. The scores below come from the",
              "pipeline's tests (folds × seeds), and every score is in %. Full details are in",
              f"`{out_dir.name}/report.html` and `results_viewer.ipynb`.", "",
              "| scenario | what the score means |", "|---|---|",
              "| A | trained and tested on Harry's real recordings (within-subject CV) |",
              "| B | trained on the real data, tested on Jan2026 (other people) |",
              "| C | trained on Jan2026, tested on the real data |",
              "| D | Jan2026 10-fold CV, i.e. other people, Lab3 B9 / CW3 marking protocol |",
              "| E | Jan2026 pre-training + real fine-tuning, tested on the real data |", "",
              f"**Recommended** = the best TFLite model by mean of scenarios {' + '.join(recommend_by)}. Its copy is in",
              "`recommended/<task>/`.", ""]
    for task in ["har", "social"]:
        rows = []
        for j in [j for j in ex if j["task"] == task]:
            e, m = j["export"], j["model"]
            r = {"model": m, "owner": ZOO[m].owner, "group": ZOO[m].group, "file": e["file"],
                 "tflite": e.get("tflite", False), "KB": e.get("size_kb"), "params": j.get("params"),
                 "window": j.get("window"), "parity": e.get("argmax_agreement"),
                 "trained_on": j.get("train_on", "?")}
            for v in T.VIEWS:
                d = runs[(runs.task == task) & (runs.model == m) & (runs.scenario == v)] if not runs.empty else runs
                r[v] = float(d.SCORE.mean()) if len(d) else np.nan
            avail = [r[v] for v in recommend_by if not np.isnan(r[v])]
            r["rank_score"] = float(np.mean(avail)) if avail else np.nan
            rows.append(r)
        if not rows:
            continue
        df = pd.DataFrame(rows).sort_values("rank_score", ascending=False, na_position="last")
        dep = df[df.tflite & df.rank_score.notna()]
        best = dep.iloc[0].model if len(dep) else None
        if best:
            rec = export_dir / "recommended" / task
            if rec.exists():
                shutil.rmtree(rec)
            rec.mkdir(parents=True)
            for f in (export_dir / task / ZOO[best].group).glob(f"{best}*"):
                shutil.copy2(f, rec / f.name)
        manifest["tasks"][task] = {"recommended": best, "models": df.replace({np.nan: None}).to_dict("records")}
        lines += [f"## {task.upper()}" + (f" — recommended: **{best}**" if best else ""), "",
                  "| | model | owner | group | file | KB | params | window | A | B | C | D | E | rank (" + "+".join(recommend_by) + ") |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for _, r in df.iterrows():
            f = lambda v: "–" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{100 * v:.1f}"
            lines.append(f"| {'★' if r.model == best else ''} | {r.model} | {r.owner} | {r.group} | `{task}/{r.group}/{r.file}` | "
                         f"{r.KB} | {r.params} | {r.window} | {f(r.A)} | {f(r.B)} | {f(r.C)} | {f(r.D)} | {f(r.E)} | "
                         f"{f(r.rank_score)} |")
        lines.append("")
    lines += ["## Using a model in the app (Lab 4)",
              "1. Copy `<task>/<GROUP>/<model>.tflite`, `<model>_meta.json` and `<model>_example.json` into the app's",
              "   `assets/models/`.",
              "2. List them in `pubspec.yaml`, and point the two path constants in `har.dart` / `social.dart` at",
              "   them.",
              "3. Input is `[1, window, 3]` raw g (float32), and the output is softmax. Normalisation and features",
              "   are inside the model. `window_samples` / `step_samples` are in the meta file (my social models",
              "   use 100 samples = 8 s).",
              "4. Run the Lab 4 Step 5.1 check with the `_example.json`.",
              "",
              "Two cautions:",
              "- The teammate's current `social.dart` rejects any model whose meta does not say `social_cnn.tflite`",
              "  with a 50-sample window, so it needs a small change for 8 s models.",
              "- `her_logreg.pkl` is not TFLite: it would need its features and classifier re-implemented in Dart.", ""]
    (export_dir / "README.md").write_text("\n".join(lines), encoding="utf-8")
    (export_dir / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    return export_dir / "README.md"
