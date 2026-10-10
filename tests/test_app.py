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
    def __init__(self, script=None, fail=None, gate=None):
        self.script, self.fail, self.gate = script or [], fail, gate
        self.asked, self.stopped, self.approved = [], [], []
        self.run_id = "run_1"

    def health(self):
        return True

    def ask(self, text, session_id):
        self.asked.append((text, session_id))
        if self.fail:
            raise self.fail
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


def window(tmp_path, client, today=date(2026, 10, 11)):
    clock = DigestClock(tmp_path / "state.json")
    clock.mark(today)  # no digest at start unless a test wants one
    return robo_app.RoboWindow(client, clock, today=lambda: today, network=lambda: True,
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
    client = FakeClient([ToolStarted("web_search", "x"), "WAIT", RunEnded("completed", "ok")],
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
