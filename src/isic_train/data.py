from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from PIL import Image
from sklearn.model_selection import StratifiedGroupKFold
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
from torchvision import transforms
from torchvision.transforms import InterpolationMode

CLASS_NAMES = ["MEL", "NV", "BCC", "AK", "BKL", "DF", "VASC", "SCC"]
MALIGNANT_CLASSES = {"MEL", "BCC", "AK", "SCC"}
SEX_VALUES = ["female", "male", "unknown"]
SITE_VALUES = [
    "anterior torso", "head/neck", "lateral torso", "lower extremity",
    "oral/genital", "palms/soles", "posterior torso", "upper extremity", "unknown",
]


@dataclass
class DataBundle:
    train_loader: DataLoader
    val_loader: DataLoader
    class_weights: torch.Tensor
    train_size: int
    val_size: int


def _metadata_vector(row: pd.Series) -> np.ndarray:
    age = pd.to_numeric(row.get("age_approx"), errors="coerce")
    age_value = 0.5 if pd.isna(age) else float(np.clip(age, 0, 100) / 100.0)
    sex = str(row.get("sex", "unknown")).lower()
    site = str(row.get("anatom_site_general", "unknown")).lower()
    if sex not in SEX_VALUES:
        sex = "unknown"
    if site not in SITE_VALUES:
        site = "unknown"
    return np.asarray(
        [age_value]
        + [float(sex == value) for value in SEX_VALUES]
        + [float(site == value) for value in SITE_VALUES],
        dtype=np.float32,
    )


class ISICDataset(Dataset):
    def __init__(
        self, frame: pd.DataFrame, images_dir: Path, image_size: int,
        training: bool, two_views: bool = True,
    ) -> None:
        self.images_dir = images_dir
        self.training = training
        self.two_views = two_views
        frame = frame.reset_index(drop=True)
        # Pandas row indexing and metadata parsing are surprisingly expensive in
        # DataLoader workers. Materialize the small, immutable fields once while
        # keeping JPEG decoding and random augmentation fully dynamic.
        self.image_ids = frame["image"].astype(str).tolist()
        targets = frame[CLASS_NAMES].to_numpy(dtype=np.float32).argmax(axis=1).astype(np.int64)
        metadata = np.stack(
            [_metadata_vector(row) for _, row in frame.iterrows()]
        ).astype(np.float32, copy=False)
        melanoma = (targets == CLASS_NAMES.index("MEL")).astype(np.float32)
        malignant_indices = {CLASS_NAMES.index(name) for name in MALIGNANT_CLASSES}
        malignant = np.fromiter(
            (target in malignant_indices for target in targets),
            dtype=np.float32,
            count=len(targets),
        )
        # These fields are immutable. Building their tensors once avoids several
        # tiny allocations for every sample in every DataLoader worker.
        self.targets = torch.from_numpy(targets)
        self.metadata = torch.from_numpy(metadata)
        self.melanoma = torch.from_numpy(melanoma)
        self.malignant = torch.from_numpy(malignant)
        normalize = transforms.Normalize(mean=(0.485, 0.456, 0.406), std=(0.229, 0.224, 0.225))
        self.train_transform = transforms.Compose([
            transforms.RandomResizedCrop(image_size, scale=(0.65, 1.0), interpolation=InterpolationMode.BICUBIC),
            transforms.RandomHorizontalFlip(),
            transforms.RandomVerticalFlip(),
            transforms.RandomRotation(30, interpolation=InterpolationMode.BILINEAR),
            transforms.ColorJitter(brightness=0.2, contrast=0.2, saturation=0.2, hue=0.05),
            transforms.ToTensor(), normalize,
        ])
        self.eval_transform = transforms.Compose([
            transforms.Resize(int(image_size * 1.14), interpolation=InterpolationMode.BICUBIC),
            transforms.CenterCrop(image_size), transforms.ToTensor(), normalize,
        ])

    def __len__(self) -> int:
        return len(self.image_ids)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor | str]:
        image_id = self.image_ids[index]
        image_path = self.images_dir / f"{image_id}.jpg"
        with Image.open(image_path) as handle:
            image = handle.convert("RGB")
        view1 = self.train_transform(image) if self.training else self.eval_transform(image)
        sample = {
            "image1": view1,
            "metadata": self.metadata[index],
            "target": self.targets[index],
            "melanoma": self.melanoma[index],
            "malignant": self.malignant[index],
            "image_id": image_id,
        }
        # Do not clone, pin and transfer a second full image when the experiment
        # does not use two-view contrastive learning.
        if self.training and self.two_views:
            sample["image2"] = self.train_transform(image)
        return sample


def _load_frame(cfg: dict) -> tuple[pd.DataFrame, Path]:
    root = Path(cfg["root"])
    labels = pd.read_csv(root / cfg["labels_csv"])
    metadata = pd.read_csv(root / cfg["metadata_csv"])
    frame = labels.merge(metadata, on="image", how="inner", validate="one_to_one")
    if "UNK" in frame.columns:
        frame = frame[frame["UNK"].fillna(0) < 0.5].copy()
    valid = frame[CLASS_NAMES].sum(axis=1).eq(1)
    frame = frame[valid].copy()
    frame["target"] = frame[CLASS_NAMES].to_numpy().argmax(axis=1)
    frame["group"] = frame.get("lesion_id", frame["image"]).fillna(frame["image"])
    images_dir = root / cfg["images_dir"]
    if not images_dir.is_dir():
        raise FileNotFoundError(f"Images directory does not exist: {images_dir}")
    return frame, images_dir


def create_dataloaders(
    cfg: dict, seed: int, batch_size: int, two_views: bool = True
) -> DataBundle:
    frame, images_dir = _load_frame(cfg)
    folds = max(2, round(1.0 / float(cfg["val_fraction"])))
    splitter = StratifiedGroupKFold(n_splits=folds, shuffle=True, random_state=seed)
    splits = list(splitter.split(frame, frame["target"], groups=frame["group"]))
    train_idx, val_idx = splits[int(cfg.get("split_fold", 0)) % len(splits)]
    train_frame, val_frame = frame.iloc[train_idx].copy(), frame.iloc[val_idx].copy()
    counts = train_frame["target"].value_counts().reindex(range(8), fill_value=1).sort_index()
    class_weights = len(train_frame) / (8.0 * counts.to_numpy(dtype=np.float32))

    sampler = None
    shuffle = True
    if cfg.get("class_balanced_sampling", True):
        sample_weights = train_frame["target"].map(dict(enumerate(class_weights))).to_numpy()
        sampler = WeightedRandomSampler(
            torch.as_tensor(sample_weights, dtype=torch.double), len(sample_weights), replacement=True,
            generator=torch.Generator().manual_seed(seed),
        )
        shuffle = False

    common = {
        "batch_size": batch_size,
        "num_workers": int(cfg["num_workers"]),
        "pin_memory": bool(cfg.get("pin_memory", True)),
        "persistent_workers": bool(cfg.get("persistent_workers", True)) and int(cfg["num_workers"]) > 0,
    }
    if int(cfg["num_workers"]) > 0:
        common["prefetch_factor"] = int(cfg.get("prefetch_factor", 2))
    train_loader = DataLoader(
        ISICDataset(train_frame, images_dir, int(cfg["image_size"]), True, two_views),
        shuffle=shuffle, sampler=sampler, drop_last=True, **common,
    )
    val_loader = DataLoader(
        ISICDataset(val_frame, images_dir, int(cfg["image_size"]), False),
        shuffle=False, drop_last=False, **common,
    )
    return DataBundle(
        train_loader, val_loader, torch.from_numpy(class_weights), len(train_frame), len(val_frame)
    )


def metadata_dimension() -> int:
    return 1 + len(SEX_VALUES) + len(SITE_VALUES)
