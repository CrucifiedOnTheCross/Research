from __future__ import annotations

from typing import Any

import numpy as np
from sklearn.metrics import (
    accuracy_score,
    balanced_accuracy_score,
    confusion_matrix,
    f1_score,
    matthews_corrcoef,
    precision_recall_fscore_support,
    roc_auc_score,
)

from .data import CLASS_NAMES


def classification_metrics(
    targets: np.ndarray,
    probabilities: np.ndarray,
    melanoma_targets: np.ndarray,
    melanoma_probabilities: np.ndarray,
    malignant_targets: np.ndarray,
    malignant_probabilities: np.ndarray,
) -> dict[str, Any]:
    predictions = probabilities.argmax(axis=1)
    precision, recall, f1, support = precision_recall_fscore_support(
        targets, predictions, labels=np.arange(len(CLASS_NAMES)), zero_division=0
    )
    result: dict[str, Any] = {
        "accuracy": float(accuracy_score(targets, predictions)),
        "balanced_accuracy": float(balanced_accuracy_score(targets, predictions)),
        "macro_f1": float(f1_score(targets, predictions, average="macro", zero_division=0)),
        "weighted_f1": float(f1_score(targets, predictions, average="weighted", zero_division=0)),
        "mcc": float(matthews_corrcoef(targets, predictions)),
        "classwise": {
            name: {
                "precision": float(precision[index]),
                "recall": float(recall[index]),
                "f1": float(f1[index]),
                "support": int(support[index]),
            }
            for index, name in enumerate(CLASS_NAMES)
        },
        "confusion_matrix": confusion_matrix(
            targets, predictions, labels=np.arange(len(CLASS_NAMES))
        ).tolist(),
    }
    result["melanoma"] = _binary_metrics(melanoma_targets, melanoma_probabilities)
    result["malignant"] = _binary_metrics(malignant_targets, malignant_probabilities)
    return result

def _binary_metrics(targets: np.ndarray, probabilities: np.ndarray) -> dict[str, float]:
    predictions = (probabilities >= 0.5).astype(np.int64)
    precision, recall, f1, _ = precision_recall_fscore_support(
        targets, predictions, average="binary", zero_division=0
    )
    result = {
        "accuracy": float(accuracy_score(targets, predictions)),
        "balanced_accuracy": float(balanced_accuracy_score(targets, predictions)),
        "precision": float(precision),
        "recall": float(recall),
        "f1": float(f1),
        "mcc": float(matthews_corrcoef(targets, predictions)),
    }
    try:
        result["roc_auc"] = float(roc_auc_score(targets, probabilities))
    except ValueError:
        result["roc_auc"] = float("nan")
    return result
