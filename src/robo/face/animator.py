"""Pure time-stepped face animation: springs, blinks, glances, breathing, talking."""

from __future__ import annotations

import math
import random
from dataclasses import fields, replace

from robo.face.expressions import FaceParams

FLOATS = [f.name for f in fields(FaceParams) if f.name not in ("effects", "bob")]
OMEGA = 14.0  # spring stiffness (rad/s); critically damped
BLINK = 0.15  # seconds, close + open
# Eye/mouth shape: changing these half-way looks broken (half happy, half sad), so a new
# expression swaps them in one step at the middle of a blink, like EMO-style robots do.
SHAPE = ("eye_round", "lid_top", "lid_angle", "lid_bottom", "skew", "wink", "mouth_curve")


class Animator:
    """Eases the face toward a target and layers life on top. Deterministic with a seed."""

    def __init__(self, seed: int | None = None):
        self.rng = random.Random(seed)
        self.x: dict[str, float] | None = None
        self.v = dict.fromkeys(FLOATS, 0.0)
        self.next_blink = self.rng.uniform(2, 6)
        self.blink_at = -1.0
        self.next_glance = 0.0
        self.glance = (0.0, 0.0)
        self.phase = 0.0
        self.shape: dict[str, float] | None = None  # the expression shape the eyes show now

    def step(self, target: FaceParams, dt: float, talking: bool, now: float) -> FaceParams:
        if self.x is None:
            self.x = {n: getattr(target, n) for n in FLOATS}
        asleep = "zzz" in target.effects
        goal = {n: getattr(target, n) for n in FLOATS}
        new_shape = {n: goal[n] for n in SHAPE}
        if self.shape is None:
            self.shape = new_shape
        p = (now - self.blink_at) / BLINK
        if new_shape != self.shape:
            if not 0 <= p <= 1:  # a new expression: blink, and swap the shape mid-blink
                self.blink_at, p = now, 0.0
            if p >= 0.5:
                self.shape = new_shape
        for n in SHAPE:  # shape is never sprung: it switches while the eyes are shut
            self.x[n], self.v[n] = self.shape[n], 0.0

        if now >= self.next_glance:  # micro-glance: pick a new small gaze offset
            self.next_glance = now + self.rng.uniform(1.2, 4.0)
            self.glance = (self.rng.uniform(-0.35, 0.35), self.rng.uniform(-0.2, 0.2))
        goal["gaze_x"] += self.glance[0] * target.wander
        goal["gaze_y"] += self.glance[1] * target.wander

        for n in (n for n in FLOATS if n not in SHAPE):  # exact critically damped spring
            e, v = self.x[n] - goal[n], self.v[n]
            k = math.exp(-OMEGA * dt)
            c = v + OMEGA * e
            self.x[n] = goal[n] + (e + c * dt) * k
            self.v[n] = (v - OMEGA * c * dt) * k

        if talking:  # mouth chatter ~6-9 Hz with jitter
            self.phase += dt * 2 * math.pi * self.rng.uniform(6, 9)
            o = 0.5 + 0.5 * math.sin(self.phase)
            self.x["mouth_open"] = min(1.0, 0.1 + 0.6 * o * self.rng.uniform(0.6, 1.0))
            self.v["mouth_open"] = 0.0

        if now >= self.next_blink:
            self.next_blink = now + self.rng.uniform(2, 6)
            if not asleep and not 0 <= p <= 1:
                self.blink_at = now
        p = (now - self.blink_at) / BLINK
        squash = 1 - 0.92 * math.sin(math.pi * p) if 0 <= p <= 1 else 1.0

        out = replace(target, **self.x, effects=target.effects)
        breath = math.sin(now * 2 * math.pi / (6.0 if asleep else 4.0))
        return replace(out, eye_h=out.eye_h * squash, bob=breath)
