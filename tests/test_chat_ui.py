"""The chat card as a whole: letters typed at a real speed, the card, header lights, themes and
their persistence. Offscreen, a fake Hermes, a temporary theme.json (tests/conftest.py)."""

import json
import os
import threading
import time
from dataclasses import replace
from types import SimpleNamespace

import numpy as np
import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QPoint, Qt  # noqa: E402
from PySide6.QtGui import QImage, QRegion  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QWidget  # noqa: E402
from test_app import (  # noqa: E402
    FakeClient,
    FakeListener,
    FakeWatcher,
    Writer,
    floating,
    pump,
    window,
)

from robo import app as robo_app  # noqa: E402
from robo import hud  # noqa: E402
from robo import theme as themes  # noqa: E402
from robo.brain import BrainError  # noqa: E402
from robo.events import Delta, Feeling, RunEnded, ToolStarted  # noqa: E402
from robo.wake import DigestClock  # noqa: E402
from robo.widgets import BUBBLE_W  # noqa: E402

HELLO = "Hello there, this is a short reply."
LONG = " ".join(f"word{i}" for i in range(45))  # about 250 characters: a few seconds to type
LINK = "[notes](https://example.invalid/x) and then a long tail of words " + LONG


def at_speed(cps: float, **tokens) -> None:
    """The theme.json of the next window: typing at `cps` characters per second (0 = at once)."""
    themes.CONFIG.write_text(json.dumps({"tokens": {"cps": cps, **tokens}}))


def reply_window(tmp_path, text, cps=55.0, **kw):
    """A floating window whose Hermes sends `text` in one delta and finishes."""
    at_speed(cps)
    return floating(tmp_path, FakeClient([Delta(text), RunEnded("completed", text)]), **kw)


def shot(w: QWidget) -> np.ndarray:
    """What `w` paints with its children, on a transparent ground (no window colour behind)."""
    img = QImage(w.size(), QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    w.render(img, QPoint(), QRegion(), QWidget.RenderFlag.DrawChildren)
    img = img.convertToFormat(QImage.Format.Format_RGBA8888)
    return np.frombuffer(img.constBits(), np.uint8).reshape(img.height(), img.width(), 4)


def settle(win) -> None:
    pump(win, lambda: False, timeout=0.3)


@pytest.fixture
def opened(tmp_path, monkeypatch):
    """A vault under tmp_path (notes robo writes there get "opened": nothing real happens)."""
    box = SimpleNamespace(vault=tmp_path / "Vault")
    monkeypatch.setattr(robo_app, "VAULT", box.vault)
    monkeypatch.setattr(robo_app, "open_note", lambda path, front=True: None)
    return box


# --- the typing -------------------------------------------------------------------------------


def test_the_reply_types_at_the_theme_speed_and_never_runs_ahead_of_hermes(tmp_path):
    at_speed(55)
    gate = threading.Event()
    client = FakeClient([Delta("Hello there, "), "WAIT", Delta("this is a short reply."),
                         RunEnded("completed", HELLO)], gate=gate)
    win, _ = floating(tmp_path, client)
    assert win.tw.pace.cps == 55
    win.ask("hi")
    seen, talked = [], []

    def sample() -> bool:
        seen.append((win.bubble.toPlainText(), win.tw.k, win.reply))
        talked.append(win.face.talking)
        assert win.close_at == 0.0  # a reply is never closed under the reader
        return win.tw.k >= len("Hello there, ") and not win.tw.pending

    assert pump(win, sample)  # it caught up with what Hermes has sent so far
    pump(win, lambda: False, timeout=0.2)
    assert win.mind.talking is False and win.face.talking is False  # the mouth closed to wait
    gate.set()
    assert pump(win, lambda: win.typed)
    shown = [text for text, _, _ in seen]
    assert len(shown) > 5 and shown[0] != shown[-1]  # it was typed, not shown at once
    for (before, _, _), (after, _, _) in zip(seen, seen[1:], strict=False):
        assert after.startswith(before.rstrip())  # the text only grows
    assert all(k <= len(reply) for _, k, reply in seen)  # never past what Hermes sent
    assert any(talked)  # the mouth moved while letters appeared
    assert win.bubble.toPlainText() == HELLO
    assert pump(win, lambda: not win.face.talking)
    now = time.monotonic()
    assert now + robo_app.CLOSE_AFTER - 3 < win.close_at < now + robo_app.CLOSE_AFTER + 1


def test_the_first_letters_show_at_once_and_the_rest_of_the_word_is_invisible(tmp_path):
    at_speed(55)
    win, _ = floating(tmp_path, FakeClient([]))
    win._feed("Hello wonderful world")  # one step: only the first letters are due
    doc = win.bubble.document()
    assert 0 < win.tw.k < len("Hello")
    fragments = [(f.text(), f.charFormat().foreground().color().alpha())
                 for f in iter_fragments(doc)]
    assert fragments[-1][1] == 0  # the rest of the word is laid out, painted transparent
    assert fragments[0][1] == 255 or fragments[0][0] == ""  # what shows is opaque
    assert doc.toPlainText().startswith("Hello")  # so a word that won't fit wraps early


def iter_fragments(doc):
    block = doc.begin()
    while block.isValid():
        it = block.begin()
        while not it.atEnd():
            yield it.fragment()
            it += 1
        block = block.next()


def test_a_click_on_the_reply_shows_the_rest(tmp_path):
    win, _ = reply_window(tmp_path, LONG)
    win.ask("go")
    assert pump(win, lambda: win.tw.k > 5)
    assert win.tw.pending and win.close_at == 0.0
    QTest.mouseClick(win.bubble.viewport(), Qt.MouseButton.LeftButton, pos=QPoint(40, 6))
    assert win.tw.skipped and not win.tw.pending
    assert pump(win, lambda: win.typed, timeout=1.0)  # no waiting for the typing
    assert win.bubble.toPlainText() == LONG and not win.revealer.isActive()
    assert win.close_at > time.monotonic() + robo_app.CLOSE_AFTER - 3


def test_a_click_on_a_link_or_a_drag_over_the_text_does_not_skip(tmp_path):
    win, _ = reply_window(tmp_path, LINK)
    win.bubble.setOpenExternalLinks(False)  # a click must never open a real browser
    win.bubble.setOpenLinks(False)
    win.ask("go")
    assert pump(win, lambda: win.tw.k > 12)
    cursor = win.bubble.textCursor()
    cursor.setPosition(2)
    spot = win.bubble.cursorRect(cursor).center() + QPoint(3, 0)  # on the letters of the link
    assert win.bubble.anchorAt(spot)  # that is the link
    viewport = win.bubble.viewport()
    QTest.mouseClick(viewport, Qt.MouseButton.LeftButton, pos=spot)
    assert not win.tw.skipped
    QTest.mousePress(viewport, Qt.MouseButton.LeftButton, pos=QPoint(150, 8))
    QTest.mouseRelease(viewport, Qt.MouseButton.LeftButton, pos=QPoint(250, 8))
    assert not win.tw.skipped  # a selection, not a click
    QTest.mouseClick(viewport, Qt.MouseButton.RightButton, pos=QPoint(150, 8))
    assert not win.tw.skipped  # only the left button


def test_escape_shows_the_rest_first_and_the_next_one_closes(tmp_path):
    win, _ = reply_window(tmp_path, LONG)
    win.ask("go")
    assert pump(win, lambda: not win.busy and win.tw.k > 5)  # Hermes is done, the letters are not
    assert win.tw.pending
    win._escape()
    assert win.bubble.toPlainText() == LONG and not win.panel.isHidden()
    assert win.typed
    win._escape()
    assert win.panel.isHidden() and win.close_at == 0.0


def test_escape_while_hermes_runs_stops_the_run_and_leaves_the_typing(tmp_path):
    at_speed(55)
    gate = threading.Event()
    client = FakeClient([Delta(LONG), "WAIT", RunEnded("cancelled")], gate=gate)
    win, _ = floating(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.tw.k > 5)
    win._escape()
    assert pump(win, lambda: client.stopped == ["run_1"])
    assert not win.tw.skipped
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_skipping_while_hermes_still_streams_shows_what_arrives_at_once(tmp_path):
    at_speed(55)
    gate = threading.Event()
    client = FakeClient([Delta(LONG[:200]), "WAIT", Delta(LONG[200:]), "WAIT",
                         RunEnded("completed", LONG)], gate=gate)
    win, _ = floating(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.tw.k > 5)
    win._skip()
    assert win.tw.skipped and not win.typed  # Hermes has not finished
    assert win.bubble.toPlainText() == LONG[:200].rstrip()
    gate.set()
    assert pump(win, lambda: len(win.bubble.toPlainText()) == len(LONG))
    gate.set()
    assert pump(win, lambda: win.typed)


def test_a_final_text_that_differs_from_the_stream_is_retyped_from_the_first_difference(tmp_path):
    at_speed(400)
    client = FakeClient([Delta("Helo wor"), RunEnded("completed", "Hello world, all done.")])
    win, _ = floating(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.typed)
    assert win.bubble.toPlainText() == "Hello world, all done."  # not a garbled mix
    assert win.tw.text == "Hello world, all done."


def test_a_local_message_is_typed_and_closes_eight_seconds_after_the_last_letter(tmp_path):
    at_speed(55)
    win, _ = floating(tmp_path, FakeClient([]))
    win._say("Sorry, I didn't catch that.")
    assert win.tw.pending and win.close_at == 0.0 and not win.heard.toPlainText()
    assert not win.quote.isVisibleTo(win)
    assert pump(win, lambda: win.typed)
    assert win.bubble.toPlainText() == "Sorry, I didn't catch that."
    assert time.monotonic() + 8 - 2 < win.close_at <= time.monotonic() + 8


def test_a_new_question_mid_typing_clears_everything_of_the_old_reply(tmp_path, opened):
    at_speed(55)
    note = opened.vault / "Notes" / "A note.md"
    client = Writer({note: "x"}, [Delta(LONG), RunEnded("completed", LONG)])
    win, _ = floating(tmp_path, client)
    win.ask("first")
    assert pump(win, lambda: not win.busy and win.tw.k > 5)
    assert win.tw.pending and win.footer.text() and win.footer.isHidden()
    gate = threading.Event()
    client.script = [ToolStarted("web_search"), "WAIT", RunEnded("completed", "ok")]
    client.gate = gate
    win.ask("second")  # asked while the first answer is still on screen
    assert win.tw.text == "" and not win.revealer.isActive() and win.close_at == 0.0
    assert win.bubble.toPlainText() == "" and win.footer.text() == "" and win.footer.isHidden()
    assert win.heard.toPlainText() == "second" and not win.quote.tag.isHidden()  # a follow-up
    assert not win.caret.isVisible()
    gate.set()
    assert pump(win, lambda: not win.busy)


def test_speaking_over_a_typing_answer_clears_it_and_the_mic_light_follows(tmp_path):
    win, ear = reply_window(tmp_path, LONG)
    win.ask("go")
    assert pump(win, lambda: not win.busy and win.tw.k > 5)
    ear.on_wake()
    assert pump(win, lambda: win.mind.activity == "listening")
    assert win.tw.text == "" and not win.revealer.isActive() and win.bubble.toPlainText() == ""
    assert win.heard.toPlainText() == "" and not win.quote.isVisibleTo(win)
    assert win.panel.header.mic.label == "LISTENING"


def test_the_footer_shows_when_the_typing_is_done_and_is_not_part_of_the_markdown(tmp_path, opened):
    at_speed(40)
    note = opened.vault / "Drafts" / "Email to Prof Lee.md"
    reply = "It is **in Obsidian** now."
    win, _ = floating(tmp_path, Writer({note: "Hi"}, [Delta(reply), RunEnded("completed", reply)]))
    win.ask("write me an email")
    assert pump(win, lambda: not win.busy)
    assert win.footer.isHidden() and win.tw.pending  # still typing: no footer yet
    assert win.footer.text() == "📓 In Obsidian: Email to Prof Lee"
    assert pump(win, lambda: win.typed)
    assert not win.footer.isHidden() and win.footer.isVisibleTo(win)
    assert win.bubble.toPlainText() == "It is in Obsidian now."
    assert "📓" not in win.bubble.toPlainText() and "📓" not in win.tw.text


def test_a_local_note_during_a_run_leaves_the_footer_and_the_auto_close_working(tmp_path, opened):
    at_speed(200)
    gate = threading.Event()
    note = opened.vault / "Drafts" / "Email to Prof Lee.md"
    reply = "It is in Obsidian now."
    client = Writer({note: "Hi"}, [Delta("It is "), "WAIT", Delta("in Obsidian now."),
                                   RunEnded("completed", reply)])
    client.gate = gate
    win, ear = floating(tmp_path, client)
    win.ask("write me an email")
    assert pump(win, lambda: win.tw.k > 2)
    ear.on_error("The microphone stopped.")  # a local note while Hermes is still streaming
    assert pump(win, lambda: win.bubble.toPlainText() == "The microphone stopped.")
    assert pump(win, lambda: not win.tw.pending)
    assert win.busy and win.close_at == 0.0
    gate.set()
    assert pump(win, lambda: not win.busy and win.tw.text == reply and not win.tw.pending)
    assert pump(win, lambda: win.typed)
    assert win.bubble.toPlainText() == reply
    assert not win.footer.isHidden() and win.footer.text() == "📓 In Obsidian: Email to Prof Lee"
    assert win.close_at > time.monotonic() + robo_app.CLOSE_AFTER - 3  # it closes by itself


def test_the_caret_shows_while_typing_blinks_when_waiting_and_goes_a_moment_after_the_end(tmp_path):
    at_speed(55)
    gate = threading.Event()
    client = FakeClient([Delta("Friday has the **lab"), "WAIT", Delta(" report** due."),
                         RunEnded("completed", "Friday has the **lab report** due.")], gate=gate)
    win, _ = floating(tmp_path, client)
    win.ask("go")
    assert pump(win, lambda: win.tw.k > 4 and not win.caret.isHidden())
    assert win.caret.geometry().intersects(win.bubble.viewport().rect())
    assert pump(win, lambda: not win.tw.pending)  # caught up: waiting for Hermes
    seen = set()
    pump(win, lambda: seen.add(win.caret.on) or {True, False} <= seen, timeout=3)
    assert {True, False} <= seen  # it blinks
    gate.set()
    assert pump(win, lambda: win.typed)
    assert not win.caret.isHidden()
    win.typed_at -= robo_app.CARET_S + 1  # a while after the last letter
    win._show()
    assert win.caret.isHidden()


def test_instant_typing_has_no_caret_and_no_timer(tmp_path):
    win, _ = reply_window(tmp_path, LONG, cps=0)
    win.ask("go")
    assert pump(win, lambda: win.typed)
    assert win.bubble.toPlainText() == LONG and win.caret.isHidden()
    assert not win.revealer.isActive()


def test_a_long_reply_follows_the_caret_unless_the_reader_scrolled_up(tmp_path):
    long = "\n\n".join(f"Paragraph {i} with a few words in it." for i in range(24))
    win, _ = reply_window(tmp_path, long, cps=400)
    win.ask("go")
    bar = win.bubble.verticalScrollBar()
    assert pump(win, lambda: bar.maximum() > 40)
    assert bar.value() >= bar.maximum() - 4  # follows the last letter
    assert win.bubble.height() == robo_app.TEXT_MAX
    mid = bar.maximum() // 2
    bar.setValue(mid)  # the reader goes back, not to the very top: setMarkdown resets to 0
    pump(win, lambda: False, timeout=0.4)
    assert bar.value() == mid and bar.maximum() > 2 * mid  # still reading the same lines
    assert win.bubble.viewport().rect().contains(win.caret.geometry())  # kept inside the box
    assert pump(win, lambda: win.typed)
    assert bar.value() == mid


def test_an_error_keeps_its_sad_face_while_its_text_types(tmp_path):
    at_speed(55)
    err = "Hermes is not running (connection refused); start it."
    win, _ = floating(tmp_path, FakeClient([RunEnded("failed", error=err)]))
    win.ask("go")
    assert pump(win, lambda: win.tw.k > 3)
    assert win.mind.activity == "error" and win.face.activity == "error"  # not "talking"
    assert pump(win, lambda: win.typed)
    assert win.bubble.toPlainText() == err


def test_the_face_keeps_the_talking_pose_while_letters_are_still_due(tmp_path):
    win, _ = reply_window(tmp_path, LONG)
    win.ask("go")
    assert pump(win, lambda: not win.busy and win.tw.pending)
    assert win.mind.activity == "idle" and win.face.activity == "talking"  # RunEnded made it idle
    assert pump(win, lambda: win.typed, timeout=15)
    pump(win, lambda: win.face.activity == "idle")


# --- the card, the quote and the follow-up ---------------------------------------------------


def test_the_quote_shows_what_you_said_without_a_prefix_and_hides_for_the_digest(tmp_path):
    win, _ = floating(tmp_path, FakeClient([RunEnded("completed", "ok")]))
    win.ask("what's due?")
    assert pump(win, lambda: not win.busy)
    settle(win)
    assert win.heard.toPlainText() == "what's due?" and win.quote.isVisibleTo(win)
    assert win.quote.tag.isHidden()  # the first question is no follow-up
    win.ask(robo_app.DIGEST_PROMPT)
    assert pump(win, lambda: not win.busy)
    settle(win)
    assert not win.quote.isVisibleTo(win) and win.heard.toPlainText() == ""


def test_a_question_while_the_answer_is_up_or_just_was_is_marked_as_a_follow_up(tmp_path):
    client = FakeClient([RunEnded("completed", "It's 3 pm.")])
    win, _ = floating(tmp_path, client)
    win.ask("what time is it")
    assert pump(win, lambda: not win.busy)
    win.ask("and in Tokyo?")  # the answer is on screen
    assert not win.quote.tag.isHidden() and win.quote.tag.text() == "↳ FOLLOW-UP"
    assert pump(win, lambda: not win.busy)
    win._close_bubble()
    win.answered_at = time.monotonic() - robo_app.FOLLOW_UP_S - 1  # long ago, bubble gone
    win.ask("what about London?")
    assert win.quote.tag.isHidden()
    assert pump(win, lambda: not win.busy)
    win._close_bubble()
    win.answered_at = time.monotonic() - 2  # the bubble closed, but a moment ago
    win.ask("and Paris?")
    assert not win.quote.tag.isHidden()


def test_the_card_has_a_header_with_the_name_and_the_model_and_one_layout(tmp_path):
    at_speed(0, bot_name="PIXEL", model_chip="my-model")
    win, _ = floating(tmp_path, FakeClient([]))
    win._open()
    pump(win, lambda: False, timeout=0.2)
    assert isinstance(win.panel, hud.Card) and win.panel.width() == BUBBLE_W
    header = win.panel.header
    assert header.theme.bot_name == "PIXEL" and header._chip_text == "my-model"
    margins = win.panel.layout().contentsMargins()
    assert (margins.left(), margins.top(), margins.right(), margins.bottom()) == hud.MARGINS
    assert win.panel.layout() is win.panel.inner and win.panel.inner.spacing() == hud.SPACING


def test_the_leds_are_built_in_the_cards_theme_not_cyan(tmp_path):
    for key in ("matrix", "daylight"):  # a window that never changes its hue is never restyled
        themes.CONFIG.write_text(json.dumps({"theme": key}))
        win, _ = floating(tmp_path / key, FakeClient([]))
        assert win.panel.header.link.theme.key == key and win.panel.header.mic.theme.key == key
        assert win.panel.header.mic.hue == themes.THEMES[key].hue


# --- header lights -----------------------------------------------------------------------------


class FakePoller:
    made = []

    def __init__(self, url, on_state):
        self.url, self.on_state, self.started, self.poked, self.stopped = url, on_state, 0, 0, 0
        FakePoller.made.append(self)

    def start(self):
        self.started += 1

    def poke(self):
        self.poked += 1

    def stop(self):
        self.stopped += 1


@pytest.fixture
def poller(monkeypatch):
    FakePoller.made = []
    monkeypatch.setattr(robo_app, "HealthPoller", FakePoller)
    return FakePoller


def test_the_hermes_light_follows_the_health_poller(tmp_path, poller):
    url = "http://127.0.0.1:8642/p/robo"
    win, _ = floating(tmp_path, FakeClient([]), health=url)
    (p,) = poller.made
    assert p.url == url and p.started == 1
    link = win.panel.header.link
    assert (link.state, link.label) == ("unknown", "HERMES")
    for state, label in (("ok", "HERMES"), ("warn", "HERMES …"), ("bad", "HERMES ✕"),
                         ("ok", "HERMES")):
        p.on_state(state)  # what the poller thread does through the bridge
        assert pump(win, lambda state=state: link.state == state)
        assert link.label == label
    win.close()
    assert p.stopped == 1


def test_no_gateway_url_means_no_poller_and_a_failed_run_pokes_it(tmp_path, poller):
    win, _ = floating(tmp_path, FakeClient([]))
    assert win.poller is None and not poller.made
    win, _ = floating(tmp_path / "2", FakeClient(fail=BrainError("Hermes is not running")),
                      health="http://127.0.0.1:9")
    win.ask("hi")
    assert pump(win, lambda: not win.busy)
    assert poller.made[0].poked == 1


def test_the_microphone_light_has_a_word_for_every_state(tmp_path):
    win, ear = floating(tmp_path, FakeClient([]))
    mic = win.panel.header.mic

    def shows(state, label):
        win._show()
        assert (mic.state, mic.label) == (state, label)

    shows("ok", "MIC")
    ear.ready = False  # the thread runs, the model is still loading
    shows("loading", "MIC …")
    ear.ready = True
    ear.on_wake()
    assert pump(win, lambda: win.mind.activity == "listening")
    shows("hot", "LISTENING")
    ear.on_error("Voice input stopped: device unplugged")
    assert pump(win, lambda: win.noted)
    shows("bad", "MIC ✕")
    ear.on_wake()  # listening again clears the problem
    assert pump(win, lambda: win.mind.activity == "listening" and not win.noted)
    shows("hot", "LISTENING")
    win.listener = None  # docked, or the start failed
    shows("off", "MIC OFF")


def test_without_a_microphone_the_light_says_off(tmp_path):
    win = robo_app.RoboWindow(FakeClient([]), DigestClock(tmp_path / "s.json"),
                              network=lambda: True, watch_wake=False, floating=True,
                              listener=lambda *c: FakeListener(*c, ok=False))
    win._show()
    assert win.panel.header.mic.label == "MIC OFF"


# --- the menu and the themes -----------------------------------------------------------------


def grid_cells(win):
    grid = win.menu.layout()
    return {grid.itemAt(i).widget().text(): grid.getItemPosition(i) for i in range(grid.count())}


def test_the_menu_is_three_by_two_and_without_a_watcher_theme_and_quit_take_three_each(tmp_path):
    win, _ = floating(tmp_path / "a", FakeClient([]))
    cells = {k.split()[-1]: v for k, v in grid_cells(win).items()}  # (row, col, rows, cols)
    assert cells == {"Digest": (0, 0, 1, 2), "Type": (0, 2, 1, 2), "Stay": (0, 4, 1, 2),
                     "Theme": (1, 0, 1, 3), "Quit": (1, 3, 1, 3)}
    win, _ = floating(tmp_path / "b", FakeClient([]), watcher=FakeWatcher())
    cells = {k.split()[-1]: v for k, v in grid_cells(win).items()}
    assert cells["Watch"] == (1, 0, 1, 2) and cells["Theme"] == (1, 2, 1, 2)
    assert cells["Quit"] == (1, 4, 1, 2) and len(cells) == 6


def test_the_theme_button_opens_the_swatches_and_the_menu_stays_open(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    win._show_menu()
    pump(win, lambda: False, timeout=0.2)
    assert not win.picker.isVisibleTo(win) and win.themer.text() == "🎨 Theme"
    win.themer.click()
    assert win.picker.isVisibleTo(win) and win.menu.isVisibleTo(win)  # the menu did not close
    assert len(win.picker.swatches) == 5
    assert win.panel.rect().contains(win.picker.geometry())
    assert win.picker.label.text() == "THEME ▸ CYAN HUD"
    win.themer.click()
    assert not win.picker.isVisibleTo(win)
    win.themer.click()
    win._hide_menu()  # closing the menu takes the swatches with it
    assert not win.picker.isVisibleTo(win) and not win.menu.isVisibleTo(win)


def test_a_swatch_switches_the_look_at_once_and_is_remembered_with_the_other_settings(tmp_path):
    at_speed(0, bot_name="PIXEL")
    said = "See [notes](https://x.y) now."
    win, _ = floating(tmp_path, FakeClient([Delta(said), RunEnded("completed", said)]))
    win.ask("go")
    assert pump(win, lambda: not win.busy)
    win._show_menu()
    win.themer.click()
    old_sheet = win.styleSheet()
    win.picker.swatches["matrix"].click()
    t = themes.THEMES["matrix"]
    assert win.theme.key == "matrix" and win.theme.bot_name == "PIXEL"  # tokens kept
    assert win.tw.pace.cps == 0  # and so is the typing speed from them
    assert win.styleSheet() != old_sheet and t.text in win.styleSheet()
    assert win.panel.theme is win.theme and win.panel.header.theme is win.theme
    assert win.picker.label.text() == "THEME ▸ MATRIX"
    assert win.face.hue_fn is not None and win.face.bg[0].name() == t.face_bg[0]
    link = next(f for f in iter_fragments(win.bubble.document()) if f.charFormat().isAnchor())
    assert link.charFormat().foreground().color().name() == t.link  # the reply was restyled
    saved = json.loads(themes.CONFIG.read_text())
    assert saved == {"tokens": {"cps": 0, "bot_name": "PIXEL"}, "theme": "matrix"}
    assert themes.load().key == "matrix"
    win._type()
    assert t.bg_top in win.typer.styleSheet() and t.text in win.typer.styleSheet()


def test_a_theme_that_cannot_be_saved_still_applies_for_this_run(tmp_path, monkeypatch):
    blocked = tmp_path / "file"
    blocked.write_text("not a folder")
    monkeypatch.setattr(themes, "CONFIG", blocked / "theme.json")
    win, _ = floating(tmp_path / "w", FakeClient([]))
    win._show_menu()
    win.picker.swatches["amber"].click()
    assert win.theme.key == "amber" and not themes.CONFIG.exists()


def test_a_theme_json_edited_by_hand_shows_when_the_menu_opens(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    assert win.theme.key == "cyan"
    win._show_menu()
    assert win.theme.key == "cyan"  # nothing changed: nothing re-read
    time.sleep(0.01)
    themes.CONFIG.write_text(json.dumps({"theme": "aurora", "tokens": {"cps": 0, "hue": 300}}))
    win._show_menu()
    assert win.theme.key == "aurora" and win.theme.hue == 300
    assert win.picker.label.text() == "THEME ▸ VIOLET AURORA"


def test_a_cps_of_zero_from_a_theme_switch_finishes_a_reply_that_is_being_typed(tmp_path):
    win, _ = reply_window(tmp_path, LONG)
    win.ask("go")
    assert pump(win, lambda: not win.busy and win.tw.k > 5)
    win.apply_theme(replace(win.theme, cps=0.0))
    assert pump(win, lambda: win.typed, timeout=1.0)
    assert win.bubble.toPlainText() == LONG
    win.apply_theme(replace(win.theme, cps=55.0))  # and a speed again for the next one
    assert win.tw.pace.cps == 55


@pytest.mark.parametrize("key", list(themes.THEMES))
def test_the_card_follows_the_mood_of_the_face_in_every_theme_and_red_for_an_error(tmp_path, key):
    themes.CONFIG.write_text(json.dumps({"theme": key, "tokens": {"cps": 0}}))
    win, _ = floating(tmp_path, FakeClient([]))
    assert win.theme.follow_emotion and win.panel.hue == round(win.theme.hue / 2) * 2 % 360

    def near(a, b, tol=2.0):
        return abs((a - b + 180) % 360 - 180) <= tol

    win._on_event(Feeling("proud"))
    goal = win.face.goal.hue
    assert goal != win.theme.hue
    assert pump(win, lambda: near(win.panel.hue, goal))  # the card took the face's colour
    win._on_event(RunEnded("failed", error="boom"))
    assert pump(win, lambda: near(win.panel.hue, 356.0), timeout=6)  # red, whatever the theme


def test_a_live_switch_looks_exactly_like_a_window_built_in_that_theme(tmp_path):
    def exchange(path):
        win, _ = floating(path, FakeClient([Delta(MD), RunEnded("completed", MD)]))
        win.ask("what is due this week?")
        assert pump(win, lambda: win.typed)
        return win

    MD = "## Plan\n\nFriday has the **lab report** due.\n\n- read `ch. 4`\n- see [notes](https://x.y)"
    themes.CONFIG.write_text(json.dumps({"tokens": {"cps": 0}}))
    live = exchange(tmp_path / "a")
    live.apply_theme(themes.load(choice="matrix"))
    themes.CONFIG.write_text(json.dumps({"theme": "matrix", "tokens": {"cps": 0}}))
    fresh = exchange(tmp_path / "b")
    assert pump(live, lambda: live.panel.hue == fresh.panel.hue)  # the face has settled
    live._show()
    settle(live)
    settle(fresh)
    assert live.size() == fresh.size() and live.panel.size() == fresh.panel.size()
    a, b = shot(live.panel).astype(float), shot(fresh.panel).astype(float)
    assert np.abs(a - b).mean() < 0.5


# --- docked --------------------------------------------------------------------------------------


def test_docked_the_quote_and_the_typed_reply_work_in_the_ordinary_window(tmp_path):
    at_speed(120)
    win = window(tmp_path, FakeClient([Delta("Hi **you**."), RunEnded("completed", "Hi **you**.")]))
    win.show()
    assert win.input.placeholderText() == "▸ Type and press Enter"
    assert not win.quote.isVisibleTo(win)
    win.input.setText("hi")
    win.send()
    assert win.quote.isVisibleTo(win) and win.heard.toPlainText() == "hi"
    assert pump(win, lambda: win.typed)
    assert win.bubble.toPlainText() == "Hi you."
    win.ask(robo_app.DIGEST_PROMPT)
    assert pump(win, lambda: not win.busy)
    assert not win.quote.isVisibleTo(win)
