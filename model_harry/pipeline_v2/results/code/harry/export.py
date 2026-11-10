"""TFLite export in the Lab 4 contract + verification + a batch TFLite runner (PLAN.md G6, G7.1)."""
import contextlib
import io
import json
from pathlib import Path

import numpy as np
import tensorflow as tf

from .data import FS, AXES


class TFLiteRunner:
    """Runs any of the .tflite files (float or int8 I/O) on a batch of raw windows."""
    def __init__(self, path):
        self.path = Path(path)
        self.it = tf.lite.Interpreter(model_path=str(path))
        self.inp = self.it.get_input_details()[0]
        self.out = self.it.get_output_details()[0]
        self.window = int(self.inp["shape"][1])

    def _prep(self, X):
        if self.inp["dtype"] == np.int8:
            s, z = self.inp["quantization"]
            return np.clip(np.round(X / s + z), -128, 127).astype(np.int8)
        return X.astype(np.float32)

    def _post(self, P):
        if self.out["dtype"] == np.int8:
            s, z = self.out["quantization"]
            return (P.astype(np.float32) - z) * s
        return P

    def predict(self, X, chunk=512):
        res = []
        for i in range(0, len(X), chunk):
            xb = self._prep(X[i:i + chunk])
            try:
                self.it.resize_tensor_input(self.inp["index"], list(xb.shape))
                self.it.allocate_tensors()
                self.it.set_tensor(self.inp["index"], xb); self.it.invoke()
                res.append(self._post(self.it.get_tensor(self.out["index"])))
            except (RuntimeError, ValueError):                   # fixed batch-1 model
                self.it.resize_tensor_input(self.inp["index"], [1, *xb.shape[1:]]); self.it.allocate_tensors()
                for w in xb:
                    self.it.set_tensor(self.inp["index"], w[None]); self.it.invoke()
                    res.append(self._post(self.it.get_tensor(self.out["index"])))
        return np.concatenate(res)


def export(model, name, out_dir, window, step, classes, task, X_check, y_check, extra_meta=None):
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    conv = tf.lite.TFLiteConverter.from_keras_model(model)
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]       # no Flex: must run in the app
    with contextlib.redirect_stdout(io.StringIO()):
        blob = conv.convert()
    path = out_dir / f"{name}.tflite"; path.write_bytes(blob)

    lite = TFLiteRunner(path)
    p_lite = lite.predict(X_check)
    p_keras = model.predict(X_check, batch_size=512, verbose=0)
    agree = float((p_lite.argmax(1) == p_keras.argmax(1)).mean())
    dmax = float(np.abs(p_lite - p_keras).max())
    meta = {
        "model_file": path.name, "task": task, "sampling_frequency_hz": FS,
        "window_samples": int(window), "step_samples": int(step),
        "input": {"shape": [1, int(window), 3], "channels": AXES, "units": "g (raw accelerometer values)",
                  "dtype": "float32"},
        "output": {"shape": [1, len(classes)], "classes": list(classes), "dtype": "float32"},
        "normalization": "inside the model – feed raw values",
        **(extra_meta or {}),
    }
    (out_dir / f"{name}_meta.json").write_text(json.dumps(meta, indent=2))
    ex = {"input_window": X_check[0].round(6).tolist(), "expected_probabilities": p_lite[0].round(6).tolist(),
          "expected_class": classes[int(p_lite[0].argmax())], "true_class": classes[int(y_check[0])]}
    (out_dir / f"{name}_example.json").write_text(json.dumps(ex))
    return {"file": path.name, "size_kb": round(len(blob) / 1024, 1), "argmax_agreement": agree,
            "max_abs_dprob": dmax, "sum_to_one": float(np.abs(p_lite.sum(1) - 1).max())}
