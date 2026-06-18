from __future__ import annotations

import dataclasses
from pathlib import Path
from typing import Any

import yaml


@dataclasses.dataclass(frozen=True)
class Config:
    raw: dict[str, Any]

    def section(self, name: str) -> dict[str, Any]:
        return self.raw[name]


def load_config(path: str | Path) -> Config:
    path = Path(path)
    with path.open("r", encoding="utf-8") as handle:
        raw = yaml.safe_load(handle)
    required = {"experiment", "data", "model", "training"}
    missing = required.difference(raw)
    if missing:
        raise ValueError(f"Missing config sections: {sorted(missing)}")
    return Config(raw=raw)
