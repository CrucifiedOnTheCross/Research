# ISIC 2019 experiment protocol v1

The active full model (`seed=42`, `fold=0`) is the preregistered anchor. Queue order is
fixed before inspecting subsequent results.

## Questions

1. How much signal comes from image and metadata independently?
2. What is gained by class balancing, metadata fusion, binary auxiliary tasks, the
   image-only auxiliary classifier, two-view training, and SupCon?
3. How dependent are conclusions on pretraining, SupCon weight/temperature, and image
   resolution?
4. Are the full-model gains over the image-only baseline stable across seeds and all
   five lesion-grouped folds?

## Decision rules

- Primary metric: multiclass MCC.
- Secondary metrics: Balanced Accuracy, Macro-F1, melanoma recall.
- Compare additive experiments only against the immediately preceding controlled
  experiment and leave-one-out experiments against the full anchor.
- Treat seed/fold aggregates as the evidence for conclusions; a single best run is not
  sufficient.
- Report mean, standard deviation, per-fold paired deltas and bootstrap confidence
  intervals. Do not select conclusions from Accuracy alone.
- `d*` sensitivity runs explain tuning sensitivity; they are not independent evidence
  of generalization.
- `s*` runs repeat each main leave-one-out ablation across seeds 7, 42, and 2026;
  component gains are reported as paired seed deltas against the corresponding full run.

The 384px run keeps effective batch size 32 (`4 × accumulation 8`). The single-view and
two-view controls isolate the effect of SupCon from the extra augmentation view.

For one-view configurations, execution uses `batch_size=32` and one optimizer step per
batch instead of the mathematically equivalent `batch_size=16` with two gradient
accumulation steps. The effective optimizer batch remains 32. Two-view/SupCon and
384px configurations retain their original microbatch settings, so the SupCon positive
set is unchanged.
