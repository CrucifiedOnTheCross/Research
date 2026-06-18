import pandas as pd
import torch
from PIL import Image

from isic_train.config import apply_overrides, load_config
from isic_train.data import CLASS_NAMES, ISICDataset, metadata_dimension
from isic_train.losses import SupConLoss
from isic_train.model import ISICMultimodalModel


def test_metadata_dimension() -> None:
    assert metadata_dimension() == 13


def test_supcon_is_finite() -> None:
    features = torch.randn(4, 2, 16, requires_grad=True)
    labels = torch.tensor([0, 0, 1, 1])
    loss = SupConLoss()(features, labels)
    assert torch.isfinite(loss)
    loss.backward()
    assert features.grad is not None


def test_config_overrides() -> None:
    config = apply_overrides(
        load_config("configs/train.yaml"),
        ["model.use_metadata=false", "training.loss_weights.supcon=0"],
    )
    assert config.raw["model"]["use_metadata"] is False
    assert config.raw["training"]["loss_weights"]["supcon"] == 0


def test_metadata_only_forward() -> None:
    model = ISICMultimodalModel(
        backbone_name="convnextv2_atto", metadata_dim=metadata_dimension(),
        metadata_hidden_dim=16, metadata_embedding_dim=8, projection_dim=4,
        dropout=0.0, pretrained=False, use_image=False, use_metadata=True,
    )
    output = model(torch.zeros(2, 3, 32, 32), torch.zeros(2, metadata_dimension()))
    assert output["diagnosis"].shape == (2, 8)
    assert output["melanoma"].shape == (2,)


def test_dataset_precomputes_labels_and_metadata(tmp_path) -> None:
    row = {name: float(name == "MEL") for name in CLASS_NAMES}
    row.update({
        "image": "sample", "age_approx": 50, "sex": "female",
        "anatom_site_general": "head/neck",
    })
    Image.new("RGB", (256, 256), color=(64, 128, 192)).save(tmp_path / "sample.jpg")
    dataset = ISICDataset(pd.DataFrame([row]), tmp_path, 224, training=False)

    sample = dataset[0]
    assert sample["target"].item() == CLASS_NAMES.index("MEL")
    assert sample["melanoma"].item() == 1.0
    assert sample["malignant"].item() == 1.0
    assert sample["metadata"].shape == (metadata_dimension(),)
    assert sample["image1"].shape == (3, 224, 224)
