"""Theme tokens: the five themes, the user's theme.json (validation, atomic save), the hue rule
for emotions and WCAG contrast of every text token. Qt-free; nothing here touches the real
~/.config/robo."""

import json
import os
from dataclasses import fields, replace
from pathlib import Path

import pytest

from robo import setup, theme
from robo.face.expressions import EMOTION, FaceParams, target
from robo.theme import THEMES, Theme

KEYS = ["cyan", "matrix", "amber", "aurora", "daylight"]
HEX = "#{:02x}{:02x}{:02x}"


@pytest.fixture
def cfg(tmp_path, monkeypatch) -> Path:
    path = tmp_path / "robo" / "theme.json"
    monkeypatch.setattr(theme, "CONFIG", path)
    return path


def write(path: Path, content) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content if isinstance(content, str) else json.dumps(content))


# --- the table -------------------------------------------------------------------------------

# Spec 3.4: token -> (low, high). `hue` wraps instead and is tested apart.
RANGES = dict(acc_s=(0, 1), lab_s=(0, 1), lab_v=(0, 1), grid_a=(0, 1), acc_v=(0.3, 1),
              bg_a=(0.90, 1), sheen=(0, 0.6), scan_a=(0, 0.4), scan_px=(2, 8), aura=(0, 0.3),
              aura_dh=(0, 120), corner=(0, 24), border_a=(0.2, 1), glow=(0, 1.6), br_len=(0, 30),
              br_w=(0.8, 3), radius=(0, 12), text_px=(12, 18), line_h=(105, 150), cps=(0, 400),
              caret_ms=(300, 1000))
COLOURS = ["bg_top", "bg_bot", "scan_c", "text", "text_dim", "head", "link", "code_bg", "code_fg",
           "inline_bg", "on_accent", "led_ok", "led_warn", "led_bad"]


def test_five_themes_in_menu_order():
    assert list(THEMES) == KEYS
    assert [t.key for t in THEMES.values()] == KEYS
    assert [t.label for t in THEMES.values()] == [
        "Cyan HUD", "Matrix", "Amber CRT", "Violet Aurora", "Daylight"]


def test_cyan_is_the_default():
    t = Theme()
    assert t == THEMES["cyan"]
    assert (t.hue, t.cps, t.bot_name, t.model_chip, t.caret) == (188, 55, "ROBO", "", "block")
    assert (t.shape, t.corner, t.dark) == ("cut", 9, True)


def test_every_theme_follows_the_face_mood():
    # The user's decision: the card accent follows the live emotion hue in all five themes.
    assert all(t.follow_emotion for t in THEMES.values())


@pytest.mark.parametrize("key, hue, cps, shape, corner, caret_ms, dark, text, bg_top", [
    ("cyan", 188, 55, "cut", 9, 530, True, "#e6efff", "#0b1322"),
    ("matrix", 128, 70, "cut", 0, 530, True, "#c9f6d3", "#04100a"),
    ("amber", 38, 40, "round", 14, 620, True, "#ffdca8", "#150d05"),
    ("aurora", 268, 50, "round", 16, 530, True, "#efe8ff", "#150d2a"),
    ("daylight", 196, 55, "round", 12, 530, False, "#13223a", "#f7fbff"),
])
def test_spec_values(key, hue, cps, shape, corner, caret_ms, dark, text, bg_top):
    t = THEMES[key]
    assert (t.hue, t.cps, t.shape, t.corner, t.caret_ms, t.dark, t.text, t.bg_top) == (
        hue, cps, shape, corner, caret_ms, dark, text, bg_top)


def test_mono_themes_set_the_body_in_mono():
    assert {k for k, t in THEMES.items() if t.body_mono} == {"matrix", "amber"}
    assert {k: THEMES[k].text_px for k in ("cyan", "matrix")} == {"cyan": 14, "matrix": 13}


def test_the_resting_hue_is_the_faces():
    assert FaceParams().hue == theme.FACE_BASE_HUE


def valid(t: Theme) -> None:
    """Every token of `t` is inside what spec 3.4 allows."""
    for name, (lo, hi) in RANGES.items():
        assert lo <= getattr(t, name) <= hi, name
    assert 0 <= t.hue < 360
    for name in COLOURS:
        assert len(getattr(t, name)) == 7 and getattr(t, name)[0] == "#", name
        int(getattr(t, name)[1:], 16)
    assert len(t.face_bg) == 2
    assert t.shape in ("cut", "round") and t.caret in ("block", "bar", "under")
    assert isinstance(t.follow_emotion, bool) and isinstance(t.body_mono, bool)
    assert t.bot_name.strip() and len(t.bot_name) <= 12 and len(t.model_chip) <= 12


# --- resolve and load ------------------------------------------------------------------------

def test_unknown_theme_is_cyan():
    assert theme.resolve("nope") is THEMES["cyan"]
    assert theme.resolve(None) is THEMES["cyan"]
    assert theme.resolve(["matrix"]) is THEMES["cyan"]  # unhashable JSON must not raise


def test_no_file_is_plain_cyan(cfg):
    assert theme.load() is THEMES["cyan"]


def test_file_picks_a_theme_and_overrides_tokens(cfg):
    write(cfg, {"theme": "matrix",
                "tokens": {"bot_name": "PIXEL", "hue": 300, "cps": 80, "caret": "bar",
                           "scan_a": 0, "model_chip": "x", "text": "#ABCDEF"}})
    t = theme.load()
    assert (t.key, t.bot_name, t.hue, t.cps, t.caret, t.scan_a, t.model_chip, t.text) == (
        "matrix", "PIXEL", 300, 80, "bar", 0, "x", "#ABCDEF")
    assert t.corner == THEMES["matrix"].corner  # untouched tokens stay the theme's
    assert theme.load(choice="daylight").key == "daylight"
    assert theme.load(choice="daylight").bot_name == "PIXEL"  # a menu pick keeps the overrides


def test_a_bad_token_is_skipped_and_the_rest_applies(cfg):
    write(cfg, {"tokens": {"hue": "red", "cps": 90, "bg_top": "#zzz", "bot_name": "PIXEL"}})
    t = theme.load()
    assert (t.hue, t.cps, t.bg_top, t.bot_name) == (188, 90, "#0b1322", "PIXEL")


HOSTILE = {
    "every token bad": '{"theme": "matrix", "tokens": {"hue": "red", "bg_top": "#zzz", "cps": true,'
    ' "bogus": 1, "bot_name": "' + "x" * 40 + '", "caret": "blink", "shape": 3,'
    ' "follow_emotion": "yes", "face_bg": ["#000"], "model_chip": 5, "text_px": null,'
    ' "scan_a": [0.1], "glow": {"a": 1}, "aura": NaN, "br_len": Infinity, "radius": -Infinity,'
    ' "line_h": 1' + "0" * 400 + '}}',
    "theme is a list": '{"theme": ["matrix"], "tokens": ["hue", 5]}',
    "theme is a number": '{"theme": 5, "tokens": "hue"}',
    "tokens is null": '{"theme": "matrix", "tokens": null}',
    "list": "[1, 2, 3]",
    "string": '"matrix"',
    "null": "null",
    "number": "42",
    "true": "true",
    "empty": "",
    "not json": "{not json",
    "nested too deep": "[" * 200000,
}


@pytest.mark.parametrize("name", HOSTILE)
def test_hostile_file_still_gives_a_valid_theme(cfg, name):
    write(cfg, HOSTILE[name])
    t = theme.load()
    valid(t)
    assert t.hue in (188, 128)  # cyan, or matrix when the file named it
    assert t.bot_name == "ROBO" and t.caret == "block"


def test_hostile_file_values_are_individually_dropped(cfg):
    write(cfg, {"theme": "matrix", "tokens": {"hue": "red", "bg_top": "#zzz", "cps": True,
                                              "bogus": 1, "bot_name": "x" * 40}})
    t = theme.load()
    assert (t.hue, t.bg_top, t.cps, t.bot_name) == (128, "#04100a", 70, "ROBO")
    assert not hasattr(t, "bogus")


def test_a_binary_file_is_not_a_theme(cfg):
    cfg.parent.mkdir(parents=True)
    cfg.write_bytes(b"\xff\xfe\x00\x80")
    assert theme.load() is THEMES["cyan"]


@pytest.mark.parametrize("name, lo, hi", [(n, lo, hi) for n, (lo, hi) in RANGES.items()])
def test_numbers_clamp(name, lo, hi):
    mid = (lo + hi) / 2
    t = theme.resolve("cyan", {name: lo - 1000})
    assert getattr(t, name) == lo
    assert getattr(theme.resolve("cyan", {name: hi + 1000}), name) == hi
    assert getattr(theme.resolve("cyan", {name: mid}), name) == pytest.approx(mid, abs=0.51)
    valid(t)


def test_hue_wraps_instead_of_clamping():
    assert theme.resolve("cyan", {"hue": 725}).hue == 5
    assert theme.resolve("cyan", {"hue": -10}).hue == 350
    assert theme.resolve("cyan", {"hue": 359.5}).hue == 359.5


def test_integer_tokens_stay_integers():
    t = theme.resolve("cyan", {"scan_px": 3.7, "text_px": 15.2, "caret_ms": 600.0})
    assert (t.scan_px, t.text_px, t.caret_ms) == (4, 15, 600)
    assert all(isinstance(getattr(t, n), int) for n in ("scan_px", "text_px", "caret_ms"))


def test_name_label_dark_key_and_rev_cannot_be_overridden():
    base = THEMES["daylight"]
    t = theme.resolve("daylight", {"label": "x", "dark": True, "key": "cyan", "rev": 0})
    assert (t.label, t.dark, t.key) == (base.label, False, "daylight")
    assert t.rev != 0


def test_text_tokens():
    t = theme.resolve("cyan", {"bot_name": "x" * 12, "model_chip": ""})
    assert (t.bot_name, t.model_chip) == ("x" * 12, "")
    assert theme.resolve("cyan", {"bot_name": ""}).bot_name == "ROBO"
    assert theme.resolve("cyan", {"bot_name": "   "}).bot_name == "ROBO"
    assert theme.resolve("cyan", {"model_chip": "x" * 13}).model_chip == ""


def test_colours_must_be_six_digit_hex():
    for bad in ("#abc", "#zzzzzz", "red", "rgb(1,2,3)", "#12345678", 0x123456, None):
        assert theme.resolve("cyan", {"text": bad}).text == THEMES["cyan"].text
    assert theme.resolve("cyan", {"text": "#AbCdEf"}).text == "#AbCdEf"


def test_face_bg_is_a_pair_of_colours():
    assert theme.resolve("cyan", {"face_bg": ["#101010", "#202020"]}).face_bg == (
        "#101010", "#202020")
    for bad in (["#101010"], "#101010", ["#101010", "nope"], ["#101010", "#202020", "#303030"]):
        assert theme.resolve("cyan", {"face_bg": bad}).face_bg == THEMES["cyan"].face_bg


def test_resolve_without_valid_tokens_reuses_the_theme():
    assert theme.resolve("matrix", {"bogus": 1, "hue": "red"}) is THEMES["matrix"]


def test_every_token_of_every_theme_is_valid():
    for t in THEMES.values():
        valid(t)
        assert theme.resolve(t.key, {n: getattr(t, n) for n in RANGES}) == t


# --- revision counter ------------------------------------------------------------------------

def test_every_new_theme_object_gets_a_new_revision():
    cyan = THEMES["cyan"]
    other = replace(cyan, hue=10)
    assert other.rev != cyan.rev
    assert replace(cyan).rev != cyan.rev
    assert theme.resolve("cyan") is cyan and cyan.rev == THEMES["cyan"].rev
    assert len({t.rev for t in THEMES.values()}) == len(THEMES)
    assert replace(cyan) == cyan  # the revision is not part of equality


def test_the_revision_is_not_a_constructor_argument():
    assert "rev" not in {f.name for f in fields(Theme) if f.init}


# --- model chip ------------------------------------------------------------------------------

def test_model_chip_follows_what_setup_configured(monkeypatch):
    monkeypatch.setitem(setup.CONFIG, "model.default", "claude-sonnet-5.5")
    assert theme.chip_text(THEMES["cyan"]) == "sonnet-5.5"
    monkeypatch.setitem(setup.CONFIG, "model.default", "gpt-x")
    assert theme.chip_text(THEMES["cyan"]) == "gpt-x"


def test_model_chip_override_and_hide():
    assert theme.chip_text(replace(THEMES["cyan"], model_chip="hermes")) == "hermes"
    assert theme.chip_text(replace(THEMES["cyan"], model_chip="  ")) == ""


def test_importing_theme_pulls_in_no_qt_and_no_setup():
    import subprocess
    import sys

    code = ("import sys, robo.theme; "
            "print(sorted(m for m in ('robo.setup', 'PySide6') if m in sys.modules))")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
    assert out.stdout.strip() == "[]"


# --- saving the choice -----------------------------------------------------------------------

def test_save_choice_creates_the_file(cfg):
    assert theme.save_choice("aurora") is True
    assert json.loads(cfg.read_text()) == {"theme": "aurora"}
    assert theme.load().key == "aurora"


def test_save_choice_keeps_every_other_key(cfg):
    write(cfg, {"theme": "cyan", "tokens": {"bot_name": "PIXEL", "cps": 80}, "note": [1, "é"]})
    theme.save_choice("matrix")
    assert json.loads(cfg.read_text()) == {
        "theme": "matrix", "tokens": {"bot_name": "PIXEL", "cps": 80}, "note": [1, "é"]}


def test_save_choice_leaves_no_tmp_and_is_a_replace(cfg):
    write(cfg, {"theme": "cyan"})
    inode = cfg.stat().st_ino
    theme.save_choice("amber")
    assert sorted(p.name for p in cfg.parent.iterdir()) == ["theme.json"]
    assert cfg.stat().st_ino != inode  # os.replace of a tmp file, not an in-place rewrite


def test_save_choice_writes_through_a_symlink_and_keeps_it(cfg, tmp_path):
    real = tmp_path / "dotfiles" / "theme.json"
    write(real, {"theme": "cyan", "tokens": {"cps": 80}})
    cfg.parent.mkdir(parents=True)
    cfg.symlink_to(real)
    assert theme.save_choice("matrix") is True
    assert cfg.is_symlink()  # a dotfiles-managed config stays managed
    assert json.loads(real.read_text()) == {"theme": "matrix", "tokens": {"cps": 80}}


def test_save_choice_failure_keeps_the_old_file_and_swallows_oserror(cfg, monkeypatch):
    write(cfg, {"theme": "cyan", "tokens": {"cps": 80}})
    before = cfg.read_text()

    def boom(*args):
        raise OSError("disk full")

    monkeypatch.setattr(os, "replace", boom)
    assert theme.save_choice("matrix") is False
    assert cfg.read_text() == before
    assert sorted(p.name for p in cfg.parent.iterdir()) == ["theme.json"]


def test_save_choice_swallows_an_unwritable_directory(tmp_path, monkeypatch):
    blocker = tmp_path / "robo"
    blocker.write_text("a file where the folder should be")
    monkeypatch.setattr(theme, "CONFIG", blocker / "theme.json")
    assert theme.save_choice("matrix") is False


def test_save_choice_never_overwrites_a_file_it_cannot_read(cfg):
    for content in ("{ half edited", "[1, 2]", '"x"'):
        write(cfg, content)
        assert theme.save_choice("matrix") is False
        assert cfg.read_text() == content


def test_save_choice_replaces_an_empty_file_and_ignores_unknown_themes(cfg):
    write(cfg, "")
    assert theme.save_choice("matrix") is True
    assert theme.save_choice("nope") is False
    assert json.loads(cfg.read_text()) == {"theme": "matrix"}


def test_stamp_changes_when_the_file_does(cfg):
    assert theme.stamp() == 0
    write(cfg, {})
    first = theme.stamp()
    assert first > 0
    os.utime(cfg, ns=(first + 10**9, first + 10**9))
    assert theme.stamp() != first


def test_config_path_follows_xdg(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    assert theme.config_path() == tmp_path / "xdg" / "robo" / "theme.json"
    monkeypatch.setenv("XDG_CONFIG_HOME", "")
    monkeypatch.setattr(Path, "home", lambda: tmp_path / "home")
    assert theme.config_path() == tmp_path / "home" / ".config" / "robo" / "theme.json"
    monkeypatch.delenv("XDG_CONFIG_HOME")
    assert theme.config_path() == tmp_path / "home" / ".config" / "robo" / "theme.json"


# --- hues ------------------------------------------------------------------------------------

STATES = dict(neutral=("idle", "neutral"), happy=("talking", "happy"), calm=("idle", "calm"),
              proud=("idle", "proud"), playful=("idle", "playful"),
              concerned=("idle", "concerned"), sad=("idle", "sad"), error=("error", "neutral"))
# Spec 3.3 (with follow_emotion on everywhere the card uses the same hues as the face).
HUES = dict(cyan=(188, 168, 176, 44, 318, 34, 216, 356),
            matrix=(128, 108, 116, 44, 318, 34, 216, 356),
            amber=(38, 18, 26, 52, 318, 24, 216, 356),
            aurora=(268, 248, 256, 44, 318, 34, 216, 356),
            daylight=(196, 176, 184, 44, 318, 34, 216, 356))


def hue_of(t: Theme, state: str) -> float:
    activity, emotion = STATES[state]
    return theme.hue_for(t, activity, emotion, target(activity, emotion).hue)


@pytest.mark.parametrize("key", KEYS)
def test_hue_table(key):
    assert tuple(hue_of(THEMES[key], s) for s in STATES) == HUES[key]


def test_cyan_reproduces_todays_face_hues_exactly():
    for activity, emotion in [("idle", "neutral"), ("talking", "happy"), ("idle", "calm"),
                              ("idle", "proud"), ("idle", "curious"), ("error", "neutral"),
                              ("asleep", "happy"), ("thinking", "sad")]:
        base = target(activity, emotion).hue
        assert theme.hue_for(THEMES["cyan"], activity, emotion, base) == base


def test_error_is_red_whatever_the_theme_or_emotion():
    for t in THEMES.values():
        for emotion in EMOTION:
            assert theme.hue_for(t, "error", emotion, target("error", emotion).hue) == 356
        assert theme.hue_for(t, "idle", "x", 356.0) == 356


def test_signal_hues_keep_14_degrees_from_the_resting_hue():
    for t in (replace(THEMES["cyan"], hue=h) for h in range(0, 360, 5)):
        for state in ("proud", "playful", "concerned", "sad"):
            hue = hue_of(t, state)
            assert abs((hue - t.hue + 180) % 360 - 180) >= 14 - 1e-9, (t.hue, state)


def test_live_hue_rule():
    amber = THEMES["amber"]
    assert theme.live_hue(amber, 17.0, "idle") == 17.0  # follows the face
    still = replace(amber, follow_emotion=False)
    assert theme.live_hue(still, 17.0, "idle") == 38.0  # one phosphor colour
    assert theme.live_hue(still, 356.0, "error") == 356.0  # an error always turns it red
    assert theme.live_hue(amber, 365.0, "idle") == 5.0


def test_the_aura_drifts_toward_pink_by_at_most_aura_dh_and_never_jumps():
    aurora = THEMES["aurora"]

    def from_pink(h: float) -> float:
        return abs((theme.PINK - h + 180) % 360 - 180)

    for h in range(360):
        d = theme.aura_shift(aurora, h)
        assert abs(d) <= aurora.aura_dh
        assert from_pink(h + d) <= from_pink(h) + 10  # never away from pink (a little past is fine)
        assert abs(theme.aura_shift(aurora, h + 1) - d) < 2  # no jump while the face's hue sweeps
    for state in STATES:  # every mood, error too, ends on a pink, magenta or violet, not a new hue
        hue = hue_of(aurora, state)
        assert from_pink(hue + theme.aura_shift(aurora, hue)) < 60, state
    assert theme.aura_shift(THEMES["cyan"], 188) == 0  # no aura, no shift


def test_accent_and_label_colours():
    cyan = THEMES["cyan"]
    assert theme.accent(cyan, 188, 1.0) == (38, 226, 255, 255)  # HSV(188, .85, 1.0)
    assert theme.accent(cyan, 188, 0.5)[3] == 128
    assert theme.accent(cyan, 548, 1.0) == theme.accent(cyan, 188, 1.0)  # the hue wraps
    assert theme.label_colour(cyan, 188) == (135, 212, 224, 255)  # HSV(188, .40, .88)
    assert theme.label_colour(cyan, 188, 0.1)[3] == 26
    assert theme.accent(cyan, 0, 7)[3] == 255 and theme.accent(cyan, 0, -1)[3] == 0


def test_rgba_and_css():
    assert theme.rgba("#04121a") == (4, 18, 26, 255)
    assert theme.rgba("#FFFFFF", 0.5) == (255, 255, 255, 128)
    assert theme.css((1, 2, 3, 4)) == "rgba(1,2,3,4)"


# --- WCAG contrast ---------------------------------------------------------------------------
# The helpers live here on purpose: src has no use for them.

def _lin(c: int) -> float:
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(rgb) -> float:
    r, g, b = rgb[:3]
    return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b)


def ratio(a, b) -> float:
    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def rgb(colour: str) -> tuple[int, int, int]:
    return tuple(int(colour[i:i + 2], 16) for i in (1, 3, 5))


def over(fg, alpha: float, ground) -> tuple[int, ...]:
    return tuple(round(f * alpha + g * (1 - alpha)) for f, g in zip(fg, ground, strict=True))


def grounds(t: Theme) -> list[tuple[int, ...]]:
    """The card fill (both gradient stops) on the two worst wallpapers: white and black."""
    return [over(rgb(stop), t.bg_a, ground)
            for stop in (t.bg_top, t.bg_bot) for ground in ((255, 255, 255), (0, 0, 0))]


def emotion_hues(t: Theme) -> set[float]:
    """Every hue the face can wear in this theme (all activities x all emotions)."""
    return {theme.hue_for(t, act, emo, target(act, emo).hue)
            for act in ("idle", "talking", "error", "asleep") for emo in EMOTION}


@pytest.mark.parametrize("key", KEYS)
@pytest.mark.parametrize("token", ["text", "text_dim", "head", "link", "code_fg"])
def test_text_has_4_5_to_1_on_the_card(key, token):
    t = THEMES[key]
    for ground in grounds(t):
        assert ratio(rgb(getattr(t, token)), ground) >= 4.5, (key, token, ground)


@pytest.mark.parametrize("key", KEYS)
def test_code_has_4_5_to_1_on_its_own_box(key):
    t = THEMES[key]
    assert ratio(rgb(t.code_fg), rgb(t.code_bg)) >= 4.5
    assert ratio(rgb(t.text), rgb(t.inline_bg)) >= 4.5


@pytest.mark.parametrize("key", KEYS)
def test_label_has_4_5_to_1_at_every_emotion_hue(key):
    t = THEMES[key]
    assert len(emotion_hues(t)) >= 8
    for hue in emotion_hues(t):
        for ground in grounds(t):
            assert ratio(theme.label_colour(t, hue), ground) >= 4.5, (key, hue, ground)


@pytest.mark.parametrize("key", KEYS)
def test_label_holds_while_the_hue_sweeps(key):
    # The animator springs the hue linearly, so a switch passes through every hue in between.
    t = THEMES[key]
    for hue in range(360):
        for ground in grounds(t):
            assert ratio(theme.label_colour(t, hue), ground) >= 4.5, (key, hue, ground)
