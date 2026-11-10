"""Model zoo for the pipeline: the teammate's architectures (faithful replicas of Lab3_trained.ipynb)
and Harry's architectures, organised into comparison groups (MLP, CNN, RNN, FEATURE).

Every Keras model takes raw g windows (B, W, 3) and returns softmax probabilities, so all of them fit
the Lab 4 app contract. Recurrent models train with unroll=False (fast) and are rebuilt with
unroll=True only for TFLite export, exactly as Lab 3 B4 recommends.
"""
from dataclasses import dataclass, field

import keras
from keras import layers

from .layers import Gravity, DynamicChannels, LogStd, BandPower
from .models import HAR_BANDS, SOCIAL_BANDS, harry as harry_multibranch, _conv


@dataclass(frozen=True)
class Spec:
    model_id: str
    group: str            # MLP | CNN | RNN | FEATURE
    owner: str            # hers | mine
    windows: dict         # task -> window length in samples
    recipe: str           # "teammate" | "harry" (data-scale variants are picked by the runner)
    kind: str = "keras"   # keras | sklearn
    notes: str = ""
    kwargs: dict = field(default_factory=dict)


ZOO = {s.model_id: s for s in [
    # ───────────── MLP group
    Spec("her_mlp", "MLP", "hers", {"har": 50, "social": 50}, "teammate",
         notes="Lab3 A4 build_mlp: Normalization -> Flatten -> Dense64 -> Dense32 (dropout .2)"),
    Spec("harry_mlp", "MLP", "mine", {"har": 50, "social": 100}, "harry",
         notes="gravity-split front end -> flattened dynamics MLP + gravity + spectral branches"),
    # ───────────── CNN group
    Spec("her_cnn", "CNN", "hers", {"har": 50, "social": 50}, "teammate",
         notes="B3 baseline shipped as har_cnn / social_cnn: Conv32k5-Conv64k5 valid, GAP"),
    Spec("her_cnn_bn", "CNN", "hers", {"har": 50, "social": 50}, "teammate", notes="B3 exp 2: + BatchNorm"),
    Spec("her_cnn_k3", "CNN", "hers", {"har": 50, "social": 50}, "teammate", notes="B3 exp 3: kernel 3"),
    Spec("her_cnn_3conv", "CNN", "hers", {"har": 50, "social": 50}, "teammate", notes="B3 exp 4: + Conv64k3"),
    Spec("harry_cnn", "CNN", "mine", {"har": 50, "social": 100}, "harry",
         notes="multi-branch: dilated CNN (GAP||GMP) + gravity + fixed-DFT band power (= harry_full)"),
    # ───────────── RNN group
    Spec("her_lstm", "RNN", "hers", {"har": 50, "social": 50}, "teammate",
         notes="B4 shipped as har_rnn: Normalization -> LSTM32 -> dropout .2"),
    Spec("harry_rnn", "RNN", "mine", {"har": 50, "social": 100}, "harry",
         notes="gravity-split front end -> Conv stem (stride 2) -> GRU48 + gravity + spectral branches"),
    # ───────────── FEATURE group (hand-crafted features + shallow classifier)
    Spec("her_logreg", "FEATURE", "hers", {"har": 50, "social": 50}, "sklearn", kind="sklearn",
         notes="B2 best: 28 stats features (mean/std/min/max/energy/range/diff) + StandardScaler + LogReg"),
    Spec("harry_feat", "FEATURE", "mine", {"har": 50, "social": 100}, "harry",
         notes="in-graph log band power + log-std + gravity -> Dense (TFLite-deployable)"),
]}
GROUPS = ["MLP", "CNN", "RNN", "FEATURE"]


def _norm_raw(X_fit):
    n = layers.Normalization(axis=-1, name="normalize")
    n.adapt(X_fit)
    return n


def _her_seq(name, window, body, X_fit, n_classes):
    return keras.Sequential([keras.Input(shape=(window, 3), name="window"), _norm_raw(X_fit), *body,
                             layers.Dense(n_classes, activation="softmax", name="probabilities")], name=name)


def _harry_frontend(task, window, X_fit):
    """Shared gravity-split front end; returns input, normalised dynamics, gravity branch, spectral branch."""
    bands = HAR_BANDS if task == "har" else SOCIAL_BANDS
    inp = keras.Input(shape=(window, 3), name="window")
    g = Gravity(name="gravity")(inp)
    dyn = DynamicChannels(name="dynamic")(inp)
    feats = layers.Concatenate(name="features")([BandPower(window, bands, name="band_power")(dyn[:, :, :4]),
                                                 LogStd(name="log_std")(dyn)])
    g_fit, d_fit, f_fit = keras.Model(inp, [g, dyn, feats]).predict(X_fit, batch_size=2048, verbose=0)
    n_g = layers.Normalization(axis=-1, name="norm_gravity"); n_g.adapt(g_fit)
    n_d = layers.Normalization(axis=-1, name="norm_dynamic"); n_d.adapt(d_fit.reshape(-1, d_fit.shape[-1]))
    n_f = layers.Normalization(axis=-1, name="norm_features"); n_f.adapt(f_fit)
    g_branch = layers.Dense(16 if task == "har" else 8, activation="relu", name="g_dense")(n_g(g))
    f_branch = layers.Dense(32, activation="relu", name="f_dense")(n_f(feats))
    return inp, n_d(dyn), g_branch, f_branch


def _harry_head(inp, parts, n_classes, name, dropout=0.3):
    h = layers.Concatenate(name="merge")(parts)
    h = layers.Dropout(dropout, name="head_drop0")(h)
    h = layers.Dense(64, activation="relu", name="head_dense")(h)
    h = layers.Dropout(dropout, name="head_drop1")(h)
    return keras.Model(inp, layers.Dense(n_classes, activation="softmax", name="probabilities")(h), name=name)


def build(model_id, task, n_classes, X_fit, for_export=False):
    """Return an (untrained) Keras model whose normalisers are adapted on X_fit (training windows only)."""
    s = ZOO[model_id]
    W = s.windows[task]
    if model_id == "her_mlp":
        return _her_seq("her_mlp", W, [layers.Flatten(), layers.Dense(64, activation="relu"), layers.Dropout(0.2),
                                       layers.Dense(32, activation="relu"), layers.Dropout(0.2)], X_fit, n_classes)
    if model_id == "her_cnn":
        return _her_seq("her_cnn", W, [layers.Conv1D(32, 5, activation="relu"), layers.MaxPooling1D(2),
                                       layers.Conv1D(64, 5, activation="relu"), layers.MaxPooling1D(2),
                                       layers.GlobalAveragePooling1D(), layers.Dropout(0.2)], X_fit, n_classes)
    if model_id == "her_cnn_bn":
        body = []
        for f in (32, 64):
            body += [layers.Conv1D(f, 5, use_bias=False), layers.BatchNormalization(), layers.Activation("relu"),
                     layers.MaxPooling1D(2)]
        return _her_seq("her_cnn_bn", W, body + [layers.GlobalAveragePooling1D(), layers.Dropout(0.2)], X_fit, n_classes)
    if model_id == "her_cnn_k3":
        return _her_seq("her_cnn_k3", W, [layers.Conv1D(32, 3, activation="relu"), layers.MaxPooling1D(2),
                                          layers.Conv1D(64, 3, activation="relu"), layers.MaxPooling1D(2),
                                          layers.GlobalAveragePooling1D(), layers.Dropout(0.2)], X_fit, n_classes)
    if model_id == "her_cnn_3conv":
        return _her_seq("her_cnn_3conv", W, [layers.Conv1D(32, 5, activation="relu"), layers.MaxPooling1D(2),
                                             layers.Conv1D(64, 5, activation="relu"), layers.MaxPooling1D(2),
                                             layers.Conv1D(64, 3, activation="relu"),
                                             layers.GlobalAveragePooling1D(), layers.Dropout(0.2)], X_fit, n_classes)
    if model_id == "her_lstm":
        return _her_seq("her_lstm", W, [layers.LSTM(32, unroll=for_export, name="lstm"), layers.Dropout(0.2)],
                        X_fit, n_classes)
    if model_id == "harry_cnn":
        return harry_multibranch(task, W, n_classes, X_fit, name="harry_cnn")
    if model_id == "harry_feat":
        return harry_multibranch(task, W, n_classes, X_fit, use_cnn=False, name="harry_feat")
    if model_id == "harry_mlp":
        inp, dyn, g_b, f_b = _harry_frontend(task, W, X_fit)
        x = layers.Flatten(name="flat")(dyn)
        x = layers.Dense(64, activation="relu", name="mlp_dense0")(x)
        x = layers.Dropout(0.3, name="mlp_drop")(x)
        x = layers.Dense(64, activation="relu", name="mlp_dense1")(x)
        return _harry_head(inp, [g_b, x, f_b], n_classes, "harry_mlp")
    if model_id == "harry_rnn":
        inp, dyn, g_b, f_b = _harry_frontend(task, W, X_fit)
        x = _conv(dyn, 32, 5, 1, name="stem")
        x = layers.MaxPooling1D(2, name="stem_pool")(x)           # halves the sequence -> cheaper recurrence
        x = layers.GRU(48, unroll=for_export, name="gru")(x)
        x = layers.Dropout(0.3, name="gru_drop")(x)
        return _harry_head(inp, [g_b, x, f_b], n_classes, "harry_rnn")
    raise KeyError(model_id)
