import random

import pytest

from robo import mind
from robo.events import (
    ACTIVITIES,
    EMOTIONS,
    ApprovalNeeded,
    Delta,
    Feeling,
    RunEnded,
    ToolCompleted,
    ToolStarted,
    UserSent,
)
from robo.mind import initial, react, tick


def run(*events, start=0.0):
    """React to events one second apart, starting from a fresh mind at `start`."""
    m, t = initial(start), start
    for ev in events:
        t += 1
        m = react(m, ev, t)
    return m, t


def test_initial_is_idle_neutral():
    m = initial(5.0)
    assert (m.activity, m.emotion, m.talking, m.label) == ("idle", "neutral", False, "")
    assert m.since == m.last_input == 5.0


def test_user_sent_thinks_resets_emotion_and_records_input():
    m = react(initial(0), Feeling("happy"), 1)
    m = react(m, UserSent("hi"), 2)
    assert (m.activity, m.emotion, m.last_input, m.since) == ("thinking", "neutral", 2, 2)


@pytest.mark.parametrize("state", ["sleepy", "asleep"])
def test_user_sent_wakes(state):
    m = tick(initial(0), 2000 if state == "asleep" else 400)
    assert m.activity == state
    assert react(m, UserSent("hi"), 2001).activity == "thinking"


def test_tool_done_goes_back_to_thinking():
    m, _ = run(UserSent("x"), ToolStarted("web_search"), ToolCompleted("web_search", False))
    assert (m.activity, m.label, m.emotion) == ("thinking", "", "neutral")


@pytest.mark.parametrize(
    ("tool", "label"),
    [
        ("browser_navigate", "browsing…"),
        ("browser_click", "browsing…"),
        ("web_search", "searching the web…"),
        ("web_extract", "reading a page…"),
        ("memory", "remembering…"),
        ("skill_view", "checking a skill…"),
        ("frobnicate", "using frobnicate…"),
    ],
)
def test_tool_started_works_with_label(tool, label):
    m, _ = run(UserSent("x"), ToolStarted(tool))
    assert (m.activity, m.label) == ("working", label)


def test_tool_error_flashes_concerned_then_continues():
    m, t = run(UserSent("x"), ToolStarted("web_search"), ToolCompleted("web_search", True))
    assert (m.activity, m.emotion) == ("thinking", "concerned")
    m = tick(m, t + mind.FLASH)
    assert (m.activity, m.emotion) == ("thinking", "neutral")


def test_tool_ok_keeps_emotion():
    m, _ = run(UserSent("x"), ToolStarted("memory"), ToolCompleted("memory", False))
    assert m.emotion == "neutral"


def test_feeling_sets_emotion_and_holds_during_run():
    m, t = run(UserSent("x"), Feeling("curious"))
    assert m.emotion == "curious"
    assert tick(m, t + 1000).emotion == "curious"


def test_feeling_outside_vocab_ignored():
    assert run(UserSent("x"), Feeling("ecstatic"))[0].emotion == "neutral"


def test_delta_talks_then_mouth_closes_after_pause():
    m, t = run(UserSent("x"), Delta("hel"))
    assert (m.activity, m.talking, m.last_delta) == ("talking", True, t)
    assert tick(m, t + mind.TALK_PAUSE - 0.01).talking
    m = tick(m, t + mind.TALK_PAUSE)
    assert (m.activity, m.talking) == ("talking", False)


def test_approval_waits():
    m, _ = run(UserSent("x"), ApprovalNeeded("rm -rf?"))
    assert m.activity == "waiting"


def test_completed_goes_idle_keeping_emotion_then_decays():
    m, t = run(UserSent("x"), Feeling("proud"), Delta("done"), RunEnded("completed"))
    assert (m.activity, m.emotion, m.talking, m.label) == ("idle", "proud", False, "")
    assert tick(m, t + mind.EMOTION_HOLD - 0.01).emotion == "proud"
    assert tick(m, t + mind.EMOTION_HOLD).emotion == "neutral"


@pytest.mark.parametrize(("status", "emotion"), [("failed", "sad"), ("interrupted", "confused")])
def test_failure_shows_error_then_idles(status, emotion):
    m, t = run(UserSent("x"), RunEnded(status, error="boom"))
    assert (m.activity, m.emotion) == ("error", emotion)
    assert tick(m, t + mind.ERROR_HOLD - 0.01).activity == "error"
    m = tick(m, t + mind.ERROR_HOLD)
    assert (m.activity, m.emotion) == ("idle", "neutral")


def test_cancelled_goes_idle_neutral():
    m, _ = run(UserSent("x"), Feeling("happy"), RunEnded("cancelled"))
    assert (m.activity, m.emotion) == ("idle", "neutral")


def test_idle_gets_sleepy_then_asleep():
    m = initial(0)
    assert tick(m, mind.SLEEPY_AFTER - 0.01).activity == "idle"
    m = tick(m, mind.SLEEPY_AFTER)
    assert m.activity == "sleepy"
    assert tick(m, mind.ASLEEP_AFTER - 0.01).activity == "sleepy"
    assert tick(m, mind.ASLEEP_AFTER).activity == "asleep"


def test_sleep_clock_restarts_after_a_run():
    m, t = run(UserSent("x"), RunEnded("completed"), start=0)
    assert tick(m, t + mind.SLEEPY_AFTER - 1).activity == "idle"


@pytest.mark.parametrize(
    "ev",
    [ToolCompleted("t", False), ToolStarted("w"), Delta("x"), ApprovalNeeded("ok?")],
)
def test_never_sleepy_mid_run(ev):
    m, t = run(UserSent("x"), ev)
    for dt in (mind.SLEEPY_AFTER, mind.ASLEEP_AFTER, 10 * mind.ASLEEP_AFTER):
        m = tick(m, t + dt)
        assert m.activity not in ("sleepy", "asleep")


def test_fuzz_stays_in_vocab():
    rng = random.Random(1234)
    pool = [
        lambda: UserSent("x"),
        lambda: ToolStarted(rng.choice(["browser_click", "web_search", "zzz", ""])),
        lambda: ToolCompleted("t", rng.random() < 0.5),
        lambda: Feeling(rng.choice([*EMOTIONS, "bogus", ""])),
        lambda: Delta("d"),
        lambda: ApprovalNeeded("a"),
        lambda: RunEnded(rng.choice(["completed", "failed", "interrupted", "cancelled", "lost"])),
    ]
    for _ in range(200):
        m, t = initial(0), 0.0
        for _ in range(50):
            t += rng.choice([0.05, 0.5, 3, 10, 400, 1000])
            m = react(m, rng.choice(pool)(), t) if rng.random() < 0.7 else tick(m, t)
            assert m.activity in ACTIVITIES and m.emotion in EMOTIONS


def test_tool_error_flash_gives_the_reply_emotion_back():
    m, t = run(UserSent("x"), Feeling("happy"), ToolStarted("web_search"),
               ToolCompleted("web_search", True))
    assert m.emotion == "concerned"
    m = tick(m, t + mind.FLASH)
    assert m.emotion == "happy"
    m = react(m, RunEnded("completed"), t + mind.FLASH + 1)
    assert m.emotion == "happy"


def test_run_ending_during_a_flash_keeps_the_reply_emotion():
    m, t = run(UserSent("x"), Feeling("proud"), ToolCompleted("t", True), RunEnded("completed"))
    assert (m.activity, m.emotion) == ("idle", "proud")
    m = tick(m, t + mind.EMOTION_HOLD)
    assert m.emotion == "neutral"
