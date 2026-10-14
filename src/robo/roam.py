"""Where the floating face goes: a pure, time-stepped wander along the screen edges."""

from __future__ import annotations

import math
import random
from collections.abc import Sequence
from dataclasses import dataclass

SPEED = 40.0  # px/s average travel speed (ease-in-out peaks at 1.5x)
CALL_SPEED = 240.0  # px/s: the walk to a corner when called; a drift's pace would take a minute
REST = (20.0, 60.0)  # s to rest between drifts
MARGIN = 160  # px: drift targets lie this close to the bottom, left or right edge
EDGE = 24  # px gap from the bottom-right corner where it sleeps
HOLD = 600.0  # s to stay where the user dropped it
MAX_DT = 0.25  # s: a longer gap (a suspended laptop) counts as one capped frame


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    w: int
    h: int


def _clamp(pos: tuple[float, float], size: tuple[int, int], screen: Rect) -> tuple[float, float]:
    """Clamp a top-left so the window is fully inside one screen; pinned top-left if it cannot."""
    x = max(screen.x, min(pos[0], screen.x + screen.w - size[0]))
    y = max(screen.y, min(pos[1], screen.y + screen.h - size[1]))
    return x, y


def _overlap(pos: tuple[float, float], size: tuple[int, int], screen: Rect) -> float:
    w = min(pos[0] + size[0], screen.x + screen.w) - max(pos[0], screen.x)
    h = min(pos[1] + size[1], screen.y + screen.h) - max(pos[1], screen.y)
    return max(w, 0) * max(h, 0)


def fit(pos: tuple[float, float], size: tuple[int, int],
        screens: Sequence[Rect]) -> tuple[float, float]:
    """Keep the window fully inside the screens, where it may straddle two that touch.

    Screens never overlap, so the window is inside their union exactly when its overlaps add up
    to its whole area. Otherwise (a dead corner between unequal monitors, or past the edge) it
    moves to the nearest spot inside a single screen; pinned top-left if it fits on none."""
    if sum(_overlap(pos, size, s) for s in screens) >= size[0] * size[1] - 1e-3:
        return pos
    return min((_clamp(pos, size, s) for s in screens), key=lambda p: math.dist(p, pos))


def pick_target(rng: random.Random, screen: Rect, size: tuple[int, int]) -> tuple[float, float]:
    """A random top-left in the margin band along the bottom, left or right edge."""
    right, bottom = screen.x + screen.w - size[0], screen.y + screen.h - size[1]
    side = rng.choice(("bottom", "left", "right"))
    x = rng.uniform(screen.x, right)
    y = rng.uniform(screen.y, bottom)
    if side == "bottom":
        y = rng.uniform(bottom - MARGIN, bottom)
    elif side == "left":
        x = rng.uniform(screen.x, screen.x + MARGIN)
    else:
        x = rng.uniform(right - MARGIN, right)
    return _clamp((x, y), size, screen)


def _ease(p: float) -> float:
    return p * p * (3 - 2 * p)


class Roamer:
    """Moves the window like a pet: rest, drift, sleep in the corner, stay when needed."""

    def __init__(self, screens: Sequence[Rect], size: tuple[int, int], seed: int | None = None,
                 start: tuple[float, float] | None = None):
        self.rng = random.Random(seed)
        self.screens, self.size = tuple(screens), size
        self.pos = start or (0.0, 0.0)  # `_bed` needs it: the corner of the screen it is on
        self.pos = fit(start or self._bed(), size, self.screens)
        self.mode = ""
        self.last: float | None = None
        self.held_until = -math.inf
        self.rest_until = 0.0
        self.origin = self.goal = self.pos
        self.trip = self.elapsed = 0.0

    @property
    def heading(self) -> int:
        """-1 / 1 while drifting left / right, else 0: where its eyes should lead."""
        dx = self.goal[0] - self.pos[0]
        return ((dx > 8) - (dx < -8)) if self.mode in ("drift", "come") else 0

    def resize(self, size: tuple[int, int]) -> None:
        self.size = size
        self.pos = fit(self.pos, size, self.screens)

    def set_screens(self, screens: Sequence[Rect]) -> None:
        self.screens = tuple(screens)
        self.pos = fit(self.pos, self.size, self.screens)

    def hold(self, now: float, pos: tuple[float, float], seconds: float = HOLD) -> None:
        """The user dropped it at `pos`: stay there for `seconds`."""
        self.pos = fit(pos, self.size, self.screens)
        self.held_until = now + seconds

    def step(self, now: float, activity: str, engaged: bool,
             called: bool = False) -> tuple[int, int]:
        """Advance to `now`; return the window's top-left. `engaged`: the user has it by the
        mouse, so it freezes. `called`: a request or the card is up, so it walks to the nearest
        corner and stays (a spot the user chose, `held`, wins)."""
        dt = 0.0 if self.last is None else min(max(now - self.last, 0.0), MAX_DT)
        self.last = now
        if engaged:
            self.mode = "present"
        elif now < self.held_until:
            self.mode = "held"
        elif called:
            if self.mode != "come" or self.goal != self._nearest_corner():
                self._go(self._nearest_corner(), CALL_SPEED)
            self.mode = "come"
            self._travel(dt)
        elif activity == "asleep":
            if self.mode != "sleep" or self.goal != self._bed():
                self._go(self._bed())
            self.mode = "sleep"
            self._travel(dt)
        else:
            self._wander(now, dt)
        self.pos = fit(self.pos, self.size, self.screens)
        return round(self.pos[0]), round(self.pos[1])

    def _wander(self, now: float, dt: float) -> None:
        if self.mode not in ("rest", "drift"):
            self._rest(now)
        if self.mode == "rest" and now >= self.rest_until:
            self._go(pick_target(self.rng, self._any_screen(), self.size))
            self.mode = "drift"
        if self.mode == "drift" and self._travel(dt):
            self._rest(now)

    def _rest(self, now: float) -> None:
        self.mode = "rest"
        self.rest_until = now + self.rng.uniform(*REST)

    def _any_screen(self) -> Rect:
        """A random screen to drift to (the only one without drawing, so a seed keeps its path)."""
        return self.screens[0] if len(self.screens) == 1 else self.rng.choice(self.screens)

    def _corners(self) -> list[tuple[float, float]]:
        """The four corners (top-left, top-right, bottom-left, bottom-right) of the screen it is
        on, EDGE in from each, so a walk to one never crosses to another screen."""
        s = max(self.screens, key=lambda s: _overlap(self.pos, self.size, s))
        left, top = s.x + EDGE, s.y + EDGE
        right, bottom = s.x + s.w - self.size[0] - EDGE, s.y + s.h - self.size[1] - EDGE
        return [_clamp(c, self.size, s) for c in
                ((left, top), (right, top), (left, bottom), (right, bottom))]

    def _bed(self) -> tuple[float, float]:
        """The bottom-right corner, so a nap never needs a long walk."""
        return self._corners()[3]

    def _nearest_corner(self) -> tuple[float, float]:
        return min(self._corners(), key=lambda c: math.dist(c, self.pos))

    def _go(self, goal: tuple[float, float], speed: float = SPEED) -> None:
        self.origin, self.goal, self.elapsed = self.pos, goal, 0.0
        self.trip = math.dist(self.pos, goal) / speed

    def _travel(self, dt: float) -> bool:
        """Ease from origin toward goal; True on arrival."""
        self.elapsed += dt
        p = min(1.0, self.elapsed / self.trip) if self.trip > 0 else 1.0
        e = _ease(p)
        (x0, y0), (x1, y1) = self.origin, self.goal
        self.pos = (x0 * (1 - e) + x1 * e, y0 * (1 - e) + y1 * e)
        return p >= 1.0
