import os
import threading
import time
from datetime import date
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QPoint, Qt  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from robo import app as robo_app  # noqa: E402
from robo import hud, widgets  # noqa: E402
from robo.brain import BrainError  # noqa: E402
from robo.events import ApprovalNeeded, Delta, Feeling, RunEnded, ToolStarted  # noqa: E402
from robo.wake import DigestClock  # noqa: E402

QAPP = QApplication.instance() or QApplication([])
REAL_OPEN_FILE = robo_app.open_file  # conftest swaps robo.app.open_file for a refusal per test


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
                self.gate.clear()  # each WAIT needs its own set()
                continue
            yield ev

    def stop(self, run_id):
        self.stopped.append(run_id)

    def approve(self, run_id, choice):
        self.approved.append((run_id, choice))


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
    # The question it queued runs next and would wait 5 s for the gate: that stale run's end
    # would land in a later test (and open its notes). Let it finish here.
    gate.set()
    assert pump(win, lambda: len(client.asked) == 2 and not win.busy)


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


@pytest.mark.parametrize(("button", "choice"), [("allow", "once"), ("deny", "deny")])
def test_approval_bar(tmp_path, button, choice):
    gate = threading.Event()
    client = FakeClient([ApprovalNeeded("open a page"), "WAIT", RunEnded("completed", "ok")],
                        gate=gate)
    win = window(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.approval.isVisibleTo(win))
    assert "open a page" in win.approval_text.text()
    getattr(win, button).click()
    assert pump(win, lambda: client.approved == [("run_1", choice)])
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


class FakeListener:
    def __init__(self, on_wake, on_text, on_error, ok=True):
        self.on_wake, self.on_text, self.on_error, self.ok = on_wake, on_text, on_error, ok
        self.now, self.stopped, self.follow = 0, False, 0
        self.running = self.ready = True  # the real one: its thread is alive, its model loaded

    def start(self):
        return self.ok

    def listen_now(self):
        self.now += 1

    def follow_up(self, seconds):
        self.follow = seconds

    def stop(self, wait=5.0):
        self.stopped = True


def floating(tmp_path, client, **kw):
    tmp_path.mkdir(parents=True, exist_ok=True)
    clock = DigestClock(tmp_path / "state.json")
    clock.mark(date(2026, 10, 11))
    made = []

    def listener(*callbacks):
        made.append(FakeListener(*callbacks))
        return made[-1]

    win = robo_app.RoboWindow(client, clock, today=lambda: date(2026, 10, 11),
                              network=lambda: True, watch_wake=False, floating=True,
                              listener=listener, **kw)
    win.show()
    return win, made[0]


def test_floating_starts_as_just_a_face_and_the_bubble_opens_for_a_reply(tmp_path):
    client = FakeClient([Feeling("happy"), Delta("Hi!"), RunEnded("completed", "Hi!")])
    win, _ = floating(tmp_path, client)
    face_only = win.size()
    assert win.panel.isHidden() and not win.input.isVisibleTo(win)
    win.ask("hello")
    assert pump(win, lambda: not win.busy)
    assert not win.panel.isHidden() and win.height() > face_only.height()
    assert win.heard.toPlainText() == "hello" and "Hi!" in win.bubble.toPlainText()
    assert win.close_at > time.monotonic() + robo_app.CLOSE_AFTER - 5  # closes by itself later
    win.close_at = 1  # the reply's time is up
    assert pump(win, lambda: win.panel.isHidden())
    assert win.size() == face_only


def test_bubble_grows_upward_keeping_the_face_in_place(tmp_path):
    win, _ = floating(tmp_path, FakeClient([RunEnded("completed", "x")]))
    face_at = win.face.mapToGlobal(win.face.rect().center())
    win._open()
    assert win.face.mapToGlobal(win.face.rect().center()).y() == face_at.y()


def test_wake_word_listens_then_the_heard_text_is_asked(tmp_path):
    client = FakeClient([RunEnded("completed", "ok")])
    win, ear = floating(tmp_path, client)
    ear.on_wake()
    assert pump(win, lambda: win.mind.activity == "listening")
    assert not win.panel.isHidden() and "listening" in win.status.text()
    ear.on_text("what's on my calendar today")
    assert pump(win, lambda: client.asked)
    assert client.asked[0][0] == "what's on my calendar today"
    assert pump(win, lambda: not win.busy)


def test_nothing_heard_says_so_without_asking(tmp_path):
    client = FakeClient([])
    win, ear = floating(tmp_path, client)
    ear.on_wake()
    ear.on_text("")
    assert pump(win, lambda: "didn't catch" in win.bubble.toPlainText())
    assert client.asked == [] and win.mind.activity == "idle"


def test_wake_while_answering_interrupts(tmp_path):
    gate = threading.Event()
    client = FakeClient([Delta("long answer"), "WAIT", RunEnded("cancelled")], gate=gate)
    win, ear = floating(tmp_path, client)
    win.ask("tell me a story")
    assert pump(win, lambda: win.mind.activity == "talking")
    ear.on_wake()
    assert pump(win, lambda: client.stopped == ["run_1"])
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_click_listens_and_drag_moves_and_pins(tmp_path):
    from PySide6.QtCore import QPointF
    from PySide6.QtTest import QTest

    win, ear = floating(tmp_path, FakeClient([]))
    QTest.mouseClick(win.face, Qt.MouseButton.LeftButton)
    assert ear.now == 1
    assert pump(win, lambda: win.mind.activity == "listening")  # visible at once
    assert not win.panel.isHidden() and "listening" in win.status.text()
    ear.on_text("")  # nothing said: back to idle
    assert pump(win, lambda: win.mind.activity == "idle")
    start = win.pos()
    QTest.mousePress(win.face, Qt.MouseButton.LeftButton, pos=QPointF(10, 10).toPoint())
    QTest.mouseMove(win.face, QPointF(60, 10).toPoint())
    QTest.mouseRelease(win.face, Qt.MouseButton.LeftButton, pos=QPointF(60, 10).toPoint())
    assert ear.now == 1  # a drag is not a click
    assert win.roamer.mode in ("", "present") or win.roamer.held_until > time.monotonic()
    assert win.pos() != start or win.roamer.held_until > time.monotonic()


def test_closing_stops_the_listener(tmp_path):
    win, ear = floating(tmp_path, FakeClient([]))
    win.close()
    assert ear.stopped


def test_no_microphone_falls_back_to_typing(tmp_path):
    clock = DigestClock(tmp_path / "state.json")
    clock.mark(date(2026, 10, 11))
    win = robo_app.RoboWindow(FakeClient([]), clock, today=lambda: date(2026, 10, 11),
                              network=lambda: True, watch_wake=False, floating=True,
                              listener=lambda *c: FakeListener(*c, ok=False))
    assert win.listener is None


def test_right_click_shows_a_menu_row_in_the_bubble(tmp_path):
    from PySide6.QtTest import QTest

    client = FakeClient([RunEnded("completed", "digest")])
    win, _ = floating(tmp_path, client)
    QTest.mouseClick(win.face, Qt.MouseButton.RightButton)
    assert pump(win, lambda: win.menu.isVisibleTo(win) and not win.panel.isHidden())
    labels = [b.text() for b in win.menu.findChildren(robo_app.QPushButton)]
    assert any("Digest" in t for t in labels) and any("Quit" in t for t in labels)
    next(b for b in win.menu.findChildren(robo_app.QPushButton) if "Digest" in b.text()).click()
    assert pump(win, lambda: client.asked and not win.busy)
    assert client.asked[0][0] == robo_app.DIGEST_PROMPT
    assert not win.menu.isVisibleTo(win)


def test_drag_hands_the_move_to_the_compositor_and_pins_where_dropped(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    moved = []
    win._system_move = lambda: moved.append(1) or True  # what Mutter does: it moves the window
    from PySide6.QtCore import QPointF
    from PySide6.QtTest import QTest

    QTest.mousePress(win.face, Qt.MouseButton.LeftButton, pos=QPointF(10, 10).toPoint())
    QTest.mouseMove(win.face, QPointF(60, 10).toPoint())
    assert moved == [1] and win.press is None
    win.move(200, 300)  # the compositor drops it here
    assert pump(win, lambda: win.roamer.held_until > time.monotonic() + 60)
    assert (win.roamer.pos[0], win.roamer.pos[1]) == (200, 300)


def test_a_drag_robo_moves_itself_is_not_pulled_back_by_the_roam_tick(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win._system_move = lambda: False  # no compositor drag: robo follows the mouse itself
    from PySide6.QtCore import QPoint
    from PySide6.QtTest import QTest

    start = win.pos()
    QTest.mousePress(win.face, Qt.MouseButton.LeftButton, pos=QPoint(60, 10))
    QTest.mouseMove(win.face, QPoint(10, 10))
    assert win.pos() == start + QPoint(-50, 0)
    pump(win, lambda: False, timeout=0.3)  # ten roam ticks
    assert win.pos() == start + QPoint(-50, 0)
    assert win.roamer.held_until > time.monotonic() + 60


def test_roaming_follows_the_monitors_that_are_plugged_in(tmp_path, monkeypatch):
    from robo.roam import Rect

    win, _ = floating(tmp_path, FakeClient([]))
    two = (Rect(0, 0, 800, 600), Rect(800, 0, 1920, 1080))
    monkeypatch.setattr(robo_app, "_screen_rects", lambda: two)
    win._screens_changed()  # an external monitor was plugged in
    assert pump(win, lambda: win.roamer.screens == two)
    win.roamer.hold(time.monotonic(), (1500, 400))
    assert win.roamer.pos == (1500, 400)  # a drop on the second screen stays there
    monkeypatch.setattr(robo_app, "_screen_rects", lambda: ())
    win._screens_changed()  # a display asleep for a moment lists no screens
    pump(win, lambda: False, timeout=0.1)
    assert win.roamer.screens == two
    monkeypatch.setattr(robo_app, "_screen_rects", lambda: two[:1])
    win._screens_changed()  # and it was unplugged: robo comes back to the one left
    assert pump(win, lambda: win.roamer.screens == two[:1])
    assert win.roamer.pos == (800 - win.width(), min(400, 600 - win.height()))


def test_type_opens_its_own_focusable_window_and_asks(tmp_path):
    client = FakeClient([RunEnded("completed", "ok")])
    win, _ = floating(tmp_path, client)
    win._type()
    box = win.typer
    assert box.screen() is win.screen()  # beside robo, not on the primary screen
    assert box.parent() is None and box.isVisible()  # a top-level window XWayland can focus
    assert box.windowFlags() & Qt.WindowType.WindowStaysOnTopHint
    box.setTextValue("what is 2+2")
    box.accept()
    assert pump(win, lambda: client.asked and not win.busy)
    assert client.asked[0][0] == "what is 2+2"


def test_after_a_drag_robo_wanders_again_later(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win._system_move = lambda: True
    from PySide6.QtCore import QPointF
    from PySide6.QtTest import QTest

    QTest.mousePress(win.face, Qt.MouseButton.LeftButton, pos=QPointF(10, 10).toPoint())
    QTest.mouseMove(win.face, QPointF(60, 10).toPoint())
    win.move(200, 300)
    assert pump(win, lambda: not win.moving)  # the compositor drag is over
    win.roamer.held_until = 0  # the hold expires
    win.move(250, 300)  # a roaming move must not re-pin it
    assert win.roamer.held_until == 0


def test_speaking_over_an_answer_asks_the_new_question(tmp_path):
    gate = threading.Event()
    client = FakeClient([Delta("long"), "WAIT", RunEnded("cancelled")], gate=gate)
    win, ear = floating(tmp_path, client)
    win.ask("tell me a story")
    assert pump(win, lambda: win.mind.activity == "talking")
    ear.on_wake()
    assert pump(win, lambda: client.stopped == ["run_1"])
    gate.set()  # the old run ends while robo is still listening
    assert pump(win, lambda: not win.busy)
    assert win.mind.activity == "listening" and "cancelled" not in win.bubble.toPlainText()
    client.script = [RunEnded("completed", "ok")]
    ear.on_text("what's due")
    assert pump(win, lambda: [a[0] for a in client.asked] == ["tell me a story", "what's due"])


def test_a_question_during_a_run_waits_for_it(tmp_path):
    gate = threading.Event()
    client = FakeClient([Delta("x"), "WAIT", RunEnded("completed", "x")], gate=gate)
    win, ear = floating(tmp_path, client)
    win.ask("first")
    assert pump(win, lambda: win.mind.activity == "talking")
    client2 = [RunEnded("completed", "second done")]
    ear.on_text("second")  # heard while the first still runs (its stop is on the way)
    client.script = client2
    gate.set()
    assert pump(win, lambda: [a[0] for a in client.asked] == ["first", "second"])


def test_a_listener_error_ends_listening(tmp_path):
    win, ear = floating(tmp_path, FakeClient([]))
    ear.on_wake()
    assert pump(win, lambda: win.mind.activity == "listening")
    ear.on_error("Voice input stopped: device unplugged")
    assert pump(win, lambda: win.mind.activity == "idle")
    assert "unplugged" in win.bubble.toPlainText()


def test_a_long_question_is_shown_in_full_and_scrolls(tmp_path):
    from PySide6.QtGui import QGuiApplication

    win, _ = floating(tmp_path, FakeClient([RunEnded("completed", "ok")]))
    question = " ".join(f"word{i}" for i in range(400))
    win.ask(question)
    assert win.heard.toPlainText() == question  # nothing cut
    assert pump(win, lambda: not win.busy)
    pump(win, lambda: False, timeout=0.2)
    assert win.heard.height() <= robo_app.HEARD_PX  # it scrolls instead of growing forever
    screen = QGuiApplication.primaryScreen().availableGeometry()
    assert win.height() <= screen.height()


def test_click_while_answering_interrupts_and_listens(tmp_path):
    from PySide6.QtTest import QTest

    gate = threading.Event()
    client = FakeClient([Delta("long"), "WAIT", RunEnded("cancelled")], gate=gate)
    win, ear = floating(tmp_path, client)
    win.ask("story")
    assert pump(win, lambda: win.mind.activity == "talking")
    QTest.mouseClick(win.face, Qt.MouseButton.LeftButton)
    assert pump(win, lambda: client.stopped == ["run_1"]) and ear.now == 1
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_bubble_fits_its_content_exactly(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win._say("line\n\n" * 3)
    assert pump(win, lambda: not win.panel.isHidden())
    pump(win, lambda: False, timeout=0.2)
    panel = win.panel.geometry()
    assert win.bubble.geometry().bottom() <= panel.height()
    assert win.height() - panel.height() - win.face.height() < 40  # no blank band


def test_a_huge_approval_is_shortened_so_the_buttons_stay_on_screen(tmp_path):
    gate = threading.Event()
    client = FakeClient([ApprovalNeeded("run: " + "x" * 5000), "WAIT", RunEnded("cancelled")],
                        gate=gate)
    win, _ = floating(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.approval.isVisibleTo(win))
    assert len(win.approval_text.text()) < 400
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_a_face_press_ends_a_compositor_drag(tmp_path):
    from PySide6.QtTest import QTest

    win, _ = floating(tmp_path, FakeClient([]))
    win.moving = True
    QTest.mousePress(win.face, Qt.MouseButton.LeftButton)
    assert not win.moving
    QTest.mouseRelease(win.face, Qt.MouseButton.LeftButton)


def test_desktop_control_needs_no_prompt_but_irreversible_steps_do(tmp_path):
    gate = threading.Event()
    client = FakeClient([ApprovalNeeded("Allow computer_use to perform `click`?", desktop=True),
                         ApprovalNeeded("Allow computer_use to perform `type`?", desktop=True),
                         ApprovalNeeded("recursive delete: rm -rf ~/x"), "WAIT",
                         RunEnded("completed", "ok")], gate=gate)
    win, _ = floating(tmp_path, client)
    win.ask("open the calculator and compute 12*7")
    assert pump(win, lambda: win.approval.isVisibleTo(win))  # only the delete asks
    assert client.approved == [("run_1", "session"), ("run_1", "session")]
    assert "rm -rf" in win.approval_text.text()
    win.allow.click()
    assert pump(win, lambda: client.approved[-1] == ("run_1", "once"))
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_after_an_answer_robo_listens_for_a_reply_without_its_name(tmp_path):
    client = FakeClient([RunEnded("completed", "It's 3 pm.")])
    win, ear = floating(tmp_path, client)
    win.ask("what time is it")
    assert pump(win, lambda: not win.busy)
    assert ear.follow == robo_app.FOLLOW_UP_S


def test_a_failed_answer_opens_no_follow_up(tmp_path):
    win, ear = floating(tmp_path, FakeClient([RunEnded("failed", error="offline")]))
    win.ask("x")
    assert pump(win, lambda: not win.busy)
    assert ear.follow == 0


def test_an_approval_gets_its_own_room_in_the_bubble(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win.busy = True
    win._open()
    win._on_event(Delta("**Today**\n- a\n- b\n- c"))
    pump(win, lambda: False, timeout=0.3)
    before = win.height()
    win._on_event(ApprovalNeeded("Robo wants to run: rm x"))
    pump(win, lambda: False, timeout=0.3)
    assert win.height() >= before + win.approval.height()  # the window grew, nothing squeezed
    assert win.bubble.geometry().bottom() < win.approval.geometry().top()
    win._approve("deny")
    pump(win, lambda: False, timeout=0.3)
    assert win.height() == before


class FakeWatcher:
    def __init__(self):
        self.started = self.stopped = False
        self.paused = False

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def pause(self, paused=True):
        self.paused = paused


def test_the_menu_pauses_and_resumes_watching_and_remembers_it(tmp_path, monkeypatch):
    monkeypatch.setattr(robo_app, "WATCH_PAUSED", tmp_path / "watch.paused")
    watcher = FakeWatcher()
    win, _ = floating(tmp_path, FakeClient([]), watcher=watcher)
    assert watcher.started and not watcher.paused
    button = next(b for b in win.menu.findChildren(robo_app.QPushButton) if "Watch" in b.text())
    button.click()
    assert watcher.paused and (tmp_path / "watch.paused").exists()
    win.close()
    assert watcher.stopped
    again = FakeWatcher()
    floating(tmp_path / "2", FakeClient([]), watcher=again)
    assert again.paused  # still paused after a restart


@pytest.mark.parametrize("held", [False, True])
def test_every_menu_button_fits_whole_inside_the_bubble(tmp_path, monkeypatch, held):
    monkeypatch.setattr(robo_app, "WATCH_PAUSED", tmp_path / "watch.paused")
    watcher = FakeWatcher()
    win, _ = floating(tmp_path, FakeClient([]), watcher=watcher)
    if held:  # the longest labels: "Wander" and the resume glyph
        watcher.pause(True)
        win._toggle_stay()
    win._show_menu()
    pump(win, lambda: False, timeout=0.2)
    buttons = win.menu.findChildren(robo_app.QPushButton)
    assert len(buttons) == 6 and all(b.isVisibleTo(win) for b in buttons)
    assert ("Wander" in win.stay.text()) == held and ("▶" in win.watch.text()) == held
    for b in buttons:
        assert win.menu.rect().contains(b.geometry()), b.text()  # not pushed out of the bubble
        assert b.width() >= b.sizeHint().width(), b.text()  # and its label is not clipped
    assert win.panel.rect().contains(win.menu.geometry())


def test_the_menu_on_a_fresh_robo_is_just_the_menu(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win._show_menu()  # before any text exists to size the two text boxes
    pump(win, lambda: False, timeout=0.2)
    assert not win.heard.isVisibleTo(win) and not win.bubble.isVisibleTo(win)  # no empty bands
    frame = sum(hud.MARGINS[1::2])  # the card's glow, header and tail around its content
    assert win.panel.height() - win.menu.height() < frame + 12  # the buttons and a little padding


def test_thinking_shows_typing_dots_until_the_reply_starts(tmp_path):
    gate = threading.Event()
    client = FakeClient(["WAIT", Delta("Hello"), "WAIT", RunEnded("completed", "Hello")], gate=gate)
    win, _ = floating(tmp_path, client)
    win.ask("hi")
    assert pump(win, lambda: win.typing.isVisibleTo(win))  # Messenger-style "..." while thinking
    assert win.status.text() == ""
    gate.set()
    assert pump(win, lambda: "Hello" in win.bubble.toPlainText())
    assert pump(win, lambda: not win.typing.isVisibleTo(win))  # the reply replaces the dots
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_typing_dots_bounce():
    from robo.app import TypingDots

    a, b = TypingDots.offsets(0.0), TypingDots.offsets(0.2)
    assert len(a) == 3 and a != b and max(map(abs, a)) <= TypingDots.HOP


def test_a_dead_listener_leaves_the_click_to_the_typing_dialog(tmp_path):
    from PySide6.QtTest import QTest

    win, ear = floating(tmp_path, FakeClient([]))
    ear.running = False  # its thread died after it started
    typed = []
    win._type = lambda: typed.append(1)
    QTest.mouseClick(win.face, Qt.MouseButton.LeftButton)
    assert typed == [1] and ear.now == 0  # no "listening" nobody will end
    assert win.mind.activity != "listening"


def test_the_status_row_takes_no_room_unless_dots_or_a_label_show(tmp_path):
    gate = threading.Event()
    client = FakeClient(["WAIT", Delta("Hello"), "WAIT", RunEnded("completed", "Hello")], gate=gate)
    win, ear = floating(tmp_path, client)
    win.ask("hi")
    assert pump(win, lambda: win.typing.isVisibleTo(win))
    assert win.status_row.isVisibleTo(win)  # the dots live here
    gate.set()
    assert pump(win, lambda: "Hello" in win.bubble.toPlainText())
    assert pump(win, lambda: not win.status_row.isVisibleTo(win))
    pump(win, lambda: False, timeout=0.2)
    gap = win.bubble.geometry().top() - win.quote.geometry().bottom() - 1
    assert gap == win.panel.layout().spacing()  # nothing but the panel's own spacing
    gate.set()
    assert pump(win, lambda: not win.busy)
    ear.on_wake()
    assert pump(win, lambda: win.mind.activity == "listening")
    assert win.status_row.isVisibleTo(win) and not win.typing.isVisibleTo(win)  # the label alone


def test_the_reply_is_styled_as_markdown_however_it_gets_into_the_bubble(tmp_path, monkeypatch):
    # RunEnded without ask() leaves started_at at 0: every file in ~/Robo would count as made.
    monkeypatch.setattr(robo_app, "OUTPUT_DIR", tmp_path / "Robo")
    monkeypatch.setattr(robo_app, "open_file", lambda path: pytest.fail(f"opened {path}"))
    win, _ = floating(tmp_path, FakeClient([]))
    first = lambda: win.bubble.document().begin().blockFormat()  # noqa: E731
    win._on_event(Delta("one\n\ntwo"))  # streamed
    assert first().bottomMargin() == widgets.GAP
    win.busy = True
    win._on_event(RunEnded("completed", output="three\n\nfour `x`"))  # the final text
    assert win.bubble.toPlainText().startswith("three") and first().bottomMargin() == widgets.GAP
    win._say("five\n\nsix")  # a local message
    assert win.bubble.toPlainText().startswith("five") and first().bottomMargin() == widgets.GAP


def test_the_bubble_still_fits_a_styled_reply_exactly(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win._say("## Plan\n\n- read `ch. 4`\n- do the set\n\n```\nx = 1\ny = 2\n```\n\nSee [notes](https://x.y).")
    win.heard.setPlainText("plan my week")  # _say clears it
    assert pump(win, lambda: win.bubble.height() > 0 and win.heard.height() > 0)
    pump(win, lambda: False, timeout=0.2)
    assert win.bubble.verticalScrollBar().maximum() == 0  # all of it shows, nothing scrolls
    for box in (win.bubble, win.heard):  # and nothing but a rounding margin is left over
        assert box.height() - box.document().size().height() <= 3


def test_allow_is_the_accent_button_and_deny_the_quiet_one(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win._on_event(ApprovalNeeded("rm x"))
    assert pump(win, lambda: win.approval.isVisibleTo(win))
    pump(win, lambda: False, timeout=0.2)

    def fill(button):
        return button.grab().toImage().pixelColor(8, button.height() // 2)

    allow, deny = fill(win.allow), fill(win.deny)
    assert allow.alpha() == 255 and allow.saturation() > 150  # a solid colour
    assert deny.alpha() < 255 or deny.saturation() < 100  # no fill: it recedes into the panel


def test_what_robo_made_opens_by_itself(tmp_path, monkeypatch):
    out = tmp_path / "Robo"
    out.mkdir()
    (out / "old-notes.html").write_text("old")  # made before this request: not reopened
    opened = []
    monkeypatch.setattr(robo_app, "OUTPUT_DIR", out)
    monkeypatch.setattr(robo_app, "open_file", opened.append)

    class Maker(FakeClient):
        def ask(self, text, session_id, started=None):
            (out / "diagram.html").write_text("<svg/>")
            yield from super().ask(text, session_id, started)

    client = Maker([RunEnded("completed", "Here is your diagram.")])
    time.sleep(0.02)
    win, _ = floating(tmp_path, client)
    win.ask("draw a diagram of the water cycle")
    assert pump(win, lambda: not win.busy)
    assert opened == [out / "diagram.html"]
    assert "diagram.html" in win.footer.text()


def test_a_failed_request_opens_nothing(tmp_path, monkeypatch):
    out = tmp_path / "Robo"
    out.mkdir()
    opened = []
    monkeypatch.setattr(robo_app, "OUTPUT_DIR", out)
    monkeypatch.setattr(robo_app, "open_file", opened.append)

    class Maker(FakeClient):
        def ask(self, text, session_id, started=None):
            (out / "half.html").write_text("x")
            yield from super().ask(text, session_id, started)

    win, _ = floating(tmp_path, Maker([RunEnded("failed", error="boom")]))
    win.ask("x")
    assert pump(win, lambda: not win.busy)
    assert opened == []


class Writer(FakeClient):
    """Writes files (path -> text) while it works, like Hermes does; later ones are newer."""

    def __init__(self, files, script):
        super().__init__(script)
        self.files = files

    def ask(self, text, session_id, started=None):
        now = time.time()
        for i, (path, body) in enumerate(self.files.items()):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
            os.utime(path, (now + i, now + i))
        yield from super().ask(text, session_id, started)


@pytest.fixture
def opened(tmp_path, monkeypatch):
    """robo's folders under tmp_path, and what got opened: `.files` and `.notes` (path, front)."""
    box = SimpleNamespace(out=tmp_path / "Robo", vault=tmp_path / "Vault", files=[], notes=[])
    monkeypatch.setattr(robo_app, "OUTPUT_DIR", box.out)
    monkeypatch.setattr(robo_app, "VAULT", box.vault)
    monkeypatch.setattr(robo_app, "open_file", box.files.append)
    monkeypatch.setattr(robo_app, "open_note",
                        lambda path, front=True: box.notes.append((path, front)))
    return box


def request(tmp_path, client, text="write me an email"):
    win, _ = floating(tmp_path, client)
    win.ask(text)
    assert pump(win, lambda: not win.busy)
    return win


def test_a_note_robo_wrote_opens_in_obsidian_and_the_bubble_says_so(tmp_path, opened):
    old = opened.vault / "Notes" / "old.md"  # made before this request: not reopened
    old.parent.mkdir(parents=True)
    old.write_text("old")
    os.utime(old, (1, 1))
    note = opened.vault / "Drafts" / "Email to Prof Lee.md"
    win = request(tmp_path, Writer({note: "Hi"}, [RunEnded("completed", "It is in Obsidian.")]))
    assert opened.notes == [(note, True)] and opened.files == []
    shown, footer = win.bubble.toPlainText(), win.footer.text()
    assert "It is in Obsidian." in shown and "📓 In Obsidian: Email to Prof Lee" in footer
    assert "📂" not in footer and "📓" not in shown and not win.footer.isHidden()


def test_the_automatic_digests_note_opens_behind_what_you_are_doing(tmp_path, opened):
    note = opened.vault / "Notes" / "School digest.md"
    win, _ = floating(tmp_path, Writer({note: "x"}, [RunEnded("completed", "Digest ready.")]))
    win.clock = DigestClock(tmp_path / "fresh.json")  # nothing yet today: the digest is due
    win._maybe_digest()  # what start-up and a wake from sleep run
    assert pump(win, lambda: not win.busy)
    assert opened.notes == [(note, False)]
    win.ask("and the plan?")  # a request of your own opens in front again
    assert pump(win, lambda: not win.busy)
    assert opened.notes == [(note, False), (note, True)]


def test_a_digest_you_ask_for_opens_in_front(tmp_path, opened):
    note = opened.vault / "Notes" / "School digest.md"
    win, _ = floating(tmp_path, Writer({note: "x"}, [RunEnded("completed", "Digest ready.")]))
    win.ask(robo_app.DIGEST_PROMPT)  # the right-click 📚 Digest button
    assert pump(win, lambda: not win.busy)
    assert opened.notes == [(note, True)]


def test_notes_and_pages_share_the_open_limit_notes_first(tmp_path, opened):
    names = [opened.out / "a.html", opened.out / "b.html", opened.out / "c.html",
             opened.vault / "Notes" / "n1.md", opened.vault / "Plans" / "n2.md"]
    win = request(tmp_path, Writer(dict.fromkeys(names, "x"), [RunEnded("completed", "Made.")]))
    n1, n2 = names[3:]
    assert robo_app.OPEN_MAX == 3
    assert opened.notes == [(n2, True), (n1, True)]  # newest first
    assert opened.files == [names[2]]  # what is left of the limit
    assert "📓 In Obsidian: n2, n1" in win.footer.text() and "📂 Opened c.html" in win.footer.text()


def test_a_full_limit_of_notes_leaves_no_room_for_a_page(tmp_path, opened):
    notes = [opened.vault / "Notes" / f"n{i}.md" for i in range(4)]
    page = opened.out / "page.html"
    win = request(tmp_path, Writer(dict.fromkeys([page, *notes], "x"),
                                   [RunEnded("completed", "Made.")]))
    assert robo_app.OPEN_MAX == 3
    assert [path for path, _ in opened.notes] == [notes[3], notes[2], notes[1]]  # newest three
    assert opened.files == []
    assert "📂" not in win.footer.text()


def test_a_page_in_the_output_folder_still_opens_as_a_file(tmp_path, opened):
    page = opened.out / "diagram.html"
    win = request(tmp_path, Writer({page: "<svg/>"}, [RunEnded("completed", "Here you go.")]))
    assert opened.files == [page] and opened.notes == []
    assert "📂 Opened diagram.html" in win.footer.text()
    assert "Obsidian" not in win.footer.text()


def test_only_notes_in_the_three_folders_open(tmp_path, opened):
    stray = [opened.vault / ".obsidian" / "plugins" / "readme.md",  # Obsidian's own folder
             opened.vault / "loose.md",  # not in Drafts, Plans or Notes
             opened.vault / "Notes" / "data.json"]  # not a note
    win = request(tmp_path, Writer(dict.fromkeys(stray, "x"), [RunEnded("completed", "Done.")]))
    assert opened.notes == [] and opened.files == []
    assert "Obsidian" not in win.footer.text() and win.footer.isHidden()


def test_a_failed_request_opens_no_note(tmp_path, opened):
    note = opened.vault / "Notes" / "half.md"
    request(tmp_path, Writer({note: "x"}, [RunEnded("failed", error="boom")]))
    assert opened.notes == []


def test_floating_face_stays_shown_while_another_app_is_active(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    assert win.testAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow)


def test_open_file_uses_the_os_opener(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(robo_app.subprocess, "Popen", lambda argv, **kw: calls.append(argv))
    for platform in ("linux", "darwin"):
        monkeypatch.setattr(robo_app.sys, "platform", platform)
        REAL_OPEN_FILE(tmp_path / "a.html")
    assert calls == [["xdg-open", str(tmp_path / "a.html")], ["open", str(tmp_path / "a.html")]]


# --- alive: the eyes follow the pointer, and a bored robo fidgets -----------------------------


class FakeCursor:
    """Stands in for QCursor: `pos()` is wherever the test put the pointer."""

    at = QPoint(0, 0)

    @classmethod
    def pos(cls):
        return cls.at


def test_the_eyes_follow_a_moving_pointer_then_forget_a_still_one(tmp_path, monkeypatch):
    monkeypatch.setattr(robo_app, "QCursor", FakeCursor)
    win, _ = floating(tmp_path, FakeClient([]))
    face = win.face.mapToGlobal(win.face.rect().center())
    FakeCursor.at = QPoint(face.x() + 600, face.y())  # far to the right
    win._tick()
    assert win.face.look and win.face.look[0] > 0.5  # it moved, so robo looks
    win.cursor_moved -= 60  # ...but a pointer that stopped long ago is old news
    win._tick()
    assert win.face.look is None or win.face.look[1] == 0 and abs(win.face.look[0]) < 1


def test_the_eyes_lead_the_way_while_it_walks(tmp_path, monkeypatch):
    monkeypatch.setattr(robo_app, "QCursor", FakeCursor)
    win, _ = floating(tmp_path, FakeClient([]))
    win._tick()
    win.cursor_moved -= 60
    win.roamer.mode, win.roamer.goal = "drift", (win.roamer.pos[0] - 500, win.roamer.pos[1])
    win._tick()
    assert win.face.look and win.face.look[0] < 0


def test_a_bored_robo_now_and_then_shows_a_mood(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win.fidget_at = 0.0
    win._tick()
    assert win.mind.emotion in robo_app.FIDGETS
    assert win.fidget_at > time.monotonic() + 30  # and it is a while until the next one


def test_a_busy_or_talked_to_robo_does_not_fidget(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win.busy = True
    win.fidget_at = 0.0
    win._tick()
    assert win.mind.emotion == "neutral"
    win.busy = False
    win.fidget_at = 0.0
    win._open()  # the bubble is up: the user is reading
    win._tick()
    assert win.mind.emotion == "neutral"


def test_the_first_message_into_a_fresh_robo_is_not_clipped(tmp_path):
    """The boxes start hidden; their first text must be measured at the width they will have."""
    win, _ = floating(tmp_path, FakeClient([]))
    err = "Hermes is not running (connection refused); start it with `hermes gateway start`."
    win._on_event(RunEnded("failed", error=err))
    pump(win, lambda: False, 0.5)
    assert not win.bubble.isHidden()
    assert win.bubble.verticalScrollBar().maximum() == 0  # nothing hides behind a scrollbar
    assert win.bubble.height() >= win.bubble.document().size().height()
