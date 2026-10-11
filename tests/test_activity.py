import os
import sqlite3
import stat
import threading
import time
from datetime import UTC, date, datetime

import pytest

from robo import activity as act
from robo.activity import ActivityStore, Sample, Watcher, sample, summary

NOW = datetime(2026, 10, 11, 12, 0).timestamp()  # local noon
DAY = 86400


def mode(p):
    return stat.S_IMODE(os.stat(p).st_mode)


def s(ts, app="code", title="t", idle=0, locked=False, domains=(), files=()):
    return Sample(int(ts), app, title, idle, locked, list(domains), list(files))


def rows(store, sql):
    with store.connect() as con:
        return con.execute(sql).fetchall()


# --- store ------------------------------------------------------------------------------------


def test_store_schema_and_private_modes(tmp_path):
    db = tmp_path / "robo" / "activity.db"
    store = ActivityStore(db)
    assert mode(db.parent) == 0o700 and mode(db) == 0o600
    cols = {t: [r[1] for r in rows(store, f"PRAGMA table_info({t})")]
            for t in ("minutes", "sites", "files")}
    assert cols == {"minutes": ["ts", "app", "title", "idle_s", "locked"],
                    "sites": ["ts", "domain"], "files": ["ts", "path"]}


def test_store_tightens_loose_modes(tmp_path):
    d = tmp_path / "robo"
    d.mkdir(mode=0o755)
    (d / "activity.db").touch(mode=0o644)
    os.chmod(d, 0o755), os.chmod(d / "activity.db", 0o644)
    ActivityStore(d / "activity.db")
    assert mode(d) == 0o700 and mode(d / "activity.db") == 0o600


def test_add_and_purge(tmp_path):
    store = ActivityStore(tmp_path / "a.db")
    store.add(s(NOW - 31 * DAY, domains=["old.com"], files=["/old"]))
    store.add(s(NOW - DAY, domains=["new.com", "new.com"], files=["/new"]))
    store.purge(NOW)
    assert rows(store, "SELECT ts FROM minutes") == [(int(NOW - DAY),)]
    assert rows(store, "SELECT domain FROM sites") == [("new.com",), ("new.com",)]
    assert rows(store, "SELECT path FROM files") == [("/new",)]
    store.purge(NOW, days=0)
    assert rows(store, "SELECT count(*) FROM minutes") == [(0,)]


# --- sample and D-Bus readers -----------------------------------------------------------------


def test_sample_with_fakes():
    seen = []
    got = sample(NOW, NOW - 60, focus=lambda: ("code", "x.py"), idle=lambda: 7,
                 locked=lambda: True,
                 sites=lambda a, b: seen.append(("s", a, b)) or ["a.com"],
                 files=lambda a, b: seen.append(("f", a, b)) or ["/x"])
    assert got == Sample(int(NOW), "code", "x.py", 7, True, ["a.com"], ["/x"])
    assert seen == [("s", NOW - 60, NOW), ("f", NOW - 60, NOW)]


def test_dbus_readers(monkeypatch):
    replies = {"GetIdletime": (113_900,), "GetActive": (True,), "Current": ("code", "x.py")}
    monkeypatch.setattr(act, "_call", lambda dest, path, iface, method: replies[method])
    assert act.read_idle() == 113 and act.read_locked() is True
    assert act.read_focus() == ("code", "x.py") and act.extension_status() == "on"

    def boom(*a):
        raise ConnectionError("org.robo.Focus was not provided")

    monkeypatch.setattr(act, "_call", boom)
    assert act.read_focus() == ("", "") and act.extension_status() == "not loaded"


# --- Brave history ----------------------------------------------------------------------------


def history(path, urls):
    """A Chromium-shaped History file; `urls` is [(url, unix_time)]."""
    con = sqlite3.connect(path)
    con.executescript("CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT);"
                      "CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INT);")
    for i, (url, t) in enumerate(urls, 1):
        con.execute("INSERT INTO urls VALUES (?, ?, 'secret title')", (i, url))
        con.execute("INSERT INTO visits(url, visit_time) VALUES (?, ?)", (i, act._webkit(t)))
    con.commit()
    con.close()
    return path


def test_sites_hosts_only_in_window_and_copy_deleted(tmp_path, monkeypatch):
    src = history(tmp_path / "History", [
        ("https://user:pw@Moodle.Example.com:8443/course/view.php?id=5", NOW - 10),
        ("https://a.com?q=secret", NOW - 20),
        ("http://b.org#frag", NOW - 30),
        ("https://a.com/x", NOW - 40),
        ("chrome://settings/", NOW - 10),
        ("file:///home/u/private.pdf", NOW - 10),
        ("https://[::1]:8080/", NOW - 10),
        ("https://too-old.com/", NOW - 600),
        ("https://future.com/", NOW + 10),
    ])
    work = tmp_path / "work"
    (work / ".history-stale").mkdir(parents=True)
    (work / ".history-stale" / "History").write_text("left by a SIGKILL")
    seen = []
    real = sqlite3.connect

    def spy(target, *a, **kw):
        copy = target.removeprefix("file://").split("?")[0]
        seen.append((mode(copy), mode(os.path.dirname(copy)), target.endswith("?mode=ro")))
        return real(target, *a, **kw)

    monkeypatch.setattr(act.sqlite3, "connect", spy)
    got = act.read_sites(NOW - 60, NOW, history=src, workdir=work)
    assert sorted(got) == ["a.com", "a.com", "b.org", "moodle.example.com"]
    assert seen == [(0o600, 0o700, True)]
    assert list(work.iterdir()) == []  # the copy and the stale one are gone


def test_sites_copy_deleted_on_error(tmp_path):
    src = tmp_path / "History"
    src.write_bytes(b"not a database" * 100)
    work = tmp_path / "work"
    assert act.read_sites(NOW - 60, NOW, history=src, workdir=work) == []
    assert list(work.iterdir()) == []
    assert act.read_sites(NOW - 60, NOW, history=tmp_path / "missing", workdir=work) == []


def test_history_authorizer_denies_other_columns_and_writes():
    con = sqlite3.connect(":memory:")
    con.executescript("CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT);")
    con.set_authorizer(act._history_authorizer)
    con.execute("SELECT lower(url) FROM urls").fetchall()
    for bad in ("SELECT title FROM urls", "INSERT INTO urls(url) VALUES ('x')",
                "DELETE FROM urls", "ATTACH ':memory:' AS x"):
        with pytest.raises(sqlite3.DatabaseError):
            con.execute(bad)


# --- recently-used.xbel -----------------------------------------------------------------------


def iso(t):
    return datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def test_files_from_xbel(tmp_path):
    def bm(href, added, modified, visited):
        return (f'<bookmark href="{href}" added="{iso(added)}" modified="{iso(modified)}" '
                f'visited="{iso(visited)}"><info/></bookmark>')

    old = NOW - DAY
    xbel = tmp_path / "recently-used.xbel"
    xbel.write_text(
        '<?xml version="1.0" encoding="UTF-8"?><xbel version="1.0">'
        + bm("file:///home/u/My%20Notes.pdf", old, NOW - 5, old)
        + bm("file:///home/u/visited.txt", old, old, NOW - 30)
        + bm("file:///home/u/stale.txt", old, old, old)
        + bm("https://example.com/page", NOW - 5, NOW - 5, NOW - 5)
        + bm("file:///home/u/later.txt", NOW + 5, NOW + 5, NOW + 5)
        + "</xbel>")
    got = act.read_files(NOW - 60, NOW, xbel=xbel)
    assert got == ["/home/u/My Notes.pdf", "/home/u/visited.txt"]
    assert act.read_files(NOW - 60, NOW, xbel=tmp_path / "missing") == []
    xbel.write_text("<xbel><bookmark")
    assert act.read_files(NOW - 60, NOW, xbel=xbel) == []


# --- watcher ----------------------------------------------------------------------------------


def test_watcher_pause_skips_recording_but_purges(tmp_path):
    store = ActivityStore(tmp_path / "a.db")
    store.add(s(NOW - 40 * DAY))
    calls = []
    clock = iter([NOW - 120, NOW - 60, NOW]).__next__
    w = Watcher(store, clock=clock, sampler=lambda now, since: calls.append(since) or s(now))
    w.pause(True)
    assert w.paused
    w.tick()  # paused at NOW-60: nothing recorded, window moves on, old row purged
    assert rows(store, "SELECT count(*) FROM minutes") == [(0,)]
    w.pause(False)
    w.tick()
    assert calls == [NOW - 60]  # visits made while paused are never picked up
    assert rows(store, "SELECT ts FROM minutes") == [(int(NOW),)]


def test_watcher_survives_bad_samples(tmp_path):
    store = ActivityStore(tmp_path / "a.db")
    n = {"calls": 0}

    def flaky(now, since):
        n["calls"] += 1
        if n["calls"] % 2:
            raise RuntimeError("bus hiccup")
        return s(now + n["calls"])

    w = Watcher(store, interval=0.01, sampler=flaky)
    w.start()
    deadline = time.time() + 5
    while rows(store, "SELECT count(*) FROM minutes")[0][0] < 2 and time.time() < deadline:
        time.sleep(0.01)
    w.stop()
    assert rows(store, "SELECT count(*) FROM minutes")[0][0] >= 2
    assert not any(t.name == "robo-activity" for t in threading.enumerate())


# --- summary ----------------------------------------------------------------------------------


def at(h, m):
    return datetime(2026, 10, 11, h, m).timestamp()


def test_summary_aggregates_and_excludes_idle_and_locked(tmp_path):
    store = ActivityStore(tmp_path / "a.db")
    for i in range(3):
        store.add(s(at(9, i), "brave-browser", "Moodle - Brave", domains=["moodle.org"] * 2))
    store.add(s(at(10, 0), "code", "activity.py", files=["/home/u/a.py"]))
    store.add(s(at(10, 1), "code", "idle title", idle=300))
    store.add(s(at(10, 2), "code", "locked title", locked=True))
    store.add(s(at(23, 30), "", ""))
    store.add(s(at(9, 0) - DAY, "slack", "yesterday"))
    out = summary(store, date(2026, 10, 11))
    assert "brave-browser 3" in out and "code 1" in out and "(unknown) 1" in out
    assert "idle title" not in out and "locked title" not in out and "slack" not in out
    assert "3 min  brave-browser: Moodle - Brave" in out
    assert "moodle.org 6" in out and "/home/u/a.py" in out
    assert "09:00" in out and "23:30" in out and "5 active min" in out
    assert "slack 1" in summary(store, date(2026, 10, 11), days=2)


def test_summary_is_compact_and_handles_empty(tmp_path):
    store = ActivityStore(tmp_path / "a.db")
    assert "No activity" in summary(store, date(2026, 10, 11))
    for i in range(300):
        store.add(s(at(8, 0) + 60 * i, f"app{i % 40}", "T" * 300 + str(i),
                    domains=[f"site{i}.example.com"], files=[f"/home/u/{'d' * 80}/{i}.txt"]))
    assert len(summary(store, date(2026, 10, 11))) <= 2500
