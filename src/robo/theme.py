"""Colours, shape and typing speed of the speech bubble: five themes plus the user's theme.json.

Qt-free on purpose (colours are "#rrggbb" strings, computed colours are (r, g, b, a) tuples with
a in 0..255; `QColor(*accent(...))` and `css(...)` for style sheets), so everything here is tested
without a display. The widgets read tokens from a `Theme`, they never hold a colour literal.

~/.config/robo/theme.json is configuration the user may hand-edit (state lives in
~/.local/share/robo); every key is optional:

    {"theme": "matrix", "tokens": {"bot_name": "PIXEL", "hue": 300, "cps": 80, "caret": "bar"}}

`tokens` overrides single tokens of the chosen theme. Each token is checked on its own: a bad
one is skipped, the rest still applies, and a missing or broken file gives plain Cyan HUD. The
right-click menu only ever writes the `theme` key (`save_choice`).
"""

from __future__ import annotations

import colorsys
import contextlib
import itertools
import json
import math
import os
import re
from dataclasses import dataclass, field, replace
from pathlib import Path

FACE_BASE_HUE = 188.0  # FaceParams.hue: what every neutral pose has (tests pin it to the face)
ERROR_HUE = 356.0  # expressions.ACTIVITY["error"]
SEPARATION = 14.0  # degrees a signal emotion keeps from the theme's resting hue
PINK = 330.0  # where an aura's bloom and border sweep drift to


def config_path() -> Path:
    home = os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config"
    return Path(home) / "robo" / "theme.json"


# Fixed at import so a test can patch it (tests/conftest.py); the functions below read it when
# called. Other modules must say `theme.CONFIG`, not `from robo.theme import CONFIG`.
CONFIG = config_path()

_REVS = itertools.count(1)


@dataclass(frozen=True)
class Theme:
    """One flat token table; the defaults are Cyan HUD and a theme is a `replace(...)` of it."""

    key: str = "cyan"
    label: str = "Cyan HUD"
    dark: bool = True
    # accent: HSV(live hue, acc_s, acc_v); small labels use the paler lab_s / lab_v so they hold
    # their contrast on every hue
    hue: float = 188.0  # resting hue of the face and of the accent
    acc_s: float = 0.85
    acc_v: float = 1.0
    lab_s: float = 0.40
    lab_v: float = 0.88
    follow_emotion: bool = True  # the card's accent follows the face's live hue (error: always)
    face_bg: tuple[str, str] = ("#121a2a", "#090d16")  # face screen: centre, edge
    # card surface
    bg_top: str = "#0b1322"
    bg_bot: str = "#0e182b"
    bg_a: float = 0.93  # at least .90: Qt cannot blur the wallpaper behind the window
    sheen: float = 0.05
    scan_a: float = 0.16
    scan_px: int = 3
    scan_c: str = "#000000"
    grid_a: float = 0.0
    aura: float = 0.0
    aura_dh: float = 0.0
    # frame
    shape: str = "cut"  # cut | round
    corner: int = 9
    border_a: float = 0.55
    glow: float = 1.0
    br_len: int = 15
    br_w: float = 1.6
    radius: int = 3  # chips, model chip, wells, input
    # text
    text: str = "#e6efff"
    text_dim: str = "#a6b8d8"
    head: str = "#9fe9ff"
    link: str = "#7fd0ff"
    code_bg: str = "#050a13"
    code_fg: str = "#c4d4f0"
    inline_bg: str = "#16253d"
    on_accent: str = "#04121a"
    led_ok: str = "#3ddc8a"
    led_warn: str = "#ffb62e"
    led_bad: str = "#ff5468"
    body_mono: bool = False
    text_px: int = 14
    line_h: int = 116  # percent of Qt's line spacing
    # typing
    cps: float = 55.0  # characters per second, 0 = instant
    caret: str = "block"  # block | bar | under
    caret_ms: int = 530
    # the bot
    bot_name: str = "ROBO"
    model_chip: str = ""  # "" = what `robo setup` configured, spaces only = no chip
    # Changes with every new Theme (also through replace()), so a painted-card cache keyed on it
    # can never go stale. Not an argument, not part of ==.
    rev: int = field(init=False, compare=False, repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "rev", next(_REVS))


CYAN = Theme()
# Matrix lab_v is .88, the spec's .86 left the label at 4.38:1 on the blue the hue passes through
# while the animator sweeps (tests/test_theme.py checks all 360 hues).
THEMES: dict[str, Theme] = {
    "cyan": CYAN,
    "matrix": Theme(
        key="matrix", label="Matrix", hue=128, acc_s=0.88, lab_s=0.45, lab_v=0.88,
        face_bg=("#04140a", "#010603"), bg_top="#04100a", bg_bot="#051409", bg_a=0.94,
        sheen=0.03, scan_a=0.28, grid_a=0.07, corner=0, border_a=0.60, glow=0.8, br_len=13,
        br_w=2.0, radius=0, text="#c9f6d3", text_dim="#86c99a", head="#7dff9e", link="#6bf0c8",
        code_bg="#020a05", code_fg="#a9e8b8", inline_bg="#0f2a18", on_accent="#02140a",
        led_ok="#4dff88", led_warn="#ffc640", led_bad="#ff5a5a", body_mono=True, text_px=13,
        line_h=114, cps=70.0),
    "amber": Theme(
        key="amber", label="Amber CRT", hue=38, acc_s=0.95, lab_s=0.45, lab_v=0.92,
        face_bg=("#1c1004", "#0b0601"), bg_top="#150d05", bg_bot="#1a1007", bg_a=0.94,
        sheen=0.04, scan_a=0.30, shape="round", corner=14, border_a=0.62, glow=1.35, br_len=17,
        br_w=1.8, radius=5, text="#ffdca8", text_dim="#d7a868", head="#ffc45c", link="#ffd27a",
        code_bg="#0c0703", code_fg="#f0c98f", inline_bg="#33200b", on_accent="#1a0e00",
        led_ok="#8dff6a", led_warn="#ffd23a", led_bad="#ff5a4a", body_mono=True, text_px=13,
        line_h=114, cps=40.0, caret_ms=620),
    "aurora": Theme(
        key="aurora", label="Violet Aurora", hue=268, acc_s=0.72, lab_s=0.30, lab_v=0.92,
        face_bg=("#1a1233", "#0b0719"), bg_top="#150d2a", bg_bot="#1b1136", sheen=0.07,
        scan_a=0.07, aura=0.16, aura_dh=70, shape="round", corner=16, border_a=0.66, glow=1.25,
        br_len=18, br_w=1.5, radius=8, text="#efe8ff", text_dim="#baa9e3", head="#d8c4ff",
        link="#b9a2ff", code_bg="#0c0720", code_fg="#d5c8f7", inline_bg="#2a1c52",
        on_accent="#150a33", cps=50.0),
    "daylight": Theme(
        key="daylight", label="Daylight", dark=False, hue=196, acc_s=0.88, acc_v=0.60,
        lab_s=0.88, lab_v=0.42, face_bg=("#1a2a44", "#0c1424"), bg_top="#f7fbff",
        bg_bot="#e9f1fa", bg_a=0.96, sheen=0.55, scan_a=0.035, scan_c="#0a2a4a", shape="round",
        corner=12, border_a=0.70, glow=0.45, br_len=14, br_w=1.7, radius=6, text="#13223a",
        text_dim="#4a5f80", head="#0a6a8a", link="#0b63c4", code_bg="#dde8f4",
        code_fg="#24344f", inline_bg="#d3e3f3", on_accent="#ffffff", led_ok="#12a05a",
        led_warn="#c77700", led_bad="#d42a3d"),
}

# --- the user's file -------------------------------------------------------------------------

_HEX = re.compile(r"#[0-9a-fA-F]{6}")
_COLOURS = {"bg_top", "bg_bot", "scan_c", "text", "text_dim", "head", "link", "code_bg",
            "code_fg", "inline_bg", "on_accent", "led_ok", "led_warn", "led_bad"}
_RANGES = dict(acc_s=(0, 1), acc_v=(0.3, 1), lab_s=(0, 1), lab_v=(0, 1), grid_a=(0, 1),
               bg_a=(0.90, 1), sheen=(0, 0.6), scan_a=(0, 0.4), scan_px=(2, 8), aura=(0, 0.3),
               aura_dh=(0, 120), corner=(0, 24), border_a=(0.2, 1), glow=(0, 1.6),
               br_len=(0, 30), br_w=(0.8, 3), radius=(0, 12), text_px=(12, 18),
               line_h=(105, 150), cps=(0, 400), caret_ms=(300, 1000))
_INTS = {n for n in _RANGES if isinstance(getattr(CYAN, n), int)}
_ENUMS = dict(shape=("cut", "round"), caret=("block", "bar", "under"))
_BOOLS = {"follow_emotion", "body_mono"}
_TEXTS = {"bot_name", "model_chip"}  # up to 12 characters; bot_name also not blank


def _is_hex(v) -> bool:
    return isinstance(v, str) and _HEX.fullmatch(v) is not None


def _valid(name: str, v) -> bool:
    """Is `v` fine for the non-numeric token `name`? (False for every unknown name too.)"""
    if name == "face_bg":
        return isinstance(v, list | tuple) and len(v) == 2 and all(_is_hex(c) for c in v)
    if name in _COLOURS:
        return _is_hex(v)
    if name in _ENUMS:
        return v in _ENUMS[name]
    if name in _BOOLS:
        return isinstance(v, bool)
    if name in _TEXTS:
        return isinstance(v, str) and len(v) <= 12 and (name != "bot_name" or bool(v.strip()))
    return False


def _clean(name: str, v):
    """`v` as the value of token `name`, or ValueError when it is not acceptable. label, dark,
    key and rev are in no table, so they can never be overridden."""
    if name == "hue" or name in _RANGES:
        # `v != v` is NaN; comparing with inf is exact even for an int too big for a float
        if isinstance(v, bool) or not isinstance(v, int | float) or v != v or abs(v) == math.inf:
            raise ValueError(name)
        if name == "hue":
            return float(v % 360)
        lo, hi = _RANGES[name]
        v = min(hi, max(lo, v))
        return round(v) if name in _INTS else float(v)
    if not _valid(name, v):
        raise ValueError(name)
    return tuple(v) if name == "face_bg" else v


def resolve(key, tokens=None) -> Theme:
    """Theme `key` (unknown: Cyan HUD) with the valid entries of `tokens` on top."""
    base = THEMES[key] if isinstance(key, str) and key in THEMES else CYAN
    good = {}
    for name, value in (tokens.items() if isinstance(tokens, dict) else ()):
        with contextlib.suppress(ValueError):  # a bad token never costs the user the others
            good[name] = _clean(name, value)
    return replace(base, **good) if good else base


def load(path: Path | None = None, choice: str | None = None) -> Theme:
    """The theme the file asks for, always a valid one. `choice` (a menu pick) replaces the
    file's `theme` key but keeps its `tokens`, so a pick still applies when saving it failed."""
    try:
        data = json.loads((path or CONFIG).read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError):  # unreadable, not UTF-8, not JSON, too deep
        data = None
    if not isinstance(data, dict):
        data = {}
    return resolve(choice or data.get("theme"), data.get("tokens"))


def stamp(path: Path | None = None) -> int:
    """Modification time of the file in ns, 0 if there is none: "did the user edit it?"."""
    try:
        return (path or CONFIG).stat().st_mtime_ns
    except OSError:
        return 0


def save_choice(key: str, path: Path | None = None) -> bool:
    """Remember the picked theme, keeping every other key. False (nothing written, the theme
    still applies for this run) when the file cannot be written or is not a JSON object we can
    keep: a half-edited file is the user's, never overwrite it."""
    if key not in THEMES:
        return False
    try:
        path = (path or CONFIG).resolve()  # a symlinked (dotfiles) file is updated, not replaced
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            raw = ""
        data = json.loads(raw) if raw.strip() else {}
        if not isinstance(data, dict):
            return False
        data["theme"] = key
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        try:
            tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            os.replace(tmp, path)  # atomic: a crash never leaves half a file
        finally:
            tmp.unlink(missing_ok=True)  # nothing to do after a successful replace
        return True
    except (OSError, ValueError, RecursionError):
        return False


def chip_text(t: Theme) -> str:
    """Text of the header's model chip ("" = hide it): the token, else the configured model.
    That is what `robo setup` set, not a live reading from Hermes."""
    if t.model_chip:
        return t.model_chip.strip()
    from robo import setup  # lazily: setup is heavy and may import the UI one day (cycle)

    return setup.CONFIG.get("model.default", "").removeprefix("claude-")


# --- colours ---------------------------------------------------------------------------------

def rgba(colour: str, alpha: float = 1.0) -> tuple[int, int, int, int]:
    """A "#rrggbb" token as (r, g, b, a)."""
    return int(colour[1:3], 16), int(colour[3:5], 16), int(colour[5:7], 16), _a(alpha)


def css(c: tuple[int, int, int, int]) -> str:
    """(r, g, b, a) for a Qt style sheet; a is 0..255 there too."""
    return f"rgba({c[0]},{c[1]},{c[2]},{c[3]})"


def _a(alpha: float) -> int:
    return min(255, max(0, round(255 * alpha)))


def _hsv(hue: float, s: float, v: float, alpha: float) -> tuple[int, int, int, int]:
    r, g, b = colorsys.hsv_to_rgb(hue % 360 / 360, s, v)
    return round(255 * r), round(255 * g), round(255 * b), _a(alpha)


def accent(t: Theme, hue: float, alpha: float = 1.0) -> tuple[int, int, int, int]:
    """Borders, glow, caret, solid buttons at `hue` (the live hue; see live_hue)."""
    return _hsv(hue, t.acc_s, t.acc_v, alpha)


def label_colour(t: Theme, hue: float, alpha: float = 1.0) -> tuple[int, int, int, int]:
    """Small mono labels: the accent hue, paler (dimmer on Daylight), >= 4.5:1 on every hue."""
    return _hsv(hue, t.lab_s, t.lab_v, alpha)


# --- hues ------------------------------------------------------------------------------------

def hue_for(t: Theme, activity: str, emotion: str, base: float) -> float:
    """The hue the face takes in this theme. `base` is what expressions.target() gives (188
    neutral, 168 happy, 176 calm, 44 proud, 318 playful, 34 concerned, 216 sad, 356 error).

    Error is always red. Neutral poses and the two quiet moods (happy, calm) are offsets from
    the theme's resting hue, so Cyan reproduces today's face exactly. The signal emotions keep
    their own hue (proud stays gold, sad blue) but are pushed SEPARATION degrees away when they
    land that close to the resting hue (gold on Amber), so they still differ from neutral."""
    if activity == "error" or base == ERROR_HUE:
        return base
    if abs(base - FACE_BASE_HUE) < 1e-6 or emotion in ("happy", "calm"):
        return (t.hue + base - FACE_BASE_HUE) % 360
    gap = (base - t.hue + 180) % 360 - 180
    if abs(gap) < SEPARATION:
        return (t.hue + math.copysign(SEPARATION, gap or 1)) % 360
    return base


def aura_shift(t: Theme, hue: float) -> float:
    """Degrees from `hue` to the colour of the aura's bloom and of the border's far end: toward
    pink, up to `aura_dh`, fading to nothing at pink and at its opposite so the face's hue
    sweeping past never makes it jump. Whatever the mood (an error too) it ends on a pink,
    magenta or violet, not on a colour of its own."""
    return t.aura_dh * math.sin(math.radians(PINK - hue))


def live_hue(t: Theme, face_now: float, activity: str) -> float:
    """The hue the card paints with: the face's current (animated) one when the theme follows
    the mood, else the resting hue. An error always turns the card red."""
    return (face_now if t.follow_emotion or activity == "error" else t.hue) % 360
