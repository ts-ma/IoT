"""Every figure, from the tables in final_run/tables/. Each figure is saved as .png (viewing) and .pdf (vector, for
the report) under final_run/figures/<section>/, and registered in CATALOGUE with a caption for the gallery and
the write-up. A figure whose data is missing (job not finished) is skipped, never fatal."""
import traceback

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from harry.data import HAR_CLASSES, SOCIAL_CLASSES, STATIC, DYNAMIC  # noqa: E402
from . import config as C  # noqa: E402
from .data import load_set  # noqa: E402

FIG = C.OUT / "figures"
TAB = C.OUT / "tables"
CATALOGUE = []
PAL = ["#0072B2", "#E69F00", "#009E73", "#D55E00", "#CC79A7", "#56B4E9", "#F0E442", "#000000", "#999999", "#882255", "#44AA99"]
VAR_COL = {"all": "#0072B2", "jan": "#999999", "group": "#E69F00"}
VAR_LAB = C.SCOPE_LABEL
SHORT = {"sittingStanding": "sit/stand", "lyingBack": "lie back", "lyingLeft": "lie left", "lyingRight": "lie right",
         "lyingStomach": "lie stomach", "normalWalking": "walk", "shuffleWalking": "shuffle", "ascending": "stairs up",
         "descending": "stairs down", "running": "run", "miscMovement": "misc", "breathingNormally": "breathing",
         "coughing": "coughing", "hyperventilation": "hypervent.", "other": "other"}
STEP_LAB = {25: "2 s", 12: "1 s", 6: "0.5 s"}       # the app's labels (12 samples = 0.96 s)
plt.rcParams.update({"font.size": 9, "axes.titlesize": 10, "axes.spines.top": False, "axes.spines.right": False,
                     "figure.dpi": 100, "savefig.bbox": "tight", "legend.frameon": False})


def classes(task):
    return HAR_CLASSES if task == "har" else SOCIAL_CLASSES


def short(cs):
    return [SHORT.get(c, c) for c in cs]


def save(fig, section, name, title, caption):
    d = FIG / section; d.mkdir(parents=True, exist_ok=True)
    fig.savefig(d / f"{name}.png", dpi=170); fig.savefig(d / f"{name}.pdf")
    plt.close(fig)
    CATALOGUE.append({"section": section, "name": name, "title": title, "caption": caption,
                      "png": f"figures/{section}/{name}.png", "pdf": f"figures/{section}/{name}.pdf"})


def read(name):
    f = TAB / f"{name}.csv"
    return pd.read_csv(f) if f.exists() and f.stat().st_size > 2 else pd.DataFrame()


def targets(ax, task, horizontal=True):
    if task == "har":
        ax.axhline(90, ls="--", c="#009E73", lw=1, label="static target 90 %")
        ax.axhline(85, ls=":", c="#D55E00", lw=1, label="dynamic target 85 %")
    else:
        ax.axhline(75, ls="--", c="#D55E00", lw=1, label="target 75 % per class")


# ───────────────────────── data
def fig_data():
    comp = read("data_composition")
    if not comp.empty:
        for task in ("har", "social"):
            d = comp[comp.task == task].pivot_table(index="class", columns="set", values="recordings", aggfunc="sum").reindex(classes(task)).fillna(0)
            fig, ax = plt.subplots(figsize=(6.5, 2.8))
            ax.bar(short(d.index), d.get("listed", 0), color=PAL[0], label="in fold CSV (used for CV)")
            ax.bar(short(d.index), d.get("unlisted", 0), bottom=d.get("listed", 0), color=PAL[8], label="not in fold CSV")
            for i, v in enumerate(d.sum(1)):
                ax.text(i, v, int(v), ha="center", va="bottom", fontsize=7)
            ax.set_ylabel("recordings"); ax.tick_params(axis="x", rotation=35); ax.legend()
            ax.set_title(f"datasetJan2026 {'daily activity' if task == 'har' else 'social signal'} recordings per class")
            save(fig, "data", f"recordings_per_class_{task}", ax.get_title(),
                 "Number of recordings per class. Grey: files present on disk but not listed in the official fold CSV "
                 "(unknown subjects; excluded from CV, used only to train the final models).")
            d2 = comp[(comp.task == task)].groupby("class").hours.sum().reindex(classes(task))
            fig, ax = plt.subplots(figsize=(6.5, 2.6))
            ax.bar(short(d2.index), d2.values * 60, color=PAL[2]); ax.set_ylabel("minutes of data")
            ax.tick_params(axis="x", rotation=35); ax.set_title(f"Total recorded time per class ({task})")
            save(fig, "data", f"minutes_per_class_{task}", ax.get_title(), "Total duration of accelerometer data per class (all Jan2026 files).")
        fig, axs = plt.subplots(1, 2, figsize=(6.5, 2.4))
        for ax, task in zip(axs, ("har", "social")):
            _, meta = load_set(f"jan_{task}")
            ax.hist(meta.n / C.FS, bins=40, color=PAL[0]); ax.set_xlabel("recording length (s)"); ax.set_title(task)
            ax.axvline(C.W[task] / C.FS, c="r", ls="--", lw=1, label="model window"); ax.legend()
        axs[0].set_ylabel("recordings")
        save(fig, "data", "recording_lengths", "Recording lengths", "Distribution of recording length; the dashed line is the "
             "model input window (4 s HAR, 8 s social). Every recording is longer than the window, so none is dropped.")
    fc = read("fold_composition")
    if not fc.empty:
        for task in ("har", "social"):
            d = fc[fc.task == task].pivot_table(index="activity", columns="fold", values="recordings").reindex(classes(task))
            fig, ax = plt.subplots(figsize=(6.5, 0.32 * len(d) + 1.2))
            im = ax.imshow(d.values, cmap="Blues", aspect="auto")
            ax.set_yticks(range(len(d))); ax.set_yticklabels(short(d.index)); ax.set_xticks(range(10)); ax.set_xlabel("official fold")
            for (i, j), v in np.ndenumerate(d.values):
                ax.text(j, i, int(v), ha="center", va="center", fontsize=6.5, color="white" if v > np.nanmax(d.values) * 0.6 else "black")
            fig.colorbar(im, ax=ax, label="recordings"); ax.set_title(f"Official fold composition ({task})")
            save(fig, "data", f"fold_composition_{task}", ax.get_title(), "Recordings per class in each official fold: the folds are "
                 "balanced per class, as the marking scheme describes.")
    # example signals
    for task in ("har", "social"):
        sig, meta = load_set(f"jan_{task}")
        cs = classes(task); cols = 3 if task == "har" else 2
        rows_ = int(np.ceil(len(cs) / cols))
        fig, axs = plt.subplots(rows_, cols, figsize=(6.5, 1.35 * rows_), sharex=True)
        for ax, c in zip(axs.flat, cs):
            i = np.flatnonzero(meta.activity == c)[0]
            x = sig[i][:250]; t = np.arange(len(x)) / C.FS
            for a, col, lab in zip(range(3), PAL[:3], "xyz"):
                ax.plot(t, x[:, a], c=col, lw=0.8, label=lab)
            ax.set_title(SHORT[c], fontsize=8, pad=2); ax.tick_params(labelsize=7)
        for ax in list(axs.flat)[len(cs):]:
            ax.axis("off")
        axs.flat[0].legend(ncol=3, fontsize=7, loc="upper right")
        fig.supxlabel("time (s)", fontsize=8); fig.supylabel("acceleration (g)", fontsize=8)
        save(fig, "data", f"example_signals_{task}", f"Example raw signals ({task})",
             "First 20 s of one recording per class (x, y, z in g). Posture shows up as the constant offset (gravity), "
             "activity as the oscillation around it.")
    # gravity orientation
    jg, q = read("jan_gravity"), read("real_data_quality")
    if not jg.empty:
        fig, axs = plt.subplots(1, 2, figsize=(6.5, 3.0))
        for ax, (a, b) in zip(axs, [("gx", "gy"), ("gz", "gy")]):
            for k, c in enumerate(STATIC):
                d = jg[jg["class"] == c]
                ax.scatter(d[a], d[b], s=4, alpha=0.25, c=PAL[k], label=SHORT[c])
                if not q.empty:
                    for m, (person, mk) in enumerate(zip(C.PEOPLE, ["*", "^"])):
                        r = q[(q.har == c) & (q.person == person)]
                        ax.scatter(r[a], r[b], s=45, marker=mk, c=PAL[k], edgecolors="k", lw=0.6)
            ax.set_xlabel(f"mean {a[1]} (g)"); ax.set_ylabel(f"mean {b[1]} (g)")
        axs[0].legend(fontsize=7, markerscale=3, loc="best")
        fig.suptitle("Sensor orientation (gravity) per posture: Jan2026 dots, ★ Subject A, ▲ Subject B", fontsize=9)
        save(fig, "data", "gravity_orientation", "Gravity orientation per posture",
             "Mean acceleration of each static recording (= gravity direction = posture). Group members' recordings "
             "(large markers) fall inside the Jan2026 clusters, so sensor placement matches the dataset.")
    if not q.empty:
        fig, axs = plt.subplots(2, 1, figsize=(6.5, 4.2))
        for k, person in enumerate(C.PEOPLE):
            d = q[q.person == person].reset_index(drop=True)
            axs[0].bar(np.arange(len(d)) + 0.4 * k, d.angle_to_jan_class_deg, width=0.4, color=PAL[k], label=C.PEOPLE[person])
            axs[1].bar(np.arange(len(d)) + 0.4 * k, d.fs_est, width=0.4, color=PAL[k])
        axs[0].axhline(35, c="r", ls="--", lw=1, label="flag threshold"); axs[0].set_ylabel("angle to Jan2026\nclass mean (°)"); axs[0].legend(fontsize=7)
        axs[1].axhline(12.5, c="k", ls="--", lw=1); axs[1].set_ylabel("sampling rate (Hz)"); axs[1].set_xlabel("recording (alphabetical per person)")
        axs[1].set_ylim(10, 14)
        save(fig, "data", "real_data_quality", "Group recordings: quality checks",
             "Per recording of each group member: angle between its gravity vector and the Jan2026 mean for the same class "
             "(placement check) and the sampling rate estimated from timestamps (nominal 12.5 Hz).")
    # spectra and intensity
    from scipy.signal import welch
    for task in ("har", "social"):
        sig, meta = load_set(f"jan_{task}")
        fig, ax = plt.subplots(figsize=(6.5, 2.8))
        for k, c in enumerate(classes(task)):
            ids = np.flatnonzero(meta.activity == c)[:200]
            ps = []
            for i in ids:
                x = sig[i]; mag = np.linalg.norm(x, axis=1); mag = mag - mag.mean()
                f, p = welch(mag, fs=C.FS, nperseg=min(128, len(mag)))
                ps.append(p)
            ax.semilogy(f, np.mean(ps, 0), c=PAL[k % len(PAL)], lw=1.2, label=SHORT[c])
        ax.set_xlabel("frequency (Hz)"); ax.set_ylabel("power of |a| (g²/Hz)"); ax.legend(fontsize=7, ncol=2)
        ax.set_title(f"Mean spectrum of the acceleration magnitude ({task})")
        save(fig, "data", f"spectra_{task}", ax.get_title(), "Welch power spectrum of the gravity-free acceleration magnitude, "
             "averaged over up to 200 recordings per class. These frequency bands motivate the in-model band-power features.")
        rows = []
        for c in classes(task):
            for i in np.flatnonzero(meta.activity == c)[:400]:
                rows.append((c, float(np.log10((sig[i] - sig[i].mean(0)).std() + 1e-5))))
        d = pd.DataFrame(rows, columns=["c", "v"])
        fig, ax = plt.subplots(figsize=(6.5, 2.6))
        ax.boxplot([d[d.c == c].v for c in classes(task)], showfliers=False)
        ax.set_xticks(range(1, len(classes(task)) + 1)); ax.set_xticklabels(short(classes(task)), rotation=35)
        ax.set_ylabel("log10 std of a − gravity (g)"); ax.set_title(f"Movement intensity per class ({task})")
        save(fig, "data", f"intensity_{task}", ax.get_title(), "How much the signal varies around gravity in each class "
             "(log scale). Static and social classes differ by orders of magnitude from dynamic ones.")
    dup = read("duplicates_har_social")
    if not dup.empty:
        fig, ax = plt.subplots(figsize=(6.5, 2.4))
        d = dup.groupby(["har_class", dup.har_fold == dup.social_fold]).size().unstack(fill_value=0)
        d.index = short(d.index)
        d.plot.bar(stacked=True, ax=ax, color=[PAL[3], PAL[2]], rot=0)
        ax.legend(["different fold in the two CSVs", "same fold"]); ax.set_ylabel("HAR files")
        ax.set_title("Static HAR recordings that are byte-copies of social recordings")
        save(fig, "data", "duplicates", ax.get_title(), "Every static daily-activity file is a copy of a social-signal "
             "recording (breathing). The two official fold CSVs mostly place the copies in different folds.")


# ───────────────────────── training curves
def fig_training():
    ep = read("epochs")
    if ep.empty:
        return
    for task in ("har", "social"):
        for v in C.SCOPES:
            d = ep[(ep.group == "main") & (ep.task == task) & (ep.variant == v) & (ep.seed == 0)]
            if d.empty:
                continue
            fig, axs = plt.subplots(1, 3, figsize=(6.8, 2.4))
            for stage, ls in [("train", "-"), ("finetune", "--")]:
                s = d[d.stage == stage]
                if s.empty:
                    continue
                off = 0 if stage == "train" else d[d.stage == "train"].epoch.max()
                g = s.groupby("epoch")
                for ax, cols in zip(axs, [("train_loss", "test/loss"), ("train_acc", "test/acc"), (None, "test/score")]):
                    for col, colr, lab in [(cols[0], PAL[0], "train"), (cols[1], PAL[3], "test fold")]:
                        if col and col in s:
                            m, sd = g[col].mean(), g[col].std()
                            ax.plot(m.index + off, m.values, ls=ls, c=colr, lw=1.2, label=f"{lab}{' (fine-tune)' if stage == 'finetune' else ''}")
                            ax.fill_between(m.index + off, m - sd, m + sd, color=colr, alpha=0.15)
            for ax, t in zip(axs, ["loss", "accuracy", "marked score (test fold)"]):
                ax.set_title(t); ax.set_xlabel("epoch")
            axs[0].legend(fontsize=6.5)
            fig.suptitle(f"{C.MODEL_NAMES[C.FINAL[task]]} – {task} – {VAR_LAB[v]} (mean ± sd over 10 folds)", fontsize=9, y=1.06)
            save(fig, "training", f"learning_curves_{task}_{v.replace('+', '_')}", f"Learning curves ({task}, {VAR_LAB[v]})",
                 "Training and held-out-fold loss/accuracy per epoch, mean ± sd over the 10 official folds. The test fold was "
                 "only monitored, never used to stop or tune training (fixed epochs, as in Lab 3).")
        d = ep[(ep.group.isin(["main", "baseline"])) & (ep.task == task) & (ep.seed == 0)]
        if not d.empty and "test/score" in d:
            fig, ax = plt.subplots(figsize=(6.5, 3))
            for k, (m, g) in enumerate(d.groupby("model")):
                s = g[g.stage == "train"].groupby("epoch")["test/score"].mean()
                ax.plot(s.index, s.values * 100, lw=2 if m == C.FINAL[task] else 1, c=PAL[k % len(PAL)], label=C.MODEL_NAMES.get(m, m))
            ax.set_xlabel("epoch"); ax.set_ylabel("held-out score (%)"); ax.legend(fontsize=7, ncol=2)
            ax.set_title(f"Held-out score per epoch, every architecture ({task})")
            save(fig, "training", f"learning_curves_all_models_{task}", ax.get_title(),
                 "Mean held-out score (static/dynamic mean for HAR, balanced accuracy for social) over the 10 folds after each epoch.")
    j = read("jobs_index")
    if not j.empty:
        d = j[j.status == "ok"].groupby(["group", "task", "model"]).seconds.mean().reset_index()
        d = d[d.group.isin(["main", "baseline"])]
        if not d.empty:
            fig, ax = plt.subplots(figsize=(6.5, 3))
            lab = [f"{C.MODEL_NAMES.get(m, m)} ({t})" for t, m in zip(d.task, d.model)]
            ax.barh(lab, d.seconds / 60, color=[PAL[0] if t == "har" else PAL[1] for t in d.task])
            ax.set_xlabel("minutes per fold (training + testing, this Mac, 2 threads)"); ax.set_title("Training cost per fold")
            save(fig, "training", "training_time", "Training cost per fold", "Wall-clock time per fold job on an Apple M1 Pro "
                 "(2 threads per job, 4 jobs in parallel).")


# ───────────────────────── official-fold results
def _main_pc():
    pc = read("per_fold_class")
    return pc[pc.group == "main"] if not pc.empty else pc


def fig_results():
    pc, s = _main_pc(), read("summary_per_class")
    if pc.empty:
        return
    for task in ("har", "social"):
        cs = classes(task)
        fig, ax = plt.subplots(figsize=(6.5, 2.9))
        width = 0.38
        for k, v in enumerate(C.SCOPES):
            d = s[(s.group == "main") & (s.task == task) & (s.variant == v)].set_index("class").reindex(cs)
            if d["mean"].isna().all():
                continue
            x = np.arange(len(cs)) + (k - 0.5) * width
            ax.bar(x, d["mean"] * 100, width, yerr=d.fold_std * 100, color=VAR_COL[v], label=VAR_LAB[v], capsize=2, error_kw={"lw": 0.7})
            for xi, m in zip(x, d["mean"] * 100):
                ax.text(xi, 2, f"{m:.0f}", ha="center", fontsize=6, color="white", rotation=90)
        targets(ax, task)
        ax.set_xticks(range(len(cs))); ax.set_xticklabels(short(cs), rotation=35); ax.set_ylim(0, 105); ax.set_ylabel("recall (%)")
        ax.legend(fontsize=7, loc="upper left", bbox_to_anchor=(1.01, 1)); ax.set_title(f"Per-class accuracy, official 10-fold CV ({task})")
        save(fig, "results", f"per_class_{task}", ax.get_title(), "Mean over the 10 official folds of each class's recall "
             "(the marked number), error bars = sd over folds. Blue: every test window of each fold (datasetJan2026 + the group "
             "member in that fold); grey: the datasetJan2026 windows only, i.e. what the CW3 marking computes.")
        # group scores
        fs = read("fold_scores"); fs = fs[fs.group == "main"]
        mets = ["static", "dynamic"] if task == "har" else ["social", "social_min"]
        fig, ax = plt.subplots(figsize=(4.2, 2.6))
        for k, v in enumerate(C.SCOPES):
            d = fs[(fs.task == task) & (fs.variant == v)]
            if d.empty:
                continue
            per_seed = d.groupby("seed")[mets].mean()
            ax.bar(np.arange(len(mets)) + (k - 0.5) * 0.38, per_seed.mean() * 100, 0.38, yerr=d[d.seed == 0][mets].std() * 100,
                   color=VAR_COL[v], label=VAR_LAB[v], capsize=3)
        targets(ax, task)
        ax.set_xticks(range(len(mets))); ax.set_xticklabels(["static mean", "dynamic mean"] if task == "har" else ["balanced", "weakest class"])
        ax.set_ylim(0, 105); ax.set_ylabel("%"); ax.legend(fontsize=6.5, loc="upper left", bbox_to_anchor=(1.01, 1)); ax.set_title(f"Group scores ({task})")
        save(fig, "results", f"group_scores_{task}", ax.get_title(), "Marked group scores (mean over folds and seeds); error bars = sd over folds.")
        # heatmap fold x class
        for v in C.SCOPES:
            d = pc[(pc.task == task) & (pc.variant == v) & (pc.seed == 0)].pivot_table(index="class", columns="fold", values="recall").reindex(cs)
            if d.empty or d.isna().all().all():
                continue
            fig, ax = plt.subplots(figsize=(6.5, 0.3 * len(cs) + 1.3))
            im = ax.imshow(d.values * 100, cmap="RdYlGn", vmin=50, vmax=100, aspect="auto")
            for (i, jj), val in np.ndenumerate(d.values * 100):
                ax.text(jj, i, f"{val:.0f}", ha="center", va="center", fontsize=6.5)
            ax.set_yticks(range(len(cs))); ax.set_yticklabels(short(cs)); ax.set_xticks(range(d.shape[1])); ax.set_xticklabels(d.columns)
            ax.set_xlabel("fold"); fig.colorbar(im, ax=ax, label="recall (%)")
            ax.set_title(f"Recall per class and fold ({task}, {VAR_LAB[v]}, seed 0)")
            save(fig, "results", f"fold_heatmap_{task}_{v.replace('+', '_')}", ax.get_title(), "Every fold's recall per class: shows which folds (groups of subjects) are hard.")
        # strip / box per class
        d = pc[(pc.task == task) & (pc.variant == C.HEADLINE)]
        if not d.empty:
            fig, ax = plt.subplots(figsize=(6.5, 2.8))
            data = [d[d["class"] == c].recall * 100 for c in cs]
            ax.boxplot(data, showfliers=False, widths=0.5)
            for i, vals in enumerate(data):
                ax.scatter(np.random.default_rng(i).normal(i + 1, 0.06, len(vals)), vals, s=6, alpha=0.6, c=PAL[0])
            targets(ax, task); ax.set_xticks(range(1, len(cs) + 1)); ax.set_xticklabels(short(cs), rotation=35)
            ax.set_ylabel("recall (%)"); ax.set_title(f"Spread over folds and seeds ({task}, {VAR_LAB[C.HEADLINE]})")
            save(fig, "results", f"fold_spread_{task}", ax.get_title(), "Each dot is one fold of one seed; boxes show the median and quartiles.")
            # seeds
            g = d.groupby(["class", "seed"]).recall.mean().unstack()
            if g.shape[1] > 1:
                g = g.reindex(cs)
                fig, ax = plt.subplots(figsize=(6.5, 2.5))
                for k, sd in enumerate(g.columns):
                    ax.scatter(np.arange(len(cs)) + (k - 1) * 0.12, g[sd] * 100, s=18, c=PAL[k], label=f"seed {sd}")
                ax.set_xticks(range(len(cs))); ax.set_xticklabels(short(cs), rotation=35); ax.set_ylabel("fold-mean recall (%)")
                ax.legend(fontsize=7); ax.set_title(f"Run-to-run variation across training seeds ({task})")
                save(fig, "results", f"seed_variation_{task}", ax.get_title(), "The marked number for each of the 3 training seeds: "
                     "the spread shows how much of a difference between models could be chance.")
        # precision recall f1
        d = s[(s.group == "main") & (s.task == task) & (s.variant == C.HEADLINE)].set_index("class").reindex(cs)
        if not d["mean"].isna().all():
            fig, ax = plt.subplots(figsize=(6.5, 2.6))
            for k, (col, lab) in enumerate([("mean", "recall (marked)"), ("precision", "precision"), ("f1", "F1")]):
                ax.bar(np.arange(len(cs)) + (k - 1) * 0.27, d[col] * 100, 0.27, color=PAL[k], label=lab)
            ax.set_xticks(range(len(cs))); ax.set_xticklabels(short(cs), rotation=35); ax.set_ylim(0, 105); ax.legend(fontsize=7, loc="upper left", bbox_to_anchor=(1.01, 1))
            ax.set_title(f"Recall, precision and F1 per class ({task})")
            save(fig, "results", f"precision_recall_f1_{task}", ax.get_title(), "Recall is what the marking uses; precision shows how "
                 "often a predicted class is right, which matters to an app user.")
    # confusion matrices
    cm = read("confusion_long")
    if not cm.empty:
        cm = cm[cm.group == "main"]
        for task in ("har", "social"):
            cs = classes(task)
            for v in C.SCOPES:
                d = cm[(cm.task == task) & (cm.variant == v) & (cm.seed == 0)].groupby(["true", "pred"])["count"].sum().unstack().reindex(index=cs, columns=cs).fillna(0)
                if d.values.sum() == 0:
                    continue
                for norm in (True, False):
                    m = d.values / d.values.sum(1, keepdims=True) * 100 if norm else d.values
                    fig, ax = plt.subplots(figsize=(5.2, 4.4) if task == "har" else (3.6, 3.1))
                    im = ax.imshow(m, cmap="Blues", vmin=0, vmax=100 if norm else None)
                    for (i, jj), val in np.ndenumerate(m):
                        if val >= (0.5 if norm else 1):
                            ax.text(jj, i, f"{val:.0f}" if norm else f"{int(val)}", ha="center", va="center", fontsize=6.5 if task == "har" else 8,
                                    color="white" if (val > 60 if norm else val > m.max() * 0.6) else "black")
                    ax.set_xticks(range(len(cs))); ax.set_xticklabels(short(cs), rotation=45, ha="right"); ax.set_yticks(range(len(cs)))
                    ax.set_yticklabels(short(cs)); ax.set_xlabel("predicted"); ax.set_ylabel("true")
                    fig.colorbar(im, ax=ax, fraction=0.046, label="% of true class" if norm else "windows")
                    ax.set_title(f"Confusion matrix, {task}, {VAR_LAB[v]}{' (row %)' if norm else ' (counts)'}", fontsize=9)
                    save(fig, "results", f"confusion_{task}_{v.replace('+', '_')}_{'pct' if norm else 'counts'}", ax.get_title(),
                         "All test windows of the 10 folds pooled (seed 0). Rows = true class; the diagonal is the recall.")
            d = cm[(cm.task == "social") & (cm.variant == C.HEADLINE) & (cm.seed == 0)]
            if task == "social" and not d.empty:
                fig, axs = plt.subplots(2, 5, figsize=(7.5, 3.4))
                for k, ax in enumerate(axs.flat):
                    m = d[d.fold == k].groupby(["true", "pred"])["count"].sum().unstack().reindex(index=cs, columns=cs).fillna(0).values
                    if m.sum() == 0:
                        ax.axis("off"); continue
                    m = m / m.sum(1, keepdims=True) * 100
                    ax.imshow(m, cmap="Blues", vmin=0, vmax=100)
                    for (i, jj), val in np.ndenumerate(m):
                        ax.text(jj, i, f"{val:.0f}", ha="center", va="center", fontsize=5.5, color="white" if val > 60 else "black")
                    ax.set_title(f"fold {k}", fontsize=7); ax.set_xticks([]); ax.set_yticks([])
                fig.suptitle("Social confusion matrix per fold (row %, order: breathing, coughing, hypervent., other)", fontsize=8)
                save(fig, "results", "confusion_social_per_fold", "Social confusion per fold", "Row-normalised confusion matrix of every fold.")
    # recording level
    rl = read("recording_level")
    if not rl.empty:
        for task in ("har", "social"):
            d = rl[(rl.task == task) & (rl.variant == C.HEADLINE) & (rl.seed == 0)]
            if d.empty:
                continue
            cs = classes(task)
            fig, ax = plt.subplots(figsize=(6.5, 2.7))
            parts = ax.violinplot([d[d["class"] == c].frac_correct * 100 for c in cs], showmedians=True)
            for b in parts["bodies"]:
                b.set_alpha(0.5)
            ax.set_xticks(range(1, len(cs) + 1)); ax.set_xticklabels(short(cs), rotation=35); ax.set_ylabel("% of windows correct")
            ax.set_title(f"Per-recording accuracy ({task})")
            save(fig, "results", f"recording_accuracy_{task}", ax.get_title(), "Share of correctly classified windows within each test "
                 "recording. Mass near 0 means whole recordings (people) are misread, not single windows.")
    # calibration
    cal = read("calibration_bins")
    if not cal.empty:
        fig, axs = plt.subplots(1, 2, figsize=(6.5, 2.8))
        for ax, task in zip(axs, ("har", "social")):
            for v in C.SCOPES:
                d = cal[(cal.task == task) & (cal.variant == v)].groupby("bin").apply(lambda g: pd.Series(
                    {"acc": np.average(g.acc.fillna(0), weights=g.n) if g.n.sum() else np.nan,
                     "conf": np.average(g.conf.fillna(0), weights=g.n) if g.n.sum() else np.nan, "n": g.n.sum()}))
                d = d[d.n > 0]
                ax.plot(d.conf, d.acc, "o-", c=VAR_COL[v], ms=3, label=VAR_LAB[v])
            ax.plot([0, 1], [0, 1], "k--", lw=0.8); ax.set_xlabel("predicted confidence"); ax.set_ylabel("observed accuracy"); ax.set_title(task)
        axs[0].legend(fontsize=7)
        save(fig, "results", "calibration", "Reliability diagram", "Accuracy of test windows grouped by the model's confidence. "
             "On the diagonal = confidence can be trusted (e.g. for showing a confidence value in the app).")
    _roc_pr()
    ts = read("tsne")
    if not ts.empty:
        for task in ("har", "social"):
            d = ts[ts.task == task]
            if d.empty:
                continue
            fig, axs = plt.subplots(1, 2, figsize=(7, 3.3))
            for k, c in enumerate(classes(task)):
                m = d.true == c
                axs[0].scatter(d.x[m], d.y[m], s=3, c=PAL[k % len(PAL)], label=SHORT[c])
            wrong = d.true != d.pred
            axs[1].scatter(d.x[~wrong], d.y[~wrong], s=3, c="#cccccc", label="correct")
            axs[1].scatter(d.x[wrong], d.y[wrong], s=5, c="#D55E00", label="misclassified")
            for ax in axs:
                ax.set_xticks([]); ax.set_yticks([])
            axs[0].legend(fontsize=6, markerscale=3, ncol=2); axs[1].legend(fontsize=7, markerscale=3)
            fig.suptitle(f"t-SNE of the learned representation ({task}, fold 0 test windows)", fontsize=9)
            save(fig, "results", f"tsne_{task}", f"t-SNE embedding ({task})", "Penultimate-layer activations of held-out windows, "
                 "projected to 2-D. Overlapping clusters are the classes the model confuses.")


def _roc_pr():
    from sklearn.metrics import roc_curve, precision_recall_curve, auc
    from .analyze import npz
    for task in ("har", "social"):
        Ps, ys = [], []
        for k in C.FOLDS:
            hits = sorted((C.OUT / "jobs").glob(f"main_{task}_*_s0_f{k}.npz"))
            z = np.load(hits[0]) if hits else None
            if z is not None and "cv__P" in z:
                Ps.append(z["cv__P"]); ys.append(z["cv__y"])
        if not Ps:
            continue
        P, y = np.concatenate(Ps), np.concatenate(ys)
        fig, axs = plt.subplots(1, 2, figsize=(6.8, 3))
        for c, name in enumerate(classes(task)):
            f, t, _ = roc_curve(y == c, P[:, c]); pr, rc, _ = precision_recall_curve(y == c, P[:, c])
            axs[0].plot(f, t, lw=1, c=PAL[c % len(PAL)], label=f"{SHORT[name]} ({auc(f, t):.3f})")
            axs[1].plot(rc, pr, lw=1, c=PAL[c % len(PAL)])
        axs[0].plot([0, 1], [0, 1], "k--", lw=0.6); axs[0].set_xlabel("false positive rate"); axs[0].set_ylabel("true positive rate")
        axs[1].set_xlabel("recall"); axs[1].set_ylabel("precision"); axs[0].legend(fontsize=6, title="AUC", title_fontsize=6)
        fig.suptitle(f"One-vs-rest ROC and precision–recall curves ({task}, pooled folds)", fontsize=9)
        save(fig, "results", f"roc_pr_{task}", f"ROC and PR curves ({task})", "Per-class ROC (with AUC) and precision–recall curves "
             "of the headline models, all test windows pooled.")


# ───────────────────────── architecture comparison, class-weight sweep, deployment
def fig_comparison():
    fs, dep, pc = read("fold_scores"), read("deploy"), read("per_fold_class")
    if fs.empty:
        return
    for task in ("har", "social"):
        d = fs[(fs.task == task) & (fs.seed == 0) & (fs.variant == C.HEADLINE) & fs.group.isin(["main", "baseline"])]
        if d.empty:
            continue
        mets = ["static", "dynamic"] if task == "har" else ["social", "social_min"]
        g = d.groupby("model")[mets].agg(["mean", "std"])
        order = g[(mets[1], "mean")].sort_values().index if task == "har" else g[(mets[0], "mean")].sort_values().index
        fig, ax = plt.subplots(figsize=(6.5, 0.35 * len(order) + 1.2))
        y = np.arange(len(order))
        for k, m in enumerate(mets):
            ax.barh(y + (k - 0.5) * 0.38, g.loc[order, (m, "mean")] * 100, 0.38, xerr=g.loc[order, (m, "std")] * 100,
                    color=PAL[k], label={"static": "static mean", "dynamic": "dynamic mean", "social": "balanced", "social_min": "weakest class"}[m], capsize=2)
        ax.set_yticks(y); ax.set_yticklabels([("★ " if m == C.FINAL[task] else "") + C.MODEL_NAMES.get(m, m) for m in order])
        for v in ([90, 85] if task == "har" else [75]):
            ax.axvline(v, c="k", ls=":", lw=0.8)
        ax.set_xlabel("% (10-fold CV, all test windows, seed 0)"); ax.legend(fontsize=7, loc="upper left", bbox_to_anchor=(1.01, 1)); ax.set_xlim(0, 100)
        ax.set_title(f"Architecture comparison ({task})")
        save(fig, "comparison", f"architectures_{task}", ax.get_title(), "Each of our four architectures trained and tested on the same "
             "folds with the same data. ★ = deployed model. Error bars = sd over folds.")
        p = pc[(pc.task == task) & (pc.seed == 0) & (pc.variant == C.HEADLINE) & pc.group.isin(["main", "baseline"])]
        h = p.groupby(["model", "class"]).recall.mean().unstack().reindex(columns=classes(task)).reindex(order)
        fig, ax = plt.subplots(figsize=(6.5, 0.32 * len(h) + 1.4))
        im = ax.imshow(h.values * 100, cmap="RdYlGn", vmin=40, vmax=100, aspect="auto")
        for (i, jj), v in np.ndenumerate(h.values * 100):
            ax.text(jj, i, f"{v:.0f}", ha="center", va="center", fontsize=6.5)
        ax.set_yticks(range(len(h))); ax.set_yticklabels([C.MODEL_NAMES.get(m, m) for m in h.index], fontsize=7)
        ax.set_xticks(range(h.shape[1])); ax.set_xticklabels(short(h.columns), rotation=40, ha="right"); fig.colorbar(im, ax=ax, label="recall (%)")
        ax.set_title(f"Per-class recall of every architecture ({task})")
        save(fig, "comparison", f"architectures_per_class_{task}", ax.get_title(), "Which classes each architecture gets right; "
             "the weak classes are shared by all models, i.e. they are hard in the data, not only for one model.")
        if not dep.empty:
            dd = dep[(dep.task == task) & ~dep.model.str.contains("final")].drop_duplicates("model").set_index("model")
            score = g[(mets[1] if task == "har" else mets[0], "mean")] * 100
            k = dd.index.intersection(score.index)
            if len(k):
                fig, axs = plt.subplots(1, 2, figsize=(6.8, 2.8))
                for ax, col, lab in [(axs[0], "size_kb", "model size (KB)"), (axs[1], "ms_per_window", "inference time per window (ms, 1 thread)")]:
                    ax.scatter(dd.loc[k, col], score[k], c=[PAL[3] if m == C.FINAL[task] else PAL[0] for m in k], s=25)
                    for m in k:
                        ax.annotate(C.MODEL_NAMES.get(m, m).split(" (")[0], (dd.loc[m, col], score[m]), fontsize=6, xytext=(3, 2), textcoords="offset points")
                    ax.set_xlabel(lab)
                axs[0].set_ylabel("dynamic mean (%)" if task == "har" else "social balanced (%)")
                fig.suptitle(f"Accuracy vs cost ({task}; red = deployed)", fontsize=9)
                save(fig, "comparison", f"accuracy_vs_cost_{task}", f"Accuracy vs model cost ({task})",
                     "Trade-off between accuracy and TFLite size / single-window latency on this Mac (a phone is slower, but the ranking holds).")
    # class-weight sweep
    s = read("summary_per_class")
    if not s.empty:
        d = s[(s.task == "social") & s.group.isin(["sweep", "main"]) & (s.variant == C.HEADLINE)]
        if d.power.nunique() > 1:
            fig, ax = plt.subplots(figsize=(5.5, 3))
            for k, c in enumerate(SOCIAL_CLASSES):
                q = d[d["class"] == c].sort_values("power")
                ax.plot(q.power, q["mean"] * 100, "o-", c=PAL[k], label=SHORT[c], ms=4)
            mn = d.groupby("power")["mean"].min().sort_index()
            ax.plot(mn.index, mn.values * 100, "k--", lw=1, label="weakest class")
            ax.axhline(75, c="r", ls=":", lw=1); ax.axvline(C.SOCIAL_POWER, c="#999999", lw=6, alpha=0.3)
            ax.set_xlabel("class-weight power (0 = none, 1 = fully balanced)"); ax.set_ylabel("fold-mean recall (%)")
            ax.legend(fontsize=7, loc="upper left", bbox_to_anchor=(1.01, 1)); ax.set_title("Social: effect of class weighting")
            save(fig, "comparison", "class_weight_sweep", "Class-weight sweep (social)", "Each class's marked recall as the class "
                 "weights move from none (0) to fully balanced (1). The grey band is the chosen setting.")
    st = read("stat_tests")
    if not st.empty:
        d = st.sort_values("mean_diff")
        fig, ax = plt.subplots(figsize=(6.5, 0.26 * len(d) + 1))
        ax.barh(range(len(d)), d.mean_diff * 100, color=[PAL[2] if p < 0.05 else PAL[8] for p in d.p_wilcoxon.fillna(1)])
        ax.set_yticks(range(len(d))); ax.set_yticklabels([f"{c} [{m}, {sc}]" for c, m, sc in zip(d.comparison, d.metric, d.scope)], fontsize=6)
        for i, (v, p) in enumerate(zip(d.mean_diff * 100, d.p_wilcoxon)):
            ax.text(v, i, f" p={p:.3f}" if pd.notna(p) else "", va="center", fontsize=5.5)
        ax.axvline(0, c="k", lw=0.8); ax.set_xlabel("mean difference over folds (percentage points; A − B in 'A vs B')")
        ax.set_title("Paired comparisons (Wilcoxon signed-rank over 10 folds; green = p < 0.05)")
        save(fig, "comparison", "paired_tests", "Paired statistical comparisons", "Differences between models / settings on the same "
             "folds with Wilcoxon signed-rank p-values (10 folds = small sample, so p ≥ 0.002 is the smallest possible).")
    if not dep.empty:
        for col, lab, fn in [("size_kb", "TFLite size (KB)", "model_size"), ("ms_per_window", "ms per window (1 thread, Mac)", "inference_time"),
                             ("params", "parameters", "parameters")]:
            d = dep.dropna(subset=[col]).sort_values(col)
            if d.empty:
                continue
            fig, ax = plt.subplots(figsize=(6.5, 0.24 * len(d) + 1))
            ax.barh([f"{C.MODEL_NAMES.get(m.split(' ')[0], m)} [{t}]{' final' if 'final' in m else ''}" for m, t in zip(d.model, d.task)], d[col],
                    color=[PAL[0] if t == "har" else PAL[1] for t in d.task])
            ax.set_xlabel(lab); ax.set_title(lab)
            save(fig, "deploy", fn, lab, "Deployment cost of each of our architectures (blue = HAR, orange = social).")


# ───────────────────────── group members (unseen-person folds) and the social window choice
def fig_real():
    pp = read("person_per_class")
    if not pp.empty:
        for task in ("har", "social"):
            d = pp[pp.task == task]
            if d.empty:
                continue
            cs = classes(task)
            fig, ax = plt.subplots(figsize=(6.5, 2.7))
            for k, person in enumerate(C.PEOPLE):
                q = d[d.person == person].set_index("class").recall.reindex(cs)
                ax.bar(np.arange(len(cs)) + (k - 0.5) * 0.38, q * 100, 0.38, color=PAL[k], label=f"{C.PEOPLE[person]} (fold {int(d[d.person == person].fold.iloc[0]) if (d.person == person).any() else '?'})")
            targets(ax, task); ax.set_ylim(0, 105); ax.set_ylabel("recall (%)")
            ax.set_xticks(range(len(cs))); ax.set_xticklabels(short(cs), rotation=35)
            ax.legend(fontsize=6.5, loc="upper left", bbox_to_anchor=(1.01, 1))
            ax.set_title(f"Group members as unseen test subjects ({task})")
            save(fig, "real", f"person_{task}", f"Group members as unseen subjects ({task})", "Each member's recordings are the "
                 "test set of one fold, so these models never saw that person (the other member and the other 9 Jan2026 folds "
                 "were in training). Mean over the 3 seeds.")
    po = read("person_postures")
    if not po.empty:
        g = po.groupby(["person", "postures"]).balanced.mean().unstack()
        fig, ax = plt.subplots(figsize=(5.5, 2.5))
        g.plot.bar(ax=ax, color=PAL[:3], rot=0)
        ax.axhline(0.75, c="r", ls=":", lw=1); ax.set_ylabel("balanced accuracy"); ax.set_xlabel("")
        ax.legend(fontsize=7, loc="upper left", bbox_to_anchor=(1.01, 1)); ax.set_title("Social accuracy on the group members by posture")
        save(fig, "real", "person_social_postures", "Social accuracy by posture (group members)", "Sitting/standing vs lying, on the "
             "fold where each member is the unseen test subject (seed 0).")
    ws = read("social_window_study_summary")
    if not ws.empty:
        ws = ws.set_index(ws.columns[0])
        lat = ws["lat_med_real"] if "lat_med_real" in ws else None
        fig, axs = plt.subplots(1, 2, figsize=(7, 2.9))
        cs = SOCIAL_CLASSES
        for k, c in enumerate(cs):
            axs[0].bar(np.arange(len(ws)) + (k - 1.5) * 0.2, ws[c], 0.2, color=PAL[k], label=SHORT[c])
        axs[0].axhline(75, c="r", ls=":", lw=1); axs[0].axhline(C.MIN_CLASS_RULE * 100, c="k", ls="--", lw=0.8)
        axs[0].set_xticks(range(len(ws))); axs[0].set_xticklabels(ws.index, fontsize=7); axs[0].set_ylim(50, 100)
        axs[0].set_ylabel("fold-mean recall (%)"); axs[0].legend(fontsize=6, ncol=2); axs[0].set_title("accuracy per class")
        if lat is not None:
            for name in ws.index:
                c = PAL[3] if name == C.SOCIAL_CANDIDATE else PAL[0]
                axs[1].scatter(lat[name], ws.loc[name, "min_class"], s=40, c=c)
                axs[1].annotate(name, (lat[name], ws.loc[name, "min_class"]), fontsize=7, xytext=(4, 2), textcoords="offset points")
            axs[1].axhline(C.MIN_CLASS_RULE * 100, c="k", ls="--", lw=0.8, label="rule: every class ≥ 77 %")
            axs[1].set_xlabel("median s until shown (group recordings)"); axs[1].set_ylabel("weakest class (%)")
            axs[1].legend(fontsize=7); axs[1].set_title("speed vs weakest class")
        fig.suptitle("Choosing the social window (official folds, Jan2026 training; red = chosen)", fontsize=9, y=1.04)
        save(fig, "real", "social_window_choice", "Choosing the social window", "Candidates: 4/5/6/8 s windows and an 8 s model "
             "trained to answer from the most recent seconds (rec). Left: marked per-class recall; right: replayed app latency "
             "(32-sample packets, 0.5 s updates) against the weakest class. The fastest candidate keeping every class ≥ 77 % is used.")
    st = read("social_window_study_streams")
    if not st.empty:
        d = st[st.stream == "real"]
        fig, ax = plt.subplots(figsize=(6.5, 2.7))
        names = list(dict.fromkeys(d.cand))
        ax.boxplot([d[d.cand == n].lat_s6.dropna() for n in names], showfliers=False)
        ax.set_xticks(range(1, len(names) + 1)); ax.set_xticklabels(names)
        ax.set_ylabel("seconds until shown"); ax.axhline(4.5, c="r", ls=":", lw=1, label="target ≈ 4–4.5 s")
        ax.legend(fontsize=7); ax.set_title("Social: time from a change until the new class is shown (group recordings)")
        save(fig, "real", "social_latency", "Social latency per window candidate", "App replay on same-posture changes in both members' "
             "recordings (models never trained on them): RESpeck packets of 32 samples (2.56 s), a result every 0.5 s.")


def run(log):
    CATALOGUE.clear()
    for fn in (fig_data, fig_training, fig_results, fig_comparison, fig_real):
        try:
            fn()
        except Exception:                                          # noqa: BLE001
            log(f"figure group {fn.__name__} partly failed:\n{traceback.format_exc()}")
    log(f"{len(CATALOGUE)} figures written to {FIG}")
    return CATALOGUE
