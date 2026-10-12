"""The typewriter is pure (no Qt, no clock): tests drive it with dt, like the 33 ms timer does.
Qt is used only to see what a revealed prefix looks like once Markdown is rendered."""

import bisect
import os
import re
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtGui import QTextDocument  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from robo import typewriter  # noqa: E402
from robo.typewriter import (  # noqa: E402
    WORD_MAX,
    Pace,
    Typewriter,
    classify,
    markdown_prefix,
    schedule,
)

QAPP = QApplication.instance() or QApplication([])
DT = 1 / 30
STEP = 1 / 55  # seconds per visible character at the default pace

SAMPLES = [
    "Hi! Here is **today**: two things are due.\n\n"
    "- **Linear Algebra** quiz at *10:00*, room `B-204`\n"
    "- Essay draft for [History](https://moodle.example.edu/x)\n"
    "- Lab report (due Friday)\n\n"
    "Run this to check:\n\n```python\nprint('ok')\nfor i in range(3):\n    print(i)\n```\n\n"
    "Good luck... you've got this!",
    "## Week plan\n\n"
    "1. **Monday**: finish the `lab` report, then read [chapter 3](https://x.example/c3)\n"
    "2. *Tuesday*: quiz at **10:00** in room B-204\n"
    "3. Wednesday is free\n\n"
    "> Remember: **draft first**, polish later.\n\n"
    "### Notes\n\n"
    "- Bring the **calculator** and a `pen`\n"
    "- Ping Sam about the group task\n\n"
    "~~~text\nline one\nline two\n~~~\n\nDone! \U0001f44d\U0001f3fd",
]


def prose(n: int) -> str:
    """n characters of plain text with a sentence end and a clause break every dozen words."""
    return ("the quick brown fox jumps over a lazy dog, and then plans the week. " * n)[:n]


def play(tw: Typewriter, limit: float = 60.0) -> float:
    """Tick at 30 Hz until the reply is done; the seconds that took."""
    t = 0.0
    while not tw.done and t < limit:
        tw.advance(DT)
        t += DT
    return t


def at_once(text: str) -> Typewriter:
    """Hermes delivered everything in one go and the run is over."""
    tw = Typewriter()
    tw.feed(text)
    tw.end()
    return tw


def gap(text: str, i: int) -> float:
    """Seconds between the reveal of text[i] and text[i + 1] at the default pace."""
    r = schedule(text, Pace(), True)[0]
    return r[i + 1] - r[i]


def stream(text: str, cps: float, chunk: int = 24):
    """Hermes sends `chunk` characters at a time at `cps`; the window ticks at 30 Hz.
    -> (seconds until done, seconds after the run ended, most characters held back)"""
    tw, t, got, ended_at, lag = Typewriter(), 0.0, 0, None, 0
    while not tw.done and t < 60:
        while got < len(text) and got / cps <= t:
            got = min(len(text), got + chunk)
            tw.feed(text[:got])
        if got == len(text) and ended_at is None:
            tw.end()
            ended_at = t
        tw.advance(DT)
        t += DT
        assert tw.k <= got  # never ahead of what was received
        lag = max(lag, got - tw.k)
    return t, t - ended_at, lag


def stray_syntax(md: str):
    """What a reader would see of `md` that is Markdown syntax, or None."""
    doc = QTextDocument()
    doc.setMarkdown(md)
    block = doc.begin()
    while block.isValid():
        text, item = block.text(), block.textList() is not None
        if "**" in text or "`" in text or "](" in text:
            return text
        if (item and not text.strip()) or re.fullmatch(r"#+", text.strip()):
            return f"empty bullet or bare #: {text!r}"
        block = block.next()
    return None


# --- Markdown while typing -------------------------------------------------------------------


@pytest.mark.parametrize("sample", SAMPLES)
def test_no_reachable_prefix_shows_markdown_syntax(sample):
    r, kind, _ = schedule(sample, Pace(), True)
    for k in sorted({bisect.bisect_right(r, t) for t in r}):  # every k a player can stop at
        md, hidden = markdown_prefix(sample, kind, k)
        assert 0 <= hidden <= 2 * WORD_MAX  # UTF-16 units
        assert stray_syntax(md) is None, (k, md)


@pytest.mark.parametrize("sample", SAMPLES)
@pytest.mark.parametrize(("chunk", "every"), [(1, 1), (1, 6), (3, 9)])
def test_a_stream_cut_anywhere_never_shows_syntax(sample, chunk, every):
    """Hermes may split a mark across deltas (`-` | ` item`, `*` | `*bold`) and stall in between."""
    tw, got, tick, seen = Typewriter(), 0, 0, set()
    while not tw.done and tick < 20000:
        if got < len(sample) and tick % every == 0:
            got = min(len(sample), got + chunk)
            tw.feed(sample[:got])
            if got == len(sample):
                tw.end()
        tw.advance(DT)
        tick += 1
        if (tw.k, got) not in seen:
            seen.add((tw.k, got))
            assert stray_syntax(tw.view()[0]) is None, (tw.k, tw.view())
    assert tw.view() == (sample, 0)


def test_marks_cost_no_time_and_ride_with_a_neighbour():
    r = schedule("**hi**", Pace(), True)[0]
    assert r[0] == r[1] == r[2]  # the opening ** comes with the h
    assert r[3] == r[4] == r[5]  # the closing ** goes with the i
    kind, code = classify("a\n```py\nx = 1\n```\nb")
    assert code[kind.index(1)] and not code[0] and not code[-1]  # the fence line is code


def test_unfinished_marks_get_closers_and_the_rest_of_the_word_is_hidden():
    text = "Hello **world** and see [the docs](http://x.io) now"
    kind, _ = classify(text)
    assert markdown_prefix(text, kind, len("Hello **wo")) == ("Hello **world**", 3)
    assert markdown_prefix(text, kind, len("Hello **world** and see [the"))[0].endswith("[the](#)")
    emoji = "a \U0001f44d\U0001f3fd bc"  # hidden counts UTF-16 units, as QTextCursor does
    assert markdown_prefix(emoji, classify(emoji)[0], 2)[1] == 4


def test_a_closer_never_follows_a_space():
    tw = Typewriter()
    tw.feed("**bo ")  # the delta ended on the space
    for _ in range(30):
        tw.advance(DT)
    assert tw.waiting and tw.view() == ("**bo** ", 0)


def test_a_half_received_mark_waits_for_its_other_half():
    tw = Typewriter()
    tw.feed("Items:\n\n-")
    for _ in range(90):
        tw.advance(DT)
    assert tw.waiting and tw.pending and "-" not in tw.view()[0]  # no empty bullet while it waits
    tw.feed("Items:\n\n- one")
    for _ in range(30):
        tw.advance(DT)
    assert tw.view()[0] == "Items:\n\n- one"
    tw = Typewriter()
    tw.feed("pick one -")
    tw.end()  # a dash that really is the last character is shown once the run is over
    assert play(tw) < 2 and tw.view() == ("pick one -", 0)


# --- emoji -----------------------------------------------------------------------------------

# (name, text, offsets inside it where a cut is fine: between two flags)
CLUSTERS = [
    ("thumbs up with a skin tone", "\U0001f44d\U0001f3fd", ()),
    ("two flags", "\U0001f1f3\U0001f1f1\U0001f1e9\U0001f1ea", (2,)),
    ("family with ZWJ", "\U0001f468\u200d\U0001f469\u200d\U0001f467", ()),
    ("keycap", "1\ufe0f\u20e3", ()),
    ("e and a combining accent", "e\u0301", ()),
]


@pytest.mark.parametrize(("name", "cluster", "cuts"), CLUSTERS, ids=[c[0] for c in CLUSTERS])
def test_an_emoji_cluster_is_one_step_and_is_never_cut(name, cluster, cuts):
    text = "a" + cluster + "b"
    r = schedule(text, Pace(), True)[0]
    assert len(set(r)) == len(cuts) + 3  # a, the cluster's steps, b
    stops = {bisect.bisect_right(r, t) for t in r}
    assert stops == {1, 1 + len(cluster), len(text)} | {1 + c for c in cuts}


# --- timing ----------------------------------------------------------------------------------


def test_110_plain_characters_take_two_seconds():
    plain = "abcdefghij " * 10
    assert schedule(plain, Pace(), True)[0][-1] == pytest.approx(len(plain) / 55, abs=0.05)
    tw = Typewriter()
    tw.feed(plain)  # the run goes on: backlog / lag is exactly 1, so the base pace
    for _ in range(30):
        tw.advance(DT)
    assert 50 <= tw.k <= 60  # one second in
    for _ in range(36):
        tw.advance(DT)
    assert tw.k == len(plain)


def test_a_sentence_end_pauses_but_decimals_and_versions_do_not():
    assert gap("Hi. Yo", 2) == pytest.approx(STEP + 0.20)
    assert gap("so... ok", 4) == pytest.approx(STEP + 0.20)  # only the last dot of an ellipsis
    assert gap("so... ok", 2) == pytest.approx(STEP)
    assert gap("pi is 3.14 ok", 7) == pytest.approx(STEP)
    assert gap("see v1.2 now", 6) == pytest.approx(STEP)
    assert gap("a, b", 1) == pytest.approx(STEP + 0.07)
    assert gap("a\nb", 1) == pytest.approx(STEP + 0.08)
    assert gap("a\n\nb", 2) == pytest.approx(STEP + 0.18)


def test_code_types_2_2_times_faster_with_no_sentence_pause():
    text = "x\n\n```\nab. cd\nef\n```"
    plain = gap("ab cd", 0)
    assert plain == pytest.approx(STEP)
    assert gap(text, text.index("ab")) == pytest.approx(plain / 2.2)
    assert gap(text, text.index(".")) == pytest.approx(plain / 2.2)  # no pause after the dot
    newline = text.index("cd") + 2  # a code newline adds 0.03 s
    assert gap(text, newline) == pytest.approx(plain / 2.2 + 0.03)


def test_a_whole_reply_that_arrives_at_once_is_typed_never_popped():
    tw = at_once(prose(40))
    tw.advance(DT)
    assert 0 < tw.k < 10 and tw.pending
    assert play(at_once(prose(11))) < 0.5
    assert play(at_once(prose(40))) < 1.5
    assert play(at_once(prose(120))) < 2.6
    assert play(at_once(prose(400))) < 3.7
    assert play(at_once(prose(1200))) < 6.5
    assert play(at_once(prose(3000))) < 12.5  # a click skips it long before


def test_a_streamed_reply_trails_hermes_by_about_two_seconds_and_finishes_fast():
    for n, cps, total, after in ((300, 250, 4.5, 3.3), (600, 120, 8.6, 3.3), (1200, 250, 9.2, 4.1)):
        t, ended, lag = stream(prose(n), cps)
        assert t < total and ended < after, (n, cps, t, ended)
        assert lag / cps < 2.6, (n, cps, lag)


def test_a_stream_slower_than_the_typewriter_is_typed_as_it_arrives():
    t, ended, lag = stream(prose(600), 30, chunk=3)
    assert lag < 40 and ended < 1.0
    tw = Typewriter()
    tw.feed("Hello there")
    for _ in range(60):
        tw.advance(DT)
    assert tw.k == 11 and tw.waiting and not tw.done  # caught up: the caret blinks, nothing else


def test_done_needs_the_end_of_the_run():
    tw = Typewriter()
    tw.feed("hi")
    for _ in range(30):
        tw.advance(DT)
    assert tw.started and not tw.pending and tw.waiting and not tw.done and tw.fraction == 1
    tw.end()
    assert tw.done and not tw.waiting


def test_the_finished_reply_is_rendered_exactly_as_received():
    tw = Typewriter()
    tw.feed("2*3 is six")  # a lone * looks like an open italic while streaming
    tw.end()
    assert play(tw) < 1 and tw.view() == ("2*3 is six", 0)


def test_skip_shows_what_is_there_and_whatever_arrives_next():
    tw = Typewriter()
    tw.feed("abc def")
    tw.skip()
    assert tw.k == 7 and not tw.pending
    tw.feed("abc def ghi")
    assert tw.k == 11 and tw.view() == ("abc def ghi", 0)
    assert not tw.advance(DT) and not tw.done
    tw.end("abc def ghi.")
    assert tw.done and tw.k == 12
    tw = Typewriter()
    tw.feed("**bo")
    tw.skip()
    assert tw.view() == ("**bo**", 0)  # still streaming: the closer stays


def test_a_final_text_that_differs_is_retyped_from_the_first_difference():
    tw = Typewriter()
    tw.feed("Hello wonderful world, how are you today my friend")
    for _ in range(10):
        tw.advance(DT)
    shown = tw.k
    assert 15 < shown < 25
    tw.end("Hello wonderful world, how are you today my friend, and more")  # an extension
    assert tw.k == shown
    final = "Hello wondrous place"
    tw.end(final)
    assert tw.k == len("Hello wond") and tw.text == final  # cut back to the common prefix
    tw.advance(DT)
    assert 10 <= tw.k <= 13  # and it carries on from there: no jump, no restart
    assert play(tw) < 2 and tw.view() == (final, 0)


def test_cps_zero_is_instant():
    tw = Typewriter(Pace(cps=0))
    tw.feed("**bo")
    assert tw.k == 4 and tw.waiting and tw.view() == ("**bo", 0)  # as the app showed it before
    assert not tw.advance(DT) and not tw.revealing
    tw.end("**bold** done")
    assert tw.done and tw.view() == ("**bold** done", 0)


def test_set_pace_carries_on_from_the_character_shown():
    tw = Typewriter()
    tw.feed(prose(100))
    for _ in range(10):
        tw.advance(DT)
    shown = tw.k
    tw.set_pace(Pace(cps=110))
    assert tw.k == shown
    tw.advance(DT)
    assert 2 <= tw.k - shown <= 6  # about 110 / 30 characters
    tw.set_pace(Pace(cps=0))
    assert tw.k == 100 and tw.view() == (prose(100), 0)


def test_the_mouth_moves_with_visible_characters_and_closes_in_a_pause():
    tw = Typewriter()
    tw.feed("Hi there. Next sentence follows")
    assert not tw.revealing
    while tw.k < len("Hi there."):
        tw.advance(0.01)
    assert tw.revealing
    tw.advance(0.05)
    assert tw.revealing and tw.k == len("Hi there.")  # inside talk_gap
    tw.advance(0.07)
    assert not tw.revealing and tw.k == len("Hi there.")  # the 0.2 s sentence pause is longer
    while tw.k == len("Hi there."):
        tw.advance(0.01)
    assert tw.revealing


def test_reset_starts_a_new_exchange():
    tw = at_once(prose(40))
    tw.advance(DT)
    tw.skip()
    tw.reset()
    assert tw.text == "" and tw.k == 0 and not tw.started and not tw.done and not tw.revealing
    tw.feed("fresh")
    assert tw.pending  # skip did not outlive the exchange


def test_a_tick_is_cheap(monkeypatch):
    """A tick only bisects and slices; the O(n) plan happens once per delta, never per tick."""
    text = (SAMPLES[0] + "\n\n") * 4
    assert len(text) > 1000
    tw = Typewriter()
    tw.feed(text)
    for _ in range(30):
        tw.advance(DT)
    assert tw.pending
    planned = []
    for name in ("schedule", "classify"):
        real = getattr(typewriter, name)
        monkeypatch.setattr(typewriter, name, lambda *a, _real=real: planned.append(1) or _real(*a))
    t0 = time.perf_counter()
    for _ in range(50):
        tw.advance(DT)
        tw.view()
    tick = (time.perf_counter() - t0) / 50
    assert not planned
    monkeypatch.undo()
    t0 = time.perf_counter()
    for _ in range(20):
        tw.feed(text)
    plan = (time.perf_counter() - t0) / 20
    print(f"\ntypewriter, {len(text)} chars: tick {tick * 1e6:.0f} us, feed {plan * 1e3:.2f} ms")
    assert tick < 0.005 and plan < 0.01  # loose: CI machines are slow, an O(n^2) is not
