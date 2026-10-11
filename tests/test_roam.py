import math
import random

import pytest

from robo.roam import EDGE, HOLD, MARGIN, MAX_DT, REST, SPEED, Rect, Roamer, fit, pick_target

SCREEN = Rect(0, 0, 1920, 1080)
FACE = (120, 120)
BUBBLE = (400, 300)
FPS = 30
PEAK = 1.5 * SPEED  # smoothstep ease-in-out peaks at 1.5x the average speed
ROUNDING = 1.5  # px: integer output can add up to ~sqrt(2) to a step
TOP = (900, 0)  # far from the margin band, so the first drift is long


def run(r, t0, seconds, activity="idle", engaged=False, fps=FPS):
    """Step `r` at `fps` for `seconds` after t0; return [(t, pos)]."""
    ts = [t0 + i / fps for i in range(1, int(seconds * fps) + 1)]
    return [(t, r.step(t, activity, engaged)) for t in ts]


def until(r, t, mode, limit=600.0):
    """Step an idle `r` at FPS from t until it is in `mode`; return the time."""
    while r.mode != mode:
        t += 1 / FPS
        assert t < limit, f"never reached {mode}"
        r.step(t, "idle", False)
    return t


def inside(pos, size, screen=SCREEN):
    """Fully on screen, or pinned to the top/left edge on an axis it cannot fit."""
    spans = zip(pos, (screen.x, screen.y), (screen.w, screen.h), size, strict=True)
    return all(lo <= v <= max(lo, lo + span - s) for v, lo, span, s in spans)


@pytest.mark.parametrize("pos, want", [
    ((-50, -50), (0, 0)),
    ((5000, 5000), (1800, 960)),
    ((300, 400), (300, 400)),
])
def test_fit_keeps_the_window_inside(pos, want):
    assert fit(pos, FACE, SCREEN) == want


@pytest.mark.parametrize("activity", ["idle", "asleep"])
def test_window_bigger_than_screen_is_pinned_top_left(activity):
    tiny = Rect(10, 20, 100, 80)
    r = Roamer(tiny, FACE, seed=0)
    assert {p for _, p in run(r, 0.0, 200, activity)} == {(10, 20)}


@pytest.mark.parametrize("activity", ["idle", "asleep"])
def test_present_freezes_mid_drift(activity):
    r = Roamer(SCREEN, FACE, seed=2, start=TOP)
    t = until(r, 0.0, "drift") + 1
    run(r, t - 1, 1)
    assert r.mode == "drift"
    frozen = r.step(t, activity, True)
    assert {p for _, p in run(r, t, 30, activity, engaged=True)} == {frozen}
    assert r.mode == "present"


def test_present_slides_the_bubble_on_screen():
    r = Roamer(SCREEN, FACE, seed=3, start=(1800, 960))
    r.step(0.0, "idle", True)
    r.resize(BUBBLE)
    pos = r.step(0.1, "idle", True)
    assert pos == (1520, 780)
    assert {p for _, p in run(r, 0.1, 10, engaged=True)} == {pos}

    r = Roamer(SCREEN, FACE, seed=3, start=(300, 200))
    r.resize(BUBBLE)
    assert r.step(0.0, "idle", True) == (300, 200)


def test_sleep_glides_to_the_bottom_right_corner_and_stays():
    r = Roamer(SCREEN, FACE, seed=4, start=(0, 0))
    path = run(r, 0.0, 120, "asleep")
    bed = (1920 - 120 - EDGE, 1080 - 120 - EDGE)
    assert path[-1][1] == bed and r.mode == "sleep"
    assert {p for _, p in run(r, 120, 60, "asleep")} == {bed}


def test_hold_stays_put_then_wanders_from_there():
    r = Roamer(SCREEN, FACE, seed=5)
    r.step(0.0, "idle", False)
    r.hold(0.0, (500, 300))
    assert {p for _, p in run(r, 0.0, HOLD - 1, fps=4)} == {(500, 300)}
    assert {p for _, p in run(r, HOLD - 1, 0.5, "asleep", fps=4)} == {(500, 300)}
    assert r.mode == "held"
    path = [p for _, p in run(r, HOLD, 120)]
    assert any(p != (500, 300) for p in path)
    assert math.dist(path[0], (500, 300)) <= 2


def test_hold_is_clamped():
    r = Roamer(SCREEN, FACE, seed=5)
    r.hold(0.0, (5000, -40))
    assert r.step(0.0, "idle", False) == (1800, 0)


def test_drift_reaches_its_target_then_rests():
    r = Roamer(SCREEN, FACE, seed=1)
    t = until(r, 0.0, "drift")
    goal = r.goal
    t = until(r, t, "rest")
    assert r.step(t, "idle", False) == (round(goal[0]), round(goal[1]))
    rested = until(r, t, "drift") - t
    assert REST[0] <= rested <= REST[1] + 2 / FPS


@pytest.mark.parametrize("screen", [SCREEN, Rect(-1280, 200, 1280, 1024)])
def test_targets_lie_in_the_margin_band(screen):
    rng = random.Random(0)
    w, h = FACE
    cx, cy = screen.x + screen.w / 2, screen.y + screen.h / 2
    sides = set()
    for _ in range(2000):
        x, y = pick_target(rng, screen, FACE)
        assert inside((x, y), FACE, screen)
        gaps = (x - screen.x, screen.x + screen.w - x - w, screen.y + screen.h - y - h)
        assert min(gaps) <= MARGIN
        assert not (x <= cx <= x + w and y <= cy <= y + h)
        sides |= {i for i, g in enumerate(gaps) if g <= MARGIN}
    assert sides == {0, 1, 2}


def test_never_faster_than_the_speed_limit():
    r = Roamer(SCREEN, FACE, seed=6)
    path = [(0.0, r.step(0.0, "idle", False))] + run(r, 0.0, 600)
    for (t0, a), (t1, b) in zip(path, path[1:], strict=False):
        assert math.dist(a, b) <= PEAK * (t1 - t0) + ROUNDING
    assert len({p for _, p in path}) > 100


def test_a_long_gap_moves_at_most_one_capped_frame():
    r = Roamer(SCREEN, FACE, seed=7, start=TOP)
    t = until(r, 0.0, "drift") + 0.5
    a = r.step(t, "idle", False)
    assert r.mode == "drift"
    b = r.step(t + 3600, "idle", False)
    assert math.dist(a, b) <= PEAK * MAX_DT + ROUNDING


def test_same_seed_same_path():
    a, b, c = (run(Roamer(SCREEN, FACE, seed=s), 0.0, 300) for s in (9, 9, 10))
    assert a == b != c


def test_resize_and_a_new_screen_keep_it_on_screen():
    r = Roamer(SCREEN, FACE, seed=11, start=(1800, 960))
    r.resize(BUBBLE)
    assert r.step(0.0, "idle", False) == (1520, 780)
    r.set_screen(Rect(0, 0, 1280, 720))
    assert r.step(0.1, "idle", False) == (880, 420)


def test_an_hour_of_jittery_frames_never_leaves_the_screen():
    rng = random.Random(0)
    screens = [SCREEN, Rect(-1280, 200, 1280, 1024), Rect(0, 0, 200, 150)]
    r, t = Roamer(SCREEN, FACE, seed=12), 0.0
    while t < 3600:
        t += rng.choice([1 / FPS] * 30 + [0.0, 0.5, 5.0])
        engaged = (t // 90) % 5 == 0
        size = BUBBLE if engaged else FACE
        if size != r.size:
            r.resize(size)
        screen = screens[min(int(t // 1200), 2)]
        if screen != r.screen:
            r.set_screen(screen)
        if rng.random() < 0.0005:
            r.hold(t, (rng.uniform(-500, 3000), rng.uniform(-500, 3000)), seconds=60)
        activity = "asleep" if (t // 300) % 4 == 3 else "idle"
        pos = r.step(t, activity, engaged)
        assert all(type(v) is int for v in pos)
        assert all(math.isfinite(v) for v in r.pos)
        assert inside(pos, size, screen)
