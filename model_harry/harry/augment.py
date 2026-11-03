"""Training-only augmentation as a Keras layer (same distribution as harry/train.py::augment).

Used as  train_model = Input -> RandomAugment -> core_model.  Only core_model is evaluated/exported,
so nothing random ever reaches TFLite. Running inside the graph means one model.fit() call per job
(no Python epoch loop) and the work runs on the GPU when there is one.
"""
import numpy as np
import keras
from keras import ops, layers


@keras.saving.register_keras_serializable("harry")
class RandomAugment(layers.Layer):
    def __init__(self, roll_deg=30.0, tilt_deg=10.0, amp=(0.8, 1.25), noise=0.002, seed=None, **kw):
        super().__init__(**kw)
        self.roll, self.tilt = float(np.deg2rad(roll_deg)), float(np.deg2rad(tilt_deg))
        self.amp, self.noise, self.seed = tuple(amp), float(noise), seed
        self.gen = keras.random.SeedGenerator(seed)

    def call(self, x, training=None):
        if not training:
            return x
        b = ops.shape(x)[0]
        g = ops.mean(x, axis=1, keepdims=True)
        x = g + (x - g) * keras.random.uniform((b, 1, 1), self.amp[0], self.amp[1], seed=self.gen)
        # roll about the sensor Y axis (body long axis)
        t = keras.random.uniform((b,), -self.roll, self.roll, seed=self.gen)
        c, s = ops.cos(t), ops.sin(t)
        z, o = ops.zeros_like(c), ops.ones_like(c)
        ry = ops.stack([ops.stack([c, z, s], -1), ops.stack([z, o, z], -1), ops.stack([-s, z, c], -1)], 1)
        # small tilt about a random axis (Rodrigues)
        ax = keras.random.normal((b, 3), seed=self.gen)
        ax = ax / ops.sqrt(ops.sum(ax * ax, -1, keepdims=True) + 1e-9)
        p = keras.random.uniform((b,), -self.tilt, self.tilt, seed=self.gen)
        kx, ky, kz = ax[:, 0], ax[:, 1], ax[:, 2]
        K = ops.stack([ops.stack([z, -kz, ky], -1), ops.stack([kz, z, -kx], -1), ops.stack([-ky, kx, z], -1)], 1)
        eye = ops.eye(3, dtype=x.dtype)[None]
        rt = eye + ops.sin(p)[:, None, None] * K + (1 - ops.cos(p))[:, None, None] * ops.matmul(K, K)
        R = ops.matmul(ry, rt)
        x = ops.einsum("bwc,bdc->bwd", x, R)
        return x + keras.random.normal(ops.shape(x), stddev=self.noise, seed=self.gen)

    def get_config(self):
        return {**super().get_config(), "roll_deg": float(np.rad2deg(self.roll)), "tilt_deg": float(np.rad2deg(self.tilt)),
                "amp": list(self.amp), "noise": self.noise, "seed": self.seed}
