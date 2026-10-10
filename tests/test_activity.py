"""Local activity watching: what is counted, and what is never stored.

`pli watch` records how active the user is, in counts per hour. Rules pinned here:

**Only (day, hour, kind, key, n) is stored, and the key is a repository directory name, an
allowlisted domain or empty.** Never a page title, a full URL, a search term, a file name,
a commit message, a path or a shell command. One test builds a browser history, a git
repository and a source tree full of canary strings, runs every scan into a real database
and then searches the raw bytes of the file for them.

**Only allowlisted domains are stored** (a subdomain counts as its parent); every other
visit in the history is discarded.

**The browser History file is never opened in place.** It is copied into a private (0700)
directory, the copy is opened read-only, only the host of a visit is taken from it, and the
copy is deleted on success, on a corrupt file and when sqlite raises.

**The database file is mode 0600 from creation.** `purge` deletes what is older than the
retention. A rescan is idempotent; `active_min` accumulates.

**Nothing raises into the caller** because of the environment: no gdbus, an unreadable
repository, a locked or corrupt History, a missing folder.

**A pause flag stops collection** within one cycle: nothing is sampled, scanned or stored.

Nothing here touches D-Bus, the real browser or the real home directory: the command runner
is a fake, every database and tree is built in `tmp_path`, and times are fixed in
Asia/Dubai (UTC+4, no daylight saving) so a local day is never the same as a UTC day.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import subprocess
import sys
from collections.abc import Sequence
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import unquote, urlsplit
from zoneinfo import ZoneInfo

import pytest

from pli import activity
from pli.activity import ActivityStore, Reading
from pli.config import Settings

DUBAI = ZoneInfo("Asia/Dubai")
#: Just after local midnight: the window reaches back into yesterday, and (UTC+4) the
#: UTC date of "now" is still the 8th while the local date is the 9th.
NOW = datetime(2026, 10, 9, 1, 30, tzinfo=DUBAI)
GIT = shutil.which("git")


@pytest.fixture(autouse=True)
def _no_real_home(tmp_path, monkeypatch):
    """`~` is an empty folder: nothing here may reach the real browser or the real repos."""
    home = tmp_path / "empty-home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))


def ago(**kwargs: float) -> datetime:
    return NOW - timedelta(**kwargs)


def webkit(when: datetime) -> int:
    return int((when.timestamp() + 11_644_473_600) * 1_000_000)


# --- idle ------------------------------------------------------------------------------------


class FakeGdbus:
    """Answers the two gdbus calls the sampler is allowed to make."""

    def __init__(
        self,
        idle: str = "(uint64 5000,)\n",
        locked: str = "(false,)\n",
        rc: tuple[int, int] = (0, 0),
    ) -> None:
        self.idle, self.locked, self.rc = idle, locked, rc
        self.calls: list[list[str]] = []

    def __call__(self, cmd: list[str], timeout: float = 10.0) -> tuple[int, str]:
        self.calls.append(list(cmd))
        if "org.gnome.Mutter.IdleMonitor.GetIdletime" in cmd:
            return self.rc[0], self.idle
        if "org.gnome.ScreenSaver.GetActive" in cmd:
            return self.rc[1], self.locked
        raise AssertionError(f"unexpected command {cmd}")


def _idle_ms(ms: int) -> str:
    return f"(uint64 {ms},)\n"


def test_input_less_than_two_minutes_ago_is_active():
    assert activity.IDLE_ACTIVE_SECONDS == 120
    assert activity.sample_idle(FakeGdbus(idle=_idle_ms(119_999))) is True


def test_idle_boundary_is_exactly_two_minutes():
    assert activity.sample_idle(FakeGdbus(idle=_idle_ms(120_000))) is False
    assert activity.sample_idle(FakeGdbus(idle=_idle_ms(0))) is True


def test_a_locked_screen_is_never_active():
    assert activity.sample_idle(FakeGdbus(idle=_idle_ms(0), locked="(true,)\n")) is False


def test_the_sampler_asks_gnome_only_for_idle_time_and_lock_state():
    fake = FakeGdbus()
    activity.sample_idle(fake)
    assert fake.calls == [
        [
            "gdbus", "call", "--session", "--dest", "org.gnome.Mutter.IdleMonitor",
            "--object-path", "/org/gnome/Mutter/IdleMonitor/Core",
            "--method", "org.gnome.Mutter.IdleMonitor.GetIdletime",
        ],
        [
            "gdbus", "call", "--session", "--dest", "org.gnome.ScreenSaver",
            "--object-path", "/org/gnome/ScreenSaver",
            "--method", "org.gnome.ScreenSaver.GetActive",
        ],
    ]  # fmt: skip


@pytest.mark.parametrize("rc", [(1, 0), (0, 1), (127, 127)])
def test_a_failing_gdbus_is_unavailable_not_idle(rc):
    assert activity.sample_idle(FakeGdbus(rc=rc)) is None


@pytest.mark.parametrize("garbage", ["", "oops", "(uint64 abc,)", "(int32 5,)", "(uint64 ,)"])
def test_garbled_idle_output_is_unavailable(garbage):
    assert activity.sample_idle(FakeGdbus(idle=garbage)) is None


@pytest.mark.parametrize("garbage", ["", "oops", "(maybe,)", "(1,)"])
def test_garbled_lock_output_is_unavailable(garbage):
    assert activity.sample_idle(FakeGdbus(locked=garbage)) is None


# --- the command runner ----------------------------------------------------------------------


def test_the_real_runner_returns_code_and_output():
    code, out = activity._run([sys.executable, "-c", "print('hello')"])
    assert (code, out.strip()) == (0, "hello")


def test_the_real_runner_never_raises_for_a_missing_program_or_a_timeout():
    assert activity._run(["/nonexistent/definitely-not-a-program"]) == (1, "")
    sleeper = [sys.executable, "-c", "import time; time.sleep(5)"]
    assert activity._run(sleeper, timeout=0.2) == (1, "")


# --- git -------------------------------------------------------------------------------------


def _fake_repo(root: Path, relative: str, *, gitfile: bool = False) -> Path:
    repo = root / relative
    repo.mkdir(parents=True, exist_ok=True)
    if gitfile:
        (repo / ".git").write_text("gitdir: ../elsewhere\n")
    else:
        (repo / ".git").mkdir()
    return repo


class FakeGit:
    """Answers the three git commands the scanner may run, by repository directory name.

    The log answer honours `--author` the way git does (and ignores `--since`, so the
    scanner's own window is what is under test). Any other command, or a log format that
    could carry a message, fails the test.
    """

    def __init__(self, repos: dict[str, dict]) -> None:
        self.repos = repos
        self.calls: list[list[str]] = []

    def __call__(self, cmd: list[str], timeout: float = 10.0) -> tuple[int, str]:
        self.calls.append(list(cmd))
        assert cmd[:2] == ["git", "-C"], cmd
        repo = self.repos[Path(cmd[2]).name]
        rest = cmd[3:]
        if rest[:1] == ["rev-parse"]:
            assert rest == ["rev-parse", "-q", "--verify", "HEAD"]
            return (0, "abc123\n") if repo.get("head", True) else (128, "")
        if rest == ["config", "user.email"]:
            email = repo.get("email", "me@example.com")
            return (0, f"{email}\n") if email else (1, "")
        if rest[:1] == ["log"]:
            assert [a for a in rest if a.startswith("--format")] == ["--format=%ct"]
            assert any(a.startswith("--since=") for a in rest)
            wanted = [a.split("=", 1)[1].strip("<>") for a in rest if a.startswith("--author=")]
            lines = [
                str(int(when.timestamp()) if isinstance(when, datetime) else when)
                for when, author in repo.get("commits", [])
                if not wanted or author in wanted
            ]
            lines += repo.get("noise", [])
            return 0, "".join(f"{line}\n" for line in lines)
        raise AssertionError(f"unexpected git command {cmd}")

    def queried(self) -> set[str]:
        return {Path(c[2]).name for c in self.calls}


def test_commits_are_counted_per_local_hour_per_repository(tmp_path):
    _fake_repo(tmp_path, "alpha")
    _fake_repo(tmp_path, "beta")
    git = FakeGit(
        {
            "alpha": {
                "commits": [
                    (ago(hours=3), "me@example.com"),  # 22:30 on the 8th
                    (ago(hours=3, minutes=-10), "me@example.com"),  # 22:40
                    (ago(minutes=45), "me@example.com"),  # 00:45 on the 9th
                ]
            },
            "beta": {"commits": [(ago(hours=2), "me@example.com")]},  # 23:30 on the 8th
        }
    )
    assert activity.scan_git([tmp_path], NOW, git) == [
        Reading("2026-10-08", 22, "commit", "alpha", 2),
        Reading("2026-10-08", 23, "commit", "beta", 1),
        Reading("2026-10-09", 0, "commit", "alpha", 1),
    ]


def test_only_the_repositorys_own_author_is_counted(tmp_path):
    _fake_repo(tmp_path, "alpha")
    git = FakeGit(
        {
            "alpha": {
                "email": "me@example.com",
                "commits": [
                    (ago(hours=3), "me@example.com"),
                    (ago(hours=3), "someone.else@example.com"),
                ],
            }
        }
    )
    assert activity.scan_git([tmp_path], NOW, git) == [
        Reading("2026-10-08", 22, "commit", "alpha", 1)
    ]
    log = next(c for c in git.calls if "log" in c)
    assert "--author=<me@example.com>" in log


def test_a_repository_with_no_commits_is_skipped_not_an_error(tmp_path):
    _fake_repo(tmp_path, "empty")
    git = FakeGit({"empty": {"head": False, "commits": [(ago(hours=1), "me@example.com")]}})
    assert activity.scan_git([tmp_path], NOW, git) == []
    assert not any("log" in c for c in git.calls)


def test_a_repository_with_no_author_email_is_skipped(tmp_path):
    _fake_repo(tmp_path, "anon")
    git = FakeGit({"anon": {"email": "", "commits": [(ago(hours=1), "x@example.com")]}})
    assert activity.scan_git([tmp_path], NOW, git) == []


def test_commits_outside_the_window_and_garbage_lines_are_ignored(tmp_path):
    _fake_repo(tmp_path, "alpha")
    git = FakeGit(
        {
            "alpha": {
                "commits": [
                    (ago(hours=30), "me@example.com"),  # git's --since is not trusted blindly
                    (ago(hours=-2), "me@example.com"),  # in the future
                    (ago(hours=1), "me@example.com"),
                ],
                "noise": ["", "not-a-number", "12x", "-5"],
            }
        }
    )
    assert activity.scan_git([tmp_path], NOW, git) == [
        Reading("2026-10-09", 0, "commit", "alpha", 1)
    ]


def test_the_window_starts_at_the_top_of_the_hour_24_hours_ago():
    assert activity.window_start(NOW) == datetime(2026, 10, 8, 1, 0, tzinfo=DUBAI)
    assert activity.window_start(datetime(2026, 10, 9, 1, 0, 0, tzinfo=DUBAI)) == datetime(
        2026, 10, 8, 1, 0, tzinfo=DUBAI
    )


def test_the_first_hour_of_the_window_is_complete_not_cut_at_the_minute(tmp_path):
    _fake_repo(tmp_path, "alpha")
    git = FakeGit(
        {
            "alpha": {
                "commits": [
                    (datetime(2026, 10, 8, 0, 59, tzinfo=DUBAI), "me@example.com"),  # before
                    (datetime(2026, 10, 8, 1, 5, tzinfo=DUBAI), "me@example.com"),  # before :30
                ]
            }
        }
    )
    assert activity.scan_git([tmp_path], NOW, git) == [
        Reading("2026-10-08", 1, "commit", "alpha", 1)
    ]


def test_a_git_failure_yields_nothing_and_never_raises(tmp_path):
    _fake_repo(tmp_path, "alpha")
    assert activity.scan_git([tmp_path], NOW, lambda cmd, timeout=10.0: (1, "")) == []


def test_the_key_is_the_directory_name_never_a_path(tmp_path):
    _fake_repo(tmp_path, "deep/er/project")
    git = FakeGit({"project": {"commits": [(ago(hours=1), "me@example.com")]}})
    (reading,) = activity.scan_git([tmp_path], NOW, git)
    assert reading.key == "project"
    assert "/" not in reading.key


def test_a_missing_root_is_nothing_not_an_error(tmp_path):
    assert activity.scan_git([tmp_path / "nope"], NOW, FakeGit({})) == []


def test_repository_discovery_stops_at_depth_five(tmp_path):
    _fake_repo(tmp_path, "a/b/c/d/five")  # five levels below the root: found
    _fake_repo(tmp_path, "a/b/c/d/e/six")  # six: not
    git = FakeGit({"five": {}, "six": {}})
    activity.scan_git([tmp_path], NOW, git)
    assert git.queried() == {"five"}


def test_the_root_itself_may_be_a_repository_and_a_gitfile_counts(tmp_path):
    _fake_repo(tmp_path, ".")
    _fake_repo(tmp_path.parent / (tmp_path.name + "-wt"), ".", gitfile=True)
    git = FakeGit({tmp_path.name: {}, tmp_path.name + "-wt": {}})
    activity.scan_git([tmp_path, tmp_path.parent / (tmp_path.name + "-wt")], NOW, git)
    assert git.queried() == {tmp_path.name, tmp_path.name + "-wt"}
    shutil.rmtree(tmp_path.parent / (tmp_path.name + "-wt"))


@pytest.mark.parametrize(
    "pruned", [".venv", "node_modules", ".cache", ".local", ".cargo", "snap", ".npm", "__pycache__"]
)
def test_repositories_inside_pruned_folders_are_never_visited(tmp_path, pruned):
    _fake_repo(tmp_path, f"{pruned}/hidden")
    _fake_repo(tmp_path, "proj/" + pruned + "/inner")
    _fake_repo(tmp_path, "real")
    git = FakeGit({"hidden": {}, "inner": {}, "real": {}})
    activity.scan_git([tmp_path], NOW, git)
    assert git.queried() == {"real"}


def test_at_most_twenty_repositories_are_scanned(tmp_path):
    for i in range(25):
        _fake_repo(tmp_path, f"repo{i:02d}")
    git = FakeGit({f"repo{i:02d}": {} for i in range(25)})
    activity.scan_git([tmp_path], NOW, git)
    assert len(git.queried()) == 20


@pytest.mark.skipif(os.geteuid() == 0, reason="root ignores directory permissions")
def test_an_unreadable_folder_is_skipped(tmp_path):
    _fake_repo(tmp_path, "readable")
    locked = tmp_path / "locked"
    locked.mkdir()
    _fake_repo(locked, "inside")
    locked.chmod(0)
    try:
        git = FakeGit({"readable": {}, "inside": {}})
        activity.scan_git([tmp_path], NOW, git)
        assert git.queried() == {"readable"}
    finally:
        locked.chmod(0o700)


def _git_env(**extra: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull, **extra)
    return env


def _real_repo(root: Path, name: str, email: str) -> Path:
    repo = root / name
    repo.mkdir(parents=True)
    for args in (["init", "-q"], ["config", "user.email", email]):
        subprocess.run(
            ["git", "-C", str(repo), *args], check=True, env=_git_env(), capture_output=True
        )
    return repo


def _commit(repo: Path, when: datetime, email: str, message: str = "work") -> None:
    iso = when.isoformat()
    env = _git_env(
        GIT_AUTHOR_NAME="T", GIT_AUTHOR_EMAIL=email, GIT_AUTHOR_DATE=iso,
        GIT_COMMITTER_NAME="T", GIT_COMMITTER_EMAIL=email, GIT_COMMITTER_DATE=iso,
    )  # fmt: skip
    cmd = ["git", "-C", str(repo), "commit", "--allow-empty", "-q", "-m", message]
    subprocess.run(cmd, check=True, env=env, capture_output=True)


@pytest.mark.skipif(GIT is None, reason="git is not installed")
def test_real_git_counts_the_configured_author_only_inside_the_window(tmp_path, monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    me = "me.dev+pli@example.com"  # '.' and '+' would be wildcards in a regex match
    lookalike = "meXdevvpli@example.com"  # matches that regex; must not be counted
    repo = _real_repo(tmp_path, "proj", me)
    # Oldest first, as a real history is: git stops walking at the first commit older than
    # --since, so a history whose dates run backwards would hide commits.
    _commit(repo, ago(hours=30), me)  # outside the window
    _commit(repo, ago(hours=3), me)  # 22:30 on the 8th
    _commit(repo, ago(hours=3, minutes=-15), me)  # 22:45
    _commit(repo, ago(hours=2), lookalike)
    _commit(repo, ago(minutes=45), me)  # 00:45 on the 9th
    _real_repo(tmp_path, "empty", me)  # no commits: skipped without an error
    assert activity.scan_git([tmp_path], NOW) == [
        Reading("2026-10-08", 22, "commit", "proj", 2),
        Reading("2026-10-09", 0, "commit", "proj", 1),
    ]


@pytest.mark.skipif(GIT is None, reason="git is not installed")
def test_a_repository_cannot_make_the_scan_run_its_own_program(tmp_path, monkeypatch):
    """A downloaded project's own `.git/config` may name a `gpg.program`; `git log` would run
    it to check a signed commit's signature. The scan only needs timestamps, so it must not."""
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    me = "me@example.com"
    repo = _real_repo(tmp_path, "starter", me)
    marker = tmp_path / "ran"
    program = tmp_path / "gpg-spy"
    program.write_text(f"#!/bin/sh\ntouch {marker}\nexit 1\n")
    program.chmod(0o700)
    for key, value in (("log.showSignature", "true"), ("gpg.program", str(program))):
        subprocess.run(
            ["git", "-C", str(repo), "config", key, value],
            check=True, env=_git_env(), capture_output=True,
        )  # fmt: skip
    stamp = int(ago(hours=1).timestamp())
    commit = (
        f"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
        f"author T <{me}> {stamp} +0000\ncommitter T <{me}> {stamp} +0000\n"
        "gpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n\nwork\n"
    )
    git = ["git", "-C", str(repo)]
    made = subprocess.run(
        [*git, "hash-object", "-t", "commit", "-w", "--literally", "--stdin"],
        input=commit, text=True, check=True, env=_git_env(), capture_output=True,
    )  # fmt: skip
    subprocess.run(
        [*git, "update-ref", "HEAD", made.stdout.strip()],
        check=True, env=_git_env(), capture_output=True,
    )  # fmt: skip

    counted = activity.scan_git([tmp_path], NOW)

    assert counted == [Reading("2026-10-09", 0, "commit", "starter", 1)]  # the scan still works
    assert not marker.exists(), "git ran the repository's own gpg program"


# --- files -----------------------------------------------------------------------------------


def _touch(path: Path, when: datetime) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("x")
    os.utime(path, (when.timestamp(), when.timestamp()))
    return path


def test_modified_files_are_counted_per_local_hour_with_an_empty_key(tmp_path):
    _touch(tmp_path / "a.py", datetime(2026, 10, 8, 23, 10, tzinfo=DUBAI))
    _touch(tmp_path / "sub" / "b.md", datetime(2026, 10, 8, 23, 50, tzinfo=DUBAI))
    _touch(tmp_path / "sub" / "deeper" / "c.txt", datetime(2026, 10, 9, 0, 5, tzinfo=DUBAI))
    assert activity.scan_files([tmp_path], NOW) == [
        Reading("2026-10-08", 23, "files", "", 2),
        Reading("2026-10-09", 0, "files", "", 1),
    ]


def test_noise_is_excluded_from_the_file_count(tmp_path):
    when = ago(hours=1)
    _touch(tmp_path / "keep.py", when)
    for noise in (
        ".venv/lib/x.py", "node_modules/p/index.js", "pkg/__pycache__/m.py",
        ".ruff_cache/0/x", ".pytest_cache/v/x", ".git/objects/ab", ".git/index",
        "data/state.csv", "app/data/y.csv", "mod/m.cpython-314.pyc", "uv.lock", "a/run.log",
    ):  # fmt: skip
        _touch(tmp_path / noise, when)
    assert activity.scan_files([tmp_path], NOW) == [Reading("2026-10-09", 0, "files", "", 1)]


def test_a_file_called_data_is_not_a_data_directory(tmp_path):
    _touch(tmp_path / "data.py", ago(hours=1))
    _touch(tmp_path / "database", ago(hours=1))
    assert sum(r.n for r in activity.scan_files([tmp_path], NOW)) == 2


def test_files_older_than_the_window_or_in_the_future_are_ignored(tmp_path):
    _touch(tmp_path / "old.py", ago(hours=30))
    _touch(tmp_path / "future.py", ago(hours=-3))
    _touch(tmp_path / "recent.py", ago(hours=23))
    assert [r.n for r in activity.scan_files([tmp_path], NOW)] == [1]


def test_file_names_never_appear_in_the_readings(tmp_path):
    _touch(tmp_path / "CANARY-FILE-XYZ.py", ago(hours=1))
    readings = activity.scan_files([tmp_path], NOW)
    assert "CANARY" not in repr(readings)
    assert {r.key for r in readings} == {""}


class StepClock:
    """A clock that advances one second every time it is read."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        self.now += 1.0
        return self.now


def test_a_scan_that_runs_out_of_time_reports_nothing_never_a_partial_count(tmp_path):
    """The collector replaces a whole 24 h window with what a scan returns, so a half-finished
    count (150 files seen as 9) would erase a good one. Nothing means "keep what we have"."""
    for i in range(40):
        _touch(tmp_path / f"f{i}.py", ago(hours=1))
    assert sum(r.n for r in activity.scan_files([tmp_path], NOW)) == 40
    assert activity.scan_files([tmp_path], NOW, budget_s=10, clock=StepClock()) == []


def test_a_budget_of_zero_counts_nothing(tmp_path):
    _touch(tmp_path / "a.py", ago(hours=1))
    assert activity.scan_files([tmp_path], NOW, budget_s=0, clock=StepClock()) == []


def test_a_missing_files_root_is_nothing_not_an_error(tmp_path):
    assert activity.scan_files([tmp_path / "nope"], NOW) == []


def test_symlinked_folders_are_not_followed(tmp_path):
    outside = tmp_path / "outside"
    _touch(outside / "x.py", ago(hours=1))
    root = tmp_path / "root"
    root.mkdir()
    (root / "link").symlink_to(outside, target_is_directory=True)
    assert activity.scan_files([root], NOW) == []


# --- browser history -------------------------------------------------------------------------

_CHROMIUM_SCHEMA = """
CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR,
    visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
    last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL,
    visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL,
    segment_id INTEGER, visit_duration INTEGER DEFAULT 0 NOT NULL);
CREATE TABLE keyword_search_terms(keyword_id INTEGER NOT NULL, url_id INTEGER NOT NULL,
    term LONGVARCHAR NOT NULL, normalized_term LONGVARCHAR NOT NULL);
CREATE TABLE downloads(id INTEGER PRIMARY KEY, target_path LONGVARCHAR NOT NULL,
    tab_url LONGVARCHAR);
"""


def make_history(
    path: Path,
    visits: Sequence[tuple[str, str, datetime]],
    *,
    searches: Sequence[str] = (),
    downloads: Sequence[str] = (),
) -> Path:
    con = sqlite3.connect(path)
    con.executescript(_CHROMIUM_SCHEMA)
    ids: dict[str, int] = {}
    for url, title, when in visits:
        if url not in ids:
            cur = con.execute(
                "INSERT INTO urls(url, title, last_visit_time) VALUES (?,?,?)",
                (url, title, webkit(when)),
            )
            ids[url] = int(cur.lastrowid or 0)
        con.execute("INSERT INTO visits(url, visit_time) VALUES (?,?)", (ids[url], webkit(when)))
    for term in searches:
        con.execute("INSERT INTO keyword_search_terms VALUES (1, 1, ?, ?)", (term, term.lower()))
    for target in downloads:
        con.execute("INSERT INTO downloads(target_path, tab_url) VALUES (?,?)", (target, target))
    con.commit()
    con.close()
    return path


def scan(history: Path | None, tmp_path: Path, domains=("github.com",), now=NOW):
    return activity.scan_history(history, list(domains), now, tmp_path / "work")


def test_only_allowlisted_domains_are_counted_per_local_hour(tmp_path):
    history = make_history(
        tmp_path / "History",
        [
            ("https://github.com/a/b", "t", datetime(2026, 10, 8, 23, 10, tzinfo=DUBAI)),
            ("https://github.com/c/d", "t", datetime(2026, 10, 8, 23, 40, tzinfo=DUBAI)),
            ("https://docs.python.org/3/", "t", datetime(2026, 10, 9, 0, 5, tzinfo=DUBAI)),
            ("https://bank.example/account", "t", datetime(2026, 10, 9, 0, 6, tzinfo=DUBAI)),
        ],
    )
    assert scan(history, tmp_path, ["github.com", "docs.python.org"]) == [
        Reading("2026-10-08", 23, "visit", "github.com", 2),
        Reading("2026-10-09", 0, "visit", "docs.python.org", 1),
    ]


def test_a_domain_not_on_the_allowlist_is_discarded(tmp_path):
    history = make_history(tmp_path / "History", [("https://bank.example/x", "t", ago(hours=1))])
    assert scan(history, tmp_path) == []


def test_with_an_empty_allowlist_the_history_is_not_even_opened(tmp_path, monkeypatch):
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    spy = _spy(monkeypatch)
    assert scan(history, tmp_path, domains=[]) == []
    assert scan(history, tmp_path, domains=["", " ", "."]) == []
    assert spy.opened == []
    assert not (tmp_path / "work").exists()


def test_a_subdomain_counts_as_its_parent_domain(tmp_path):
    history = make_history(
        tmp_path / "History",
        [
            ("https://docs.github.com/en", "t", ago(hours=1)),
            ("https://gist.github.com/x", "t", ago(hours=1)),
            ("https://GitHub.com:443/y", "t", ago(hours=1)),
            ("https://a.b.github.com/z", "t", ago(hours=1)),
        ],
    )
    assert scan(history, tmp_path) == [Reading("2026-10-09", 0, "visit", "github.com", 4)]


@pytest.mark.parametrize(
    "url",
    [
        "https://github.com.evil.example/login",
        "https://notgithub.com/",
        "https://evilgithub.com/",
        "https://evil.example/github.com",
        "https://evil.example/?next=https://github.com/",
        "https://github.com@evil.example/",
        "https://user:pw@evil.example/@github.com",
        "file:///home/me/github.com/index.html",
        "chrome://history/",
        "not a url",
        "",
    ],
)
def test_lookalike_hosts_do_not_match_the_allowlist(tmp_path, url):
    history = make_history(tmp_path / "History", [(url, "t", ago(hours=1))])
    assert scan(history, tmp_path) == []


def test_the_more_specific_allowlist_entry_wins(tmp_path):
    history = make_history(tmp_path / "History", [("https://docs.github.com/", "t", ago(hours=1))])
    assert scan(history, tmp_path, ["github.com", "docs.github.com"]) == [
        Reading("2026-10-09", 0, "visit", "docs.github.com", 1)
    ]


def test_webkit_microseconds_since_1601_are_converted_to_local_time(tmp_path):
    # 13_344_473_600_000_000 us since 1601 is unix 1_700_000_000 = 2023-11-14 22:13:20 UTC
    # = 02:13:20 on the 15th in Dubai. Written out by hand, not by the helper under test.
    history = tmp_path / "History"
    con = sqlite3.connect(history)
    con.executescript(_CHROMIUM_SCHEMA)
    con.execute("INSERT INTO urls(id, url, title, last_visit_time) VALUES (1,'https://github.com/',"
                "'t', 13344473600000000)")  # fmt: skip
    con.execute("INSERT INTO visits(url, visit_time) VALUES (1, 13344473600000000)")
    con.commit()
    con.close()
    now = datetime(2023, 11, 15, 3, 0, tzinfo=DUBAI)
    assert scan(history, tmp_path, now=now) == [Reading("2023-11-15", 2, "visit", "github.com", 1)]


def test_visits_are_bucketed_by_the_local_day_not_the_utc_day(tmp_path):
    just_before = datetime(2026, 10, 8, 23, 59, tzinfo=DUBAI)  # 19:59 UTC on the 8th
    just_after = datetime(2026, 10, 9, 0, 1, tzinfo=DUBAI)  # 20:01 UTC on the 8th
    history = make_history(
        tmp_path / "History",
        [("https://github.com/", "t", just_before), ("https://github.com/", "t", just_after)],
    )
    assert scan(history, tmp_path) == [
        Reading("2026-10-08", 23, "visit", "github.com", 1),
        Reading("2026-10-09", 0, "visit", "github.com", 1),
    ]


def test_visits_outside_the_window_are_ignored(tmp_path):
    history = make_history(
        tmp_path / "History",
        [
            ("https://github.com/", "t", ago(hours=30)),
            ("https://github.com/", "t", ago(hours=-2)),
            ("https://github.com/", "t", ago(hours=1)),
        ],
    )
    assert scan(history, tmp_path) == [Reading("2026-10-09", 0, "visit", "github.com", 1)]


def test_no_history_means_no_readings(tmp_path):
    assert scan(None, tmp_path) == []
    assert scan(tmp_path / "missing", tmp_path) == []
    assert scan(tmp_path, tmp_path) == []  # a directory


def test_default_history_path_is_the_brave_default_profile_when_it_exists(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert activity.default_history_path() is None
    profile = tmp_path / ".config/BraveSoftware/Brave-Browser/Default"
    profile.mkdir(parents=True)
    assert activity.default_history_path() is None  # a profile without a History file
    (profile / "History").write_bytes(b"")
    assert activity.default_history_path() == profile / "History"


def test_a_history_without_the_chromium_tables_is_nothing_not_an_error(tmp_path):
    other = tmp_path / "History"
    con = sqlite3.connect(other)
    con.execute("CREATE TABLE unrelated(a)")
    con.commit()
    con.close()
    assert scan(other, tmp_path) == []
    assert list((tmp_path / "work").iterdir()) == []


class ConnectSpy:
    """Wraps `sqlite3.connect` to see where a database is opened, and when to fail."""

    def __init__(self, real, fail_first: int = 0, fail_all: bool = False) -> None:
        self.real, self.fail_first, self.fail_all = real, fail_first, fail_all
        self.opened: list[str] = []
        self.seen: list[tuple[int, int]] = []  # (dir mode, file mode) at open time

    def __call__(self, database, *args, **kwargs):
        self.opened.append(str(database))
        if str(database).startswith("file:"):
            path = Path(unquote(urlsplit(str(database)).path))
            if path.exists():
                self.seen.append((path.parent.stat().st_mode & 0o777, path.stat().st_mode & 0o777))
        if self.fail_all or len(self.opened) <= self.fail_first:
            raise sqlite3.OperationalError("database is locked")
        return self.real(database, *args, **kwargs)


def _spy(monkeypatch, **kwargs) -> ConnectSpy:
    spy = ConnectSpy(sqlite3.connect, **kwargs)
    monkeypatch.setattr(activity.sqlite3, "connect", spy)
    return spy


def test_the_history_file_is_copied_never_opened_in_place_and_not_modified(tmp_path, monkeypatch):
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    before = (history.read_bytes(), history.stat().st_mtime_ns)
    spy = _spy(monkeypatch)
    assert len(scan(history, tmp_path)) == 1
    assert spy.opened and all(str(history) not in o for o in spy.opened)
    assert all(str(tmp_path / "work") in o for o in spy.opened)
    assert all("mode=ro" in o for o in spy.opened)
    assert (history.read_bytes(), history.stat().st_mtime_ns) == before


def test_the_copy_lives_in_a_private_directory(tmp_path, monkeypatch):
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    spy = _spy(monkeypatch)
    scan(history, tmp_path)
    assert spy.seen == [(0o700, 0o600)]


def test_the_copy_is_deleted_after_a_successful_scan(tmp_path):
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    assert scan(history, tmp_path)
    assert list((tmp_path / "work").iterdir()) == []


def test_the_copy_is_deleted_after_a_corrupt_history(tmp_path):
    history = tmp_path / "History"
    history.write_bytes(b"this is not a sqlite database" * 100)
    assert scan(history, tmp_path) == []
    assert list((tmp_path / "work").iterdir()) == []


def test_the_copy_is_deleted_when_sqlite_raises(tmp_path, monkeypatch):
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    spy = _spy(monkeypatch, fail_all=True)
    assert scan(history, tmp_path) == []
    assert len(spy.opened) == 2  # one retry, then give up
    assert list((tmp_path / "work").iterdir()) == []


def test_a_locked_or_inconsistent_copy_is_retried_once(tmp_path, monkeypatch):
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    spy = _spy(monkeypatch, fail_first=1)
    assert scan(history, tmp_path) == [Reading("2026-10-09", 0, "visit", "github.com", 1)]
    assert len(spy.opened) == 2
    assert list((tmp_path / "work").iterdir()) == []


def test_a_copy_left_behind_by_a_killed_scan_is_removed_by_the_next_one(tmp_path):
    """A scan stopped by SIGKILL or a power cut cannot clean up after itself."""
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    stale = tmp_path / "work" / ".history-dead1234"
    stale.mkdir(parents=True)
    (stale / "History").write_bytes(b"a whole copy of the browser history")
    (tmp_path / "work" / "keep.txt").write_text("not ours to delete")

    assert scan(history, tmp_path)

    assert [p.name for p in (tmp_path / "work").iterdir()] == ["keep.txt"]


def test_a_stale_copy_is_removed_even_when_there_is_nothing_to_scan_now(tmp_path):
    stale = tmp_path / "work" / ".history-dead1234"
    stale.mkdir(parents=True)
    (stale / "History").write_bytes(b"a whole copy of the browser history")

    assert scan(None, tmp_path) == []

    assert not stale.exists()


def test_the_copy_is_deleted_when_copying_itself_fails(tmp_path, monkeypatch):
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])

    def broken(src, dst, *args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(activity.shutil, "copyfileobj", broken)
    assert scan(history, tmp_path) == []
    assert list((tmp_path / "work").iterdir()) == []


def test_only_the_urls_and_visits_tables_and_only_three_columns_may_be_read():
    allow = activity._history_authorizer
    ok, deny = sqlite3.SQLITE_OK, sqlite3.SQLITE_DENY
    read = sqlite3.SQLITE_READ
    assert allow(read, "urls", "url", "main", None) == ok
    assert allow(read, "urls", "id", "main", None) == ok
    assert allow(read, "visits", "url", "main", None) == ok
    assert allow(read, "visits", "visit_time", "main", None) == ok
    assert allow(sqlite3.SQLITE_SELECT, None, None, None, None) == ok
    for table, column in (
        ("urls", "title"),
        ("visits", "visit_duration"),
        ("keyword_search_terms", "term"),
        ("downloads", "target_path"),
        ("sqlite_master", "sql"),
    ):
        assert allow(read, table, column, "main", None) == deny, (table, column)
    for action in (
        sqlite3.SQLITE_INSERT, sqlite3.SQLITE_UPDATE, sqlite3.SQLITE_DELETE,
        sqlite3.SQLITE_DROP_TABLE, sqlite3.SQLITE_ATTACH, sqlite3.SQLITE_PRAGMA,
    ):  # fmt: skip
        assert allow(action, "urls", "url", "main", None) == deny


def test_a_query_that_reaches_for_a_title_is_refused_by_the_database(tmp_path, monkeypatch):
    history = make_history(
        tmp_path / "History", [("https://github.com/", "CANARY-TITLE-XYZ", ago(hours=1))]
    )
    monkeypatch.setattr(
        activity,
        "_HISTORY_SQL",
        "SELECT u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url "
        "WHERE v.visit_time >= ? AND v.visit_time <= ?",
    )
    assert scan(history, tmp_path) == []


def test_titles_urls_searches_and_downloads_never_leave_the_history(tmp_path):
    history = make_history(
        tmp_path / "History",
        [
            (
                "https://github.com/CANARY-PATH-XYZ?q=CANARY-QUERY-XYZ",
                "CANARY-TITLE-XYZ",
                ago(hours=1),
            ),
            ("https://bank.example/CANARY-BANK-XYZ", "CANARY-BANK-TITLE-XYZ", ago(hours=1)),
        ],
        searches=["CANARY-SEARCH-XYZ"],
        downloads=["/home/me/CANARY-DOWNLOAD-XYZ.pdf"],
    )
    readings = scan(history, tmp_path)
    assert readings == [Reading("2026-10-09", 0, "visit", "github.com", 1)]
    assert "CANARY" not in repr(readings)


# --- the store -------------------------------------------------------------------------------


def rows(path: Path) -> list[tuple]:
    con = sqlite3.connect(path)
    try:
        return con.execute(
            "SELECT day, hour, kind, key, n FROM activity ORDER BY 1,2,3,4"
        ).fetchall()
    finally:
        con.close()


def test_the_database_is_mode_0600_from_creation_whatever_the_umask(tmp_path):
    old = os.umask(0)
    try:
        store = ActivityStore(tmp_path / "data" / "activity.db")
        store.add_active_minute(NOW)
        store.close()
    finally:
        os.umask(old)
    assert (tmp_path / "data" / "activity.db").stat().st_mode & 0o777 == 0o600
    assert [p.name for p in (tmp_path / "data").iterdir()] == ["activity.db"]


def test_the_database_file_is_created_with_mode_0600_not_chmodded_afterwards(tmp_path, monkeypatch):
    created: list[tuple[str, int]] = []
    real_open = os.open

    def spy(path, flags, mode=0o777, *args, **kwargs):
        if str(path).endswith("activity.db"):
            created.append((str(path), mode))
        return real_open(path, flags, mode, *args, **kwargs)

    monkeypatch.setattr(activity.os, "open", spy)
    ActivityStore(tmp_path / "activity.db").close()
    assert created and all(mode == 0o600 for _path, mode in created)


def test_an_existing_looser_database_is_tightened(tmp_path):
    path = tmp_path / "activity.db"
    path.write_bytes(b"")
    path.chmod(0o644)
    ActivityStore(path).close()
    assert path.stat().st_mode & 0o777 == 0o600


def test_the_table_has_exactly_the_five_columns(tmp_path):
    ActivityStore(tmp_path / "a.db").close()
    con = sqlite3.connect(tmp_path / "a.db")
    info = con.execute("PRAGMA table_info(activity)").fetchall()
    con.close()
    assert [(c[1], c[2]) for c in info] == [
        ("day", "TEXT"), ("hour", "INTEGER"), ("kind", "TEXT"), ("key", "TEXT"), ("n", "INTEGER"),
    ]  # fmt: skip
    assert sorted(c[1] for c in info if c[5]) == ["day", "hour", "key", "kind"]  # the primary key


def test_active_minutes_accumulate_per_local_hour(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        for _ in range(3):
            store.add_active_minute(NOW)
        store.add_active_minute(ago(hours=1))
    assert rows(tmp_path / "a.db") == [
        ("2026-10-09", 0, "active_min", "", 1),
        ("2026-10-09", 1, "active_min", "", 3),
    ]


def test_the_store_survives_reopening(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        store.add_active_minute(NOW)
    with ActivityStore(tmp_path / "a.db") as store:
        store.add_active_minute(NOW)
    assert rows(tmp_path / "a.db") == [("2026-10-09", 1, "active_min", "", 2)]


FILES_8 = Reading("2026-10-08", 23, "files", "", 5)
FILES_9 = Reading("2026-10-09", 0, "files", "", 7)
COMMIT = Reading("2026-10-09", 0, "commit", "proj", 2)


def test_replacing_twice_gives_the_same_rows(tmp_path):
    since = activity.window_start(NOW)
    with ActivityStore(tmp_path / "a.db") as store:
        store.replace([FILES_8, FILES_9, COMMIT], since, ["files", "commit"])
        first = rows(tmp_path / "a.db")
        store.replace([FILES_8, FILES_9, COMMIT], since, ["files", "commit"])
    assert rows(tmp_path / "a.db") == first
    assert len(first) == 3


def test_a_rescan_replaces_the_old_numbers_and_drops_vanished_rows(tmp_path):
    since = activity.window_start(NOW)
    with ActivityStore(tmp_path / "a.db") as store:
        store.replace([FILES_8, FILES_9], since, ["files"])
        store.replace([Reading("2026-10-09", 0, "files", "", 3)], since, ["files"])
    assert rows(tmp_path / "a.db") == [("2026-10-09", 0, "files", "", 3)]


def test_replace_touches_only_the_named_kinds_and_only_the_window(tmp_path):
    older = Reading("2026-10-07", 12, "files", "", 9)  # before the window: history, kept
    minutes = Reading("2026-10-09", 0, "active_min", "", 4)
    with ActivityStore(tmp_path / "a.db") as store:
        store.replace([older, minutes, COMMIT], datetime(2026, 10, 1, tzinfo=DUBAI), ["files"])
        store.replace([FILES_9], activity.window_start(NOW), ["files"])
    kept = rows(tmp_path / "a.db")
    assert ("2026-10-07", 12, "files", "", 9) in kept  # an older day is never rewritten
    assert ("2026-10-09", 0, "files", "", 7) in kept
    assert all(r[2] != "commit" for r in kept)  # never offered under the "files" kind


def test_a_reading_from_before_the_window_is_set_not_added_on_a_repeat(tmp_path):
    older = Reading("2026-10-07", 12, "files", "", 9)
    with ActivityStore(tmp_path / "a.db") as store:
        for _ in range(2):
            store.replace([older], activity.window_start(NOW), ["files"])
    assert rows(tmp_path / "a.db") == [("2026-10-07", 12, "files", "", 9)]


def test_replace_ignores_readings_of_a_kind_it_was_not_given(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        store.replace([FILES_9, COMMIT], activity.window_start(NOW), ["files"])
        store.replace([FILES_9], activity.window_start(NOW), ["no-such-kind"])
    assert rows(tmp_path / "a.db") == [("2026-10-09", 0, "files", "", 7)]


@pytest.mark.parametrize(
    "key",
    ["/home/me/secret", "a/b", "C:\\Users\\me", "line\nbreak", "tab\tbed", "x" * 101, "\x00nul"],
)
def test_a_path_or_unprintable_or_overlong_key_is_never_stored(tmp_path, key):
    bad = Reading("2026-10-09", 0, "commit", key, 1)
    good = Reading("2026-10-09", 0, "commit", "proj", 1)
    with ActivityStore(tmp_path / "a.db") as store:
        store.replace([bad, good], activity.window_start(NOW), ["commit"])
    assert rows(tmp_path / "a.db") == [("2026-10-09", 0, "commit", "proj", 1)]


def test_malformed_readings_are_not_stored(tmp_path):
    bad = [
        Reading("yesterday", 0, "files", "", 1),
        Reading("2026-10-09", 24, "files", "", 1),
        Reading("2026-10-09", -1, "files", "", 1),
        Reading("2026-10-09", 3, "files", "", 0),
        Reading("2026-10-09", 3, "files", "", -4),
    ]
    with ActivityStore(tmp_path / "a.db") as store:
        store.replace(bad, activity.window_start(NOW), ["files"])
    assert rows(tmp_path / "a.db") == []


def test_purge_deletes_exactly_the_days_older_than_the_retention(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        store.replace(
            [
                Reading("2026-09-08", 10, "files", "", 1),  # 31 days ago: gone
                Reading("2026-09-09", 10, "files", "", 2),  # 30 days ago: kept
                Reading("2026-10-09", 0, "files", "", 3),
            ],
            datetime(2026, 9, 1, tzinfo=DUBAI),
            ["files"],
        )
        assert store.purge(NOW, 30) == 1
        assert store.purge(NOW, 30) == 0
    assert [r[0] for r in rows(tmp_path / "a.db")] == ["2026-09-09", "2026-10-09"]


def test_a_nonsense_retention_never_deletes_today(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        store.add_active_minute(NOW)
        store.purge(NOW, -5)
    assert len(rows(tmp_path / "a.db")) == 1


def test_summary_reports_the_row_count_and_the_latest_hour(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        assert store.summary() == (0, None)
        store.replace([FILES_8, FILES_9, COMMIT], activity.window_start(NOW), ["files", "commit"])
        assert store.summary() == (3, "2026-10-09 00")


def test_close_releases_the_database(tmp_path):
    store = ActivityStore(tmp_path / "a.db")
    store.close()
    with pytest.raises(sqlite3.ProgrammingError):
        store.add_active_minute(NOW)


# --- the digest ------------------------------------------------------------------------------

HEADER = (
    "Activity per day (counts only; 'active' = keyboard/mouse input in the last 2 minutes, "
    "not time spent studying)."
)


def _fill(store: ActivityStore, readings: list[Reading]) -> None:
    kinds = sorted({r.kind for r in readings})
    store.replace(readings, datetime(2026, 1, 1, tzinfo=DUBAI), kinds)


def _minutes(store: ActivityStore, when: datetime, count: int) -> None:
    for _ in range(count):
        store.add_active_minute(when)


def test_the_digest_line_format(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        _minutes(store, datetime(2026, 10, 8, 9, 0, tzinfo=DUBAI), 312)  # 5.2 h
        _fill(
            store,
            [
                Reading("2026-10-08", 10, "commit", "personal-website", 3),
                Reading("2026-10-08", 10, "files", "", 30),
                Reading("2026-10-08", 11, "files", "", 11),
                Reading("2026-10-08", 10, "visit", "github.com", 5),
                Reading("2026-10-08", 14, "visit", "github.com", 7),
            ],
        )
        text = activity.digest(store, NOW)
    assert text.splitlines() == [
        HEADER,
        "Thu 10-08: active 5.2 h; commits 3 (personal-website); files edited 41; "
        "github.com 12 visits",
    ]


def test_active_hours_are_minutes_over_sixty_rounded_to_a_tenth(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        _minutes(store, datetime(2026, 10, 8, 9, 0, tzinfo=DUBAI), 95)
        text = activity.digest(store, NOW)
    assert "active 1.6 h" in text


def test_days_are_newest_first_and_empty_days_are_left_out(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        _fill(
            store,
            [
                Reading("2026-10-05", 9, "files", "", 1),
                Reading("2026-10-09", 0, "files", "", 3),
                Reading("2026-10-07", 9, "files", "", 2),
            ],
        )
        lines = activity.digest(store, NOW).splitlines()
    assert [line.split(":")[0] for line in lines[1:]] == ["Fri 10-09", "Wed 10-07", "Mon 10-05"]


def test_the_digest_covers_only_the_requested_number_of_days(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        _fill(
            store,
            [
                Reading("2026-10-02", 9, "files", "", 1),  # 7 days back: outside a 7-day digest
                Reading("2026-10-03", 9, "files", "", 1),
                Reading("2026-10-09", 0, "files", "", 1),
            ],
        )
        assert len(activity.digest(store, NOW).splitlines()) == 3
        assert len(activity.digest(store, NOW, days=1).splitlines()) == 2


def test_repositories_and_domains_are_listed_busiest_first(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        _fill(
            store,
            [
                Reading("2026-10-09", 0, "commit", "small", 1),
                Reading("2026-10-09", 0, "commit", "big", 4),
                Reading("2026-10-09", 0, "visit", "docs.python.org", 1),
                Reading("2026-10-09", 0, "visit", "github.com", 9),
            ],
        )
        line = activity.digest(store, NOW).splitlines()[1]
    assert line == "Fri 10-09: commits 5 (big, small); github.com 9 visits; docs.python.org 1 visit"


def test_an_empty_store_has_no_digest(tmp_path):
    with ActivityStore(tmp_path / "a.db") as store:
        assert activity.digest(store, NOW) == ""
        _fill(store, [Reading("2026-08-01", 9, "files", "", 4)])  # rows, but none in the window
        assert activity.digest(store, NOW) == ""


# --- the privacy contract, end to end --------------------------------------------------------


@pytest.mark.skipif(GIT is None, reason="git is not installed")
def test_no_title_url_search_file_name_commit_message_or_path_reaches_the_database_file(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    root = tmp_path / "code"
    repo = _real_repo(root, "proj", "me@example.com")
    _commit(repo, ago(hours=1), "me@example.com", message="CANARY-COMMIT-MESSAGE-XYZ")
    _touch(repo / "CANARY-FILE-XYZ.py", ago(hours=1))
    _touch(repo / "CANARY-DIR-XYZ" / "notes.txt", ago(hours=1))
    history = make_history(
        tmp_path / "History",
        [
            (
                "https://github.com/CANARY-PATH-XYZ?q=CANARY-QUERY-XYZ",
                "CANARY-TITLE-XYZ",
                ago(hours=1),
            ),
            ("https://docs.github.com/CANARY-DOCS-XYZ", "CANARY-DOCS-TITLE-XYZ", ago(hours=1)),
            ("https://bank.example/CANARY-BANK-XYZ", "CANARY-BANK-TITLE-XYZ", ago(hours=1)),
        ],
        searches=["CANARY-SEARCH-XYZ"],
        downloads=["/home/me/CANARY-DOWNLOAD-XYZ.pdf"],
    )
    settings = Settings(
        _env_file=None,
        pli_home=tmp_path / "home",
        activity_roots=str(root),
        activity_domains="github.com",
        activity_history_path=str(history),
    )
    with ActivityStore(settings.activity_db_path) as store:
        status = activity.collect_once(store, settings, NOW, idle=lambda: True)
        text = activity.digest(store, NOW)
        assert status == "ok"
    stored = [p for p in settings.home.rglob("*") if p.is_file()]
    blob = b"".join(p.read_bytes() for p in stored) + text.encode()
    assert b"CANARY" not in blob
    assert b"bank.example" not in blob
    assert b"/home/me" not in blob and str(tmp_path).encode() not in blob
    assert b"github.com" in blob and b"proj" in blob  # the allowed words did get stored
    body = text.splitlines()[1:]
    assert body and all("/" not in line and "http" not in line for line in body)
    assert "github.com 2 visits" in text


# --- pause -----------------------------------------------------------------------------------


def test_pause_and_resume_toggle_the_flag_file_idempotently(tmp_path):
    flag = tmp_path / "data" / "activity.paused"
    assert activity.is_paused(flag) is False
    activity.pause(flag)
    activity.pause(flag)
    assert activity.is_paused(flag) is True and flag.exists()
    activity.resume(flag)
    activity.resume(flag)
    assert activity.is_paused(flag) is False and not flag.exists()


def test_pause_resume_and_check_never_raise(tmp_path):
    blocker = tmp_path / "file"
    blocker.write_text("x")
    flag = blocker / "activity.paused"  # its parent is a file
    activity.pause(flag)
    activity.resume(flag)
    assert activity.is_paused(flag) in (True, False)


# --- one collection cycle --------------------------------------------------------------------


def make_settings(tmp_path: Path, **overrides) -> Settings:
    values = {
        "pli_home": tmp_path / "home",
        "activity_roots": str(tmp_path / "roots"),
        "activity_domains": "github.com",
        "activity_history_path": "",
        "activity_retention_days": 30,
    }
    values.update(overrides)
    return Settings(_env_file=None, **values)


def no_git(cmd: list[str], timeout: float = 10.0) -> tuple[int, str]:
    return 1, ""


def explode(*args, **kwargs):
    raise AssertionError("must not be called while paused")


def test_a_paused_cycle_collects_nothing_and_asks_nothing(tmp_path):
    settings = make_settings(tmp_path, activity_history_path=str(tmp_path / "History"))
    make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    _touch(tmp_path / "roots" / "a.py", ago(hours=1))
    activity.pause(settings.activity_pause_path)
    with ActivityStore(settings.activity_db_path) as store:
        status = activity.collect_once(store, settings, NOW, idle=explode, run=explode)
        assert status == "paused"
        assert store.summary() == (0, None)
    assert not (tmp_path / "work").exists()


def test_resuming_restarts_collection(tmp_path):
    settings = make_settings(tmp_path)
    activity.pause(settings.activity_pause_path)
    with ActivityStore(settings.activity_db_path) as store:
        assert (
            activity.collect_once(store, settings, NOW, idle=lambda: True, run=no_git) == "paused"
        )
        activity.resume(settings.activity_pause_path)
        assert activity.collect_once(store, settings, NOW, idle=lambda: True, run=no_git) == "ok"
        assert store.summary()[0] == 1


def test_an_active_sample_adds_one_minute_and_an_idle_one_adds_none(tmp_path):
    settings = make_settings(tmp_path)
    with ActivityStore(settings.activity_db_path) as store:
        activity.collect_once(store, settings, NOW, idle=lambda: True, run=no_git, scan=False)
        activity.collect_once(store, settings, NOW, idle=lambda: False, run=no_git, scan=False)
    assert rows(settings.activity_db_path) == [("2026-10-09", 1, "active_min", "", 1)]


def test_unavailable_idle_is_reported_but_the_scans_still_run(tmp_path):
    settings = make_settings(tmp_path)
    _touch(tmp_path / "roots" / "a.py", ago(hours=1))
    with ActivityStore(settings.activity_db_path) as store:
        status = activity.collect_once(store, settings, NOW, idle=lambda: None, run=no_git)
    assert status == "idle-unavailable"
    assert rows(settings.activity_db_path) == [("2026-10-09", 0, "files", "", 1)]


def test_scan_false_samples_idle_only(tmp_path):
    settings = make_settings(tmp_path)
    _touch(tmp_path / "roots" / "a.py", ago(hours=1))
    calls: list[list[str]] = []

    def spy(cmd, timeout=10.0):
        calls.append(cmd)
        return 1, ""

    with ActivityStore(settings.activity_db_path) as store:
        activity.collect_once(store, settings, NOW, idle=lambda: True, run=spy, scan=False)
    assert calls == []
    assert [r[2] for r in rows(settings.activity_db_path)] == ["active_min"]


def test_a_scan_cycle_stores_all_three_kinds_and_is_idempotent(tmp_path):
    settings = make_settings(tmp_path, activity_history_path=str(tmp_path / "History"))
    make_history(tmp_path / "History", [("https://docs.github.com/", "t", ago(hours=1))])
    _fake_repo(tmp_path / "roots", "proj")
    _touch(tmp_path / "roots" / "proj" / "a.py", ago(hours=1))
    git = FakeGit({"proj": {"commits": [(ago(hours=1), "me@example.com")]}})
    with ActivityStore(settings.activity_db_path) as store:
        for _ in range(2):
            status = activity.collect_once(
                store, settings, NOW, idle=lambda: False, run=git, history_workdir=tmp_path / "w"
            )
    assert status == "ok"
    assert rows(settings.activity_db_path) == [
        ("2026-10-09", 0, "commit", "proj", 1),
        ("2026-10-09", 0, "files", "", 1),
        ("2026-10-09", 0, "visit", "github.com", 1),
    ]
    assert list((tmp_path / "w").iterdir()) == []


def test_a_scan_that_finds_nothing_does_not_wipe_what_was_collected(tmp_path):
    settings = make_settings(tmp_path, activity_history_path=str(tmp_path / "History"))
    history = make_history(tmp_path / "History", [("https://github.com/", "t", ago(hours=1))])
    with ActivityStore(settings.activity_db_path) as store:
        activity.collect_once(store, settings, NOW, idle=lambda: False, run=no_git)
        history.unlink()  # the browser is gone, or the file is locked: an empty scan, not a zero
        activity.collect_once(store, settings, NOW, idle=lambda: False, run=no_git)
    assert rows(settings.activity_db_path) == [("2026-10-09", 0, "visit", "github.com", 1)]


def test_each_cycle_purges_what_is_past_the_retention(tmp_path):
    settings = make_settings(tmp_path, activity_retention_days=7)
    with ActivityStore(settings.activity_db_path) as store:
        _fill(
            store,
            [Reading("2026-09-01", 9, "files", "", 1), Reading("2026-10-05", 9, "files", "", 1)],
        )
        activity.collect_once(store, settings, NOW, idle=lambda: False, run=no_git, scan=False)
    assert [r[0] for r in rows(settings.activity_db_path)] == ["2026-10-05"]


def test_old_rows_are_deleted_even_while_paused_but_nothing_is_collected(tmp_path):
    settings = make_settings(tmp_path, activity_retention_days=7)
    activity.pause(settings.activity_pause_path)
    with ActivityStore(settings.activity_db_path) as store:
        _fill(
            store,
            [Reading("2026-09-01", 9, "files", "", 1), Reading("2026-10-05", 9, "files", "", 1)],
        )
        status = activity.collect_once(store, settings, NOW, idle=explode, run=explode)
    assert status == "paused"
    assert [r[0] for r in rows(settings.activity_db_path)] == ["2026-10-05"]


def test_an_exception_inside_a_scan_does_not_escape_or_stop_the_other_scans(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    _touch(tmp_path / "roots" / "a.py", ago(hours=1))

    def boom(*args, **kwargs):
        raise RuntimeError("a bug in a scan")

    monkeypatch.setattr(activity, "scan_git", boom)
    monkeypatch.setattr(activity, "scan_history", boom)
    with ActivityStore(settings.activity_db_path) as store:
        status = activity.collect_once(store, settings, NOW, idle=lambda: True, run=no_git)
    assert status == "error"
    assert [r[2] for r in rows(settings.activity_db_path)] == ["files", "active_min"]


def test_a_broken_idle_sampler_or_store_does_not_escape(tmp_path):
    settings = make_settings(tmp_path)

    def broken_idle() -> bool:
        raise OSError("bus gone")

    store = ActivityStore(settings.activity_db_path)
    assert activity.collect_once(store, settings, NOW, idle=broken_idle, run=no_git) == "error"
    store.close()  # a closed store: every write fails
    assert activity.collect_once(store, settings, NOW, idle=lambda: True, run=no_git) == "error"


def test_a_missing_roots_folder_and_no_browser_are_not_errors(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path / "nohome"))
    settings = make_settings(tmp_path)  # roots does not exist; no history configured or found
    with ActivityStore(settings.activity_db_path) as store:
        assert activity.collect_once(store, settings, NOW, idle=lambda: False, run=no_git) == "ok"
        assert store.summary() == (0, None)
