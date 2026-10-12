"""The holographic card and what is painted on it: frame geometry and cache, header and LEDs,
quote, caret, theme picker, style sheet. Offscreen; nothing here reads a real config file."""

import os
from dataclasses import replace
from types import SimpleNamespace

import numpy as np
import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QPoint, QRect, QSize, Qt, qInstallMessageHandler  # noqa: E402
from PySide6.QtGui import QColor, QImage, QRegion, QTextCursor  # noqa: E402
from PySide6.QtWidgets import QApplication, QLabel, QTextBrowser, QWidget  # noqa: E402

from robo import hud, theme  # noqa: E402
from robo.theme import CYAN, THEMES, accent, chip_text, css, label_colour, rgba  # noqa: E402
from robo.widgets import BUBBLE_W, TypingDots, style_markdown  # noqa: E402

QAPP = QApplication.instance() or QApplication([])
KEYS = list(THEMES)
ALL = list(THEMES.values())


def alpha(pm, x, y, dpr=1.0) -> int:
    return pm.toImage().pixelColor(round(x * dpr), round(y * dpr)).alpha()


def pixels(img: QImage) -> np.ndarray:
    img = img.convertToFormat(QImage.Format.Format_RGBA8888)
    return np.frombuffer(img.constBits(), np.uint8).reshape(img.height(), img.width(), 4)


def shot(w: QWidget) -> QImage:
    """What `w` paints (and its children) on a transparent ground: no window colour, no parent."""
    img = QImage(w.size(), QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    w.render(img, QPoint(), QRegion(), QWidget.RenderFlag.DrawChildren)
    return img


@pytest.fixture
def card():
    c = hud.Card()
    c.resize(BUBBLE_W, 200)
    c.show()
    yield c
    c.close()
    c.deleteLater()


# --- the frame -------------------------------------------------------------------------------

def test_the_card_is_as_wide_as_the_old_panel_and_puts_the_header_in_the_frame(card):
    assert card.width() == BUBBLE_W == 340
    assert card.header.geometry() == QRect(6, 6, 328, 26)  # inside the 6 px glow margin
    m = card.inner.contentsMargins()
    assert (m.left(), m.top(), m.right(), m.bottom()) == hud.MARGINS == (19, 42, 19, 19)
    assert card.inner.spacing() == hud.SPACING
    card.resize(BUBBLE_W, 330)
    assert card.header.geometry() == QRect(6, 6, 328, 26)


@pytest.mark.parametrize("t", ALL, ids=KEYS)
def test_the_frame_has_the_corners_and_the_tail_the_theme_asks_for(t):
    size, dpr = QSize(340, 200), 2.0
    pm = hud.chrome(t, size, dpr, t.hue)
    assert pm.size() == size * 2 and pm.devicePixelRatio() == 2.0
    mid = alpha(pm, 170, 100, dpr)
    assert mid >= 0.9 * 255 - 2  # glass: never more see-through than 10 %
    assert alpha(pm, 1, 1, dpr) == 0  # outside everything
    if t.corner:  # chamfered or rounded: the very corner of the frame is empty
        assert alpha(pm, 7, 7, dpr) < 40
    else:
        assert alpha(pm, 8, 8, dpr) >= 200
    # the frame's bottom edge is at y = 190.5; the tail is a notch under it, centred
    assert alpha(pm, 170, 195, dpr) >= 200 and alpha(pm, 170, 198, dpr) > 0
    assert alpha(pm, 185, 195, dpr) < 40 and alpha(pm, 155, 195, dpr) < 40
    assert alpha(pm, 100, 197, dpr) == 0  # below the frame, away from the tail


def test_the_fill_is_the_themes_glass():
    for t in ALL:
        img = hud.chrome(t, QSize(340, 200), 1.0, t.hue).toImage()
        px = img.pixelColor(170, 175)  # under the content area, past the sheen
        want = QColor(t.bg_bot)
        assert all(abs(a - b) < 40 for a, b in
                   zip((px.red(), px.green(), px.blue()),
                       (want.red(), want.green(), want.blue()), strict=True)), t.key
        assert (px.lightness() > 150) == (not t.dark)


def test_the_frame_follows_the_hue_and_the_glow_stays_inside_its_margin():
    a = hud.chrome(CYAN, QSize(340, 200), 1.0, 188).toImage()
    b = hud.chrome(CYAN, QSize(340, 200), 1.0, 356).toImage()  # error: red
    arm = lambda img: img.pixelColor(20, 6)  # noqa: E731 - on the top left corner bracket
    assert arm(a).blue() > 200 > arm(a).red() and arm(b).red() > 200 > arm(b).blue()
    for img in (a, b):  # nothing painted in the outermost pixels except the tail's dot
        edge = [img.pixelColor(x, y).alpha() for x in (0, 339) for y in range(0, 190)]
        edge += [img.pixelColor(x, y).alpha() for y in (0,) for x in range(340)]
        assert max(edge) == 0


def test_the_aurora_border_ends_on_pink_for_every_mood_and_an_error_stays_red():
    from robo.face.expressions import target
    aurora = THEMES["aurora"]
    for activity, emotion in [("idle", "neutral"), ("talking", "happy"), ("idle", "proud"),
                              ("idle", "playful"), ("idle", "concerned"), ("idle", "sad"),
                              ("error", "neutral")]:
        hue = theme.hue_for(aurora, activity, emotion, target(activity, emotion).hue)
        img = hud.chrome(aurora, QSize(340, 200), 1.0, hue).toImage()
        edge = img.pixelColor(333, 130).hue()  # the right edge, past the sweep's 90 %
        assert abs((edge - 330 + 180) % 360 - 180) < 60, (emotion, hue, edge)  # not yellow/green


# --- the cache -------------------------------------------------------------------------------

def test_the_frame_pixmap_is_rebuilt_only_when_what_it_shows_changes(card):
    first = card.chrome()
    assert card.chrome() is first  # a hit
    assert card.set_hue(card.hue + 0.6) is False and card.chrome() is first  # same 2 degree step
    card.set_theme(card.theme)  # nothing new
    assert card.chrome() is first
    assert card.set_hue(card.hue + 40) is True
    hue_step = card.chrome()
    assert hue_step is not first and card.chrome() is hue_step
    card.set_theme(THEMES["matrix"])
    themed = card.chrome()
    assert themed is not hue_step
    card.resize(BUBBLE_W, 260)
    resized = card.chrome()
    assert resized is not themed and resized.height() == 260
    card.set_theme(replace(THEMES["matrix"], glow=0.0))  # a user token: a new revision
    assert card.chrome() is not resized


def test_hue_is_followed_in_two_degree_steps_and_wraps(card):
    card.set_hue(359.2)
    assert card.hue == 0
    card.set_hue(101)
    assert card.hue in (100, 102)
    assert card.hue % 2 == 0


def test_a_hue_change_restyles_every_widget_in_the_tree(card):
    quote, label, dots = hud.Quote(), hud.MicroLabel("x"), TypingDots()
    box = QTextBrowser()
    caret = hud.Caret(box.viewport())
    for w in (quote, label, dots, box):
        card.inner.addWidget(w)
    card.set_hue(300)
    for w in (card.header, card.header.link, card.header.mic, quote, label, dots, caret):
        assert w.hue == card.hue == 300 and w.theme is card.theme, w
    card.set_theme(THEMES["aurora"])
    for w in (card.header, quote, label, dots, caret):
        assert w.theme is THEMES["aurora"], w


# --- LEDs and header -------------------------------------------------------------------------

LINK = {"unknown": "HERMES", "ok": "HERMES", "warn": "HERMES …", "bad": "HERMES ✕"}
MIC = {"ok": "MIC", "loading": "MIC …", "hot": "LISTENING", "off": "MIC OFF", "bad": "MIC ✕"}


@pytest.mark.parametrize(("state", "label"), LINK.items())
def test_the_hermes_led_always_carries_a_word(state, label):
    led = hud.Led("HERMES", state)
    assert led.label == label and led.width() > 14 + 20 and led.height() == hud.HEADER_H


@pytest.mark.parametrize(("state", "label"), MIC.items())
def test_the_mic_led_always_carries_a_word(state, label):
    led = hud.Led("MIC", state, hot="LISTENING")
    assert led.label == label


def test_an_unknown_led_state_is_an_error():
    with pytest.raises(ValueError, match="nope"):
        hud.Led("MIC").set_state("nope")


def test_a_state_that_means_trouble_is_not_told_by_colour_alone():
    labels = {s: hud.Led("MIC", s, hot="LISTENING").label for s in MIC}
    assert len(set(labels.values())) == len(MIC)  # five states, five different words


def test_mic_state_reads_plain_objects():
    running, starting = SimpleNamespace(ready=True), SimpleNamespace(ready=False)
    assert hud.mic_state(None, "idle") == "off"
    assert hud.mic_state(None, "listening") == "off"  # no listener: nothing is listening
    assert hud.mic_state(starting, "idle") == "loading"
    assert hud.mic_state(running, "idle") == "ok"
    assert hud.mic_state(running, "listening") == "hot"
    assert hud.mic_state(running, "idle", noted=True) == "bad"
    assert hud.mic_state(starting, "idle", noted=True) == "bad"
    assert hud.mic_state(running, "listening", noted=True) == "hot"  # the next wake clears it


def test_the_header_lays_out_again_when_a_label_grows(card):
    head = card.header
    head.set_status("ok", "ok")
    before = head.mic.x()
    head.set_status("bad", "hot")  # "HERMES ✕" is wider than "HERMES"
    assert head.link.label == "HERMES ✕" and head.mic.label == "LISTENING"
    assert head.mic.x() > before
    assert head.mic.x() >= head.link.x() + head.link.width()
    assert head.mic.x() + head.mic.width() <= head.width()


def test_blinking_and_pulsing_follow_the_phase_the_app_gives():
    def at(led, t):
        led.set_phase(t)
        return shot(led)

    warn = hud.Led("HERMES", "warn")
    assert at(warn, 0.0) != at(warn, 0.6)  # 1 Hz: lit for half a second, dark for half
    assert at(warn, 0.0) == at(warn, 1.0)
    ok = hud.Led("HERMES", "ok")
    assert at(ok, 0.0) == at(ok, 0.6)  # steady lights do not move
    hot = hud.Led("MIC", "hot", hot="LISTENING")
    assert at(hot, 0.0) != at(hot, 0.3125)  # the pulse peaks 0.3125 s in


def test_a_led_repaints_only_when_what_it_draws_changes():
    led = hud.Led("MIC", "ok")
    led.show()
    led.grab()
    drawn = []
    led.update = lambda *a: drawn.append(1)
    for t in (0.0, 0.1, 0.2, 0.3, 0.4):  # steady: nothing to redraw
        led.set_phase(t)
    assert drawn == []


def test_the_dot_is_a_ring_when_unknown_or_off_and_solid_otherwise():
    def dot(state):
        return shot(hud.Led("X", state)).pixelColor(7, hud.HEADER_H // 2).alpha()

    assert dot("ok") > 200 and dot("unknown") < 80 and dot("off") < 80  # empty in the middle


def test_the_header_shows_the_name_the_chip_and_nothing_overlaps(card):
    t = replace(CYAN, bot_name="pixel", model_chip="gpt-5")
    card.set_theme(t)
    head = card.header
    assert head.chip is not None and head.chip.right() <= head.width() - 12
    assert head.chip.left() > head.mic.x() + head.mic.width()
    assert head._chip_text == "gpt-5"
    assert head._name()[1] == "PIXEL"  # the name is upper-case


def test_the_chip_defaults_to_the_configured_model_and_a_blank_one_hides_it(card):
    assert card.header._chip_text == chip_text(CYAN) and card.header.chip is not None
    card.set_theme(replace(CYAN, model_chip="   "))
    assert card.header.chip is None


@pytest.mark.parametrize("name", ["ROBO", "WWWWWWWWWWWW", "iiiiiiiiiiii"])
@pytest.mark.parametrize("states", [("ok", "ok"), ("bad", "hot"), ("unknown", "off")])
def test_the_chip_gives_way_before_the_name_and_the_leds(card, name, states):
    card.set_theme(replace(CYAN, bot_name=name, model_chip="a-very-long-model"))
    card.header.set_status(*states)
    head, chip = card.header, card.header.chip
    assert head.mic.x() + head.mic.width() <= head.width() - 12  # the LEDs always fit
    if chip is not None:  # else hidden, which is the fallback
        assert chip.width() >= 40 and chip.left() >= head.mic.x() + head.mic.width()
        assert chip.right() <= head.width() - 12


def test_the_header_text_is_painted(card):
    img = shot(card.header)
    assert len({img.pixel(x, 13) for x in range(0, 328)}) > 8  # diamond, name, LEDs, chip


# --- quote and labels ------------------------------------------------------------------------

def test_the_quote_hides_when_there_is_nothing_to_quote():
    q = hud.Quote()
    q.set_text("what's due?")
    assert not q.isHidden() and q.text.toPlainText() == "what's due?" and q.tag.isHidden()
    q.set_text("and Friday?", follow_up=True)
    assert not q.tag.isHidden()
    q.set_text("")  # the automatic digest
    assert q.isHidden()


def test_the_quote_paints_its_accent_bar():
    q = hud.Quote(replace(CYAN))
    q.setStyleSheet(hud.qss(CYAN))  # the text box is transparent, as in the app
    q.set_text("hi")
    q.resize(300, 60)
    img = shot(q)
    bar = img.pixelColor(0, 10)
    want = accent(CYAN, CYAN.hue)
    assert abs(bar.red() - want[0]) < 30 and abs(bar.blue() - want[2]) < 30  # the live accent
    foot = q.height() - 1
    assert img.pixelColor(150, foot).alpha() > 0  # the hairline at the foot
    assert img.pixelColor(290, foot).alpha() < 10  # fades out to the right


def test_a_micro_label_is_a_label_that_paints_itself_in_the_label_colour():
    label = hud.MicroLabel("YOU ▸")
    assert isinstance(label, QLabel) and label.text() == "YOU ▸"
    label.setText("searching the web…")
    assert label.sizeHint().width() > 60 and label.minimumSizeHint() == label.sizeHint()
    want = QColor(*label_colour(CYAN, CYAN.hue))
    img = shot(label)
    px = [img.pixelColor(x, y) for x in range(img.width()) for y in range(img.height())]
    assert any(c.alpha() > 250 and abs(c.hue() - want.hue()) < 12 for c in px)
    warn = shot(hud.MicroLabel("APPROVAL ▸", tone="warn"))
    px = [warn.pixelColor(x, y) for x in range(warn.width()) for y in range(warn.height())]
    assert any(c.alpha() > 250 and c.hue() == QColor(CYAN.led_warn).hue() for c in px)


# --- the caret -------------------------------------------------------------------------------

@pytest.fixture
def reply():
    box = QTextBrowser()
    box.resize(302, 120)
    box.setMarkdown("Friday has the **lab report** due and a meeting with the professor. " * 6)
    box.show()
    yield box
    box.close()


def end_rect(box) -> QRect:
    box.verticalScrollBar().setValue(box.verticalScrollBar().maximum())  # as the app follows it
    cur = QTextCursor(box.document())
    cur.movePosition(QTextCursor.MoveOperation.End)
    return box.cursorRect(cur)


@pytest.mark.parametrize("t", ALL, ids=KEYS)
def test_the_caret_sits_inside_the_viewport_at_the_end_of_the_text(reply, t):
    caret = hud.Caret(reply.viewport(), t)
    line = end_rect(reply)
    box = caret.place(line)
    vp = reply.viewport().rect()
    assert vp.contains(box) and caret.geometry() == box
    px = t.text_px
    assert abs(box.width() - 2 - px * 0.58) <= 1.5 and abs(box.height() - 2 - px * 1.18) <= 1.5
    assert box.center().y() == pytest.approx(line.center().y(), abs=3)  # on the text line
    assert box.left() >= line.x() - 1  # at the cursor, not before it


def test_the_caret_is_kept_inside_even_when_the_line_is_not_visible_yet(reply):
    caret = hud.Caret(reply.viewport())
    vp = reply.viewport().rect()
    for line in (QRect(5000, 9000, 1, 16), QRect(-50, -90, 1, 16), QRect(299, 119, 1, 16)):
        assert vp.contains(caret.place(line)), line


@pytest.mark.parametrize("style", ["block", "bar", "under"])
def test_the_caret_is_a_block_a_bar_or_an_underline(reply, style):
    t = replace(CYAN, caret=style)
    caret = hud.Caret(reply.viewport(), t)
    box = caret.place(end_rect(reply))
    img = shot(caret)
    w, h = box.width(), box.height()
    centre, left, bottom = img.pixelColor(w // 2, h // 2), img.pixelColor(2, h // 2), \
        img.pixelColor(w // 2, h - 3)
    solid = lambda c: c.alpha() > 200  # noqa: E731
    marks = {"block": (True, True, True), "bar": (False, True, False),
             "under": (False, False, True)}
    assert (solid(centre), solid(left), solid(bottom)) == marks[style]
    caret.set_on(False)  # the dark half of a blink: none of the three marks is painted
    off = shot(caret)
    assert not any(solid(off.pixelColor(x, y)) for x, y in ((w // 2, h // 2), (2, h // 2),
                                                           (w // 2, h - 3)))


def test_the_caret_takes_no_clicks(reply):
    caret = hud.Caret(reply.viewport())
    assert caret.testAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)


# --- the picker ------------------------------------------------------------------------------

def test_the_picker_has_five_swatches_and_says_which_theme_is_current():
    picker = hud.Picker("matrix")
    assert list(picker.swatches) == KEYS and len(picker.swatches) == 5
    assert picker.label.text() == "THEME ▸ MATRIX"
    assert [s.current for s in picker.swatches.values()] == [k == "matrix" for k in KEYS]
    picker.set_current("amber")
    assert picker.label.text() == "THEME ▸ AMBER CRT"
    assert [k for k, s in picker.swatches.items() if s.current] == ["amber"]


def test_a_click_on_a_swatch_says_which_theme_was_picked():
    picker, got = hud.Picker(), []
    picker.picked.connect(got.append)
    picker.swatches["aurora"].click()
    picker.swatches["daylight"].click()
    assert got == ["aurora", "daylight"]


def test_a_picker_is_one_grid_not_nested_rows():
    # CLAUDE.md: nested per-row layouts gave "shared QObject was deleted directly" at exit
    grid = hud.Picker().layout()
    assert grid.count() == 6 and all(grid.itemAt(i).widget() for i in range(6))


def test_swatches_are_miniature_cards_in_their_own_colours():
    shots = {}
    for key, t in THEMES.items():
        s = hud.Swatch(t)
        assert s.size() == QSize(54, 34) and s.toolTip() == t.label
        img = shot(s)
        shots[key] = img
        px = img.pixelColor(45, 8)  # the card's own glass, top right
        want = QColor(t.bg_top)
        assert abs(px.red() - want.red()) < 30 and abs(px.blue() - want.blue()) < 30, key
        dot = img.pixelColor(54 - 10, 34 - 9)  # the accent dot at the bottom right
        a = accent(t, t.hue)
        assert abs(dot.red() - a[0]) < 40 and abs(dot.green() - a[1]) < 40, key
    assert len({bytes(pixels(i).tobytes()) for i in shots.values()}) == 5


def test_the_current_swatch_is_ringed():
    s = hud.Swatch(THEMES["matrix"])
    plain = shot(s)
    s.set_current(True)
    ringed = shot(s)
    assert plain != ringed
    assert ringed.pixelColor(2, 17).alpha() > 200  # the stroke on the left edge
    assert ringed.pixelColor(2, 17).green() > plain.pixelColor(2, 17).green()


# --- style sheet -----------------------------------------------------------------------------

@pytest.mark.parametrize("t", ALL, ids=KEYS)
def test_every_stylesheet_parses(t):
    seen = []
    old = qInstallMessageHandler(lambda mode, ctx, msg: seen.append(msg))
    try:
        w = QWidget()
        w.setStyleSheet(hud.qss(t))
        w.ensurePolished()
    finally:
        qInstallMessageHandler(old)
    assert not [m for m in seen if "stylesheet" in m.lower() or "parse" in m.lower()], seen


@pytest.mark.parametrize("t", ALL, ids=KEYS)
def test_the_stylesheet_uses_the_themes_tokens_at_the_resting_hue(t):
    sheet = hud.qss(t)
    for token in (t.text, t.text_dim, t.on_accent, t.led_warn):
        assert token in sheet
    assert css(accent(t, t.hue)) in sheet  # the Allow button: solid, never see-through
    assert f"font-size: {t.text_px}px" in sheet
    assert (f'font-family: "{hud.mono_family()}"; font-size: {t.text_px}px' in sheet) == t.body_mono
    assert f"border-radius: {t.radius}px" in sheet
    assert css(rgba(t.text_dim, 0.45)) in sheet  # the Deny button's border
    assert hud.qss(t) == sheet  # a pure function: built once per theme


def test_the_cyan_stylesheet_is_what_widgets_style_still_hands_out():
    from robo import widgets

    assert hud.qss(CYAN) == widgets.STYLE


# --- a live switch is the same as a fresh build ----------------------------------------------

MD = ("## Plan\n\nYou have **three** things due: *lab*, `CS 240` and [the notes](https://x.io).\n\n"
      "- one\n- two\n\n```python\nx = 1\n```\n\nDone.")


def build(t):
    host = QWidget()
    host.setStyleSheet(hud.qss(t))
    c = hud.Card(t, host)
    c.quote = hud.Quote(t)
    c.quote.set_text("What's due this week?", follow_up=True)
    c.reply = QTextBrowser(objectName="reply")
    c.reply.setFixedHeight(220)
    c.reply.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    c.reply.setMarkdown(MD)
    style_markdown(c.reply.document(), hud.md_look(t))
    c.footer = QLabel("📓 In Obsidian: Plan", objectName="footer")
    for w in (c.quote, c.reply, c.footer):
        c.inner.addWidget(w)
    c.header.set_status("ok", "ok")
    c.resize(BUBBLE_W, 520)
    c.quote.text.setFixedHeight(18)
    host.resize(c.size())
    host.show()
    QApplication.processEvents()
    return host, c


def switch(host, c, t):
    host.setStyleSheet(hud.qss(t))
    c.reply.setMarkdown(MD)
    style_markdown(c.reply.document(), hud.md_look(t))
    c.set_theme(t)
    c.set_hue(t.hue)  # what the app does as the face settles on the new theme's hue
    QApplication.processEvents()


def test_switching_theme_live_paints_what_a_fresh_build_paints():
    for src, dst in (("cyan", "matrix"), ("aurora", "daylight"), ("daylight", "amber")):
        host, card = build(THEMES[src])
        switch(host, card, THEMES[dst])
        fresh_host, fresh = build(THEMES[dst])
        a = pixels(host.grab().toImage()).astype(int)
        b = pixels(fresh_host.grab().toImage()).astype(int)
        assert a.shape == b.shape
        assert np.abs(a - b).mean() < 0.5, (src, dst)  # of 255
        host.close()
        fresh_host.close()
