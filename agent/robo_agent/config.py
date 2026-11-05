"""Robo's runtime folder, its config and keys, and the persona.

R = ~/.local/share/robo/agent (0700). `robo setup` (the Swift app) writes R/config.json; the keys
are one line each, 0600.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

SOUL = Path(__file__).resolve().parents[1] / "SOUL.md"
DEFAULT_MODEL = "deepseek-flash"
API_BASE = "https://api.deepseek.com/anthropic"  # DeepSeek's Anthropic-format API


def runtime(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".local" / "share" / "robo" / "agent"


@dataclass
class Config:
    root: Path  # R
    port: int = 8765
    model: str = DEFAULT_MODEL

    def key(self, name: str, env: str) -> str:
        """A key from the environment, else from R/<name>; "" when neither has one."""
        if os.environ.get(env, "").strip():
            return os.environ[env].strip()
        try:
            return (self.root / name).read_text(encoding="utf-8").strip()
        except OSError:
            return ""


def load(root: Path | None = None) -> Config:
    """R/config.json; a missing or broken file gives the defaults; unknown settings are ignored."""
    root = root or runtime()
    try:
        data = json.loads((root / "config.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    fields = Config.__dataclass_fields__
    return Config(root=root, **{k: v for k, v in data.items() if k in fields and k != "root"})


def soul() -> str:
    return SOUL.read_text(encoding="utf-8")
