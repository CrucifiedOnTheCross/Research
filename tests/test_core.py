import torch

from isic_train.data import metadata_dimension
from isic_train.losses import SupConLoss


def test_metadata_dimension() -> None:
    assert metadata_dimension() == 13


def test_supcon_is_finite() -> None:
    features = torch.randn(4, 2, 16, requires_grad=True)
    labels = torch.tensor([0, 0, 1, 1])
    loss = SupConLoss()(features, labels)
    assert torch.isfinite(loss)
    loss.backward()
    assert features.grad is not None
