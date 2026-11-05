"""Robo's runtime folder, its config and keys, and the persona and skills filled from them.

R = ~/.local/share/robo/agent (0700). `robo setup` (the Swift app) writes R/config.json; the keys
are one line each, 0600. There is no install step: SOUL.md and the skills are read from the
checkout and filled here every run.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

CHECKOUT = Path(__file__).resolve().parents[2]
AGENT = CHECKOUT / "agent"  # SOUL.md, skills/ and this package: robo's own setup
DEFAULT_MODEL = "deepseek-flash"
API_BASE = "https://api.deepseek.com/anthropic"  # DeepSeek's Anthropic-format API
DESKTOP_APPS = ("Open GUI apps on this Mac with `open -a \"<App>\"` from Bash, as a command of its "
                "own. Bash runs in a sandbox: `ps`, `top`, AppleScript to other apps, anything on "
                "localhost, `git init` and `git clone` don't work there (commits in an existing "
                "repository do). Tell the user when that stops a request; don't try to get around "
                "it.")
PLACEHOLDER = re.compile(r"\{\{(\w+)\}\}")


def runtime(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".local" / "share" / "robo" / "agent"


@dataclass
class Config:
    root: Path  # R
    port: int = 8765
    model: str = DEFAULT_MODEL
    approvals: str = "off"  # "off": robo-guard's asks are allowed; "manual": the app asks the user
    vault: str = ""
    moodle_url: str | None = None
    robo_cmd: str = "robo"
    learn: bool = True

    @property
    def home(self) -> Path:
        return self.root.parents[3]  # R = <home>/.local/share/robo/agent

    def key(self, name: str, env: str) -> str:
        """A key from the environment, else from R/<name>; "" when neither has one."""
        if os.environ.get(env, "").strip():
            return os.environ[env].strip()
        try:
            return (self.root / name).read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def fill(self, text: str) -> str:
        values = {"VAULT": self.vault or str(self.home / "Documents" / "Robo"),
                  "ROBO": self.robo_cmd, "MOODLE_BASE_URL": self.moodle_url or "not set",
                  "DESKTOP_APPS": DESKTOP_APPS}
        return PLACEHOLDER.sub(lambda m: values.get(m[1], m[0]), text)


def load(root: Path | None = None) -> Config:
    """R/config.json; a missing or broken file gives the defaults (approvals off, as live)."""
    root = root or runtime()
    try:
        data = json.loads((root / "config.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    fields = Config.__dataclass_fields__
    cfg = Config(root=root, **{k: v for k, v in data.items() if k in fields and k != "root"})
    if cfg.approvals not in ("off", "manual"):
        cfg.approvals = "manual"  # an unknown mode asks rather than allows
    return cfg


def soul(cfg: Config) -> str:
    return cfg.fill((AGENT / "SOUL.md").read_text(encoding="utf-8"))


def builtin_skills() -> list[Path]:
    return sorted((AGENT / "skills").glob("*/*/SKILL.md"))


def render_skills(cfg: Config, plugin: Path, learned: Path | None = None) -> Path:
    """Write a plugin folder `plugin` with every built-in skill filled from the config, then
    the learned ones (a learned skill never replaces a built-in one). Returns `plugin`."""
    skills = plugin / "skills"
    shutil.rmtree(plugin, ignore_errors=True)
    skills.mkdir(parents=True)
    (plugin / ".claude-plugin").mkdir()
    (plugin / ".claude-plugin" / "plugin.json").write_text('{"name": "robo"}\n')
    for path in builtin_skills():
        (skills / path.parent.name).mkdir()
        (skills / path.parent.name / "SKILL.md").write_text(
            cfg.fill(path.read_text(encoding="utf-8")), encoding="utf-8")
    if learned and learned.is_dir():
        for path in sorted(learned.glob("*/SKILL.md")):
            if not (skills / path.parent.name).exists():
                shutil.copytree(path.parent, skills / path.parent.name)
    return plugin
