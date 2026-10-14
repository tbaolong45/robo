import math
import random

import pytest

from robo.roam import (
    CALL_SPEED,
    EDGE,
    HOLD,
    MARGIN,
    MAX_DT,
    REST,
    SPEED,
    Rect,
    Roamer,
    fit,
    pick_target,
)

SCREEN = Rect(0, 0, 1920, 1080)
SCREENS = (SCREEN,)
RIGHT = Rect(1920, 0, 2560, 1440)  # an external monitor to the right of SCREEN, and taller
LEFT = Rect(-2560, -180, 2560, 1440)  # or to its left, so x goes negative
BOTH = (SCREEN, RIGHT)
FACE = (120, 120)
BUBBLE = (400, 300)
FPS = 30
PEAK = 1.5 * SPEED  # smoothstep ease-in-out peaks at 1.5x the average speed
ROUNDING = 1.5  # px: integer output can add up to ~sqrt(2) to a step
TOP = (900, 0)  # far from the margin band, so the first drift is long


def run(r, t0, seconds, activity="idle", engaged=False, fps=FPS, called=False):
    """Step `r` at `fps` for `seconds` after t0; return [(t, pos)]."""
    ts = [t0 + i / fps for i in range(1, int(seconds * fps) + 1)]
    return [(t, r.step(t, activity, engaged, called)) for t in ts]


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
    assert fit(pos, FACE, SCREENS) == want


@pytest.mark.parametrize("activity", ["idle", "asleep"])
def test_window_bigger_than_screen_is_pinned_top_left(activity):
    tiny = Rect(10, 20, 100, 80)
    r = Roamer((tiny,), FACE, seed=0)
    assert {p for _, p in run(r, 0.0, 200, activity)} == {(10, 20)}


@pytest.mark.parametrize("activity", ["idle", "asleep"])
def test_present_freezes_mid_drift(activity):
    r = Roamer(SCREENS, FACE, seed=2, start=TOP)
    t = until(r, 0.0, "drift") + 1
    run(r, t - 1, 1)
    assert r.mode == "drift"
    frozen = r.step(t, activity, True)
    assert {p for _, p in run(r, t, 30, activity, engaged=True)} == {frozen}
    assert r.mode == "present"


def test_present_slides_the_bubble_on_screen():
    r = Roamer(SCREENS, FACE, seed=3, start=(1800, 960))
    r.step(0.0, "idle", True)
    r.resize(BUBBLE)
    pos = r.step(0.1, "idle", True)
    assert pos == (1520, 780)
    assert {p for _, p in run(r, 0.1, 10, engaged=True)} == {pos}

    r = Roamer(SCREENS, FACE, seed=3, start=(300, 200))
    r.resize(BUBBLE)
    assert r.step(0.0, "idle", True) == (300, 200)


def test_sleep_glides_to_the_bottom_right_corner_and_stays():
    r = Roamer(SCREENS, FACE, seed=4, start=(0, 0))
    path = run(r, 0.0, 120, "asleep")
    bed = (1920 - 120 - EDGE, 1080 - 120 - EDGE)
    assert path[-1][1] == bed and r.mode == "sleep"
    assert {p for _, p in run(r, 120, 60, "asleep")} == {bed}


def test_hold_stays_put_then_wanders_from_there():
    r = Roamer(SCREENS, FACE, seed=5)
    r.step(0.0, "idle", False)
    r.hold(0.0, (500, 300))
    assert {p for _, p in run(r, 0.0, HOLD - 1, fps=4)} == {(500, 300)}
    assert {p for _, p in run(r, HOLD - 1, 0.5, "asleep", fps=4)} == {(500, 300)}
    assert r.mode == "held"
    path = [p for _, p in run(r, HOLD, 120)]
    assert any(p != (500, 300) for p in path)
    assert math.dist(path[0], (500, 300)) <= 2


def test_hold_is_clamped():
    r = Roamer(SCREENS, FACE, seed=5)
    r.hold(0.0, (5000, -40))
    assert r.step(0.0, "idle", False) == (1800, 0)


def test_drift_reaches_its_target_then_rests():
    r = Roamer(SCREENS, FACE, seed=1)
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
    r = Roamer(SCREENS, FACE, seed=6)
    path = [(0.0, r.step(0.0, "idle", False))] + run(r, 0.0, 600)
    for (t0, a), (t1, b) in zip(path, path[1:], strict=False):
        assert math.dist(a, b) <= PEAK * (t1 - t0) + ROUNDING
    assert len({p for _, p in path}) > 100


def test_a_long_gap_moves_at_most_one_capped_frame():
    r = Roamer(SCREENS, FACE, seed=7, start=TOP)
    t = until(r, 0.0, "drift") + 0.5
    a = r.step(t, "idle", False)
    assert r.mode == "drift"
    b = r.step(t + 3600, "idle", False)
    assert math.dist(a, b) <= PEAK * MAX_DT + ROUNDING


def test_same_seed_same_path():
    a, b, c = (run(Roamer(SCREENS, FACE, seed=s), 0.0, 300) for s in (9, 9, 10))
    assert a == b != c


def test_resize_and_a_new_screen_keep_it_on_screen():
    r = Roamer(SCREENS, FACE, seed=11, start=(1800, 960))
    r.resize(BUBBLE)
    assert r.step(0.0, "idle", False) == (1520, 780)
    r.set_screens((Rect(0, 0, 1280, 720),))
    assert r.step(0.1, "idle", False) == (880, 420)


def test_an_hour_of_jittery_frames_never_leaves_the_screen():
    rng = random.Random(0)
    screens = [SCREEN, Rect(-1280, 200, 1280, 1024), Rect(0, 0, 200, 150)]
    r, t = Roamer(SCREENS, FACE, seed=12), 0.0
    while t < 3600:
        t += rng.choice([1 / FPS] * 30 + [0.0, 0.5, 5.0])
        engaged = (t // 90) % 5 == 0
        size = BUBBLE if engaged else FACE
        if size != r.size:
            r.resize(size)
        screen = screens[min(int(t // 1200), 2)]
        if (screen,) != r.screens:
            r.set_screens((screen,))
        if rng.random() < 0.0005:
            r.hold(t, (rng.uniform(-500, 3000), rng.uniform(-500, 3000)), seconds=60)
        activity = "asleep" if (t // 300) % 4 == 3 else "idle"
        pos = r.step(t, activity, engaged)
        assert all(type(v) is int for v in pos)
        assert all(math.isfinite(v) for v in r.pos)
        assert inside(pos, size, screen)


def covered(pos, size, screens, n=8):
    """Every point of an n x n grid over the window (corners included) lies on some screen.
    Checked by sampling, so it does not share fit()'s area arithmetic."""
    points = [(pos[0] + size[0] * i / n, pos[1] + size[1] * j / n)
              for i in range(n + 1) for j in range(n + 1)]
    return all(any(s.x <= x <= s.x + s.w and s.y <= y <= s.y + s.h for s in screens)
               for x, y in points)


@pytest.mark.parametrize("screens, pos, want", [
    (BOTH, (2500, 300), (2500, 300)),  # on the second screen
    (BOTH, (1860, 300), (1860, 300)),  # straddling the border with both halves on screen
    (BOTH, (9000, 300), (4360, 300)),  # past the far edge: onto the nearest screen
    ((LEFT, SCREEN), (-3000, 100), (-2560, 100)),  # a monitor on the left, negative x
    ((SCREEN, Rect(1920, 400, 2560, 1440)), (1860, 100), (1800, 100)),  # half over a dead corner
])
def test_fit_across_screens(screens, pos, want):
    got = fit(pos, FACE, screens)
    assert got == want and covered(got, FACE, screens)


def test_a_drop_on_the_second_screen_stays():
    r = Roamer(BOTH, FACE, seed=5)
    r.hold(0.0, (3000, 500))
    assert r.step(0.0, "idle", False) == (3000, 500)


def test_it_sleeps_in_the_corner_of_the_screen_it_is_on():
    r = Roamer(BOTH, FACE, seed=4, start=(3000, 500))
    path = run(r, 0.0, 200, "asleep")
    assert path[-1][1] == (RIGHT.x + RIGHT.w - 120 - EDGE, RIGHT.y + RIGHT.h - 120 - EDGE)


def test_it_wanders_onto_every_screen_and_never_off_them():
    r, seen = Roamer(BOTH, FACE, seed=1), set()
    for _, pos in run(r, 0.0, 3600):
        assert covered(pos, FACE, BOTH)
        cx, cy = pos[0] + FACE[0] / 2, pos[1] + FACE[1] / 2
        seen |= {i for i, s in enumerate(BOTH) if s.x <= cx < s.x + s.w and s.y <= cy < s.y + s.h}
    assert seen == {0, 1}


def test_unplugging_its_screen_brings_it_back_to_the_one_left():
    r = Roamer(BOTH, FACE, seed=6, start=(3000, 500))
    r.set_screens((SCREEN,))
    assert r.step(0.0, "idle", False) == (1800, 500)


# --- called: it walks to the nearest corner of its screen instead of freezing mid-drift -----------

LEFT_EDGE, RIGHT_EDGE = EDGE, 1920 - 120 - EDGE
TOP_EDGE, BOTTOM_EDGE = EDGE, 1080 - 120 - EDGE


@pytest.mark.parametrize(("start", "corner"), [
    ((700, 300), (LEFT_EDGE, TOP_EDGE)),
    ((1100, 300), (RIGHT_EDGE, TOP_EDGE)),
    ((700, 700), (LEFT_EDGE, BOTTOM_EDGE)),
    ((1100, 700), (RIGHT_EDGE, BOTTOM_EDGE)),
])
def test_called_walks_to_the_nearest_corner_at_call_speed_and_stays(start, corner):
    r = Roamer(SCREENS, FACE, seed=1, start=start)
    trip = math.dist(start, corner) / CALL_SPEED
    run(r, 0.0, trip - 1, called=True)
    assert r.pos != corner and r.mode == "come"
    assert run(r, trip - 1, 2.5, called=True)[-1][1] == corner  # on time, not at drift speed
    assert {p for _, p in run(r, trip + 1.5, 30, called=True)} == {corner}


def test_its_eyes_lead_the_way_to_the_corner():
    r = Roamer(SCREENS, FACE, seed=1, start=(700, 300))
    run(r, 0.0, 0.5, called=True)
    assert r.heading == -1


def test_pressing_it_freezes_the_walk():
    r = Roamer(SCREENS, FACE, seed=1, start=(700, 300))
    run(r, 0.0, 1, called=True)
    frozen = r.step(1.0, "idle", True, True)
    assert {p for _, p in run(r, 1.0, 5, engaged=True, called=True)} == {frozen}
    assert r.mode == "present"


def test_a_spot_the_user_chose_wins_over_a_call():
    r = Roamer(SCREENS, FACE, seed=5)
    r.hold(0.0, (500, 300))
    assert {p for _, p in run(r, 0.0, 20, called=True)} == {(500, 300)} and r.mode == "held"
    assert run(r, HOLD, 20, called=True)[-1][1] == (LEFT_EDGE, TOP_EDGE)  # the hold is over


def test_after_a_call_it_rests_in_the_corner_then_drifts_on():
    r = Roamer(SCREENS, FACE, seed=1, start=(700, 300))
    corner = (LEFT_EDGE, TOP_EDGE)
    assert run(r, 0.0, 10, called=True)[-1][1] == corner
    assert {p for _, p in run(r, 10, REST[0] - 1)} == {corner} and r.mode == "rest"
    assert any(p != corner for _, p in run(r, 10 + REST[0] - 1, REST[1] + 10))


def test_the_corner_is_one_of_the_screen_it_is_on():
    main, built_in = Rect(0, 0, 2560, 1440), Rect(-1800, 271, 1800, 1169)
    r = Roamer((main, built_in), FACE, seed=1, start=(-1700, 500))
    assert run(r, 0.0, 30, called=True)[-1][1] == (-1800 + EDGE, 271 + EDGE)


def test_a_call_wins_over_sleep():
    r = Roamer(SCREENS, FACE, seed=1, start=(700, 300))  # bed: bottom-right; call: top-left
    assert run(r, 0.0, 20, "asleep", called=True)[-1][1] == (LEFT_EDGE, TOP_EDGE)


def test_a_bigger_window_re_aims_the_walk():
    r = Roamer(SCREENS, FACE, seed=1, start=(1100, 700))
    run(r, 0.0, 1, called=True)
    r.resize(BUBBLE)
    assert run(r, 1.0, 20, called=True)[-1][1] == (1920 - 400 - EDGE, 1080 - 300 - EDGE)
