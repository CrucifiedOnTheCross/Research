from __future__ import annotations

import torch
from torch import nn


class SupConLoss(nn.Module):
    """Supervised contrastive loss for tensors shaped [batch, views, dim]."""

    def __init__(self, temperature: float = 0.07) -> None:
        super().__init__()
        self.temperature = temperature

    def forward(self, features: torch.Tensor, labels: torch.Tensor) -> torch.Tensor:
        if features.ndim != 3:
            raise ValueError("features must have shape [batch, views, dim]")
        batch_size, views, _ = features.shape
        features = nn.functional.normalize(features, dim=-1)
        contrast = features.reshape(batch_size * views, -1)
        logits = contrast @ contrast.T / self.temperature
        logits = logits - logits.max(dim=1, keepdim=True).values.detach()

        repeated_labels = labels.repeat_interleave(views)
        positive_mask = repeated_labels[:, None].eq(repeated_labels[None, :])
        self_mask = torch.eye(batch_size * views, device=features.device, dtype=torch.bool)
        positive_mask = positive_mask & ~self_mask
        valid_mask = ~self_mask

        exp_logits = torch.exp(logits) * valid_mask
        log_prob = logits - torch.log(exp_logits.sum(dim=1, keepdim=True).clamp_min(1e-12))
        positives = positive_mask.sum(dim=1)
        mean_log_prob = (positive_mask * log_prob).sum(dim=1) / positives.clamp_min(1)
        valid_anchors = positives > 0
        if not valid_anchors.any():
            return features.sum() * 0.0
        return -mean_log_prob[valid_anchors].mean()
