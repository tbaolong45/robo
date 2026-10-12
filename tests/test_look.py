"""Where robo's eyes point: at the cursor while it moves, along its walk, else free glances."""

import math

import pytest

from robo.face.animator import LOOK_GAIN, LOOK_STALE, Animator, look_at
from robo.face.expressions import target
from robo.roam import Rect, Roamer

CENTRE = (500.0, 500.0)


def test_eyes_point_toward_the_cursor():
    right, above = look_at(CENTRE, (900, 500), 0), look_at(CENTRE, (500, 100), 0)
    assert right[0] > 0.3 and abs(right[1]) < 1e-9
    assert above[1] < -0.3 and abs(above[0]) < 1e-9


def test_a_near_cursor_looks_less_than_a_far_one_and_it_caps():
    near = math.hypot(*look_at(CENTRE, (540, 500), 0))
    far = math.hypot(*look_at(CENTRE, (900, 500), 0))
    gone = math.hypot(*look_at(CENTRE, (5000, 5000), 0))
    assert 0 < near < far < gone
    assert gone == pytest.approx(LOOK_GAIN)


def test_a_cursor_on_the_face_gives_no_pull():
    assert look_at(CENTRE, CENTRE, 0) == (0.0, 0.0)


def test_a_still_cursor_is_forgotten_then_the_walk_decides():
    assert look_at(CENTRE, (900, 500), LOOK_STALE) is None
    assert look_at(CENTRE, (900, 500), LOOK_STALE, heading=-1)[0] < 0
    assert look_at(CENTRE, (900, 500), LOOK_STALE, heading=1)[0] > 0


def test_a_moving_cursor_beats_the_walk():
    assert look_at(CENTRE, (900, 500), 0, heading=-1)[0] > 0


def settle(anim, goal, look, secs=1.5, dt=1 / 30):
    t, p = 0.0, None
    while t < secs:
        t += dt
        p = anim.step(goal, dt, False, t, look=look)
    return p


def test_idle_eyes_follow_the_look_and_free_glances_stay_small():
    idle = target("idle", "neutral")
    assert settle(Animator(1), idle, (0.9, 0.0)).gaze_x > 0.7
    assert abs(settle(Animator(1), idle, None).gaze_x) <= 0.36


def test_a_thinking_face_keeps_its_own_gaze():
    thinking = target("thinking", "neutral")
    p = settle(Animator(1), thinking, (-0.9, 0.0))
    assert p.gaze_x == pytest.approx(thinking.gaze_x, abs=0.05)


def test_no_look_changes_nothing():
    idle = target("idle", "neutral")
    a, b = Animator(5), Animator(5)
    for i in range(1, 200):
        assert a.step(idle, 1 / 60, False, i / 60) == b.step(idle, 1 / 60, False, i / 60, look=None)


@pytest.mark.parametrize(("start", "goal", "want"),
                         [((100, 900), (900, 900), 1), ((900, 900), (100, 900), -1)])
def test_heading_follows_a_drift_and_is_zero_at_rest(start, goal, want):
    r = Roamer(Rect(0, 0, 1920, 1080), (120, 120), seed=1, start=start)
    assert r.heading == 0  # resting before the first drift
    r.pos = r.origin = start
    r._go(goal)
    r.mode = "drift"
    assert r.heading == want
    r.mode = "rest"
    assert r.heading == 0


def test_the_widget_hands_the_look_to_the_animator():
    from PySide6.QtWidgets import QApplication

    from robo.face.widget import FaceWidget

    app = QApplication.instance() or QApplication([])
    w = FaceWidget(seed=1)
    w.set_state("idle", "neutral")
    w.set_look((0.9, 0.0))
    for _ in range(60):
        w.last -= 1 / 30  # pretend a frame's time passed instead of sleeping
        w._tick()
    assert w.params.gaze_x > 0.7
    w.set_look(None)
    for _ in range(60):
        w.last -= 1 / 30
        w._tick()
    assert abs(w.params.gaze_x) < 0.4
    assert app is not None
