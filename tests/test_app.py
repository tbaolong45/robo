import os
import threading
import time
from datetime import date

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtWidgets import QApplication  # noqa: E402

from robo import app as robo_app  # noqa: E402
from robo.brain import BrainError  # noqa: E402
from robo.events import ApprovalNeeded, Delta, Feeling, RunEnded, ToolStarted  # noqa: E402
from robo.wake import DigestClock  # noqa: E402

QAPP = QApplication.instance() or QApplication([])


class FakeClient:
    def __init__(self, script=None, fail=None, gate=None, before_start=None):
        self.script, self.fail, self.gate = script or [], fail, gate
        self.before_start = before_start  # holds the run between "asked" and "started"
        self.asked, self.stopped, self.approved = [], [], []

    def ask(self, text, session_id, started=None):
        self.asked.append((text, session_id))
        if self.fail:
            raise self.fail
        if self.before_start:
            self.before_start.wait(5)
        if started:
            started("run_1")
        for ev in self.script:
            if ev == "WAIT":
                self.gate.wait(5)
                continue
            yield ev

    def stop(self, run_id):
        self.stopped.append(run_id)

    def approve(self, run_id, allow):
        self.approved.append((run_id, allow))


def pump(win, until, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        QAPP.processEvents()
        if until():
            return True
        time.sleep(0.01)
    return False


def window(tmp_path, client, today=lambda: date(2026, 10, 11)):
    clock = DigestClock(tmp_path / "state.json")
    clock.mark(today())  # no digest at start unless a test wants one
    return robo_app.RoboWindow(client, clock, today=today, network=lambda: True,
                               watch_wake=False)


def test_reply_streams_without_tags_and_returns_to_idle(tmp_path):
    client = FakeClient([Feeling("happy"), Delta("Hel"), Delta("lo **you**"),
                         RunEnded("completed", output="Hello **you**")])
    win = window(tmp_path, client)
    win.input.setText("hi")
    win.send()
    assert pump(win, lambda: not win.busy)
    assert client.asked == [("hi", win.session_id)]
    assert "Hello" in win.bubble.toPlainText() and "[[" not in win.bubble.toPlainText()
    assert win.mind.activity == "idle" and win.mind.emotion == "happy"
    assert win.input.text() == ""


def test_brain_error_shows_message_and_sad_face(tmp_path):
    win = window(tmp_path, FakeClient(fail=BrainError("Hermes is not running")))
    win.ask("hi")
    assert pump(win, lambda: not win.busy)
    assert win.bubble.toPlainText() == "Hermes is not running"  # no generic prefix
    assert win.mind.activity == "error"


def test_tool_label_shows_while_working(tmp_path):
    gate = threading.Event()
    client = FakeClient([ToolStarted("web_search"), "WAIT", RunEnded("completed", "ok")],
                        gate=gate)
    win = window(tmp_path, client)
    win.ask("news?")
    assert pump(win, lambda: win.mind.activity == "working")
    assert "searching" in win.status.text()
    win.ask("second while busy")  # ignored, one run at a time
    gate.set()
    assert pump(win, lambda: not win.busy)
    assert [a[0] for a in client.asked] == ["news?"]


def test_escape_stops_the_run(tmp_path):
    gate = threading.Event()
    client = FakeClient([Delta("long"), "WAIT", RunEnded("cancelled")], gate=gate)
    win = window(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.mind.activity == "talking")
    win.stop()
    assert pump(win, lambda: client.stopped == ["run_1"])
    gate.set()
    assert pump(win, lambda: not win.busy)


@pytest.mark.parametrize("allow", [True, False])
def test_approval_bar(tmp_path, allow):
    gate = threading.Event()
    client = FakeClient([ApprovalNeeded("open a page"), "WAIT", RunEnded("completed", "ok")],
                        gate=gate)
    win = window(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.approval.isVisibleTo(win))
    assert "open a page" in win.approval_text.text()
    (win.allow if allow else win.deny).click()
    assert pump(win, lambda: client.approved == [("run_1", allow)])
    assert not win.approval.isVisibleTo(win)
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_digest_runs_once_per_day_at_start_and_on_wake(tmp_path):
    client = FakeClient([RunEnded("completed", "digest")])
    clock = DigestClock(tmp_path / "state.json")
    today = date(2026, 10, 11)
    win = robo_app.RoboWindow(client, clock, today=lambda: today, network=lambda: True,
                              watch_wake=False)
    assert pump(win, lambda: len(client.asked) == 1 and not win.busy)
    assert client.asked[0][0] == robo_app.DIGEST_PROMPT
    assert not clock.due(today)
    win.resumed.emit()  # a later wake the same day: nothing
    pump(win, lambda: False, timeout=0.3)
    assert len(client.asked) == 1


def test_failed_digest_stays_due(tmp_path):
    client = FakeClient([RunEnded("failed", error="offline")])
    clock = DigestClock(tmp_path / "state.json")
    today = date(2026, 10, 11)
    win = robo_app.RoboWindow(client, clock, today=lambda: today, network=lambda: True,
                              watch_wake=False)
    assert pump(win, lambda: len(client.asked) == 1 and not win.busy)
    assert clock.due(today)


def test_stop_before_the_run_exists_stops_it_once_started(tmp_path):
    hold = threading.Event()
    client = FakeClient([RunEnded("cancelled")], before_start=hold)
    win = window(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: client.asked)
    win.stop()  # no run id yet
    hold.set()
    assert pump(win, lambda: not win.busy)
    assert pump(win, lambda: client.stopped == ["run_1"])


def test_stop_while_waiting_for_the_network_never_starts_a_run(tmp_path):
    online = threading.Event()
    client = FakeClient([RunEnded("completed", "digest")])
    win = robo_app.RoboWindow(client, DigestClock(tmp_path / "s.json"),
                              today=lambda: date(2026, 10, 11),
                              network=lambda: online.wait(0.05), watch_wake=False)
    assert pump(win, lambda: win.busy)  # the start-up digest waits for the network
    win.stop()
    online.set()
    assert pump(win, lambda: not win.busy)
    assert client.asked == [] and win.mind.activity == "idle"


def test_closing_mid_run_stops_it(tmp_path):
    gate = threading.Event()
    client = FakeClient([Delta("x"), "WAIT", RunEnded("cancelled")], gate=gate)
    win = window(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.mind.activity == "talking")
    win.close()
    gate.set()
    assert client.stopped == ["run_1"]


def test_session_follows_the_date(tmp_path):
    day = [date(2026, 10, 11)]
    client = FakeClient([RunEnded("completed", "ok")])
    win = window(tmp_path, client, today=lambda: day[0])
    win.ask("a")
    assert pump(win, lambda: not win.busy)
    day[0] = date(2026, 10, 12)
    win.ask("b")
    assert pump(win, lambda: not win.busy)
    assert [s for _, s in client.asked] == ["robo-2026-10-11", "robo-2026-10-12"]


def test_digest_across_midnight_counts_for_the_day_it_started(tmp_path):
    gate = threading.Event()
    day = [date(2026, 10, 11)]
    clock = DigestClock(tmp_path / "state.json")
    client = FakeClient(["WAIT", RunEnded("completed", "digest")], gate=gate)
    win = robo_app.RoboWindow(client, clock, today=lambda: day[0], network=lambda: True,
                              watch_wake=False)
    assert pump(win, lambda: client.asked)
    day[0] = date(2026, 10, 12)
    gate.set()
    assert pump(win, lambda: not win.busy)
    assert not clock.due(date(2026, 10, 11)) and clock.due(date(2026, 10, 12))


def test_session_carries_the_persona_stamp(tmp_path):
    client = FakeClient([RunEnded("completed", "ok")])
    clock = DigestClock(tmp_path / "state.json")
    clock.mark(date(2026, 10, 11))
    win = robo_app.RoboWindow(client, clock, today=lambda: date(2026, 10, 11),
                              network=lambda: True, watch_wake=False, persona="ab12cd34")
    win.ask("a")
    assert pump(win, lambda: not win.busy)
    assert client.asked[0][1] == "robo-2026-10-11-ab12cd34"
