"""In-model preprocessing layers (PLAN.md G2.1, G2.2, G3.2).

All of them use only keras.ops primitives that lower to TFLite builtins (mean, sub, mul, sqrt, matmul,
log, concat, pad) so the exported model keeps the Lab 4 contract: raw g in, softmax out, no Flex ops.
"""
import numpy as np
import keras
from keras import ops, layers


@keras.saving.register_keras_serializable("harry")
class Gravity(layers.Layer):
    """(B, W, 3) -> (B, 3): mean over the window = gravity direction = posture."""
    def call(self, x):
        return ops.mean(x, axis=1)


@keras.saving.register_keras_serializable("harry")
class DynamicChannels(layers.Layer):
    """(B, W, 3) -> (B, W, 7): gravity-free AC (3), |x| - mean|x| (1), first difference (3)."""
    def call(self, x):
        ac = x - ops.mean(x, axis=1, keepdims=True)
        mag = ops.sqrt(ops.sum(x * x, axis=-1, keepdims=True) + 1e-9)
        mag_ac = mag - ops.mean(mag, axis=1, keepdims=True)
        d = x[:, 1:, :] - x[:, :-1, :]
        d = ops.concatenate([ops.zeros_like(d[:, :1, :]), d], axis=1)
        return ops.concatenate([ac, mag_ac, d], axis=-1)


@keras.saving.register_keras_serializable("harry")
class LogStd(layers.Layer):
    """(B, W, C) -> (B, C): log of the per-channel std over time (scale-free intensity)."""
    def call(self, x):
        m = ops.mean(x, axis=1, keepdims=True)
        return ops.log(ops.sqrt(ops.mean((x - m) ** 2, axis=1)) + 1e-4)


@keras.saving.register_keras_serializable("harry")
class BandPower(layers.Layer):
    """(B, W, C) -> (B, C * n_bands): log mean power per frequency band.

    The DFT is a fixed (W, K) cosine / sine matrix multiply, so no tf.signal op is needed in TFLite.
    A Hann taper reduces leakage between neighbouring bands.
    """
    def __init__(self, window, bands, fs=12.5, **kw):
        super().__init__(**kw)
        self.window, self.bands, self.fs = int(window), [tuple(b) for b in bands], float(fs)
        t = np.arange(self.window)
        freqs = np.fft.rfftfreq(self.window, 1 / self.fs)
        hann = 0.5 - 0.5 * np.cos(2 * np.pi * t / max(self.window - 1, 1))
        ang = 2 * np.pi * np.outer(t, np.arange(len(freqs))) / self.window
        self._cos = (np.cos(ang) * hann[:, None]).astype("float32")
        self._sin = (np.sin(ang) * hann[:, None]).astype("float32")
        bm = np.zeros((len(freqs), len(self.bands)), "float32")
        for j, (lo, hi) in enumerate(self.bands):
            sel = (freqs >= lo) & (freqs < hi) & (freqs > 0)
            if not sel.any():                                   # band narrower than the bin spacing
                sel = np.zeros_like(sel); sel[np.argmin(np.abs(freqs - (lo + hi) / 2))] = True
            bm[sel, j] = 1.0 / sel.sum()
        self._band = bm

    def call(self, x):
        xt = ops.transpose(x, (0, 2, 1))                        # (B, C, W)
        re = ops.matmul(xt, ops.convert_to_tensor(self._cos))   # (B, C, K)
        im = ops.matmul(xt, ops.convert_to_tensor(self._sin))
        p = (re * re + im * im) / self.window
        bp = ops.matmul(p, ops.convert_to_tensor(self._band))   # (B, C, n_bands)
        return ops.reshape(ops.log(bp + 1e-6), (-1, x.shape[-1] * len(self.bands)))

    def get_config(self):
        return {**super().get_config(), "window": self.window, "bands": self.bands, "fs": self.fs}
