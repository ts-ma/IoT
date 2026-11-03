> Historical contract for the previous social_cnn candidate. The app now uses
> assets/models/harry_social.tflite with a [1, 100, 3] input (8 seconds).
> See README.md and test/social_model_contract_test.dart for the current assets.

# Social CNN model contract — Stage 4A

Status: provisional model verified by static inspection; ready for Stage 4B
asset preparation. No Flutter inference integration or new inference run was
performed for this stage. These checks do not establish coursework evaluation
compliance or Android runtime performance.

This document lives at the repository root because `.gitignore` excludes
`docs/` (the "Build guides" rule). The ignore policy is unchanged.

## Artifact and evidence

- Model: [`model/social_cnn.tflite`](model/social_cnn.tflite)
- SHA-256: `42090c82322144aad471a46d7837ee974fc085ff3b0cadd6c994bb54a8b86c74`
- Size: 50,508 bytes (49.32 KiB).
- Metadata: [`model/social_cnn_meta.json`](model/social_cnn_meta.json)
- Supplied example: [`model/social_cnn_example.json`](model/social_cnn_example.json)
- Training/export evidence: [`Lab3_trained.ipynb`](Lab3_trained.ipynb).
  Cell numbers below are **zero-based JSON cell indices**, including markdown.
- Static checks: [`test/social_model_contract_test.dart`](test/social_model_contract_test.dart).

The hash was computed directly from the binary using PowerShell
`Get-FileHash model/social_cnn.tflite -Algorithm SHA256`. Recompute it before
copying the model in Stage 4B. The tests check structural contracts and saved
normalization constants, not a cryptographic hash of every model weight.

The binary has the `TFL3` identifier and schema version 3. Input/output tensors
and normalization constants were read directly from its FlatBuffer tables.
Notebook source and saved outputs were inspected as JSON, without executing
cells. Reported performance below is historical notebook evidence, not a newly
reproduced result. There is no hash-linked training/evaluation manifest proving
that these exact model bytes produced the notebook results.

## Input contract

| Property | Contract | Evidence |
|---|---|---|
| Task | `social_signal` | Metadata; notebook B6 |
| Input shape | `[1, 50, 3]` | Binary and metadata |
| Shape signature | `[-1, 50, 3]` (dynamic batch) | Binary |
| Input type | `float32` | Binary and metadata |
| Nominal sample rate | 12.5 Hz | Metadata; notebook configuration, cell 5 |
| Window size | 50 samples, approximately 4 seconds | Metadata; notebook |
| Window step | 25 samples, approximately 2 seconds | Metadata; notebook |
| Overlap | 25 samples / 50% | Derived from size and step |
| Per-row channel order | `accelX`, `accelY`, `accelZ` | Metadata; cell 7 selects `AXES` in that order |
| Temporal order | Oldest to newest within each window | Cell 7 slices `signal[s:s + window]` |
| Units | Raw acceleration in g, including gravity | Metadata; notebook raw-axis pipeline |

Feed a batch containing one window, with no axis swapping, magnitude conversion
or external standardization. Cell 7 loads the three axes as float32, drops rows
with missing values and slices consecutive windows. The inspected Social path
does not filter or resample the axes or calculate handcrafted features.
Dropping missing rows does not guarantee uniform timing in the original data.

Sampling frequency, channel semantics and time ordering are metadata/source
contracts; the tensor shape alone cannot prove them. The supplied example has
no timestamps or column names, so its chronology and physical axis meanings
cannot be independently established without the original recording. Anatomical
axis directions, mounting orientation and full coordinate conventions are not
documented sufficiently for verification.

Inference can consume the latest complete window without future samples beyond
its end. Expected nominal warm-up is about four seconds, then one prediction
every two seconds. The four-second window may dilute brief events; event-onset
accuracy has not been established.

## Embedded normalization and architecture

The graph starts with `SUB` (built-in opcode 41), followed by `MUL` (18), using
constant float32 tensors of shape `[1, 1, 3]`. In X/Y/Z order:

```text
mean = [
  -0.08247149735689163,
  -0.3982255458831787,
   0.061153262853622437
]
inverse_standard_deviation = [
  1.9124904870986938,
  2.2301547527313232,
  1.6275293827056885
]
normalized = (raw_acceleration_g - mean) * inverse_standard_deviation
```

These parameters are saved inside the TFLite binary; no separate scaler is
needed. Do not normalize again in Dart. Notebook cell 40 defines a per-axis
Keras `Normalization` layer adapted to training windows; cell 80 temporarily
supplies `X_train_social` when constructing this Social CNN.

The notebook and exported convolution weight shapes support this architecture:
normalization → Conv1D(32, kernel 5, ReLU) → MaxPooling1D(2) →
Conv1D(64, kernel 5, ReLU) → MaxPooling1D(2) → global average pooling →
Dense(4, softmax). Training includes dropout 0.2 before the final Dense layer;
dropout is inactive for inference. Internal names still contain `har_cnn`
because B6 reuses the builder; those names do not determine the task.

## Output contract and labels

Output shape is `[1, 4]`, signature `[-1, 4]`, type `float32`, confirmed in the
binary and metadata. The graph ends in softmax. Use this exact index ordering:

| Index | Stored label | Display meaning |
|---:|---|---|
| 0 | `breathingNormally` | Normal breathing |
| 1 | `coughing` | Coughing |
| 2 | `hyperventilation` | Hyperventilating |
| 3 | `other` | Other social signals |

Metadata ordering agrees with `SOCIAL_CLASSES` in cell 73, folder enumeration
in cell 7, and export arguments in cell 84. The graph confirms four outputs
but does not itself attach these semantic class names.

Cell 72 describes `other` as including talking, eating, singing and laughing
recorded in different postures. Training reads four already-merged class
folders. Without the original dataset and preparation records, correct posture
merging and the exact composition of `other` remain unverified. The notebook
describes Social recognition as applicable while stationary; behavior during
movement needs a policy and validation before live integration.

## Supplied example verification

The example contains 50 rows of three finite numeric values. Its intended
ordering is the temporal X/Y/Z contract above, supported by the notebook:
cell 22 exports `X[0]` directly, after rounding samples to six decimals.

Saved expected output, in metadata label order:

```text
[0.502465009689331,
 0.0005660000024363399,
 0.03717200085520744,
 0.4597969949245453]
```

All four probabilities are finite and between zero and one. Their sum is
approximately 1.00000000547. The largest is index 0, so the saved
`expected_class = breathingNormally` is internally consistent.

The separately supplied `true_class = other` is ground truth. This fixture
records a model misclassification. Future inference parity checks should compare
against the expected probabilities/prediction; accuracy checks should compare
against ground truth. A passing static test does not prove that invoking the
current binary reproduces these saved probabilities.

## Reported evaluation and limitations

Notebook B6 uses `datasetJan2026/social_signal`: 6,492 recordings. Cells 12 and
75 perform a seeded (`SEED = 0`), class-stratified recording-level hold-out split
of approximately 70% train / 15% validation / 15% test. Windows are generated
after splitting. The notebook checks disjoint file paths, not Social subject
groups. Cell 76 reports 63,090 training, 13,595 validation and 13,534 test windows.

Cells 81–83 report validation accuracy 65.39%, test window accuracy 66.65%
(rounded from 0.6665), test recording-majority accuracy 70.3%, and test macro-F1
0.588. Per-class test recall from the saved classification report:

| Class | Recall | Test support (windows) |
|---|---:|---:|
| `breathingNormally` | 34.9% | 2,199 |
| `coughing` | 56.6% | 2,051 |
| `hyperventilation` | 40.9% | 2,153 |
| `other` | 87.1% | 7,131 |

Cell 85 reports TFLite accuracy 0.667, 100% argmax agreement with Keras, maximum
probability difference `2.18e-6`, and 0.01 ms/window on the notebook CPU. This
rounded timing is not an Android latency measurement. The saved confusion matrix
is embedded in cell 83 as an image, not supplied as a separate machine-readable
evaluation artifact.

Key limitations and unresolved evidence:

- **No official subject-wise 10-fold evidence for Social CNN.** The Social
  hold-out split does not enforce subject grouping. Multiple recordings or
  postures from one person could cross splits; absence of such leakage is not
  established.
- B9 concerns HAR and generates its own folds (cell 108); it does not establish
  Social evaluation using the official Learn fold assignments. Those assignments
  and raw recordings are not present in the inspected project sources.
- `other` represents about 52.7% of test windows. Overall accuracy obscures low
  normal-breathing and hyperventilation recall; macro-F1 and per-class recall
  should accompany it.
- Ground truth is propagated from recording labels to windows. Results do not
  prove cough-burst timing, behavior across transitions, or movement robustness.
- Dataset preparation/posture merging, exact binary-to-run provenance, original
  example sample order, mounting conventions, Android compatibility, memory use
  and sustained live performance need further evidence or runtime tests.

## Automated checks and Stage 4B handoff

Run from the repository root:

```text
flutter test --no-pub test/social_model_contract_test.dart
flutter analyze --no-pub
```

The six tests check metadata, exact labels, binary I/O tensors, the embedded
normalization chain/constants, example dimensions and finiteness, probability
validity/sum, and argmax consistency while keeping ground truth separate. The
small test-only FlatBuffer reader reads selected schema fields; it is not a full
FlatBuffer verifier, an interpreter, or proof of model performance.

Stage 4A validation: all six contract tests passed. `flutter analyze --no-pub`
completed with exit code 1 because of 38 existing informational lint findings
in unchanged application files; none were reported in the new contract test.
The model SHA-256 was unchanged after verification.

**Ready for Stage 4B asset preparation as a provisional candidate.** Copy the
verified binary and companions into deployment assets and declare them in a
later stage; no conversion is currently required. Recheck SHA-256 after copying.
Actual Android inference parity belongs to a later runtime stage. Official-fold
evaluation and dataset provenance remain open and must be resolved before
claiming coursework evaluation compliance. Stage 4A changes no model, HAR, BLE,
SQLite, dependencies or application loading logic.
