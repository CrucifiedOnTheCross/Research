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


def apply_overrides(config: Config, overrides: list[str]) -> Config:
    for override in overrides:
        if "=" not in override:
            raise ValueError(f"Invalid override (expected key=value): {override}")
        dotted_key, raw_value = override.split("=", 1)
        keys = dotted_key.split(".")
        target = config.raw
        for key in keys[:-1]:
            if key not in target or not isinstance(target[key], dict):
                raise KeyError(f"Unknown config path: {dotted_key}")
            target = target[key]
        if keys[-1] not in target:
            raise KeyError(f"Unknown config key: {dotted_key}")
        target[keys[-1]] = yaml.safe_load(raw_value)
    return config
