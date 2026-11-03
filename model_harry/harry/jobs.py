"""Scenario planner: expands the config into independent, resumable jobs.

When are folds needed?  Only when training and testing use the SAME dataset (A, D): a model must never be
scored on recordings/subjects it trained on, so cross-validation rotates the test part. When train and test
sets are different datasets (B, C) there is nothing to rotate — train on the whole training dataset, test
once on the whole test dataset, and use seeds for the spread.

  A  real -> real        within-real CV (1 subject: behaviour/time-block HAR, leave-one-posture-out social;
                         >=2 subjects: leave-one-subject-out)                                 [folds × seeds]
  B  real -> Jan         train on ALL real, test on ALL Jan2026                                 [seeds]
  C  Jan -> real         train on ALL Jan2026, test on ALL real (this model is also E's pre-training) [seeds]
  D  Jan -> Jan          Lab3 B9 10-fold CV (official Learn folds if a fold CSV is configured) [folds × seeds]
  E  Jan + real -> real  C's model fine-tuned on each real CV training fold, tested on the matching A fold
  DEPLOY                 TFLite size / builtin ops / latency per architecture (no training)
"""
import re

from . import datasets as ds
from .zoo import ZOO, GROUPS

SCENARIO_TITLES = {
    "A": "A · train real → test real (within-subject CV)",
    "B": "B · train all real → test all Jan2026",
    "C": "C · train all Jan2026 → test all real",
    "D": "D · Jan2026 10-fold CV (Lab3 B9 protocol)",
    "E": "E · Jan2026 pre-train + real fine-tune → test real (A's folds)",
}


def safe(s):
    return re.sub(r"[^A-Za-z0-9_.=-]+", "_", s)


def _job(**kw):
    kw["id"] = safe("|".join(str(kw[k]) for k in ("scenario", "task", "model", "fold", "seed")))
    return kw


def plan(cfg, have_jan):
    p, S = cfg["profile_settings"], cfg["scenarios"]
    seeds = cfg["seeds"]
    order = {g: i for i, g in enumerate(GROUPS)}
    jobs = []
    for task in cfg["tasks"]:
        rset, jset = f"real_{task}", f"jan_{task}"
        rfolds = ds.real_folds(task)[: p["max_real_folds"]]
        jfolds = list(range(ds.N_JAN_FOLDS))[: p["max_jan_folds"]]
        sub = {"subsample": p["jan_subsample"]} if p["jan_subsample"] > 1 else {}
        for m in cfg["model_list"]:
            spec = ZOO[m]
            base = dict(task=task, model=m, group=spec.group, owner=spec.owner, group_order=order[spec.group])
            if "A" in S:
                for seed in seeds["real"]:
                    for fi, (fname, tr, te) in enumerate(rfolds):
                        jobs.append(_job(scenario="A", fold=fname, seed=seed, seed_int=seed * 100 + fi, regime="real",
                                         train={"set": rset, "segments": tr},
                                         evals={"real_test": {"set": rset, "segments": te}},
                                         monitors=["real_test"], size="small", **base))
            if not have_jan:
                continue
            if "B" in S:
                for seed in seeds["real"]:
                    jobs.append(_job(scenario="B", fold="all", seed=seed, seed_int=seed * 100, regime="real",
                                     train={"set": rset}, evals={"jan_all": {"set": jset, **sub},
                                                                 "monitor:jan_sample": {"set": jset, "every_nth": 10}},
                                     monitors=["monitor:jan_sample"], size="small", **base))
            if "D" in S:
                for seed in seeds["jan_cv"]:
                    for k in jfolds:
                        jobs.append(_job(scenario="D", fold=f"jan_fold={k}", seed=seed, seed_int=seed * 100 + k,
                                         regime="jan", train={"set": jset, "fold_ne": k, **sub},
                                         evals={"jan_test": {"set": jset, "fold_eq": k, **sub}},
                                         monitors=["jan_test"], size="big", **base))
            if "C" in S or "E" in S:
                for seed in seeds["jan_full"]:
                    pre = _job(scenario="C", fold="all", seed=seed, seed_int=seed * 100 + 99, regime="jan",
                               train={"set": jset, **sub}, evals={"real_all": {"set": rset}}, monitors=["real_all"],
                               size="big", save_model="E" in S and spec.kind == "keras", **base)
                    jobs.append(pre)
                    if "E" not in S or spec.kind != "keras":            # sklearn models cannot be fine-tuned
                        continue
                    for fi, (fname, tr, te) in enumerate(rfolds):
                        jobs.append(_job(scenario="E", fold=fname, seed=seed, seed_int=seed * 100 + fi,
                                         regime="finetune", train={"set": rset, "segments": tr},
                                         evals={"real_test": {"set": rset, "segments": te}},
                                         monitors=["real_test"], size="small", depends=pre["id"], **base))
        if "DEPLOY" in S:
            for m in cfg["model_list"]:
                spec = ZOO[m]
                jobs.append(_job(scenario="DEPLOY", task=task, model=m, group=spec.group, owner=spec.owner,
                                 group_order=order[spec.group], fold="-", seed=0, seed_int=0, regime="deploy",
                                 train={"set": rset}, evals={}, monitors=[], size="small"))
    # group-major order (MLP, CNN, RNN, FEATURE); inside a group big jobs first for load balancing
    jobs.sort(key=lambda j: (j["group_order"], j["scenario"] == "E", j["size"] != "big", j["task"], j["model"]))
    return jobs
