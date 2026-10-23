"""Robo's own Brave: a separate profile (school logins only) that Hermes drives over CDP.

The user's everyday Brave locks its login databases while it runs, so Hermes cannot borrow it.
Robo's Brave has its own data dir, listens on 127.0.0.1 only, runs headless, and is shown once
(`robo signin`) so the user can sign in to Outlook, Teams and Moodle with their passkey.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

import httpx

PORT = 9333  # not 9222, which Hermes' own `/browser connect` uses
CDP_URL = f"http://127.0.0.1:{PORT}"
MAC_BRAVE = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"


def find_brave(platform: str = sys.platform, which: Callable[[str], str | None] = shutil.which,
               ) -> str:
    """Brave on PATH, else where its installer puts it."""
    return (which("brave-browser") or which("brave")
            or (MAC_BRAVE if platform == "darwin" else "brave-browser"))


BINARY = find_brave()
DOWNLOADS = Path.home() / "Robo" / "Downloads"  # outside ~/.hermes: the agent may move files out
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


def allow_downloads(data_dir: Path, folder: Path) -> None:
    """Make robo's Brave save downloads into `folder`, and download a PDF instead of showing it.

    A headless Brave has no download folder, so nothing it fetched reached the disk; CDP's
    `setDownloadBehavior` does not outlive one connection and Hermes opens a new one per call.
    Brave rewrites its Preferences when it exits, so this works only before a start. A file that
    does not parse is left alone.
    """
    folder.mkdir(parents=True, exist_ok=True)
    file = data_dir / "Default" / "Preferences"
    file.parent.mkdir(parents=True, exist_ok=True)
    prefs: dict = {}
    if file.exists():
        try:
            prefs = json.loads(file.read_text())
        except ValueError:
            return
        if not isinstance(prefs, dict):
            return
    prefs["download"] = {**prefs.get("download", {}), "default_directory": str(folder),
                         "prompt_for_download": False}
    prefs["plugins"] = {**prefs.get("plugins", {}), "always_open_pdf_externally": True}
    tmp = file.with_name("Preferences.robo")
    tmp.write_text(json.dumps(prefs))
    tmp.replace(file)


def ensure(data_dir: Path, *, headless: bool = True, url: str | None = None,
           downloads: Path | None = None,
           up: Callable[[], bool] = up, spawn: Callable[[list[str]], None] = _spawn,
           sleep: Callable[[float], None] = time.sleep, wait: float = 20) -> bool:
    """Start robo's Brave unless it already answers on PORT; True if this call started it."""
    if up():
        return False
    data_dir.mkdir(parents=True, exist_ok=True)
    data_dir.chmod(0o700)  # cookies of the user's school accounts
    if downloads:
        allow_downloads(data_dir, downloads)
    argv = [BINARY, f"--user-data-dir={data_dir}", f"--remote-debugging-port={PORT}",
            "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check"]
    if headless:
        argv.append("--headless=new")
    try:
        spawn(argv + ([url] if url else []))
    except OSError as e:  # not installed, or installed somewhere else
        raise BrowserError(f"Could not start Brave ({BINARY}): {e}. Install it from "
                           "https://brave.com, or put `brave` on your PATH.") from e
    for _ in range(int(wait / 0.5)):
        if up():
            return True
        sleep(0.5)
    raise BrowserError(f"robo's Brave did not open its debug port {PORT} ({BINARY}).")


def _ps() -> str:
    """Every process with its full command line (macOS has no /proc)."""
    return subprocess.run(["ps", "-A", "-ww", "-o", "pid=,args="], capture_output=True,
                          text=True, timeout=10).stdout


def pids(data_dir: Path, proc: Path = Path("/proc"), ps: Callable[[], str] = _ps) -> list[int]:
    """Main and child processes of robo's Brave (matched by its exact --user-data-dir)."""
    if not proc.is_dir():  # macOS: a space-bounded match, since a home folder may hold spaces
        flag = f" --user-data-dir={data_dir} "
        try:
            lines = ps().splitlines()
        except (OSError, subprocess.SubprocessError):
            return []
        found = []
        for line in lines:
            pid, _, args = line.strip().partition(" ")
            if pid.isdigit() and flag in f" {args} ":
                found.append(int(pid))
        return sorted(found)
    flag = f"--user-data-dir={data_dir}".encode()
    out = []
    for d in proc.iterdir():
        if d.name.isdigit():
            try:
                # Chromium rewrites its argv in place, joined by spaces, so split on both.
                if flag in (d / "cmdline").read_bytes().replace(b"\0", b" ").split():
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


def signin(data_dir: Path, extra: tuple[str, ...] = ()) -> None:
    """Show robo's Brave so the user can sign in; robo goes back to headless afterwards."""
    stop(data_dir)
    ensure(data_dir, headless=False, url=SIGNIN_URLS[0], downloads=DOWNLOADS)
    for url in (*SIGNIN_URLS[1:], *extra):
        _spawn([BINARY, f"--user-data-dir={data_dir}", url])  # opens a tab in that instance
