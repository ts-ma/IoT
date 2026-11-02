"""Model builders.

teammate_cnn : exact replica of the teammate's B3/B9 CNN (control for G7.2)
harry        : gravity-split, multi-branch model (G2, G3); flags switch branches off for ablations
"""
import numpy as np
import keras
from keras import layers

from .layers import Gravity, DynamicChannels, LogStd, BandPower

HAR_BANDS = [(0.3, 1.0), (1.0, 1.5), (1.5, 2.0), (2.0, 2.5), (2.5, 3.5), (3.5, 6.26)]
SOCIAL_BANDS = [(0.1, 0.4), (0.4, 0.8), (0.8, 1.5), (1.5, 3.0), (3.0, 6.26)]


def teammate_cnn(window, n_classes, X_fit, name="teammate_cnn"):
    """Same layers as build_cnn_fold() in Lab3_trained.ipynb (valid padding, GAP only, global Normalization)."""
    norm = layers.Normalization(axis=-1, name="normalize")
    norm.adapt(X_fit)
    return keras.Sequential([
        keras.Input(shape=(window, 3), name="window"), norm,
        layers.Conv1D(32, 5, activation="relu"), layers.MaxPooling1D(2),
        layers.Conv1D(64, 5, activation="relu"), layers.MaxPooling1D(2),
        layers.GlobalAveragePooling1D(), layers.Dropout(0.2),
        layers.Dense(n_classes, activation="softmax", name="probabilities"),
    ], name=name)


def _conv(x, f, k, d, name):
    x = layers.Conv1D(f, k, padding="same", dilation_rate=d, use_bias=False, name=f"{name}_conv")(x)
    x = layers.BatchNormalization(name=f"{name}_bn")(x)
    return layers.Activation("relu", name=f"{name}_relu")(x)


def harry(task, window, n_classes, X_fit, use_gravity=True, use_cnn=True, use_spec=True,
          dropout=0.3, name=None):
    """Multi-branch model; every preprocessing step is inside the graph (raw g in, softmax out).

    gravity branch : window-mean vector -> Dense             (posture / orientation)
    cnn branch     : AC, |x|-mean, jerk -> dilated Conv1D -> GAP || GMP   (motion shape, bursts)
    spectral branch: log band power of AC + |x| and log-std of all dynamic channels -> Dense (cadence / rate)
    """
    bands = HAR_BANDS if task == "har" else SOCIAL_BANDS
    inp = keras.Input(shape=(window, 3), name="window")
    g = Gravity(name="gravity")(inp)
    dyn = DynamicChannels(name="dynamic")(inp)
    feats = layers.Concatenate(name="features")([
        BandPower(window, bands, name="band_power")(dyn[:, :, :4]),
        LogStd(name="log_std")(dyn)])

    # Adapt the normalisers on gravity-free representations of the training windows only.
    pre = keras.Model(inp, [g, dyn, feats])
    g_fit, dyn_fit, f_fit = pre.predict(X_fit, batch_size=1024, verbose=0)
    n_g = layers.Normalization(axis=-1, name="norm_gravity"); n_g.adapt(g_fit)
    n_d = layers.Normalization(axis=-1, name="norm_dynamic"); n_d.adapt(dyn_fit.reshape(-1, dyn_fit.shape[-1]))
    n_f = layers.Normalization(axis=-1, name="norm_features"); n_f.adapt(f_fit)

    parts = []
    if use_gravity:
        parts.append(layers.Dense(16 if task == "har" else 8, activation="relu", name="g_dense")(n_g(g)))
    if use_cnn:
        x = n_d(dyn)
        spec = ([(32, 5, 1), (32, 5, 2), "pool", (64, 3, 1)] if task == "har"
                else [(32, 7, 1), (32, 5, 2), (64, 5, 4), "pool", (64, 3, 1)])
        for i, s in enumerate(spec):
            x = layers.MaxPooling1D(2, name=f"pool{i}")(x) if s == "pool" else _conv(x, *s, name=f"c{i}")
        x = layers.Concatenate(name="gap_gmp")([layers.GlobalAveragePooling1D(name="gap")(x),
                                                layers.GlobalMaxPooling1D(name="gmp")(x)])
        parts.append(layers.Dropout(dropout, name="cnn_drop")(x))
    if use_spec:
        parts.append(layers.Dense(32, activation="relu", name="f_dense")(n_f(feats)))
    h = parts[0] if len(parts) == 1 else layers.Concatenate(name="merge")(parts)
    h = layers.Dropout(dropout, name="head_drop0")(h)
    h = layers.Dense(64, activation="relu", name="head_dense")(h)
    h = layers.Dropout(dropout, name="head_drop1")(h)
    out = layers.Dense(n_classes, activation="softmax", name="probabilities")(h)
    return keras.Model(inp, out, name=name or f"harry_{task}")


# Candidate list, fixed before any CV result was seen (PLAN.md G1.6).
CANDIDATES = {
    "har": {
        "teammate_cnn@50": dict(builder="teammate", window=50, recipe="teammate"),
        "harry_full@50":   dict(builder="harry", window=50, recipe="harry"),
        "harry_feat@50":   dict(builder="harry", window=50, recipe="harry", use_cnn=False),
    },
    "social": {
        "teammate_cnn@50":     dict(builder="teammate", window=50, recipe="teammate"),
        "harry_full@50":       dict(builder="harry", window=50, recipe="harry"),
        "harry_full@100":      dict(builder="harry", window=100, recipe="harry"),
        "harry_nograv@100":    dict(builder="harry", window=100, recipe="harry", use_gravity=False),
        "harry_feat@100":      dict(builder="harry", window=100, recipe="harry", use_cnn=False),
    },
}

# Post-hoc attribution ablation (added after the first CV result, never eligible for selection):
# her architecture trained with my recipe, to split the gain into "recipe" vs "architecture".
ABLATIONS = {
    "har": {"teammate_cnn+harry_recipe@50": dict(builder="teammate", window=50, recipe="harry")},
    "social": {"teammate_cnn+harry_recipe@50": dict(builder="teammate", window=50, recipe="harry")},
}


def build(task, cand, n_classes, X_fit):
    c = dict(cand)
    if c.pop("builder") == "teammate":
        return teammate_cnn(c["window"], n_classes, X_fit)
    kw = {k: v for k, v in c.items() if k in ("use_gravity", "use_cnn", "use_spec", "dropout")}
    return harry(task, c["window"], n_classes, X_fit, **kw)
