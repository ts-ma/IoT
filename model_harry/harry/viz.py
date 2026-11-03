"""Plots for the pipeline results (used by report.py and results_viewer.ipynb). Every function takes the tidy
tables from harry/tables.py and returns a matplotlib Figure.

Colour rules (validated palette, see dataviz skill): identity = categorical slots in a FIXED order —
mine is always slot 1 (blue); her models take slots 2.. in model order inside a group; hers are also dashed
(secondary encoding, never colour alone). Magnitude (scores, confusion) = one blue ramp, light -> dark.
Every chart has a legend or labels and a numbers table next to it in the report/notebook.
"""
import numpy as np
import pandas as pd
import matplotlib
import matplotlib.ticker
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap

from .tables import VIEWS, VIEW_TITLES, GOALS, classes_of, model_order
from .zoo import ZOO, GROUPS

SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e0"
SLOTS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
OWNER = {"mine": SLOTS[0], "hers": SLOTS[1]}
STATUS = {"ok": "#0ca30c", "failed": "#d03b3b", "pending": "#b9b8b2", "skipped": "#ec835a"}
BLUES = LinearSegmentedColormap.from_list("blues", ["#f3f7fd", "#cde2fb", "#86b6ef", "#3987e5", "#256abf", "#184f95", "#0d366b"])


def style():
    plt.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
        "text.color": INK, "axes.titlecolor": INK, "axes.titlesize": 10, "axes.labelsize": 9,
        "xtick.labelsize": 8, "ytick.labelsize": 8, "legend.fontsize": 8, "legend.frameon": False,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8, "axes.spines.top": False,
        "axes.spines.right": False, "lines.linewidth": 2, "font.size": 9, "figure.dpi": 110})


style()


def color_of(model):
    """Slot inside the model's group: mine -> blue; hers -> orange, aqua, yellow, magenta (fixed order)."""
    if ZOO[model].owner == "mine":
        return SLOTS[0]
    hers = [m for m in model_order() if ZOO[m].group == ZOO[model].group and ZOO[m].owner == "hers"]
    return SLOTS[1 + hers.index(model)]


def dash_of(model):
    return "-" if ZOO[model].owner == "mine" else "--"


def _label(m):
    return f"{m} ({ZOO[m].owner})"


def _empty(msg="no finished runs for this view yet"):
    fig, ax = plt.subplots(figsize=(6, 1.2)); ax.axis("off"); ax.text(0.5, 0.5, msg, ha="center", color=INK2)
    return fig


# ───────────────────────── overview
def leaderboard_heatmap(runs, task):
    d = runs[runs.task == task]
    if d.empty:
        return _empty()
    g = d.groupby(["model", "scenario"]).SCORE.agg(["mean", "std"]).reset_index()
    order = [m for m in model_order() if m in set(g.model)]
    cols = [v for v in VIEWS if v in set(g.scenario)]
    M = g.pivot(index="model", columns="scenario", values="mean").reindex(index=order, columns=cols)
    S = g.pivot(index="model", columns="scenario", values="std").reindex(index=order, columns=cols)
    fig, ax = plt.subplots(figsize=(1.6 * len(cols) + 3.2, 0.42 * len(order) + 1.4))
    im = ax.imshow(M.values, cmap=BLUES, vmin=0.25, vmax=1.0, aspect="auto")
    ax.grid(False)
    for i in range(len(order)):
        best_in_col = None
        for k, v in enumerate(cols):
            val = M.values[i, k]
            if np.isnan(val):
                ax.text(k, i, "–", ha="center", va="center", color=INK2); continue
            sd = S.values[i, k]
            win = val == np.nanmax(M.values[:, k])
            ax.text(k, i, f"{100 * val:.1f}" + ("" if np.isnan(sd) else f"\n±{100 * sd:.1f}"), ha="center", va="center",
                    fontsize=7.5, fontweight="bold" if win else "normal", color="white" if val > 0.72 else INK)
    ax.set_xticks(range(len(cols)), [VIEW_TITLES[v] for v in cols], rotation=20, ha="right")
    ax.set_yticks(range(len(order)), [f"{ZOO[m].group:7s} {_label(m)}" for m in order], family="monospace", fontsize=7.5)
    for i in range(1, len(order)):                                      # separators between groups
        if ZOO[order[i]].group != ZOO[order[i - 1]].group:
            ax.axhline(i - 0.5, color=SURFACE, lw=3)
    ax.set_title(f"{task.upper()} — score (%) per model and scenario · bold = best in column · mean ± std over runs")
    fig.colorbar(im, ax=ax, fraction=0.025, pad=0.01).ax.tick_params(labelsize=7)
    return fig


def her_vs_mine(runs, task):
    """Dumbbell: best of hers vs best of mine, for every group x scenario."""
    d = runs[runs.task == task]
    rows = []
    for grp in GROUPS:
        for v in VIEWS:
            x = d[(d.group == grp) & (d.scenario == v)].groupby(["model", "owner"]).SCORE.mean().reset_index()
            if x.owner.nunique() == 2:
                rows.append((f"{grp} · {v}", x[x.owner == "hers"].SCORE.max(), x[x.owner == "mine"].SCORE.max()))
    if not rows:
        return _empty()
    fig, ax = plt.subplots(figsize=(8, 0.34 * len(rows) + 1.2))
    for i, (lab, h, m) in enumerate(rows[::-1]):
        ax.plot([h, m], [i, i], color=GRID, lw=3, zorder=1)
        ax.scatter([h], [i], s=60, color=OWNER["hers"], zorder=2, edgecolor=SURFACE, linewidth=2, label="best of hers" if i == 0 else None)
        ax.scatter([m], [i], s=60, color=OWNER["mine"], zorder=3, edgecolor=SURFACE, linewidth=2, label="best of mine" if i == 0 else None)
        ax.text(max(h, m) + 0.01, i, f"{100 * (m - h):+.1f} pp", va="center", fontsize=7.5, color=INK2)
    ax.set_yticks(range(len(rows)), [r[0] for r in rows[::-1]])
    ax.set_xlabel("score"); ax.xaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0))
    ax.set_title(f"{task.upper()} — best of hers vs best of mine in each group × scenario (A–E)")
    ax.legend(loc="lower left")
    return fig


def progress(status):
    if status.empty:
        return _empty("no jobs yet")
    s = status.copy(); s["status"] = s.status.fillna("pending")
    t = s.groupby(["scenario", "status"]).size().unstack(fill_value=0)
    order = [c for c in ["ok", "failed", "skipped", "pending"] if c in t.columns]
    fig, ax = plt.subplots(figsize=(8, 0.4 * len(t) + 1))
    left = np.zeros(len(t))
    for c in order:
        ax.barh(t.index, t[c], left=left, color=STATUS[c], label=c, edgecolor=SURFACE, linewidth=2)
        for i, (l, w) in enumerate(zip(left, t[c])):
            if w:
                ax.text(l + w / 2, i, str(w), ha="center", va="center", fontsize=7, color="white" if c != "pending" else INK)
        left += t[c].values
    ax.set_title("jobs by scenario and status"); ax.legend(ncol=4, loc="lower right"); ax.grid(axis="y", visible=False)
    return fig


# ───────────────────────── per group / scenario
def group_scores(runs, task, group):
    d = runs[(runs.task == task) & (runs.group == group)]
    if d.empty:
        return _empty()
    models = [m for m in model_order() if m in set(d.model)]
    cols = [v for v in VIEWS if v in set(d.scenario)]
    g = d.groupby(["model", "scenario"]).SCORE.agg(["mean", "std"])
    w = 0.8 / len(models)
    fig, ax = plt.subplots(figsize=(max(6, 1.5 * len(cols) + 2), 3.4))
    for i, m in enumerate(models):
        xs = np.arange(len(cols)) + (i - (len(models) - 1) / 2) * w
        mu = [g.loc[(m, v), "mean"] if (m, v) in g.index else np.nan for v in cols]
        sd = [g.loc[(m, v), "std"] if (m, v) in g.index else np.nan for v in cols]
        ax.bar(xs, mu, w * 0.92, yerr=np.nan_to_num(sd), color=color_of(m), label=_label(m), capsize=2,
               error_kw=dict(ecolor=INK2, lw=1), hatch=None if ZOO[m].owner == "mine" else "//", edgecolor=SURFACE)
    ax.set_xticks(range(len(cols)), [VIEW_TITLES[v] for v in cols], rotation=12)
    ax.set_ylim(0, 1.02); ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0))
    ax.set_title(f"{task.upper()} · {group} group — score per scenario (bar = mean, whisker = std; hatched = hers)")
    ax.legend(ncol=min(5, len(models)), loc="lower center", bbox_to_anchor=(0.5, -0.42)); ax.grid(axis="x", visible=False)
    return fig


def requirements(runs, per_class, task, scenario, models=None):
    """CW3 targets: HAR static mean >= 90 %, dynamic mean >= 85 %; social: every class >= 75 %."""
    d = runs[(runs.task == task) & (runs.scenario == scenario)]
    if d.empty:
        return _empty()
    models = [m for m in model_order() if m in set(d.model) and (models is None or m in models)]
    if task == "har":
        panels = [(k, d.groupby("model")[k].mean()) for k in ("STATIC_MEAN", "DYNAMIC_MEAN")]
    else:
        pc = per_class[(per_class.task == task) & (per_class.scenario == scenario)]
        panels = [(c, pc[pc["class"] == c].groupby("model").recall.mean()) for c in classes_of(task)]
    fig, axs = plt.subplots(1, len(panels), figsize=(3.3 * len(panels), 0.32 * len(models) + 1.3), sharey=True)
    for ax, (k, s) in zip(np.atleast_1d(axs), panels):
        vals = [s.get(m, np.nan) for m in models]
        ax.barh(range(len(models)), vals, color=[OWNER[ZOO[m].owner] for m in models], height=0.7, edgecolor=SURFACE)
        goal = GOALS[task][k]
        ax.axvline(goal, color=INK, lw=1, ls=":")
        for i, v in enumerate(vals):
            if not np.isnan(v):
                ax.text(min(v, 1.0) + 0.01, i, f"{100 * v:.0f}{'' if v >= goal else ' ✗'}", va="center", fontsize=7,
                        color=INK if v >= goal else "#d03b3b")
        ax.set_xlim(0, 1.15); ax.set_title(f"{k} (target {goal:.0%})", fontsize=9)
        ax.xaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0)); ax.grid(axis="y", visible=False)
    np.atleast_1d(axs)[0].set_yticks(range(len(models)), [_label(m) for m in models])
    np.atleast_1d(axs)[0].invert_yaxis()
    fig.suptitle(f"{task.upper()} · {VIEW_TITLES[scenario]} — CW3 targets (dotted line); ✗ = below target", fontsize=10)
    return fig


def per_class_heatmap(per_class, task, scenario, models=None):
    pc = per_class[(per_class.task == task) & (per_class.scenario == scenario)]
    if pc.empty:
        return _empty()
    M = pc.groupby(["model", "class"]).recall.mean().unstack()
    order = [m for m in model_order() if m in M.index and (models is None or m in models)]
    M = M.reindex(index=order, columns=classes_of(task))
    fig, ax = plt.subplots(figsize=(0.8 * M.shape[1] + 3, 0.38 * len(order) + 1.4))
    ax.imshow(M.values, cmap=BLUES, vmin=0, vmax=1, aspect="auto"); ax.grid(False)
    for i in range(M.shape[0]):
        for k in range(M.shape[1]):
            v = M.values[i, k]
            if not np.isnan(v):
                ax.text(k, i, f"{100 * v:.0f}", ha="center", va="center", fontsize=7.5, color="white" if v > 0.7 else INK)
    ax.set_xticks(range(M.shape[1]), M.columns, rotation=35, ha="right")
    ax.set_yticks(range(len(order)), [_label(m) for m in order])
    ax.set_title(f"{task.upper()} · {VIEW_TITLES[scenario]} — recall per class (%)")
    return fig


def learning_curves(epochs, task, scenario, models):
    e = epochs[(epochs.task == task) & (epochs.scenario == scenario) & epochs.model.isin(models)]
    if e.empty or e.epoch.max() < 2:
        return _empty("no per-epoch history (or single-step model) for this view")
    fig, axs = plt.subplots(1, 3, figsize=(15, 3.4))
    for m in [m for m in model_order() if m in set(e.model)]:
        x = e[e.model == m].groupby("epoch")
        for ax, k in zip(axs, ["train_loss", "train_acc", "heldout_score"]):
            mu, sd = x[k].mean(), x[k].std().fillna(0)
            if mu.isna().all():
                continue
            ax.plot(mu.index, mu, color=color_of(m), ls=dash_of(m), label=_label(m))
            ax.fill_between(mu.index, mu - sd, mu + sd, color=color_of(m), alpha=0.12, linewidth=0)
    mon = e.heldout_set.dropna().iloc[0] if e.heldout_set.notna().any() else "held-out"
    for ax, t in zip(axs, ["training loss", "training accuracy (mine: measured on augmented data)",
                           f"held-out score per epoch ({mon}) — monitor only, no early stopping"]):
        ax.set_title(t, fontsize=9); ax.set_xlabel("epoch")
    axs[2].legend()
    fig.suptitle(f"{task.upper()} · {VIEW_TITLES[scenario]} — learning curves (line = mean over runs, band = ±1 std)", fontsize=10)
    return fig


def fold_spread(runs, task, scenario, models=None):
    d = runs[(runs.task == task) & (runs.scenario == scenario)]
    if d.empty:
        return _empty()
    order = [m for m in model_order() if m in set(d.model) and (models is None or m in models)]
    fig, ax = plt.subplots(figsize=(max(6, 0.75 * len(order) + 2), 3.3))
    rng = np.random.default_rng(0)
    for i, m in enumerate(order):
        v = d[d.model == m].SCORE.values
        ax.boxplot([v], positions=[i], widths=0.55, showfliers=False, medianprops=dict(color=INK),
                   boxprops=dict(color=INK2), whiskerprops=dict(color=INK2), capprops=dict(color=INK2))
        ax.scatter(i + rng.uniform(-0.15, 0.15, len(v)), v, s=14, color=OWNER[ZOO[m].owner], alpha=0.75, zorder=3)
    ax.set_xticks(range(len(order)), [_label(m) for m in order], rotation=30, ha="right")
    ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0))
    ax.set_title(f"{task.upper()} · {VIEW_TITLES[scenario]} — every fold × seed (dot), box = spread "
                 f"(blue = mine, orange = hers)")
    return fig


def confusion(conf, task, scenario, model):
    c = conf[(conf.task == task) & (conf.scenario == scenario) & (conf.model == model)]
    if c.empty:
        return _empty()
    cl = classes_of(task)
    M = c.groupby(["true", "pred"])["count"].sum().unstack(fill_value=0).reindex(index=cl, columns=cl, fill_value=0)
    R = M.values / np.maximum(M.values.sum(1, keepdims=True), 1)
    fig, ax = plt.subplots(figsize=(0.55 * len(cl) + 2.6, 0.5 * len(cl) + 1.6))
    ax.imshow(R, cmap=BLUES, vmin=0, vmax=1); ax.grid(False)
    for a in range(len(cl)):
        for b in range(len(cl)):
            if R[a, b] >= 0.01:
                ax.text(b, a, f"{100 * R[a, b]:.0f}", ha="center", va="center", fontsize=7, color="white" if R[a, b] > 0.6 else INK)
    ax.set_xticks(range(len(cl)), cl, rotation=45, ha="right"); ax.set_yticks(range(len(cl)), cl)
    ax.set_xlabel("predicted"); ax.set_ylabel("true")
    ax.set_title(f"{model} · {task} · {VIEW_TITLES[scenario]}\nrow-normalised % (pooled over runs)", fontsize=9)
    return fig


def rotation(runs, task, scenario):
    d = runs[(runs.task == task) & (runs.scenario == scenario)]
    if d.empty:
        return _empty()
    groups = [g for g in GROUPS if g in set(d.group)]
    fig, axs = plt.subplots(1, len(groups), figsize=(3.6 * len(groups), 3), sharey=True)
    for ax, grp in zip(np.atleast_1d(axs), groups):
        for m in [m for m in model_order() if ZOO[m].group == grp and m in set(d.model)]:
            x = d[d.model == m][["SCORE", "rot15", "rot30"]].mean()
            ax.plot([0, 15, 30], x.values, marker="o", ms=5, color=color_of(m), ls=dash_of(m), label=m)
        ax.set_title(grp); ax.set_xticks([0, 15, 30], ["0°", "15°", "30°"]); ax.set_xlabel("sensor rolled about Y")
        ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0)); ax.legend(fontsize=7)
    fig.suptitle(f"{task.upper()} · {VIEW_TITLES[scenario]} — robustness to sensor rotation (score)", fontsize=10)
    return fig


def deploy_tradeoff(runs, deploy, task, scenario):
    d = runs[(runs.task == task) & (runs.scenario == scenario)].groupby("model").SCORE.mean()
    dep = deploy[deploy.task == task].set_index("model") if not deploy.empty else pd.DataFrame()
    ms = [m for m in d.index if m in dep.index]
    if not ms:
        return _empty("needs DEPLOY jobs and finished runs")
    fig, axs = plt.subplots(1, 2, figsize=(11, 3.6), sharey=True)
    for ax, k, lab in zip(axs, ["ms_per_window", "size_kb"], ["inference ms / window (this PC, batch 1)", "model size (KB)"]):
        for m in ms:
            ax.scatter(dep.loc[m, k], d[m], s=70, color=OWNER[ZOO[m].owner], edgecolor=SURFACE, linewidth=2, zorder=3,
                       marker="o" if dep.loc[m].get("tflite", True) in (True, "True") else "s")
            ax.annotate(m, (dep.loc[m, k], d[m]), xytext=(5, 3), textcoords="offset points", fontsize=7, color=INK2)
        ax.set_xscale("log"); ax.set_xlabel(lab)
    axs[0].yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0)); axs[0].set_ylabel(f"score in {scenario}")
    fig.suptitle(f"{task.upper()} — accuracy vs cost (blue = mine, orange = hers; square = not TFLite)", fontsize=10)
    return fig


def train_time(runs, task):
    d = runs[runs.task == task]
    if d.empty:
        return _empty()
    t = d.drop_duplicates(["model", "scenario", "fold", "seed"]).groupby(["model", "scenario"]).train_seconds.mean().unstack()
    order = [m for m in model_order() if m in t.index]
    t = t.reindex(order)
    cols = [v for v in VIEWS if v in t.columns]
    fig, axs = plt.subplots(1, len(cols), figsize=(2.6 * len(cols) + 1.5, 0.3 * len(order) + 1.2), sharey=True)
    for ax, v in zip(np.atleast_1d(axs), cols):
        ax.barh(range(len(order)), t[v], color=[OWNER[ZOO[m].owner] for m in order], height=0.7)
        ax.set_title(v); ax.grid(axis="y", visible=False)
        for i, s in enumerate(t[v]):
            if not np.isnan(s):
                ax.text(s, i, f" {s:.0f}s", va="center", fontsize=6.5, color=INK2)
    np.atleast_1d(axs)[0].set_yticks(range(len(order)), order); np.atleast_1d(axs)[0].invert_yaxis()
    fig.suptitle(f"{task.upper()} — mean wall-clock seconds per training run (one worker)", fontsize=10)
    return fig


def legacy_bars(prev, task):
    d = prev[prev.task == task]
    if d.empty:
        return _empty("no previous results found")
    views = list(dict.fromkeys(d.scenario))
    fig, axs = plt.subplots(1, len(views), figsize=(5.2 * len(views), 0.34 * d.model.nunique() + 1.6))
    for ax, v in zip(np.atleast_1d(axs), views):
        g = d[d.scenario == v].groupby(["model", "owner"]).SCORE.agg(["mean", "std"]).reset_index().sort_values("mean")
        ax.barh(range(len(g)), g["mean"], xerr=g["std"].fillna(0), color=[OWNER[o] for o in g.owner], height=0.7,
                error_kw=dict(ecolor=INK2, lw=1))
        for i, (mu, sd) in enumerate(zip(g["mean"], g["std"].fillna(0))):
            ax.text(mu + sd + 0.01, i, f"{100 * mu:.1f}", va="center", fontsize=7)
        ax.set_yticks(range(len(g)), g.model, fontsize=7.5); ax.set_xlim(0, 1.12); ax.set_title(v)
        ax.xaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0)); ax.grid(axis="y", visible=False)
    fig.suptitle(f"{task.upper()} — previous experiments (2 Nov), score mean ± std over folds/seeds "
                 "(blue = mine, orange = hers)", fontsize=10)
    return fig
