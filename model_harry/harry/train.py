"""Training recipes (PLAN.md G4) and augmentation.

teammate : Adam 1e-3, sparse CE, 32 fixed epochs, batch 64, no class weights, no augmentation, train step 25
harry    : AdamW + cosine decay, weight decay 1e-4, label smoothing 0.1, balanced class weights,
           fresh augmentation every epoch (Y-roll +-30 deg, any-axis +-10 deg, AC amplitude x0.8-1.25,
           noise 0.002 g), dense train windows (step 6) for time-shift variety, 60 fixed epochs
"""
import numpy as np
import keras

RECIPES = {
    "teammate": dict(epochs=32, batch=64, train_step=25),
    "harry": dict(epochs=60, batch=64, train_step=6, lr=2e-3, wd=1e-4, smoothing=0.1),
}


def rot_y(theta):
    c, s = np.cos(theta), np.sin(theta)
    R = np.zeros((len(theta), 3, 3)); R[:, 0, 0] = c; R[:, 0, 2] = s; R[:, 1, 1] = 1; R[:, 2, 0] = -s; R[:, 2, 2] = c
    return R


def rot_axis(axis, theta):
    """Rodrigues rotation, axis (n,3) unit, theta (n,)."""
    K = np.zeros((len(theta), 3, 3))
    K[:, 0, 1], K[:, 0, 2], K[:, 1, 2] = -axis[:, 2], axis[:, 1], -axis[:, 0]
    K = K - K.transpose(0, 2, 1)
    s, c = np.sin(theta)[:, None, None], np.cos(theta)[:, None, None]
    return np.eye(3)[None] + s * K + (1 - c) * (K @ K)


def rotate(X, R):
    return np.einsum("nwc,ndc->nwd", X, R).astype(np.float32)


def augment(X, rng, roll_deg=30, tilt_deg=10, amp=(0.8, 1.25), noise=0.002):
    n = len(X)
    g = X.mean(1, keepdims=True)
    X = g + (X - g) * rng.uniform(*amp, (n, 1, 1))
    ax = rng.normal(size=(n, 3)); ax /= np.linalg.norm(ax, axis=1, keepdims=True)
    R = rot_y(np.deg2rad(rng.uniform(-roll_deg, roll_deg, n))) @ rot_axis(ax, np.deg2rad(rng.uniform(-tilt_deg, tilt_deg, n)))
    X = rotate(X, R)
    return (X + rng.normal(0, noise, X.shape)).astype(np.float32)


def balanced_weights(y, n_classes):
    counts = np.bincount(y, minlength=n_classes).astype(float)
    w = np.where(counts > 0, len(y) / (n_classes * np.maximum(counts, 1)), 0.0)
    return w[y].astype(np.float32)


def fit(model, X, y, n_classes, recipe, seed=0, verbose=0):
    r = RECIPES[recipe]
    if recipe == "teammate":
        model.compile(optimizer=keras.optimizers.Adam(1e-3), loss="sparse_categorical_crossentropy",
                      metrics=["accuracy"])
        model.fit(X, y, epochs=r["epochs"], batch_size=r["batch"], shuffle=True, verbose=verbose)
        return model
    steps = int(np.ceil(len(X) / r["batch"])) * r["epochs"]
    sched = keras.optimizers.schedules.CosineDecay(r["lr"], decay_steps=steps, alpha=0.05)
    model.compile(optimizer=keras.optimizers.AdamW(sched, weight_decay=r["wd"]),
                  loss=keras.losses.CategoricalCrossentropy(label_smoothing=r["smoothing"]),
                  metrics=["accuracy"])
    rng = np.random.default_rng(seed)
    Y = keras.utils.to_categorical(y, n_classes)
    sw = balanced_weights(y, n_classes)
    for ep in range(r["epochs"]):
        model.fit(augment(X, rng), Y, sample_weight=sw, batch_size=r["batch"], epochs=ep + 1,
                  initial_epoch=ep, shuffle=True, verbose=verbose)
    return model
