"""Face: expression table, animator dynamics, and a smoke render."""

import math
import os
from dataclasses import fields, replace

import pytest

from robo.events import ACTIVITIES, EMOTIONS
from robo.face.animator import Animator
from robo.face.expressions import FaceParams, target

FLOATS = [f.name for f in fields(FaceParams) if f.name != "effects"]


def dist(a: FaceParams, b: FaceParams) -> float:
    """Rough visual distance; hue counts per 60 degrees, effects count 1 each."""
    d = sum(abs(getattr(a, n) - getattr(b, n)) for n in FLOATS if n != "hue")
    return d + abs(a.hue - b.hue) / 60 + len(a.effects ^ b.effects)


@pytest.mark.parametrize("activity", ACTIVITIES)
@pytest.mark.parametrize("emotion", EMOTIONS)
def test_target_total_and_in_range(activity, emotion):
    p = target(activity, emotion)
    assert all(math.isfinite(getattr(p, n)) for n in FLOATS)
    assert 0 <= p.lid_top <= 1 and 0 <= p.lid_bottom <= 1 and 0 <= p.mouth_open <= 1
    assert -1 <= p.mouth_curve <= 1 and p.eye_w > 0 and p.eye_h > 0
    assert isinstance(p.effects, frozenset)


def test_unknown_names_fall_back():
    assert target("nope", "nope") == target("idle", "neutral")


@pytest.mark.parametrize("emotion", EMOTIONS[1:])
def test_each_emotion_reads_differently_from_neutral(emotion):
    assert dist(target("idle", emotion), target("idle", "neutral")) > 0.8


@pytest.mark.parametrize("activity", ACTIVITIES[1:])
def test_each_activity_differs_from_idle(activity):
    assert dist(target(activity, "neutral"), target("idle", "neutral")) > 0.5


def test_emotions_pairwise_distinct():
    ps = [target("idle", e) for e in EMOTIONS]
    assert min(dist(a, b) for i, a in enumerate(ps) for b in ps[i + 1:]) > 0.5


def test_happy_smiles_sad_frowns():
    assert target("idle", "happy").mouth_curve > 0.4 > target("idle", "sad").mouth_curve + 0.8


def test_asleep_overrides_emotion():
    assert target("asleep", "happy") == target("asleep", "sad")
    assert "zzz" in target("asleep", "neutral").effects


def run(anim, tgt, secs, dt=1 / 60, talking=False, t0=0.0):
    out, t = [], t0
    for _ in range(int(secs / dt)):
        t += dt
        out.append((t, anim.step(tgt, dt, talking, t)))
    return out


def test_converges_to_target():
    a = Animator(seed=1)
    a.step(target("idle", "neutral"), 1 / 60, False, 0.0)
    goal = target("working", "sad")  # no wander, so gaze should settle exactly
    t, p = run(a, goal, 1.5)[-1]
    # Sample just after the frame so a blink can't be mid-flight.
    for n in FLOATS:
        if n not in ("eye_h", "bob"):
            assert getattr(p, n) == pytest.approx(getattr(goal, n), abs=0.02), n
    assert p.effects == goal.effects


def test_effects_switch_instantly():
    a = Animator(seed=1)
    a.step(target("idle", "neutral"), 1 / 60, False, 0.0)
    assert a.step(target("idle", "confused"), 1 / 60, False, 0.02).effects == {"question"}


def test_blink_happens_and_is_quick():
    a = Animator(seed=3)
    goal = target("working", "neutral")
    frames = run(a, goal, 7.0, dt=1 / 120)
    shut = [t for t, p in frames if p.eye_h < 0.5 * goal.eye_h]
    assert shut and shut[0] < 6.5
    first = [t for t in shut if t - shut[0] < 1.0]
    assert first[-1] - first[0] < 0.3


def test_no_blink_while_asleep():
    a = Animator(seed=3)
    goal = target("asleep", "neutral")
    frames = run(a, goal, 10.0)[60:]
    assert all(abs(p.eye_h - goal.eye_h) < 0.05 for _, p in frames)


def test_talking_moves_mouth():
    a = Animator(seed=2)
    goal = target("talking", "neutral")
    opens = [p.mouth_open for _, p in run(a, goal, 2.0, talking=True)[30:]]
    assert max(opens) - min(opens) > 0.3
    closed = [p.mouth_open for _, p in run(a, goal, 1.0, talking=False, t0=2.0)]
    assert closed[-1] < 0.05


def test_idle_wanders_gaze():
    a = Animator(seed=4)
    xs = [p.gaze_x for _, p in run(a, target("idle", "neutral"), 10.0)]
    assert max(xs) - min(xs) > 0.1


def test_deterministic_with_seed():
    g = target("idle", "happy")
    assert run(Animator(seed=9), g, 5.0) == run(Animator(seed=9), g, 5.0)


def test_stable_for_large_dt():
    a = Animator(seed=5)
    t = 0.0
    for i in range(50):
        t += 5.0
        p = a.step(target(ACTIVITIES[i % len(ACTIVITIES)], EMOTIONS[i % 9]), 5.0, i % 2 == 0, t)
        assert all(math.isfinite(getattr(p, n)) for n in FLOATS)
        assert abs(p.gaze_x) < 3 and 0 <= p.eye_h < 3


def test_widget_renders_offscreen():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtWidgets import QApplication

    from robo.face.widget import FaceWidget

    app = QApplication.instance() or QApplication([])
    w = FaceWidget()
    w.resize(320, 240)
    w.set_state("talking", "happy", True)
    img = w.grab().toImage()
    assert img.width() == 320
    assert len({img.pixel(x, y) for x in range(0, 320, 8) for y in range(0, 240, 8)}) > 3
    assert app is not None


def test_expression_changes_happen_behind_a_blink():
    """No half-happy, half-sad eyes: lid and eye shapes change only while the eyes are shut."""
    from robo.face.animator import SHAPE

    a = Animator(seed=8)
    happy, sad = target("talking", "happy"), target("idle", "sad")
    run(a, happy, 1.0)
    frames = run(a, sad, 1.0, t0=1.0)
    for _, p in frames:
        open_eyes = p.eye_h > 0.4 * sad.eye_h
        for n in SHAPE:
            v, before, after = getattr(p, n), getattr(happy, n), getattr(sad, n)
            if open_eyes:  # visible: either the old shape or the new one, never a mix
                assert min(abs(v - before), abs(v - after)) < 1e-6, n
    t, p = frames[-1]
    assert all(getattr(p, n) == pytest.approx(getattr(sad, n)) for n in SHAPE)
    assert frames[0][0] - 1.0 < 0.05 and min(q.eye_h for _, q in frames[:20]) < 0.4 * sad.eye_h


@pytest.fixture
def face():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtWidgets import QApplication

    from robo.face.widget import FaceWidget

    app = QApplication.instance() or QApplication([])
    w = FaceWidget(seed=1)
    yield w
    w.deleteLater()
    assert app is not None


# Frame interval (ms) the face repaints at: the pet sleeps most of the day, so a calm face is cheap.
RATES = {"idle": 40, "sleepy": 66, "asleep": 100}


@pytest.mark.parametrize("activity", ACTIVITIES)
def test_frame_interval_follows_activity(face, activity):
    face.set_state(activity, "neutral")
    assert face.timer.interval() == RATES.get(activity, 33)


def test_waking_returns_to_the_fast_rate_at_once(face):
    face.set_state("asleep", "neutral")
    assert face.timer.interval() == 100
    face.set_state("listening", "neutral")
    assert face.timer.interval() == 33
    face.set_state("asleep", "neutral")
    face.set_state("idle", "neutral")
    assert face.timer.interval() == 40


def test_set_state_leaves_the_timer_alone_when_the_rate_is_unchanged(face):
    """setInterval restarts a running timer, and the app calls set_state all the time."""
    calls, set_interval = [], face.timer.setInterval
    face.timer.setInterval = lambda ms: (calls.append(ms), set_interval(ms))
    for activity in ("idle", "idle", "talking", "talking", "listening", "talking"):
        face.set_state(activity, "neutral", activity == "talking")
    assert calls == [33]


@pytest.mark.parametrize("activity", [a for a in ACTIVITIES if a != "asleep"])
def test_blinks_survive_the_frame_rate(activity):
    """At the frame rate its activity runs at, every blink still shows >= 2 visibly shut frames."""
    dt, goal = RATES.get(activity, 33) / 1000, target(activity, "neutral")
    a = Animator(seed=11)
    shut = {}  # blink start -> eye heights of the frames that show it
    for i in range(1, int(40 / dt)):
        p = a.step(goal, dt, False, i * dt)
        if p.eye_h < 0.9 * goal.eye_h:  # outside a blink eye_h sits at the goal
            shut.setdefault(a.blink_at, []).append(p.eye_h)
    complete = [v for k, v in shut.items() if k < 39]
    assert len(complete) >= 5
    assert all(len(v) >= 2 and min(v) < 0.5 * goal.eye_h for v in complete)


def test_glow_layers_skip_antialiasing_but_the_solid_shapes_keep_it(face):
    """The 5 %-alpha halo layers have no visible edge, so AA on them is pure cost (~4x at idle)."""
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import QImage, QPainter, QPainterPath

    from robo.face.widget import _glow

    aa = QPainter.RenderHint.Antialiasing

    class Spy(QPainter):
        seen: list[bool] = []

        def drawPath(self, path):  # noqa: N802 - Qt override
            self.seen.append(self.testRenderHint(aa))
            super().drawPath(path)

    img = QImage(64, 48, QImage.Format.Format_ARGB32_Premultiplied)
    painter = Spy(img)
    painter.setRenderHint(aa)
    path = QPainterPath()
    path.addRoundedRect(QRectF(10, 10, 30, 20), 5, 5)
    _glow(painter, path, target("idle", "neutral"))
    assert Spy.seen == [False] * 7
    assert painter.testRenderHint(aa)
    painter.end()


# --- the theme hooks: set_theme(hue_fn, bg) and render_params(..., bg=) -------------------------

def paint(params, bg=None, size=(64, 48)):
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import QImage, QPainter

    from robo.face.widget import render_params

    img = QImage(*size, QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(0)
    painter = QPainter(img)
    render_params(painter, QRectF(0, 0, *size), params, 0.5, *([] if bg is None else [bg]))
    painter.end()
    return img


def test_the_default_screen_is_the_dark_blue_it_always_was():
    from PySide6.QtGui import QColor

    from robo.face.widget import BG, SCREEN

    assert QColor(18, 26, 42) == SCREEN and QColor(9, 13, 22) == BG
    for activity, emotion in (("idle", "neutral"), ("talking", "happy"), ("error", "sad")):
        p = target(activity, emotion)
        default = paint(p)
        assert default == paint(p, (SCREEN, BG))  # pixel for pixel
        assert default == paint(p, ("#121a2a", "#090d16"))  # the same colours as theme tokens


def test_a_theme_screen_replaces_both_colours():
    from PySide6.QtGui import QColor

    p = target("idle", "neutral")
    img = paint(p, ("#336699", "#336699"))
    assert QColor(img.pixel(1, 1)) == QColor("#336699")  # a corner, clear of the face
    assert paint(p, ("#336699", "#336699")) != paint(p)
    corner = QColor(paint(p, ("#000000", "#ff0000")).pixel(1, 1))
    assert corner.red() > corner.blue() + 100  # the edge colour is at the corners


def test_without_a_theme_the_goal_is_the_expression_table(face):
    for activity, emotion in (("idle", "neutral"), ("thinking", "curious"), ("error", "sad"),
                              ("talking", "happy"), ("asleep", "proud")):
        face.set_state(activity, emotion)
        assert face.goal == target(activity, emotion)
    assert face.hue_fn is None and face.bg is None


def test_the_hue_function_gets_the_state_and_the_base_hue(face):
    seen = []

    def hue_fn(activity, emotion, hue):
        seen.append((activity, emotion, hue))
        return 99.0

    face.set_theme(hue_fn)
    face.set_state("working", "sad")
    assert seen[-1] == ("working", "sad", 216.0)  # the table's hue, before the theme's
    assert face.goal.hue == 99.0
    assert replace(face.goal, hue=216.0) == target("working", "sad")  # nothing else changes
    assert face.talking is False
    face.set_state("idle", "neutral", True)
    assert face.talking is True and seen[-1] == ("idle", "neutral", 188.0)


def test_set_theme_applies_to_the_state_the_face_is_in(face):
    face.set_state("idle", "happy", True)
    face.set_theme(lambda a, e, h: 7.0)
    assert face.goal.hue == 7.0 and face.talking is True
    assert face.timer.interval() == 40  # idle's rate: set_state ran again
    face.set_theme()  # back to the plain face
    assert face.goal == target("idle", "happy") and face.hue_fn is None


@pytest.mark.parametrize(("key", "neutral", "happy", "proud", "sad"),
                         [("cyan", 188, 168, 44, 216), ("matrix", 128, 108, 44, 216),
                          ("amber", 38, 18, 52, 216), ("aurora", 268, 248, 44, 216),
                          ("daylight", 196, 176, 44, 216)])
def test_the_face_takes_robo_themes_hues(face, key, neutral, happy, proud, sad):
    from functools import partial

    from robo.theme import THEMES, hue_for

    face.set_theme(partial(hue_for, THEMES[key]), THEMES[key].face_bg)
    for activity, emotion, hue in (("idle", "neutral", neutral), ("idle", "happy", happy),
                                   ("idle", "proud", proud), ("idle", "sad", sad),
                                   ("error", "sad", 356)):  # an error is red in every theme
        face.set_state(activity, emotion)
        assert face.goal.hue == pytest.approx(hue), (key, activity, emotion)


def test_snap_skips_the_sweep_to_the_new_hue(face):
    face.set_theme(lambda a, e, h: 128.0)
    assert face.params.hue == 188.0  # the spring would take about 0.3 s
    face.set_theme(lambda a, e, h: 128.0, snap=True)
    assert face.params.hue == 128.0 and face.anim.x["hue"] == 128.0 and face.anim.v["hue"] == 0.0
    face._tick()
    assert face.params.hue == pytest.approx(128.0, abs=0.5)  # and it stays there


def test_the_widget_paints_the_themes_screen(face):
    from PySide6.QtGui import QColor

    face.resize(160, 120)
    face.set_theme(bg=("#336699", "#336699"))
    assert QColor(face.grab().toImage().pixel(1, 1)) == QColor("#336699")
    face.set_theme()
    assert QColor(face.grab().toImage().pixel(1, 1)) != QColor("#336699")
