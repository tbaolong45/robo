"""Robo's own Brave: a separate profile (school logins only) that Hermes drives over CDP.

The user's everyday Brave locks its login databases while it runs, so Hermes cannot borrow it.
Robo's Brave has its own data dir, listens on 127.0.0.1 only, runs headless, and is shown once
(`robo signin`) so the user can sign in to Outlook, Teams and Moodle with their passkey.
"""

from __future__ import annotations

import contextlib
import os
import shutil
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

import httpx

PORT = 9333  # not 9222, which Hermes' own `/browser connect` uses
CDP_URL = f"http://127.0.0.1:{PORT}"
BINARY = shutil.which("brave-browser") or shutil.which("brave") or "brave-browser"
SIGNIN_URLS = ("https://outlook.office.com/mail/", "https://teams.microsoft.com/")


class BrowserError(RuntimeError):
    pass


def up() -> bool:
    try:
        return httpx.get(f"{CDP_URL}/json/version", timeout=2, trust_env=False).status_code == 200
    except httpx.HTTPError:
        return False


def _spawn(argv: list[str]) -> None:
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def ensure(data_dir: Path, *, headless: bool = True, url: str | None = None,
           up: Callable[[], bool] = up, spawn: Callable[[list[str]], None] = _spawn,
           sleep: Callable[[float], None] = time.sleep, wait: float = 20) -> bool:
    """Start robo's Brave unless it already answers on PORT; True if this call started it."""
    if up():
        return False
    data_dir.mkdir(parents=True, exist_ok=True)
    data_dir.chmod(0o700)  # cookies of the user's school accounts
    argv = [BINARY, f"--user-data-dir={data_dir}", f"--remote-debugging-port={PORT}",
            "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check"]
    if headless:
        argv.append("--headless=new")
    spawn(argv + ([url] if url else []))
    for _ in range(int(wait / 0.5)):
        if up():
            return True
        sleep(0.5)
    raise BrowserError(f"robo's Brave did not open its debug port {PORT} ({BINARY}).")


def pids(data_dir: Path, proc: Path = Path("/proc")) -> list[int]:
    """Main and child processes of robo's Brave (matched by its exact --user-data-dir)."""
    flag = f"--user-data-dir={data_dir}".encode()
    out = []
    for d in proc.iterdir():
        if d.name.isdigit():
            try:
                if flag in (d / "cmdline").read_bytes().split(b"\0"):
                    out.append(int(d.name))
            except OSError:
                pass
    return sorted(out)


def stop(data_dir: Path) -> None:
    for pid in pids(data_dir):
        with contextlib.suppress(OSError):  # gone already, or not ours to kill
            os.kill(pid, 15)
    for _ in range(40):
        if not up():
            return
        time.sleep(0.25)


def signin(data_dir: Path) -> None:
    """Show robo's Brave so the user can sign in; robo goes back to headless afterwards."""
    stop(data_dir)
    ensure(data_dir, headless=False, url=SIGNIN_URLS[0])
    for extra in SIGNIN_URLS[1:]:
        _spawn([BINARY, f"--user-data-dir={data_dir}", extra])  # opens a tab in that instance
