"""The vocabulary every robo module shares: what Hermes reports and what the face can show."""

from __future__ import annotations

from dataclasses import dataclass

EMOTIONS = (
    "neutral", "happy", "curious", "proud", "concerned", "confused", "playful", "sad", "calm",
)
ACTIVITIES = (
    "idle", "listening", "thinking", "working", "talking", "waiting", "error", "sleepy", "asleep",
)


# --- Hermes run events (parsed from GET /v1/runs/{id}/events) -------------------------------


@dataclass(frozen=True)
class Delta:
    """A piece of the reply text (`message.delta`)."""

    text: str


@dataclass(frozen=True)
class ToolStarted:
    tool: str


@dataclass(frozen=True)
class ToolCompleted:
    tool: str
    error: bool


@dataclass(frozen=True)
class ApprovalNeeded:
    """Hermes paused the run until the user approves or denies (`approval.request`)."""

    description: str
    desktop: bool = False  # a computer_use step (click, type, key...) in the user's apps


@dataclass(frozen=True)
class RunEnded:
    """`run.completed` / `run.failed` / `run.cancelled` / `run.interrupted`, or a lost stream."""

    status: str
    output: str = ""
    error: str = ""


# --- Events robo itself produces ------------------------------------------------------------


@dataclass(frozen=True)
class Feeling:
    """The emotion Hermes chose for this reply (its leading `[[feel:x]]` tag)."""

    emotion: str


@dataclass(frozen=True)
class Listening:
    """Robo was called by name (or clicked) and listens (`on`), or stopped (`on=False`)."""

    on: bool


@dataclass(frozen=True)
class UserSent:
    """The user sent a message (typed, or the digest button / wake trigger)."""

    text: str


Event = (
    Delta | ToolStarted | ToolCompleted | ApprovalNeeded | RunEnded | Feeling | Listening | UserSent
)
