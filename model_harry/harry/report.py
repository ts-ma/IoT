"""Build runs/<profile>/{tables/*.csv, figures/**.png, report.html, summary.md} from the job JSONs.

The JSONs are only the pipeline's raw store (for resuming). Everything meant for reading is a CSV table, a PNG
figure, the HTML report or results_viewer.ipynb.
"""
import html
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from . import tables as T  # noqa: E402
from . import viz  # noqa: E402
from .tables import VIEWS, VIEW_TITLES  # noqa: E402
from .zoo import ZOO, GROUPS  # noqa: E402

CSS = """body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:24px auto;max-width:1450px;color:#0b0b0b;background:#fcfcfb}
h1{font-size:22px}h2{font-size:19px;border-bottom:2px solid #e6e5e0;padding-top:16px}h3{font-size:16px;margin-top:22px}
h4{font-size:14px;color:#52514e;margin:14px 0 4px}table.t{border-collapse:collapse;font-size:12px;margin:6px 0 12px}
table.t td,table.t th{border:1px solid #e6e5e0;padding:3px 7px;text-align:right}table.t th{background:#f3f2ee}
table.t td:first-child{text-align:left}details{margin:4px 0}summary{cursor:pointer;color:#256abf}
.note{background:#f3f7fd;border-left:4px solid #2a78d6;padding:8px 12px;font-size:13px}img{max-width:100%}"""


def _save(fig, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=110, bbox_inches="tight"); plt.close(fig)
    return path


def _img(out_dir, path):
    return f'<img src="{path.relative_to(out_dir).as_posix()}" loading="lazy"/>'


def build(out_dir, cfg_text=""):
    out_dir = Path(out_dir)
    tb = T.write(out_dir)
    runs, pcls, eps, conf, dep, st = (tb[k] for k in ("runs", "per_class", "epochs", "confusion", "deploy", "status"))
    F = out_dir / "figures"
    H = [f"<html><head><meta charset='utf-8'><title>Her vs my models</title><style>{CSS}</style></head><body>",
         "<h1>Her vs my models — training, testing and cross-validation</h1>",
         "<p class='note'>Score = CW3 marking metric: per-class recall averaged — HAR: mean of (static mean, dynamic mean); "
         "social: balanced recall over the 4 classes. Mean ± std over all runs (folds × seeds). Folds only where train and "
         "test share a dataset (A, D). Held-out curves are monitoring only (fixed epochs, as Lab 3 B9). Numbers for every "
         "chart are in <code>tables/*.csv</code>; open <code>results_viewer.ipynb</code> to explore.</p>",
         _img(out_dir, _save(viz.progress(st), F / "progress.png"))]
    summary = ["# Pipeline summary", "", "Scores in % (mean ± std over runs). Full details: report.html, tables/*.csv,",
               "results_viewer.ipynb.", ""]
    for task in ["har", "social"]:
        if runs.empty or task not in set(runs.task):
            continue
        lb, sd = T.leaderboard(runs, task)
        num = lb.copy()
        for v in [c for c in VIEWS if c in num.columns]:
            num[v] = [("–" if a != a else f"{100 * a:.1f}" + ("" if b != b else f" ± {100 * b:.1f}")) for a, b in zip(lb[v], sd[v])]
        best = T.best_per_circumstance(runs, task)
        H += [f"<h2 id='{task}'>{task.upper()}</h2>", "<h3>Overview</h3>",
              _img(out_dir, _save(viz.leaderboard_heatmap(runs, task), F / task / "leaderboard.png")),
              num.to_html(classes="t", border=0),
              "<h4>Best model for every circumstance (and best-of-hers → best-of-mine per group)</h4>",
              best.to_html(classes="t", border=0, index=False),
              _img(out_dir, _save(viz.her_vs_mine(runs, task), F / task / "her_vs_mine.png"))]
        summary += [f"## {task.upper()}", "", _md(num.reset_index()), "", "Best per circumstance:", "", _md(best), ""]
        for v in [c for c in VIEWS if c in set(runs[runs.task == task].scenario)]:
            H += [f"<h4>CW3 targets — {VIEW_TITLES[v]}</h4>",
                  _img(out_dir, _save(viz.requirements(runs, pcls, task, v), F / task / f"targets_{v}.png"))]
        for grp in GROUPS:
            models = [m for m in T.model_order() if ZOO[m].group == grp]
            if runs[(runs.task == task) & (runs.group == grp)].empty:
                continue
            H += [f"<h3>{task.upper()} · {grp} group ({', '.join(models)})</h3>",
                  _img(out_dir, _save(viz.group_scores(runs, task, grp), F / task / grp / "scores.png"))]
            for v in VIEWS:
                gt = T.group_table(runs, pcls, task, v, models)
                if gt.empty:
                    continue
                H += [f"<h4>{VIEW_TITLES[v]}</h4>", gt.to_html(classes="t", border=0, index=False),
                      _img(out_dir, _save(viz.learning_curves(eps, task, v, models), F / task / grp / f"curves_{v}.png")),
                      "<details><summary>per-epoch numbers</summary>" + _epoch_html(eps, task, v, models) + "</details>",
                      "<details><summary>per-class recall, fold spread and confusion matrices</summary>",
                      _img(out_dir, _save(viz.per_class_heatmap(pcls, task, v, models), F / task / grp / f"per_class_{v}.png")),
                      _img(out_dir, _save(viz.fold_spread(runs, task, v, models), F / task / grp / f"spread_{v}.png"))]
                for m in models:
                    if not conf[(conf.task == task) & (conf.scenario == v) & (conf.model == m)].empty:
                        H.append(_img(out_dir, _save(viz.confusion(conf, task, v, m), F / task / grp / f"confusion_{v}_{m}.png")))
                H.append("</details>")
        H += [f"<h3>{task.upper()} · robustness, cost and training time</h3>"]
        for v in [c for c in ("A", "D") if c in set(runs[runs.task == task].scenario)]:
            H.append(_img(out_dir, _save(viz.rotation(runs, task, v), F / task / f"rotation_{v}.png")))
        ref = "D" if "D" in set(runs[runs.task == task].scenario) else "A"
        H += [_img(out_dir, _save(viz.deploy_tradeoff(runs, dep, task, ref), F / task / "deploy_tradeoff.png")),
              _img(out_dir, _save(viz.train_time(runs, task), F / task / "train_time.png"))]
    if not dep.empty:
        H += ["<h2>Deployability (TFLite, batch 1, measured on this PC)</h2>",
              dep.drop(columns=["scenario", "fold", "seed"], errors="ignore").to_html(classes="t", border=0, index=False)]
    failed = st[st.status == "failed"] if not st.empty else st
    if len(failed):
        H += ["<h2>Failed jobs</h2>", "<p>See <code>jobs/&lt;id&gt;.log</code> for the traceback.</p>",
              failed[["id", "scenario", "task", "model"]].to_html(classes="t", border=0, index=False)]
    if cfg_text:
        H += ["<h2>Config used</h2>", f"<pre>{html.escape(cfg_text)}</pre>"]
    H.append("</body></html>")
    (out_dir / "report.html").write_text("\n".join(H), encoding="utf-8")
    (out_dir / "summary.md").write_text("\n".join(summary), encoding="utf-8")
    return out_dir / "report.html"


def _epoch_html(eps, task, v, models):
    e = eps[(eps.task == task) & (eps.scenario == v) & eps.model.isin(models)]
    if e.empty:
        return "<p>no per-epoch history</p>"
    out = []
    for m in [m for m in T.model_order() if m in set(e.model)]:
        t = (e[e.model == m].groupby("epoch")[["train_loss", "train_acc", "heldout_loss", "heldout_acc", "heldout_score",
                                                "epoch_seconds"]].mean().round(4))
        out.append(f"<h4>{m} — mean over {e[e.model == m].groupby(['fold', 'seed']).ngroups} run(s)</h4>"
                   + t.to_html(classes="t", border=0))
    return "".join(out)


def _md(df):
    df = df.fillna("–")
    return ("| " + " | ".join(map(str, df.columns)) + " |\n|" + "---|" * len(df.columns) + "\n"
            + "\n".join("| " + " | ".join(map(str, r)) + " |" for r in df.itertuples(index=False)))
