"""Expression table: (activity, emotion) -> target FaceParams.

Units: eye_w/eye_h/mouth_w are scale factors (1 = default), gaze in -1..1, lids 0..1,
lid_angle > 0 lowers the inner lid edge (focused/cross), < 0 raises it (sad/worried),
skew > 0 makes the right eye bigger, hue in degrees.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field


@dataclass(frozen=True)
class FaceParams:
    eye_w: float = 1.0
    eye_h: float = 1.0
    eye_round: float = 0.55
    gaze_x: float = 0.0
    gaze_y: float = 0.0
    lid_top: float = 0.0
    lid_angle: float = 0.0
    lid_bottom: float = 0.0
    skew: float = 0.0
    wink: float = 0.0  # 1 closes the left eye
    mouth_curve: float = 0.15
    mouth_open: float = 0.0
    mouth_w: float = 1.0
    hue: float = 188.0
    sat: float = 0.85
    glow: float = 0.8
    wander: float = 0.0  # how much the animator lets the gaze drift
    bob: float = 0.0  # breathing offset, set by the animator
    effects: frozenset[str] = field(default_factory=frozenset)


# Activity sets the base pose (absolute values). `fx` lists overlay effects.
ACTIVITY: dict[str, dict] = {
    "idle": dict(wander=1.0),
    "listening": dict(eye_w=1.05, eye_h=1.12, gaze_y=-0.1, wander=0.4, mouth_w=0.8, fx="pulse"),
    "thinking": dict(eye_w=0.85, eye_h=0.85, gaze_x=0.6, gaze_y=-0.7, skew=0.15,
                     mouth_w=0.6, mouth_curve=-0.1, fx="dots"),
    "working": dict(eye_w=1.08, eye_h=0.9, lid_top=0.3, lid_angle=0.08, gaze_y=0.35,
                    mouth_w=0.6, mouth_curve=0.0, fx="gear"),
    "talking": dict(eye_h=1.05, mouth_w=1.1, wander=0.3),
    "waiting": dict(eye_h=1.18, gaze_y=-0.2, lid_angle=-0.12, mouth_w=0.75, mouth_curve=0.25),
    "error": dict(eye_w=0.9, eye_h=0.75, lid_top=0.15, lid_angle=-0.35, mouth_curve=-0.45,
                  mouth_w=0.8, hue=356.0, sat=0.75, fx="sweat"),
    "sleepy": dict(lid_top=0.55, gaze_y=0.3, glow=0.5, sat=0.65, mouth_w=0.6, mouth_curve=0.05),
    "asleep": dict(eye_h=0.1, eye_round=1.0, gaze_y=0.45, glow=0.35, sat=0.55, mouth_w=0.45,
                   mouth_curve=0.0, fx="zzz"),
}

# Emotion overlays: deltas added to the base, except hue/sat which replace it
# (unless the activity owns the colour, e.g. error).
EMOTION: dict[str, dict] = {
    "neutral": {},
    "happy": dict(lid_bottom=0.55, eye_h=0.05, mouth_curve=0.85, mouth_w=0.15, hue=168.0,
                  fx="blush"),
    "curious": dict(skew=0.4, gaze_x=0.35, gaze_y=-0.15, eye_h=0.12, mouth_w=-0.5,
                    mouth_open=0.2, mouth_curve=-0.05),
    "proud": dict(lid_top=0.18, lid_bottom=0.42, gaze_y=-0.35, mouth_curve=0.75,
                  mouth_w=0.2, hue=44.0, sat=0.7, fx="sparkle"),
    "concerned": dict(lid_top=0.12, lid_angle=-0.55, gaze_y=0.1, mouth_curve=-0.4,
                      mouth_w=-0.25, hue=34.0, sat=0.8, fx="sweat"),
    "confused": dict(skew=-0.5, lid_angle=0.25, gaze_x=-0.35, gaze_y=-0.1, mouth_curve=-0.3,
                     mouth_w=-0.3, fx="question"),
    "playful": dict(lid_bottom=0.45, wink=1.0, gaze_x=-0.3, mouth_curve=0.75, mouth_open=0.35,
                    hue=318.0, sat=0.45, fx="blush"),
    "sad": dict(lid_top=0.22, lid_angle=-0.6, gaze_y=0.4, eye_h=-0.08, mouth_curve=-0.85,
                mouth_w=-0.2, glow=-0.2, hue=216.0, sat=0.8),
    "calm": dict(lid_top=0.4, mouth_curve=0.35, mouth_w=-0.25, glow=-0.2,
                 wander=-0.6, hue=176.0, sat=0.6),
}

LIMITS = dict(eye_w=(0.3, 1.6), eye_h=(0.05, 1.6), lid_top=(0, 1), lid_bottom=(0, 1),
              lid_angle=(-1, 1), skew=(-1, 1), gaze_x=(-1, 1), gaze_y=(-1, 1),
              mouth_curve=(-1, 1), mouth_open=(0, 1), mouth_w=(0.2, 1.6), sat=(0, 1),
              glow=(0, 1), wander=(0, 1), wink=(0, 1))
MAX_LIDS = 0.7  # top + bottom lid coverage, so eyes never vanish


def _fx(spec: dict) -> set[str]:
    return set(spec.get("fx", "").split())


def target(activity: str, emotion: str) -> FaceParams:
    """The resting face for this activity with the emotion layered on top."""
    act = ACTIVITY.get(activity, ACTIVITY["idle"])
    emo = {} if activity == "asleep" else EMOTION.get(emotion, {})
    vals = asdict(FaceParams())
    vals.update({k: v for k, v in act.items() if k != "fx"})
    for k, v in emo.items():
        if k in ("hue", "sat"):
            vals[k] = vals[k] if k in act else v
        elif k != "fx":
            vals[k] += v
    for k, (lo, hi) in LIMITS.items():
        vals[k] = min(hi, max(lo, vals[k]))
    lids = vals["lid_top"] + vals["lid_bottom"]
    if lids > MAX_LIDS:
        vals["lid_top"] *= MAX_LIDS / lids
        vals["lid_bottom"] *= MAX_LIDS / lids
    vals["effects"] = frozenset(_fx(act) | _fx(emo))
    return FaceParams(**vals)
