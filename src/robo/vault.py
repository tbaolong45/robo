"""Robo's Obsidian vault: where drafts, plans and notes are written, and how one is shown.

Hermes writes the notes (it is told the vault path through {{VAULT}} in its templates); this
module only creates the vault, lists it in Obsidian and opens a note. No other robo imports.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from urllib.parse import quote

VAULT = Path.home() / "Documents" / "Robo"  # the one source of truth; templates get {{VAULT}}
FOLDERS = ("Drafts", "Plans", "Notes")  # notes are .md files directly inside these


def mac_app_dirs() -> tuple[Path, ...]:
    return Path("/Applications"), Path.home() / "Applications"


def obsidian_installed(apps: tuple[Path, ...] | None = None) -> bool:
    """`apps`: the macOS Applications folders to look in (default: system and user)."""
    if sys.platform == "darwin":
        return any((d / "Obsidian.app").is_dir() for d in apps or mac_app_dirs())
    flatpak = ("/var/lib/flatpak", Path.home() / ".local/share/flatpak")
    return bool(shutil.which("obsidian")) or any(
        (Path(d) / "exports/bin/md.obsidian.Obsidian").exists() for d in flatpak)


def obsidian_running() -> bool:
    name = "Obsidian" if sys.platform == "darwin" else "obsidian"
    try:
        return subprocess.run(["pgrep", "-x", name], capture_output=True,
                              timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return True  # cannot tell: assume it is, so its settings are left alone


def obsidian_config() -> Path:
    """Obsidian's own list of vaults."""
    base = (Path.home() / "Library/Application Support" if sys.platform == "darwin"
            else Path.home() / ".config")
    return base / "obsidian" / "obsidian.json"


def obsidian_uri(path: Path) -> str:
    return "obsidian://open?path=" + quote(str(path), safe="")


def _spawn(argv: list[str]) -> None:
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def open_note(path: Path, front: bool = True,
              spawn: Callable[[list[str]], None] | None = None) -> None:
    """Show a note in Obsidian (else in the OS's app for .md) without waiting for it.

    front=False opens it behind what you are doing (macOS `open -g`; xdg-open has no such flag).
    """
    mac = sys.platform == "darwin"
    target = obsidian_uri(path) if obsidian_installed() else str(path)
    argv = ["open" if mac else "xdg-open", *(["-g"] if mac and not front else []), target]
    (spawn or _spawn)(argv)  # looked up now, so tests can replace _spawn


def _register(vault: Path, config: Path) -> str:
    """List the vault in Obsidian's config. Returns what happened, "" if it was already there."""
    how = f"in Obsidian choose 'Open folder as vault' and pick {vault}"
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
        vaults = data.setdefault("vaults", {})
        known = [v.get("path") for v in vaults.values()]
    except FileNotFoundError:
        return f"Obsidian has not been set up here yet: install it, open it once, then {how}"
    except (OSError, ValueError, AttributeError):
        return f"I could not read Obsidian's vault list ({config}): {how}"
    if str(vault) in known:
        return ""
    if obsidian_running():  # it rewrites the file on quit and would undo the edit
        return f"Obsidian is open, so I left its settings alone: quit it and run `robo setup` " \
               f"again, or {how}"
    vaults[secrets.token_hex(8)] = {"path": str(vault), "ts": int(time.time() * 1000)}
    tmp = config.with_name(config.name + ".tmp")
    try:
        tmp.write_text(json.dumps(data, separators=(",", ":"), ensure_ascii=False),
                       encoding="utf-8")
        os.replace(tmp, config)
    except OSError as e:
        return f"I could not update Obsidian's vault list ({e}): {how}"
    return "added your Robo vault to Obsidian"


def ensure_vault(vault: Path | None = None, config: Path | None = None) -> list[str]:
    """Idempotent; returns what it did (or what you still have to do). Never raises."""
    vault, config = vault or VAULT, config or obsidian_config()  # read now, not at import
    dirs = [vault, *(vault / f for f in FOLDERS), vault / ".obsidian"]
    fresh = [d for d in dirs if not d.is_dir()]
    try:
        for d in fresh:
            d.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        return [f"could not create your Obsidian vault at {vault}: {e}"]
    done = [f"created your Obsidian vault at {vault}"] if fresh else []
    return done + [m for m in (_register(vault, config),) if m]
