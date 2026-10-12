"""Local activity watcher. Once a minute: focused app + window title, idle seconds, screen lock,
Brave site hostnames, files opened. No screenshots, no keystrokes, no URL paths or queries.
Kept only in ~/.local/share/robo/activity.db (dir 0700, file 0600) for 30 days. GNOME: focus
from robo's extension; macOS: Quartz and Spotlight."""

from __future__ import annotations

import contextlib
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from collections import Counter
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from datetime import time as dtime
from pathlib import Path
from urllib.parse import unquote, urlsplit

log = logging.getLogger(__name__)

DATA_DIR = Path.home() / ".local/share/robo"
DEFAULT_DB = DATA_DIR / "activity.db"
MAC = sys.platform == "darwin"
BRAVE_HISTORY = (Path.home() / ("Library/Application Support" if MAC else ".config")
                 / "BraveSoftware/Brave-Browser/Default/History")
RECENT_XBEL = Path.home() / ".local/share/recently-used.xbel"
LEDGER = DATA_DIR / "study.md"  # goals, exams, results the user tells robo (study-ledger skill)
IDLE_S = 120  # a minute this idle (or locked) is not active
_WEBKIT_EPOCH = 11_644_473_600  # seconds from 1601-01-01 (Chromium's epoch) to 1970-01-01

_SCHEMA = """
CREATE TABLE IF NOT EXISTS minutes(ts INTEGER, app TEXT, title TEXT, idle_s INTEGER,
                                   locked INTEGER);
CREATE TABLE IF NOT EXISTS sites(ts INTEGER, domain TEXT);
CREATE TABLE IF NOT EXISTS files(ts INTEGER, path TEXT);
CREATE INDEX IF NOT EXISTS minutes_ts ON minutes(ts);
CREATE INDEX IF NOT EXISTS sites_ts ON sites(ts);
CREATE INDEX IF NOT EXISTS files_ts ON files(ts);
"""


@dataclass
class Sample:
    ts: int
    app: str
    title: str
    idle_s: int
    locked: bool
    domains: list[str] = field(default_factory=list)
    files: list[str] = field(default_factory=list)


def ensure_ledger(path: Path = LEDGER) -> None:
    """Create the study ledger private (0600) before Hermes writes it; Hermes keeps the mode of a
    file it edits, while a file it creates would be readable by others."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.exists():
        path.write_text("# Study ledger\n\n## Goals\n\n## Exams\n\n## Results\n\n## Notes\n")
    os.chmod(path, 0o600)


class ActivityStore:
    """The 0600 SQLite file. One short connection per call, so any thread may use it."""

    def __init__(self, path: Path | str = DEFAULT_DB):
        self.path = Path(path)
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with contextlib.suppress(OSError):  # not ours to tighten (e.g. /tmp)
            os.chmod(self.path.parent, 0o700)
        os.close(os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600))  # born 0600, never wider
        os.chmod(self.path, 0o600)  # and tightened if an earlier run left it looser
        with self.connect() as con:
            con.executescript(_SCHEMA)

    @contextlib.contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        con = sqlite3.connect(self.path, timeout=10)
        try:
            with con:
                yield con
        finally:
            con.close()

    def add(self, x: Sample) -> None:
        with self.connect() as con:
            con.execute("INSERT INTO minutes VALUES (?, ?, ?, ?, ?)",
                        (x.ts, x.app, x.title, x.idle_s, int(x.locked)))
            con.executemany("INSERT INTO sites VALUES (?, ?)", [(x.ts, d) for d in x.domains])
            con.executemany("INSERT INTO files VALUES (?, ?)", [(x.ts, p) for p in x.files])

    def purge(self, now: float, days: int = 30) -> None:
        with self.connect() as con:
            for table in ("minutes", "sites", "files"):
                con.execute(f"DELETE FROM {table} WHERE ts < ?", (int(now - days * 86400),))


# --- session D-Bus readers (jeepney: already a dependency, no subprocess, real timeouts) -------


def _call(dest: str, path: str, iface: str, method: str) -> tuple:
    from jeepney import DBusAddress, new_method_call
    from jeepney.io.blocking import open_dbus_connection
    from jeepney.wrappers import unwrap_msg

    with open_dbus_connection(bus="SESSION") as conn:
        msg = new_method_call(DBusAddress(path, bus_name=dest, interface=iface), method)
        return unwrap_msg(conn.send_and_get_reply(msg, timeout=2))


def read_idle() -> int:
    ms = _call("org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
               "org.gnome.Mutter.IdleMonitor", "GetIdletime")[0]
    return int(ms) // 1000


def read_locked() -> bool:
    return bool(_call("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
                      "org.gnome.ScreenSaver", "GetActive")[0])


def _focus() -> tuple[str, str]:
    app, title = _call("org.robo.Focus", "/org/robo/Focus", "org.robo.Focus", "Current")
    return str(app), str(title)


def read_focus() -> tuple[str, str]:
    """(app_id, title) from the robo-focus GNOME Shell extension; ("", "") if it is not loaded."""
    try:
        return _focus()
    except Exception:
        return "", ""


def extension_status() -> str:
    try:
        _focus()
        return "on"
    except Exception:
        return "not loaded"


# --- Brave history: hostnames only ------------------------------------------------------------

#: The only columns the query may read. The host is cut out of `urls.url` by SQLite itself
#: (scheme://[user@]host[:port][/?#...]), so a full URL never reaches Python.
_HISTORY_READS = frozenset(
    {("urls", "id"), ("urls", "url"), ("visits", "url"), ("visits", "visit_time")}
)
_HISTORY_FUNCS = frozenset({"substr", "instr", "replace", "lower", "like"})
_HISTORY_SQL = """
SELECT lower(CASE WHEN instr(h, ':') THEN substr(h, 1, instr(h, ':') - 1) ELSE h END) FROM (
 SELECT substr(hp, instr(hp, '@') + 1) AS h FROM (
  SELECT substr(r, 1, instr(r, '/') - 1) AS hp FROM (
   SELECT replace(replace(substr(u.url, instr(u.url, '://') + 3), '?', '/'), '#', '/') || '/'
          AS r
   FROM visits AS v JOIN urls AS u ON u.id = v.url
   WHERE v.visit_time > ? AND v.visit_time <= ?
     AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%'))))
"""
_HOST = re.compile(r"[a-z0-9_-]+(\.[a-z0-9_-]+)*")


def _history_authorizer(action: int, arg1: str | None, arg2: str | None, *_: object) -> int:
    """SELECT of the four named columns with plain string functions; deny everything else."""
    if action == sqlite3.SQLITE_SELECT:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_FUNCTION and arg2 in _HISTORY_FUNCS:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_READ and (arg1, arg2) in _HISTORY_READS:
        return sqlite3.SQLITE_OK
    return sqlite3.SQLITE_DENY


def _webkit(unix: float) -> int:
    return int((unix + _WEBKIT_EPOCH) * 1_000_000)


def _read_history(history: Path, since: float, now: float, workdir: Path) -> list[str]:
    workdir.mkdir(mode=0o700, parents=True, exist_ok=True)
    private = Path(tempfile.mkdtemp(prefix=".history-", dir=workdir))  # mode 0700
    try:
        copy = private / "History"
        fd = os.open(copy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as out, open(history, "rb") as src:
            shutil.copyfileobj(src, out)
        con = sqlite3.connect(f"{copy.as_uri()}?mode=ro", uri=True)
        with contextlib.closing(con):
            con.set_authorizer(_history_authorizer)
            found = con.execute(_HISTORY_SQL, (_webkit(since), _webkit(now))).fetchall()
    finally:
        shutil.rmtree(private, ignore_errors=True)
    hosts = (h.rstrip(".") for (h,) in found if isinstance(h, str))
    return [h for h in hosts if _HOST.fullmatch(h)]


def read_sites(since: float, now: float, *, history: Path = BRAVE_HISTORY,
               workdir: Path = DATA_DIR) -> list[str]:
    """One hostname per Brave visit in (since, now]; [] when unreadable."""
    workdir = Path(workdir)
    for stale in workdir.glob(".history-*"):  # left by a SIGKILL or power cut
        shutil.rmtree(stale, ignore_errors=True)
    if not Path(history).is_file():
        return []
    for _attempt in range(2):  # a copy taken mid-write can be inconsistent: retry once
        try:
            return _read_history(Path(history), since, now, workdir)
        except (OSError, sqlite3.Error):
            continue
    return []


# --- files opened (GTK recently-used.xbel) ----------------------------------------------------


def _stamp(value: str | None) -> float | None:
    try:
        return datetime.fromisoformat(value).timestamp() if value else None
    except ValueError:
        return None


def read_files(since: float, now: float, *, xbel: Path = RECENT_XBEL) -> list[str]:
    """Local paths whose bookmark was modified or visited in (since, now]; [] when unreadable."""
    try:
        root = ET.parse(xbel).getroot()
    except (OSError, ET.ParseError):
        return []
    out: list[str] = []
    for b in root.iter("bookmark"):
        href = b.get("href", "")
        stamps = (_stamp(b.get("modified")), _stamp(b.get("visited")))
        if href.startswith("file://") and any(t and since < t <= now for t in stamps):
            path = unquote(urlsplit(href).path)
            if path not in out:
                out.append(path)
    return out


# --- macOS readers (Quartz, Spotlight): no extension needed ------------------------------------


def front_window(windows: list) -> tuple[str, str]:
    """(app, title) of the frontmost normal window in Quartz's front-to-back list. Robo's own
    always-on-top window and the menu bar sit above layer 0; the title needs Screen Recording."""
    for w in windows:
        if w.get("kCGWindowLayer") == 0 and w.get("kCGWindowAlpha", 1) > 0:
            return str(w.get("kCGWindowOwnerName") or ""), str(w.get("kCGWindowName") or "")
    return "", ""


def _quartz():
    import Quartz  # pyobjc-framework-Quartz, installed on macOS only

    return Quartz


def _mac_windows() -> list:
    """On-screen windows, front to back (Quartz window dicts)."""
    q = _quartz()
    opts = q.kCGWindowListOptionOnScreenOnly | q.kCGWindowListExcludeDesktopElements
    return list(q.CGWindowListCopyWindowInfo(opts, q.kCGNullWindowID) or [])


def mac_focus() -> tuple[str, str]:
    try:
        return front_window(_mac_windows())
    except Exception:
        return "", ""


def mac_idle() -> float:
    q = _quartz()
    return float(q.CGEventSourceSecondsSinceLastEventType(
        q.kCGEventSourceStateCombinedSessionState, q.kCGAnyInputEventType))


def mac_locked() -> bool:
    return bool((_quartz().CGSessionCopyCurrentDictionary() or {})
                .get("CGSSessionScreenIsLocked"))


def _utc(t: float) -> str:
    return datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _mdfind(query: str) -> str:
    return subprocess.run(["mdfind", "-onlyin", str(Path.home()), query], capture_output=True,
                          text=True, timeout=20).stdout


def mac_files(since: float, now: float, *, find: Callable[[str], str] = _mdfind) -> list[str]:
    """Files Spotlight saw opened in (since, now]; [] when Spotlight is off or slow."""
    query = (f"kMDItemLastUsedDate > $time.iso({_utc(since)}) && "
             f"kMDItemLastUsedDate <= $time.iso({_utc(now)})")
    try:
        found = find(query).splitlines()
    except (OSError, subprocess.SubprocessError):
        return []
    return list(dict.fromkeys(p for p in found if p.startswith("/")))


# What sample() reads on this OS: GNOME D-Bus + recently-used.xbel, or Quartz + Spotlight.
FOCUS, IDLE, LOCKED, FILES = ((mac_focus, mac_idle, mac_locked, mac_files) if MAC
                              else (read_focus, read_idle, read_locked, read_files))


# --- sampling ---------------------------------------------------------------------------------


def sample(now: float, since: float, *, focus: Callable[[], tuple[str, str]] = FOCUS,
           idle: Callable[[], int] = IDLE, locked: Callable[[], bool] = LOCKED,
           sites: Callable[[float, float], list[str]] = read_sites,
           files: Callable[[float, float], list[str]] = FILES) -> Sample:
    app, title = focus()
    return Sample(int(now), app, title, int(idle()), bool(locked()), sites(since, now),
                  files(since, now))


class Watcher:
    """Records one Sample every `interval` s on a daemon thread; purges rows past 30 days.
    Paused: nothing is recorded (and what happens meanwhile is never picked up), purge runs."""

    def __init__(self, store: ActivityStore, interval: float = 60,
                 clock: Callable[[], float] = time.time,
                 sampler: Callable[[float, float], Sample] = sample):
        self.store, self.interval, self.clock, self.sampler = store, interval, clock, sampler
        self._since = clock()
        self._paused = False
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    @property
    def paused(self) -> bool:
        return self._paused

    def pause(self, paused: bool = True) -> None:
        self._paused = bool(paused)

    def tick(self) -> None:
        now = self.clock()
        try:
            if not self._paused:
                self.store.add(self.sampler(now, self._since))
            self._since = now  # a failed sample leaves the window open for the next one
        except Exception as e:
            log.warning("activity sample failed: %s", e)
        try:
            self.store.purge(now)
        except Exception as e:
            log.warning("activity purge failed: %s", e)

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._since = self.clock()
        self._thread = threading.Thread(target=self._run, daemon=True, name="robo-activity")
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            self.tick()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)
            self._thread = None


# --- summary for the LLM ----------------------------------------------------------------------


def _clip(text: str, n: int, tail: bool = False) -> str:
    if len(text) <= n:
        return text
    return "…" + text[-(n - 1):] if tail else text[: n - 1] + "…"


def summary(store: ActivityStore, day: date | None = None, days: int = 1) -> str:
    """Compact text: active minutes per app, top windows, top sites, files, first/last active."""
    day = day or date.today()
    first = day - timedelta(days=days - 1)
    span = str(day) if days == 1 else f"{first}..{day}"
    lo = datetime.combine(first, dtime()).timestamp()
    hi = datetime.combine(day + timedelta(days=1), dtime()).timestamp()
    with store.connect() as con:
        active = con.execute(
            "SELECT ts, app, title FROM minutes WHERE ts >= ? AND ts < ? AND idle_s < ? "
            "AND locked = 0 ORDER BY ts", (lo, hi, IDLE_S)).fetchall()
        sites = con.execute(
            "SELECT domain, count(*) AS n FROM sites WHERE ts >= ? AND ts < ? GROUP BY domain "
            "ORDER BY n DESC, domain LIMIT 15", (lo, hi)).fetchall()
        files = con.execute(
            "SELECT path, max(ts) AS t FROM files WHERE ts >= ? AND ts < ? GROUP BY path "
            "ORDER BY t DESC LIMIT 12", (lo, hi)).fetchall()
        recorded = con.execute("SELECT count(*) FROM minutes WHERE ts >= ? AND ts < ?",
                               (lo, hi)).fetchone()[0]
    if not (active or sites or files):  # tell "watching but away" from "not watching"
        if recorded:
            return f"No active time for {span}: {recorded} min recorded, all idle or locked."
        return f"No activity recorded for {span}."
    fmt = "%H:%M" if days == 1 else "%m-%d %H:%M"
    apps = Counter(app or "(unknown)" for _, app, _ in active)
    titles = Counter((app or "(unknown)", title) for _, app, title in active if title)
    head = f"Activity {span}: {len(active)} active min (idle >= {IDLE_S}s and locked excluded)"
    if active:
        head += (f", first {datetime.fromtimestamp(active[0][0]).strftime(fmt)}"
                 f", last {datetime.fromtimestamp(active[-1][0]).strftime(fmt)}")
    home = str(Path.home())
    lines = [
        head,
        "Apps (active min): " + ", ".join(f"{a} {n}" for a, n in apps.most_common(12)),
        "Top windows:",
        *(f"- {n} min  {a}: {_clip(t, 70)}" for (a, t), n in titles.most_common(10)),
        "Sites (visits): " + ", ".join(f"{d} {n}" for d, n in sites),
        "Files opened: " + ", ".join(
            _clip(p.replace(home, "~", 1) if p.startswith(home) else p, 70, tail=True)
            for p, _ in files),
    ]
    return "\n".join(lines)[:2500]
