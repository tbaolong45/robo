"""What the face should show: a pure state machine fed Hermes events and clock ticks."""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

from robo.events import (
    EMOTIONS,
    ApprovalNeeded,
    Delta,
    Event,
    Feeling,
    Listening,
    RunEnded,
    ToolCompleted,
    ToolStarted,
    UserSent,
)

TALK_PAUSE = 0.3  # s without a delta before the mouth closes
FLASH = 1.5  # s of "concerned" after a tool error
EMOTION_HOLD = 8.0  # s an emotion lingers after a reply
ERROR_HOLD = 5.0  # s the error face shows before idling
SLEEPY_AFTER = 300.0  # s quiet before sleepy
ASLEEP_AFTER = 900.0  # s quiet before asleep

# Hermes tool names (~/.hermes/hermes-agent/tools/) -> status label. browser_* -> "browsing…".
TOOL_LABELS = {
    "web_search": "searching the web…",
    "web_extract": "reading a page…",
    "memory": "remembering…",
    "skill_view": "checking a skill…",
    "skills_list": "checking my skills…",
    "skill_manage": "updating a skill…",
}


@dataclass(frozen=True)
class Mind:
    activity: str
    emotion: str
    talking: bool
    label: str
    since: float  # when the activity began
    last_input: float  # last user input or run end: the sleep clock starts here
    emotion_until: float  # emotion reverts to neutral at this time
    last_delta: float
    after: tuple[str, float] | None = None  # (emotion, until) to restore when a flash ends


def initial(now: float) -> Mind:
    return Mind("idle", "neutral", False, "", now, now, math.inf, 0.0)


def tool_label(tool: str) -> str:
    return "browsing…" if tool.startswith("browser_") else TOOL_LABELS.get(tool, f"using {tool}…")


def _go(m: Mind, activity: str, now: float, **kw) -> Mind:
    since = m.since if activity == m.activity else now
    return replace(m, activity=activity, since=since, **kw)


def react(m: Mind, ev: Event, now: float) -> Mind:
    """Apply one event."""
    match ev:
        case UserSent():
            return _go(m, "thinking", now, emotion="neutral", emotion_until=math.inf,
                       label="", talking=False, last_input=now, after=None)
        case Listening(on=True):
            return _go(m, "listening", now, emotion="neutral", emotion_until=math.inf,
                       label="listening…", talking=False, last_input=now, after=None)
        case Listening(on=False) if m.activity == "listening":
            return _go(m, "idle", now, label="", last_input=now)
        case ToolStarted(tool=tool):
            return _go(m, "working", now, label=tool_label(tool))
        case ToolCompleted(error=error):  # the model reads the result and decides what next
            m = _go(m, "thinking", now, label="")
            if not error:
                return m
            return replace(m, emotion="concerned", emotion_until=now + FLASH,
                           after=m.after or (m.emotion, m.emotion_until))
        case Feeling(emotion=e) if e in EMOTIONS:
            held = m.activity in ("idle", "sleepy", "asleep", "error")
            return replace(m, emotion=e, emotion_until=now + EMOTION_HOLD if held else math.inf,
                           after=None)
        case Delta():
            return _go(m, "talking", now, label="", talking=True, last_delta=now)
        case ApprovalNeeded():
            return _go(m, "waiting", now, label="")
        case RunEnded(status=status):
            end = dict(label="", talking=False, last_input=now, after=None)
            if status == "completed":
                emotion = m.after[0] if m.after else m.emotion  # a flash gives the reply's back
                return _go(m, "idle", now, emotion=emotion, emotion_until=now + EMOTION_HOLD, **end)
            if status == "cancelled":
                return _go(m, "idle", now, emotion="neutral", emotion_until=math.inf, **end)
            sad = "confused" if status == "interrupted" else "sad"
            return _go(m, "error", now, emotion=sad, emotion_until=now + ERROR_HOLD, **end)
    return m


def tick(m: Mind, now: float) -> Mind:
    """Apply the passage of time."""
    if m.talking and now >= m.last_delta + TALK_PAUSE:
        m = replace(m, talking=False)
    if m.after and now >= m.emotion_until:
        m = replace(m, emotion=m.after[0], emotion_until=m.after[1], after=None)
    if m.emotion != "neutral" and now >= m.emotion_until:
        m = replace(m, emotion="neutral", emotion_until=math.inf)
    if m.activity == "error" and now >= m.since + ERROR_HOLD:
        m = _go(m, "idle", now)
    if m.activity in ("idle", "sleepy"):
        if now >= m.last_input + ASLEEP_AFTER:
            m = _go(m, "asleep", now)
        elif now >= m.last_input + SLEEPY_AFTER:
            m = _go(m, "sleepy", now)
    return m
