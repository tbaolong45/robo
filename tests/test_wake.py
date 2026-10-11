import json
import os
import queue
import stat
import threading
from datetime import date

from robo import wake
from robo.wake import ClockGap, DigestClock, Login1, WakeWatcher, wait_for_network

D1, D2 = date(2026, 10, 11), date(2026, 10, 12)


# --- DigestClock ------------------------------------------------------------------------------


def test_missing_file_is_due(tmp_path):
    assert DigestClock(tmp_path / "d.json").due(D1)


def test_mark_then_not_due_same_day_but_due_next_day(tmp_path):
    c = DigestClock(tmp_path / "d.json")
    c.mark(D1)
    assert not c.due(D1)
    assert c.due(D2)
    assert not DigestClock(tmp_path / "d.json").due(D1)  # persisted


def test_file_format_and_perms(tmp_path):
    p = tmp_path / "sub" / "d.json"
    DigestClock(p).mark(D1)
    assert json.loads(p.read_text()) == {"last_digest": "2026-10-11"}
    assert stat.S_IMODE(p.stat().st_mode) == 0o600


def test_corrupt_file_is_due(tmp_path):
    p = tmp_path / "d.json"
    for junk in ("{not json", "[]", '{"last_digest": 5}', '{"last_digest": "nope"}'):
        p.write_text(junk)
        assert DigestClock(p).due(D1)


def test_mark_is_atomic(tmp_path, monkeypatch):
    p = tmp_path / "d.json"
    c = DigestClock(p)
    c.mark(D1)
    calls = []
    real = os.replace
    monkeypatch.setattr(os, "replace", lambda a, b: (calls.append((a, b)), real(a, b)))
    c.mark(D2)
    assert calls and str(calls[0][1]) == str(p) and str(calls[0][0]) != str(p)
    assert sorted(x.name for x in tmp_path.iterdir()) == ["d.json"]  # no tmp left behind


# --- WakeWatcher ------------------------------------------------------------------------------


class FakeSource:
    """Stands in for the login1 connection: `recv` yields queued PrepareForSleep flags."""

    def __init__(self):
        self.q, self.closed = queue.Queue(), threading.Event()

    def recv(self, timeout):
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self):
        self.closed.set()


def test_resume_calls_back_and_sleep_does_not():
    src, woke = FakeSource(), threading.Event()
    hits = []
    w = WakeWatcher(lambda: (hits.append(1), woke.set()), connect=lambda: src, poll=0.01)
    assert w.start()
    src.q.put(True)  # going to sleep
    src.q.put(False)  # resumed
    assert woke.wait(2)
    w.stop()
    assert hits == [1]
    assert src.closed.is_set()


def test_stop_ends_thread():
    src = FakeSource()
    w = WakeWatcher(lambda: None, connect=lambda: src, poll=0.01)
    assert w.start()
    w.stop()
    assert not w._thread.is_alive()
    assert src.closed.is_set()


def test_callback_error_does_not_kill_watcher():
    src, woke = FakeSource(), threading.Event()
    n = []

    def cb():
        n.append(1)
        if len(n) == 1:
            raise RuntimeError("boom")
        woke.set()

    w = WakeWatcher(cb, connect=lambda: src, poll=0.01)
    w.start()
    src.q.put(False)
    src.q.put(False)
    assert woke.wait(2)
    w.stop()


def test_no_dbus_start_returns_false():
    def boom():
        raise OSError("no system bus")

    w = WakeWatcher(lambda: None, connect=boom)
    assert w.start() is False
    w.stop()  # harmless


# --- wait_for_network -------------------------------------------------------------------------


def test_network_up_after_retries():
    answers, slept = iter([False, False, True]), []
    assert wait_for_network(lambda: next(answers), timeout=60, interval=2, sleep=slept.append)
    assert slept == [2, 2]


def test_network_gives_up_after_timeout():
    slept = []
    assert not wait_for_network(lambda: False, timeout=10, interval=2, sleep=slept.append)
    assert sum(slept) == 10


def test_probe_exception_counts_as_down():
    answers = iter([OSError, True])

    def probe():
        a = next(answers)
        if a is OSError:
            raise OSError("refused")
        return a

    assert wait_for_network(probe, timeout=10, interval=1, sleep=lambda s: None)


def test_bus_error_reconnects():
    class Broken(FakeSource):
        def recv(self, timeout):
            raise ConnectionError("bus went away")

    broken, good, woke = Broken(), FakeSource(), threading.Event()
    sources = iter([broken, good])
    w = WakeWatcher(woke.set, connect=lambda: next(sources), poll=0.01, retry=0.01)
    assert w.start()
    good.q.put(False)
    assert woke.wait(2)
    w.stop()
    assert broken.closed.is_set() and good.closed.is_set()


def clocks():
    t = {"wall": 1000.0, "awake": 50.0}
    gap = ClockGap(wall=lambda: t["wall"], awake=lambda: t["awake"], wait=lambda s: None)
    return t, gap


def step(t, wall, awake=0.5):
    t["wall"] += wall
    t["awake"] += awake


def test_clock_gap_sees_a_sleep_but_not_a_stall_or_a_clock_change():
    t, gap = clocks()
    step(t, 5.5)  # a busy CPU: 5 s late, never asleep
    assert gap.recv(0.5) is None
    step(t, 1800.5)  # lid closed for 30 min
    assert gap.recv(0.5) is False
    step(t, 0.5)
    assert gap.recv(0.5) is None  # once per sleep
    step(t, -3600)  # clock set back an hour
    assert gap.recv(0.5) is None


def test_clock_gap_threshold_is_gap_s():
    t, gap = clocks()
    step(t, wake.GAP_S + 0.5)  # exactly GAP_S ahead of awake time: not yet a sleep
    assert gap.recv(0) is None
    step(t, wake.GAP_S + 1.5)
    assert gap.recv(0) is False


def test_wake_source_per_os(monkeypatch):
    monkeypatch.setattr(wake.sys, "platform", "darwin")
    assert WakeWatcher(lambda: None).connect is ClockGap
    monkeypatch.setattr(wake.sys, "platform", "linux")
    assert WakeWatcher(lambda: None).connect is Login1


def test_watcher_on_clock_gap_calls_on_resume():
    t, gap = clocks()
    woke = threading.Event()
    w = WakeWatcher(woke.set, connect=lambda: gap, poll=0.01)
    assert w.start()
    step(t, 900)
    assert woke.wait(2)
    w.stop()
