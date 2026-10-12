"""Where the floating face goes: a pure, time-stepped wander along the screen edges."""

from __future__ import annotations

import math
import random
from dataclasses import dataclass

SPEED = 40.0  # px/s average travel speed (ease-in-out peaks at 1.5x)
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


def fit(pos: tuple[float, float], size: tuple[int, int], screen: Rect) -> tuple[float, float]:
    """Clamp a top-left so the window is fully on screen; pinned top-left if it cannot fit."""
    x = max(screen.x, min(pos[0], screen.x + screen.w - size[0]))
    y = max(screen.y, min(pos[1], screen.y + screen.h - size[1]))
    return x, y


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
    return fit((x, y), size, screen)


def _ease(p: float) -> float:
    return p * p * (3 - 2 * p)


class Roamer:
    """Moves the window like a pet: rest, drift, sleep in the corner, stay when needed."""

    def __init__(self, screen: Rect, size: tuple[int, int], seed: int | None = None,
                 start: tuple[float, float] | None = None):
        self.rng = random.Random(seed)
        self.screen, self.size = screen, size
        self.pos = fit(start or self._bed(), size, screen)
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
        return ((dx > 8) - (dx < -8)) if self.mode == "drift" else 0

    def resize(self, size: tuple[int, int]) -> None:
        self.size = size
        self.pos = fit(self.pos, size, self.screen)

    def set_screen(self, screen: Rect) -> None:
        self.screen = screen
        self.pos = fit(self.pos, self.size, screen)

    def hold(self, now: float, pos: tuple[float, float], seconds: float = HOLD) -> None:
        """The user dropped it at `pos`: stay there for `seconds`."""
        self.pos = fit(pos, self.size, self.screen)
        self.held_until = now + seconds

    def step(self, now: float, activity: str, engaged: bool) -> tuple[int, int]:
        """Advance to `now`; return the window's top-left."""
        dt = 0.0 if self.last is None else min(max(now - self.last, 0.0), MAX_DT)
        self.last = now
        if engaged:
            self.mode = "present"
        elif now < self.held_until:
            self.mode = "held"
        elif activity == "asleep":
            if self.mode != "sleep" or self.goal != self._bed():
                self._go(self._bed())
            self.mode = "sleep"
            self._travel(dt)
        else:
            self._wander(now, dt)
        self.pos = fit(self.pos, self.size, self.screen)
        return round(self.pos[0]), round(self.pos[1])

    def _wander(self, now: float, dt: float) -> None:
        if self.mode not in ("rest", "drift"):
            self._rest(now)
        if self.mode == "rest" and now >= self.rest_until:
            self._go(pick_target(self.rng, self.screen, self.size))
            self.mode = "drift"
        if self.mode == "drift" and self._travel(dt):
            self._rest(now)

    def _rest(self, now: float) -> None:
        self.mode = "rest"
        self.rest_until = now + self.rng.uniform(*REST)

    def _bed(self) -> tuple[float, float]:
        s = self.screen
        return fit((s.x + s.w - self.size[0] - EDGE, s.y + s.h - self.size[1] - EDGE),
                   self.size, s)

    def _go(self, goal: tuple[float, float]) -> None:
        self.origin, self.goal, self.elapsed = self.pos, goal, 0.0
        self.trip = math.dist(self.pos, goal) / SPEED

    def _travel(self, dt: float) -> bool:
        """Ease from origin toward goal; True on arrival."""
        self.elapsed += dt
        p = min(1.0, self.elapsed / self.trip) if self.trip > 0 else 1.0
        e = _ease(p)
        (x0, y0), (x1, y1) = self.origin, self.goal
        self.pos = (x0 * (1 - e) + x1 * e, y0 * (1 - e) + y1 * e)
        return p >= 1.0
