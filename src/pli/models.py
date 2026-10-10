"""Domain models - the frozen contract every other module codes against.

Convention: every datetime crossing a module boundary is timezone-aware UTC.
Graph requires an explicit timeZone on writes; conversion happens once, in
`planner/apply.py`. Mixing naive and aware datetimes is the classic source of
off-by-one-hour scheduling bugs, so validators enforce awareness at the edge.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

Energy = Literal["deep", "shallow"]
#: "stub" is the Phase 1 source; "moodle"/"teams" arrive in Phases 2 and 3.
SourceName = str


def _require_aware(value: datetime) -> datetime:
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise ValueError("datetime must be timezone-aware")
    return value.astimezone(UTC)


class Course(BaseModel):
    source: SourceName
    external_id: str
    name: str
    short_name: str | None = None


class Material(BaseModel):
    """A file or resource archived from a course. Enrichment fields are filled
    in Phase 4; the planner tolerates them being absent."""

    source: SourceName
    external_id: str
    course_external_id: str
    name: str
    rel_path: str
    url: str | None = None
    mime: str | None = None
    size: int | None = None
    modified_at: datetime | None = None
    local_path: str | None = None
    sha256: str | None = None
    summary: str | None = None
    key_concepts: list[str] = Field(default_factory=list)
    difficulty: int | None = None
    estimated_hours: float | None = None

    _aware = field_validator("modified_at")(lambda v: v if v is None else _require_aware(v))


class Deadline(BaseModel):
    """A due date as reported by a source, before the LLM has judged it."""

    source: SourceName
    external_id: str
    course_external_id: str
    title: str
    due_at: datetime
    kind: str = "assignment"
    url: str | None = None
    course_name: str = ""

    _aware = field_validator("due_at")(_require_aware)


class Task(BaseModel):
    """The unit the planner schedules: a judged, estimable piece of work."""

    key: str
    title: str
    course: str
    due_at: datetime
    estimated_minutes: int
    #: 0..1, higher = more important. Supplied by the LLM or the heuristic fallback.
    priority: float = 0.5
    energy: Energy = "shallow"
    urls: list[str] = Field(default_factory=list)
    detail: str = ""
    deadline_key: str | None = None

    _aware = field_validator("due_at")(_require_aware)


class Slot(BaseModel):
    """A window of free time, UTC."""

    start: datetime
    end: datetime

    _aware = field_validator("start", "end")(_require_aware)

    @property
    def minutes(self) -> int:
        return int((self.end - self.start).total_seconds() // 60)


class Block(BaseModel):
    """One study session, placed. `block_key` is stable across replans so the
    calendar writer can reconcile instead of duplicating."""

    block_key: str
    task_key: str
    subject: str
    start: datetime
    end: datetime
    body: str = ""
    session_index: int = 0
    session_count: int = 1

    _aware = field_validator("start", "end")(_require_aware)

    @property
    def minutes(self) -> int:
        return int((self.end - self.start).total_seconds() // 60)


class RemoteEvent(BaseModel):
    """A calendar event read back from upstream.

    This is the reconcile input and the busy-time input. Both jobs are done by
    one read because the calendar is read the same way for each; which fields
    matter depends on the caller.
    """

    remote_id: str
    subject: str
    start: datetime
    end: datetime
    #: Free text, as shown in the event. This tool's blocks carry an
    #: `[pli:<block_key>]` marker line here - that marker is the only way to
    #: recognise its own events in a web UI with no custom-property support.
    body: str = ""
    #: Set only on events this tool created, recovered from the event's own
    #: body/"Study Plan" marker. None means "not ours - never touch it".
    block_key: str | None = None
    all_day: bool = False
    #: busy | free | tentative | oof | workingElsewhere | unknown
    show_as: str = "busy"
    categories: list[str] = Field(default_factory=list)

    _aware = field_validator("start", "end")(_require_aware)

    @property
    def is_ours(self) -> bool:
        return self.block_key is not None


class ChannelMessage(BaseModel):
    """One Teams channel post, as visible in the web client.

    Message bodies are the only place a lecturer announces a moved deadline, so
    they are captured verbatim and fed to the scorer as context. They are never
    parsed into deadlines automatically - a wrong guess here would silently
    invent work.
    """

    source: SourceName
    external_id: str
    team: str
    channel: str
    author: str
    posted_at: datetime
    body: str
    url: str | None = None
    #: Attachments named in the post, for Phase 4 archival.
    attachments: list[str] = Field(default_factory=list)

    _aware = field_validator("posted_at")(_require_aware)

    @property
    def course(self) -> str:
        """Teams names rarely match Moodle course codes, so the team name is
        the course identity the planner uses for weighting."""
        return self.team
