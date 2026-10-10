"""Local activity watching: counts per hour of what you did, never what it was.

`pli watch` samples four signals on this machine and keeps only a count per (day, hour):
keyboard/mouse activity, git commits, edited files and visits to a short list of websites.
There are no screenshots, no window titles and no keystrokes. This module is the whole
collector; `pli watch` only calls `collect_once` in a loop.

Rules:

1. **What is stored is `(day, hour, kind, key, n)` and nothing else.** `key` is a git
   repository's directory name, an allowlisted domain, or empty. Never a page title, a full
   URL, a search term, a file name, a commit message, a path or a shell command. `replace`
   refuses a key that looks like a path or contains a control character, so a bug in a
   scanner cannot put one in the file.
2. **Only allowlisted domains are stored.** A subdomain counts as its parent
   (`docs.github.com` is `github.com`); the stored key is the allowlist entry itself.
   Every other visit in the browser history is discarded, and with an empty allowlist the
   history is not even opened.
3. **The browser History file is never opened in place.** It is copied into a private
   (0700) directory under `workdir`, the copy is opened read-only, and the copy is deleted
   in a `finally` - on success, on a corrupt file and on any error - and a copy left by a
   scan that was killed is removed by the next scan. The query reads only the
   `urls` and `visits` tables, only `urls.url`, `urls.id`, `visits.url` and
   `visits.visit_time`, and the SQLite authorizer refuses everything else (titles, search
   terms, downloads, any write). The host is taken out of the URL by a function inside the
   query, so the full URL never reaches this module's own variables.
4. **The database file is mode 0600 from creation** (`pli.db.connect_private`); one made
   earlier with looser rights is tightened.
5. **`purge` deletes what is older than the retention,** every cycle, even while paused:
   pausing stops collecting, not the promise to forget.
6. **Nothing here raises into its caller because of the environment.** No gdbus, an
   unreadable repository, a locked or corrupt History, a missing folder: the function
   returns `None`, `False` or an empty list, and `collect_once` returns a status word.
7. **A pause flag file stops collection.** `collect_once` checks it every cycle, and a
   paused cycle samples, scans and stores nothing (it only purges).

Three behaviours worth knowing:

* Every scan covers the last 24 hours *starting at the top of the hour*, so the oldest hour
  in the window is complete. `ActivityStore.replace` deletes from that same hour on and
  inserts the fresh counts, which makes a rescan idempotent without ever halving an hour.
* `collect_once` replaces a kind only when its scan found something. A locked History or an
  unreadable folder looks, to the caller, like zero visits; replacing with zero would wipe
  the day already collected.
* "Active" means keyboard or mouse input in the last two minutes with the screen unlocked.
  It is not time spent studying, and the digest says so.

All commands go through an injectable runner (`run(cmd) -> (returncode, stdout)`) and every
scan takes its clock from `now`, so tests need no D-Bus, no git history of their own and no
real browser.
"""

from __future__ import annotations

import contextlib
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, tzinfo
from pathlib import Path
from typing import TYPE_CHECKING
from urllib.parse import urlsplit

from pli.db import connect_private

if TYPE_CHECKING:  # pragma: no cover - only needed for the annotation
    from pli.config import Settings

__all__ = [
    "IDLE_ACTIVE_SECONDS",
    "KINDS",
    "ActivityStore",
    "Reading",
    "collect_once",
    "default_history_path",
    "digest",
    "is_paused",
    "pause",
    "resume",
    "sample_idle",
    "scan_files",
    "scan_git",
    "scan_history",
    "window_start",
]

#: Input within this many seconds, with the screen unlocked, counts as "active".
IDLE_ACTIVE_SECONDS = 120
KINDS = ("active_min", "commit", "files", "visit")

WINDOW_HOURS = 24
MAX_REPOS = 20
MAX_REPO_DEPTH = 5
MAX_KEY_LENGTH = 100
RUN_TIMEOUT = 10.0
_WEBKIT_EPOCH_OFFSET = 11_644_473_600  # seconds from 1601-01-01 (Chromium) to 1970-01-01

#: Folders never searched for repositories: environments, caches, package stores.
_GIT_PRUNE = frozenset(
    {".venv", "node_modules", ".cache", ".local", ".cargo", "snap", ".npm", "__pycache__"}
)
#: Folders never counted for edited files: tooling output, state, and git's own objects.
_FILE_PRUNE = frozenset(
    {".venv", "node_modules", "__pycache__", ".ruff_cache", ".pytest_cache", ".git", "data"}
)
_FILE_SKIP_SUFFIXES = (".pyc", ".lock", ".log")

_IDLE_CMD = [
    "gdbus", "call", "--session", "--dest", "org.gnome.Mutter.IdleMonitor",
    "--object-path", "/org/gnome/Mutter/IdleMonitor/Core",
    "--method", "org.gnome.Mutter.IdleMonitor.GetIdletime",
]  # fmt: skip
_LOCK_CMD = [
    "gdbus", "call", "--session", "--dest", "org.gnome.ScreenSaver",
    "--object-path", "/org/gnome/ScreenSaver",
    "--method", "org.gnome.ScreenSaver.GetActive",
]  # fmt: skip
_IDLE_REPLY = re.compile(r"\(uint64 (\d+),?\)")
_LOCK_REPLY = re.compile(r"\((true|false),?\)")

_BAD_KEY = re.compile(r"[/\\\x00-\x1f\x7f]")
_DAY = re.compile(r"\d{4}-\d{2}-\d{2}")

Runner = Callable[[list[str]], tuple[int, str]]


@dataclass(frozen=True)
class Reading:
    """A count for one local hour. `day` is 'YYYY-MM-DD' in the local zone of `now`."""

    day: str
    hour: int
    kind: str
    key: str
    n: int


def _run(cmd: list[str], timeout: float = RUN_TIMEOUT) -> tuple[int, str]:
    """Run a command and return (returncode, stdout). Never raises: failure is (1, '')."""
    try:
        done = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            errors="replace",
            stdin=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, ValueError):
        return 1, ""
    return done.returncode, done.stdout


# --- time ------------------------------------------------------------------------------------


def _aware(moment: datetime) -> datetime:
    return moment if moment.tzinfo is not None else moment.astimezone()


def window_start(now: datetime) -> datetime:
    """Top of the hour 24 hours before `now`: where every scan starts counting."""
    now = _aware(now)
    back = datetime.fromtimestamp(now.timestamp() - WINDOW_HOURS * 3600, now.tzinfo)
    return back.replace(minute=0, second=0, microsecond=0)


class _Window:
    """The scan window as unix times, plus the local (day, hour) bucket of a timestamp."""

    def __init__(self, now: datetime) -> None:
        now = _aware(now)
        self.start = window_start(now).timestamp()
        self.end = now.timestamp()
        self.tz: tzinfo = now.tzinfo  # type: ignore[assignment]

    def bucket(self, timestamp: float) -> tuple[str, int] | None:
        if not self.start <= timestamp <= self.end:
            return None
        local = datetime.fromtimestamp(timestamp, self.tz)
        return local.strftime("%Y-%m-%d"), local.hour


def _readings(counts: Counter[tuple[str, int, str]], kind: str) -> list[Reading]:
    return [Reading(day, hour, kind, key, n) for (day, hour, key), n in sorted(counts.items())]


# --- idle ------------------------------------------------------------------------------------


def sample_idle(run: Runner = _run) -> bool | None:
    """True = active (input in the last 2 minutes, screen unlocked); False = idle or locked;
    None = GNOME's idle monitor is unavailable, failing or answered something unreadable."""
    code, out = run(_IDLE_CMD)
    idle = _IDLE_REPLY.fullmatch(out.strip()) if code == 0 else None
    code, out = run(_LOCK_CMD)
    lock = _LOCK_REPLY.fullmatch(out.strip()) if code == 0 else None
    if idle is None or lock is None:
        return None
    return int(idle[1]) < IDLE_ACTIVE_SECONDS * 1000 and lock[1] == "false"


# --- git -------------------------------------------------------------------------------------


def _find_repos(roots: Sequence[Path]) -> list[Path]:
    """Directories holding a `.git` (folder or worktree file), at most MAX_REPOS, sorted."""
    found: list[Path] = []
    for root in roots:
        stack = [(Path(root).expanduser(), 0)]
        while stack and len(found) < MAX_REPOS:
            path, depth = stack.pop()
            if os.path.lexists(path / ".git"):
                if path.name and path not in found:
                    found.append(path)
                continue
            if depth < MAX_REPO_DEPTH:
                stack.extend((child, depth + 1) for child in reversed(_subdirs(path, _GIT_PRUNE)))
    return found


def _subdirs(path: Path, prune: frozenset[str]) -> list[Path]:
    try:
        with os.scandir(path) as entries:
            return sorted(Path(e.path) for e in entries if e.name not in prune and _is_dir(e))
    except OSError:
        return []


def _is_dir(entry: os.DirEntry[str]) -> bool:
    try:
        return entry.is_dir(follow_symlinks=False)
    except OSError:
        return False


def scan_git(roots: Sequence[Path], now: datetime, run: Runner = _run) -> list[Reading]:
    """Commits per local hour by each repository's own `user.email`, last 24 h. Only the
    commit timestamps are read from git (`--format=%ct`), never a message or a file name.
    `--no-show-signature` stops a downloaded repository's own config from running a program
    (`gpg.program`) to check a signed commit."""
    window = _Window(now)
    since = datetime.fromtimestamp(window.start, window.tz).isoformat(timespec="seconds")
    counts: Counter[tuple[str, int, str]] = Counter()
    for repo in _find_repos(roots):
        base = ["git", "-C", str(repo)]
        code, _ = run([*base, "rev-parse", "-q", "--verify", "HEAD"])
        if code != 0:  # an empty repository exits 128: zero commits, not an error
            continue
        code, out = run([*base, "config", "user.email"])
        email = out.strip().splitlines()[0].strip() if code == 0 and out.strip() else ""
        if not email:
            continue
        code, out = run(
            [
                *base, "log", "--fixed-strings", "--regexp-ignore-case", "--no-show-signature",
                f"--since={since}", f"--author=<{email}>", "--format=%ct",
            ]
        )  # fmt: skip
        if code != 0:
            continue
        for line in out.splitlines():
            if line.strip().isdigit() and (bucket := window.bucket(int(line))):
                counts[(*bucket, repo.name)] += 1
    return _readings(counts, "commit")


# --- files -----------------------------------------------------------------------------------


def scan_files(
    roots: Sequence[Path],
    now: datetime,
    budget_s: float = 2.0,
    *,
    clock: Callable[[], float] = time.monotonic,
) -> list[Reading]:
    """Files modified per local hour, last 24 h, as counts with an empty key. Only the
    modification time is read; names are matched against the exclusions and dropped.
    A scan that runs out of time returns nothing, not a partial count: the collector
    replaces the whole window with what it is given, and nothing means "keep what we have"."""
    window = _Window(now)
    deadline = clock() + budget_s
    counts: Counter[tuple[str, int, str]] = Counter()
    stack = [Path(root).expanduser() for root in roots]
    while stack:
        directory = stack.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    if clock() >= deadline:
                        return []
                    _count_entry(entry, window, stack, counts)
        except OSError:
            continue
    return _readings(counts, "files")


def _count_entry(
    entry: os.DirEntry[str],
    window: _Window,
    stack: list[Path],
    counts: Counter[tuple[str, int, str]],
) -> None:
    name = entry.name
    try:
        if entry.is_dir(follow_symlinks=False):
            if name not in _FILE_PRUNE:
                stack.append(Path(entry.path))
            return
        if name == ".git" or name.endswith(_FILE_SKIP_SUFFIXES):
            return
        if not entry.is_file(follow_symlinks=False):
            return
        modified = entry.stat(follow_symlinks=False).st_mtime
    except OSError:
        return
    if bucket := window.bucket(modified):
        counts[(*bucket, "")] += 1


# --- browser history -------------------------------------------------------------------------

#: The only columns the history query may touch (rule 3). `urls.url` goes straight into
#: `allowed_domain()` inside the query; the full URL is never selected.
_HISTORY_READS = frozenset(
    {("urls", "id"), ("urls", "url"), ("visits", "url"), ("visits", "visit_time")}
)
_HISTORY_SQL = (
    "SELECT allowed_domain(u.url), v.visit_time FROM visits AS v "
    "JOIN urls AS u ON u.id = v.url WHERE v.visit_time >= ? AND v.visit_time <= ?"
)


def _history_authorizer(action: int, arg1: str | None, arg2: str | None, *_: object) -> int:
    """Allow a SELECT of the four named columns; deny everything else, including writes."""
    if action == sqlite3.SQLITE_SELECT:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_FUNCTION and arg2 == "allowed_domain":
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_READ and (arg1, arg2) in _HISTORY_READS:
        return sqlite3.SQLITE_OK
    return sqlite3.SQLITE_DENY


def default_history_path() -> Path | None:
    """Brave's default-profile History file, if it exists."""
    path = Path("~/.config/BraveSoftware/Brave-Browser/Default/History").expanduser()
    return path if path.is_file() else None


def _match_domain(url: object, domains: Sequence[str]) -> str | None:
    """The allowlist entry that `url`'s host equals or is a subdomain of, else None.
    `domains` is longest first, so the most specific entry wins."""
    if not isinstance(url, str):
        return None
    try:
        host = urlsplit(url).hostname
    except ValueError:
        return None
    if not host:
        return None
    host = host.rstrip(".")
    return next((d for d in domains if host == d or host.endswith("." + d)), None)


def _webkit_to_unix(visit_time: int) -> float:
    return visit_time / 1_000_000 - _WEBKIT_EPOCH_OFFSET


def _unix_to_webkit(timestamp: float) -> int:
    return int((timestamp + _WEBKIT_EPOCH_OFFSET) * 1_000_000)


def _copy_private(source: Path, directory: Path) -> Path:
    copy = directory / "History"
    fd = os.open(copy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as out, open(source, "rb") as src:
        shutil.copyfileobj(src, out)
    return copy


def _read_history_once(
    path: Path, domains: list[str], window: _Window, workdir: Path
) -> list[tuple[str, float]]:
    private: Path | None = None
    try:
        workdir.mkdir(parents=True, exist_ok=True)
        private = Path(tempfile.mkdtemp(prefix=".history-", dir=workdir))  # mode 0700
        copy = _copy_private(path, private)
        con = sqlite3.connect(f"{copy.as_uri()}?mode=ro", uri=True)
        with contextlib.closing(con):
            con.create_function(
                "allowed_domain", 1, lambda url: _match_domain(url, domains), deterministic=True
            )
            con.set_authorizer(_history_authorizer)
            low, high = _unix_to_webkit(window.start), _unix_to_webkit(window.end)
            found = con.execute(_HISTORY_SQL, (low, high)).fetchall()
        return [(domain, _webkit_to_unix(t)) for domain, t in found if domain is not None]
    finally:
        if private is not None:
            shutil.rmtree(private, ignore_errors=True)


def _remove_stale_copies(workdir: Path) -> None:
    """A scan stopped by SIGKILL or a power cut cannot delete its copy: the next one does."""
    for stale in Path(workdir).glob(".history-*"):
        shutil.rmtree(stale, ignore_errors=True)


def scan_history(
    path: Path | None, allowlist: Sequence[str], now: datetime, workdir: Path
) -> list[Reading]:
    """Visit counts per local hour for allowlisted domains, last 24 h. See rule 3 above.
    A locked or inconsistent copy is retried once; then the answer is no readings."""
    _remove_stale_copies(workdir)
    domains = sorted(
        {d.strip().lower().strip(".") for d in allowlist if d.strip().strip(".")},
        key=len,
        reverse=True,
    )
    if path is None or not domains or not Path(path).is_file():
        return []
    window = _Window(now)
    visits: list[tuple[str, float]] = []
    for _attempt in range(2):
        try:
            visits = _read_history_once(Path(path), domains, window, Path(workdir))
            break
        except (OSError, sqlite3.Error, ValueError, OverflowError):
            continue
    counts: Counter[tuple[str, int, str]] = Counter()
    for domain, timestamp in visits:
        if bucket := window.bucket(timestamp):
            counts[(*bucket, domain)] += 1
    return _readings(counts, "visit")


# --- the store -------------------------------------------------------------------------------

_SCHEMA = """
CREATE TABLE IF NOT EXISTS activity (
    day  TEXT    NOT NULL,
    hour INTEGER NOT NULL,
    kind TEXT    NOT NULL,
    key  TEXT    NOT NULL,
    n    INTEGER NOT NULL,
    PRIMARY KEY (day, hour, kind, key)
)
"""


def _storable(reading: Reading) -> bool:
    return (
        reading.kind in KINDS
        and bool(_DAY.fullmatch(reading.day))
        and 0 <= reading.hour <= 23
        and reading.n > 0
        and len(reading.key) <= MAX_KEY_LENGTH
        and not _BAD_KEY.search(reading.key)
    )


class ActivityStore:
    """The counts table. One file, mode 0600 from the moment it exists."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self._conn = connect_private(self.path)
        with self._conn:
            self._conn.execute(_SCHEMA)

    def add_active_minute(self, now: datetime) -> None:
        local = _aware(now)
        with self._conn:
            self._conn.execute(
                "INSERT INTO activity (day, hour, kind, key, n) VALUES (?, ?, 'active_min', '', 1) "
                "ON CONFLICT (day, hour, kind, key) DO UPDATE SET n = n + 1",
                (local.strftime("%Y-%m-%d"), local.hour),
            )

    def replace(self, readings: Sequence[Reading], since: datetime, kinds: Sequence[str]) -> None:
        """Rescan: delete the rows of `kinds` from `since`'s hour on, insert `readings`."""
        kinds = [k for k in kinds if k in KINDS]
        if not kinds:
            return
        first = _aware(since)
        totals: Counter[tuple[str, int, str, str]] = Counter()
        for r in readings:
            if r.kind in kinds and _storable(r):
                totals[(r.day, r.hour, r.kind, r.key)] += r.n
        marks = ", ".join("?" for _ in kinds)
        day = first.strftime("%Y-%m-%d")
        with self._conn:
            self._conn.execute(
                f"DELETE FROM activity WHERE kind IN ({marks}) "
                "AND (day > ? OR (day = ? AND hour >= ?))",
                (*kinds, day, day, first.hour),
            )
            self._conn.executemany(
                "INSERT INTO activity (day, hour, kind, key, n) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT (day, hour, kind, key) DO UPDATE SET n = excluded.n",
                [(*k, n) for k, n in sorted(totals.items())],
            )

    def purge(self, now: datetime, retention_days: int) -> int:
        """Delete rows from days before today minus `retention_days`. Returns how many."""
        cutoff = _aware(now).date() - timedelta(days=max(0, retention_days))
        with self._conn:
            cursor = self._conn.execute("DELETE FROM activity WHERE day < ?", (cutoff.isoformat(),))
        return cursor.rowcount

    def summary(self) -> tuple[int, str | None]:
        """(row count, latest 'YYYY-MM-DD HH' with data or None)."""
        count, latest = self._conn.execute(
            "SELECT COUNT(*), MAX(day || ' ' || printf('%02d', hour)) FROM activity"
        ).fetchone()
        return int(count), latest

    def daily_totals(self, first_day: str, last_day: str) -> list[tuple[str, str, str, int]]:
        """(day, kind, key, total n) for the days first_day..last_day inclusive."""
        return self._conn.execute(
            "SELECT day, kind, key, SUM(n) FROM activity WHERE day >= ? AND day <= ? "
            "GROUP BY day, kind, key ORDER BY day, kind, key",
            (first_day, last_day),
        ).fetchall()

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> ActivityStore:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


# --- the digest ------------------------------------------------------------------------------

_DIGEST_HEADER = (
    "Activity per day (counts only; 'active' = keyboard/mouse input in the last 2 minutes, "
    "not time spent studying)."
)


def _busiest_first(counts: dict[str, int]) -> list[str]:
    return sorted(counts, key=lambda key: (-counts[key], key))


def _day_line(day: str, rows: list[tuple[str, str, int]]) -> str:
    minutes = sum(n for kind, _key, n in rows if kind == "active_min")
    commits = {key: n for kind, key, n in rows if kind == "commit"}
    files = sum(n for kind, _key, n in rows if kind == "files")
    visits = {key: n for kind, key, n in rows if kind == "visit"}
    parts: list[str] = []
    if minutes:
        parts.append(f"active {minutes / 60:.1f} h")
    if commits:
        parts.append(f"commits {sum(commits.values())} ({', '.join(_busiest_first(commits))})")
    if files:
        parts.append(f"files edited {files}")
    parts += [
        f"{domain} {visits[domain]} {'visit' if visits[domain] == 1 else 'visits'}"
        for domain in _busiest_first(visits)
    ]
    try:
        label = datetime.strptime(day, "%Y-%m-%d").strftime("%a %m-%d")
    except ValueError:
        label = day
    return f"{label}: {'; '.join(parts)}"


def digest(store: ActivityStore, now: datetime, days: int = 7) -> str:
    """One plain line per day with data, newest first; "" when the window is empty. This is
    the only text derived from the activity file that may leave the machine."""
    today = _aware(now).date()
    first = today - timedelta(days=max(days, 1) - 1)
    by_day: dict[str, list[tuple[str, str, int]]] = {}
    for day, kind, key, n in store.daily_totals(first.isoformat(), today.isoformat()):
        by_day.setdefault(day, []).append((kind, key, int(n)))
    if not by_day:
        return ""
    lines = [_day_line(day, by_day[day]) for day in sorted(by_day, reverse=True)]
    return "\n".join([_DIGEST_HEADER, *lines])


# --- pause -----------------------------------------------------------------------------------


def pause(path: Path) -> None:
    """Create the flag file. Idempotent; never raises."""
    with contextlib.suppress(OSError):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).touch()


def resume(path: Path) -> None:
    """Remove the flag file. Idempotent; never raises."""
    with contextlib.suppress(OSError):
        Path(path).unlink(missing_ok=True)


def is_paused(path: Path) -> bool:
    """True when the flag file exists. If that cannot be told, assume paused: collecting
    on a doubt is the wrong way round for private data."""
    try:
        return Path(path).exists()
    except OSError:
        return True


# --- one cycle -------------------------------------------------------------------------------


def collect_once(
    store: ActivityStore,
    settings: Settings,
    now: datetime,
    *,
    idle: Callable[[], bool | None] = sample_idle,
    run: Runner = _run,
    history_workdir: Path | None = None,
    scan: bool = True,
) -> str:
    """One cycle of `pli watch`. Returns 'paused', 'ok', 'idle-unavailable' (the idle monitor
    could not be read; everything else still ran) or 'error' (something failed unexpectedly;
    the other steps still ran). Never raises. Old rows are deleted even while paused:
    pausing stops collecting, not the promise to forget."""
    status = "ok"
    try:
        store.purge(now, settings.activity_retention_days)
    except Exception:
        status = "error"
    if is_paused(settings.activity_pause_path):
        return "paused"
    try:
        sampled = idle()
        if sampled:
            store.add_active_minute(now)
        elif sampled is None:
            status = "idle-unavailable"
    except Exception:
        status = "error"
    if scan and not _scan_all(store, settings, now, run, history_workdir):
        status = "error"
    return status


def _scan_all(
    store: ActivityStore,
    settings: Settings,
    now: datetime,
    run: Runner,
    history_workdir: Path | None,
) -> bool:
    """Run the three scans independently. False if any of them failed unexpectedly."""
    roots = settings.activity_root_paths
    history = (
        Path(settings.activity_history_path).expanduser()
        if settings.activity_history_path
        else default_history_path()
    )
    workdir = history_workdir or settings.home
    jobs: list[tuple[str, Callable[[], list[Reading]]]] = [
        ("commit", lambda: scan_git(roots, now, run)),
        ("files", lambda: scan_files(roots, now)),
        ("visit", lambda: scan_history(history, settings.activity_domain_list, now, workdir)),
    ]
    ok = True
    for kind, job in jobs:
        try:
            readings = job()
            if readings:  # an empty scan may be a failure, not a zero: keep what we have
                store.replace(readings, window_start(now), [kind])
        except Exception:
            ok = False
    return ok
