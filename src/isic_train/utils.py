from __future__ import annotations

import json
import os
import platform
import random
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import torch


def seed_everything(seed: int, deterministic: bool) -> None:
    os.environ["PYTHONHASHSEED"] = str(seed)
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.use_deterministic_algorithms(deterministic, warn_only=True)
    torch.backends.cudnn.deterministic = deterministic
    torch.backends.cudnn.benchmark = not deterministic


def configure_accelerator() -> None:
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA GPU is required. Check the NVIDIA driver and container GPU access.")
    torch.set_float32_matmul_precision("high")
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True


def make_run_dir(base: str | Path, experiment_name: str) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = Path(base) / f"{timestamp}_{experiment_name}"
    run_dir.mkdir(parents=True, exist_ok=False)
    return run_dir


def environment_snapshot() -> dict[str, Any]:
    def command(*args: str) -> str | None:
        try:
            return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
        except (OSError, subprocess.CalledProcessError):
            return None

    device = torch.cuda.get_device_properties(0)
    return {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "python": platform.python_version(),
        "platform": platform.platform(),
        "torch": torch.__version__,
        "torch_cuda": torch.version.cuda,
        "cudnn": torch.backends.cudnn.version(),
        "gpu": device.name,
        "gpu_memory_bytes": device.total_memory,
        "gpu_compute_capability": list(device.major_minor) if hasattr(device, "major_minor") else [device.major, device.minor],
        "cpu_count": os.cpu_count(),
        "git_commit": command("git", "rev-parse", "HEAD"),
        "git_status": command("git", "status", "--porcelain"),
        "nvidia_smi": command("nvidia-smi", "--query-gpu=name,driver_version,memory.total", "--format=csv,noheader"),
        "pip_freeze": command("python", "-m", "pip", "freeze"),
    }


def write_json(path: Path, value: Any) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=True)


def append_jsonl(path: Path, value: Any) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False, allow_nan=True) + "\n")


def capture_rng_state() -> dict[str, Any]:
    return {
        "python": random.getstate(),
        "numpy": np.random.get_state(),
        "torch": torch.get_rng_state(),
        "cuda": torch.cuda.get_rng_state_all(),
    }


def restore_rng_state(state: dict[str, Any]) -> None:
    random.setstate(state["python"])
    np.random.set_state(state["numpy"])
    torch.set_rng_state(state["torch"])
    torch.cuda.set_rng_state_all(state["cuda"])
