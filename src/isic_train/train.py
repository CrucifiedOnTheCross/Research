from __future__ import annotations

import argparse
import math
import time
from contextlib import nullcontext
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch import nn
from torch.optim import AdamW
from torch.optim.lr_scheduler import LambdaLR
from torch.utils.tensorboard import SummaryWriter
from tqdm import tqdm

from .config import load_config
from .data import CLASS_NAMES, create_dataloaders, metadata_dimension
from .losses import SupConLoss
from .metrics import classification_metrics
from .model import ISICMultimodalModel
from .utils import (
    append_jsonl,
    capture_rng_state,
    configure_accelerator,
    environment_snapshot,
    make_run_dir,
    restore_rng_state,
    seed_everything,
    write_json,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train multimodal ConvNeXtV2 on ISIC 2019")
    parser.add_argument("--config", default="configs/train.yaml")
    parser.add_argument("--resume", default=None, help="Checkpoint path; overrides config")
    return parser.parse_args()


def autocast_context(dtype_name: str):
    if dtype_name == "bfloat16":
        return torch.autocast("cuda", dtype=torch.bfloat16)
    if dtype_name == "float16":
        return torch.autocast("cuda", dtype=torch.float16)
    return nullcontext()


def loss_function(
    outputs: dict[str, torch.Tensor],
    batch: dict[str, Any],
    diagnosis_loss: nn.Module,
    binary_loss: nn.Module,
    supcon_loss: nn.Module,
    weights: dict[str, float],
) -> tuple[torch.Tensor, dict[str, float]]:
    losses = {
        "diagnosis": diagnosis_loss(outputs["diagnosis"], batch["target"]),
        "image_diagnosis": diagnosis_loss(outputs["image_diagnosis"], batch["target"]),
        "melanoma": binary_loss(outputs["melanoma"], batch["melanoma"]),
        "malignant": binary_loss(outputs["malignant"], batch["malignant"]),
        "supcon": supcon_loss(outputs["projections"], batch["target"]),
    }
    total = sum(losses[name] * float(weights[name]) for name in losses)
    return total, {name: float(value.detach()) for name, value in losses.items()}


def train_epoch(
    model: nn.Module,
    loader,
    optimizer,
    scheduler,
    scaler,
    diagnosis_loss,
    binary_loss,
    supcon_loss,
    cfg: dict,
    device: torch.device,
    epoch: int,
) -> dict[str, float]:
    model.train()
    optimizer.zero_grad(set_to_none=True)
    accumulation = int(cfg["gradient_accumulation_steps"])
    totals = {
        "loss": 0.0, "diagnosis": 0.0, "image_diagnosis": 0.0,
        "melanoma": 0.0, "malignant": 0.0, "supcon": 0.0,
    }
    progress = tqdm(loader, desc=f"train {epoch}", dynamic_ncols=True)
    for step, batch in enumerate(progress):
        batch = {
            key: value.to(device, non_blocking=True) if torch.is_tensor(value) else value
            for key, value in batch.items()
        }
        images = batch["image1"]
        second_images = batch["image2"]
        if cfg.get("channels_last", True):
            images = images.contiguous(memory_format=torch.channels_last)
            second_images = second_images.contiguous(memory_format=torch.channels_last)
        with autocast_context(cfg["amp_dtype"]):
            outputs = model(images, batch["metadata"], second_images)
            loss, parts = loss_function(
                outputs, batch, diagnosis_loss, binary_loss, supcon_loss,
                cfg["loss_weights"],
            )
            scaled_loss = loss / accumulation
        scaler.scale(scaled_loss).backward()
        should_step = (step + 1) % accumulation == 0 or step + 1 == len(loader)
        if should_step:
            scaler.unscale_(optimizer)
            nn.utils.clip_grad_norm_(model.parameters(), float(cfg["gradient_clip_norm"]))
            scaler.step(optimizer)
            scaler.update()
            optimizer.zero_grad(set_to_none=True)
            scheduler.step()
        totals["loss"] += float(loss.detach())
        for name, value in parts.items():
            totals[name] += value
        progress.set_postfix(loss=f"{float(loss.detach()):.4f}")
    return {name: value / len(loader) for name, value in totals.items()}


@torch.inference_mode()
def validate(model: nn.Module, loader, cfg: dict, device: torch.device) -> dict[str, Any]:
    model.eval()
    targets, probabilities = [], []
    melanoma_targets, melanoma_probabilities = [], []
    malignant_targets, malignant_probabilities = [], []
    for batch in tqdm(loader, desc="validate", dynamic_ncols=True):
        images = batch["image1"].to(device, non_blocking=True)
        metadata = batch["metadata"].to(device, non_blocking=True)
        if cfg.get("channels_last", True):
            images = images.contiguous(memory_format=torch.channels_last)
        with autocast_context(cfg["amp_dtype"]):
            outputs = model(images, metadata)
        targets.append(batch["target"].numpy())
        probabilities.append(outputs["diagnosis"].softmax(dim=1).float().cpu().numpy())
        melanoma_targets.append(batch["melanoma"].numpy())
        melanoma_probabilities.append(outputs["melanoma"].sigmoid().float().cpu().numpy())
        malignant_targets.append(batch["malignant"].numpy())
        malignant_probabilities.append(outputs["malignant"].sigmoid().float().cpu().numpy())
    return classification_metrics(
        np.concatenate(targets), np.concatenate(probabilities),
        np.concatenate(melanoma_targets), np.concatenate(melanoma_probabilities),
        np.concatenate(malignant_targets), np.concatenate(malignant_probabilities),
    )


def main() -> None:
    args = parse_args()
    config = load_config(args.config).raw
    exp_cfg, data_cfg, model_cfg, train_cfg = (
        config["experiment"], config["data"], config["model"], config["training"]
    )
    seed_everything(int(exp_cfg["seed"]), bool(exp_cfg["deterministic"]))
    configure_accelerator()
    device = torch.device("cuda", 0)
    run_dir = make_run_dir(exp_cfg["output_dir"], exp_cfg["name"])
    write_json(run_dir / "config.json", config)
    write_json(run_dir / "environment.json", environment_snapshot())
    write_json(run_dir / "status.json", {"state": "initializing"})
    writer = SummaryWriter(run_dir / "tensorboard")

    data = create_dataloaders(data_cfg, int(exp_cfg["seed"]), int(train_cfg["batch_size"]))
    write_json(run_dir / "data_summary.json", {
        "train_size": data.train_size, "val_size": data.val_size,
        "classes": CLASS_NAMES, "class_weights": data.class_weights.tolist(),
    })
    model = ISICMultimodalModel(
        backbone_name=model_cfg["backbone"], metadata_dim=metadata_dimension(),
        metadata_hidden_dim=int(model_cfg["metadata_hidden_dim"]),
        metadata_embedding_dim=int(model_cfg["metadata_embedding_dim"]),
        projection_dim=int(model_cfg["projection_dim"]), dropout=float(model_cfg["dropout"]),
        pretrained=bool(model_cfg["pretrained"]),
    ).to(device)
    if train_cfg.get("channels_last", True):
        model = model.to(memory_format=torch.channels_last)

    backbone_parameters = list(model.backbone.parameters())
    backbone_ids = {id(parameter) for parameter in backbone_parameters}
    head_parameters = [parameter for parameter in model.parameters() if id(parameter) not in backbone_ids]
    optimizer = AdamW([
        {"params": backbone_parameters, "lr": float(train_cfg["backbone_learning_rate"])},
        {"params": head_parameters, "lr": float(train_cfg["learning_rate"])},
    ], weight_decay=float(train_cfg["weight_decay"]))
    updates_per_epoch = math.ceil(len(data.train_loader) / int(train_cfg["gradient_accumulation_steps"]))
    total_updates = updates_per_epoch * int(train_cfg["epochs"])
    warmup_updates = updates_per_epoch * int(train_cfg["warmup_epochs"])

    def schedule(step: int) -> float:
        if step < warmup_updates:
            return max(1e-3, step / max(1, warmup_updates))
        progress = (step - warmup_updates) / max(1, total_updates - warmup_updates)
        return 0.5 * (1.0 + math.cos(math.pi * min(progress, 1.0)))

    scheduler = LambdaLR(optimizer, schedule)
    scaler = torch.amp.GradScaler("cuda", enabled=train_cfg["amp_dtype"] == "float16")
    diagnosis_loss = nn.CrossEntropyLoss(label_smoothing=float(train_cfg["label_smoothing"]))
    binary_loss = nn.BCEWithLogitsLoss()
    supcon_loss = SupConLoss(float(train_cfg["supcon_temperature"]))
    start_epoch, best_mcc, patience = 1, -float("inf"), 0

    resume_path = args.resume or train_cfg.get("resume")
    if resume_path:
        checkpoint = torch.load(resume_path, map_location=device, weights_only=False)
        model.load_state_dict(checkpoint["model"])
        optimizer.load_state_dict(checkpoint["optimizer"])
        scheduler.load_state_dict(checkpoint["scheduler"])
        scaler.load_state_dict(checkpoint["scaler"])
        restore_rng_state(checkpoint["rng_state"])
        start_epoch = int(checkpoint["epoch"]) + 1
        best_mcc = float(checkpoint["best_mcc"])

    raw_model = model
    if train_cfg.get("compile", True):
        model = torch.compile(model, mode="max-autotune")
    started = time.time()
    try:
        write_json(run_dir / "status.json", {"state": "running", "started_unix": started})
        for epoch in range(start_epoch, int(train_cfg["epochs"]) + 1):
            train_metrics = train_epoch(
                model, data.train_loader, optimizer, scheduler, scaler,
                diagnosis_loss, binary_loss, supcon_loss, train_cfg, device, epoch,
            )
            val_metrics = validate(model, data.val_loader, train_cfg, device)
            record = {"epoch": epoch, "elapsed_seconds": time.time() - started,
                      "train": train_metrics, "validation": val_metrics}
            append_jsonl(run_dir / "metrics.jsonl", record)
            write_json(run_dir / "status.json", {
                "state": "running", "started_unix": started, "last_epoch": epoch,
                "best_mcc": max(best_mcc, float(val_metrics["mcc"])),
            })
            for name, value in train_metrics.items():
                writer.add_scalar(f"train/{name}", value, epoch)
            for name in ("accuracy", "balanced_accuracy", "macro_f1", "weighted_f1", "mcc"):
                writer.add_scalar(f"validation/{name}", val_metrics[name], epoch)
            writer.add_scalar("validation/melanoma_recall", val_metrics["melanoma"]["recall"], epoch)
            writer.add_scalar("validation/malignant_recall", val_metrics["malignant"]["recall"], epoch)
            writer.flush()

            checkpoint = {
                "epoch": epoch, "model": raw_model.state_dict(), "optimizer": optimizer.state_dict(),
                "scheduler": scheduler.state_dict(), "scaler": scaler.state_dict(),
                "best_mcc": max(best_mcc, float(val_metrics["mcc"])),
                "rng_state": capture_rng_state(), "config": config,
            }
            torch.save(checkpoint, run_dir / "last.pt")
            if float(val_metrics["mcc"]) > best_mcc:
                best_mcc = float(val_metrics["mcc"])
                patience = 0
                torch.save(checkpoint, run_dir / "best.pt")
                write_json(run_dir / "best_metrics.json", val_metrics)
            else:
                patience += 1
            if patience >= int(train_cfg["early_stopping_patience"]):
                break
        write_json(run_dir / "status.json", {
            "state": "completed", "started_unix": started,
            "finished_unix": time.time(), "best_mcc": best_mcc,
        })
    except BaseException as error:
        write_json(run_dir / "status.json", {
            "state": "failed", "started_unix": started,
            "finished_unix": time.time(), "error": repr(error),
        })
        raise
    finally:
        writer.close()


if __name__ == "__main__":
    main()
