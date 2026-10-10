"""`pli.models`: the contract every module codes against, and who enforces it.

The module docstring states the rule - "every datetime crossing a module
boundary is timezone-aware UTC ... validators enforce awareness at the edge" -
and `pli.backend` repeats it from the other side of the same seam. The rule is
only worth anything if the models actually enforce it where foreign data first
becomes a model: a page read, a JSON export, a source adapter.

Both halves are pinned here per model, because they fail differently:

* a naive datetime is *accepted* by Python and read as the local zone, which
  moves a block by hours. Nothing downstream can see it: the plan that comes
  out is internally consistent and wrong, which is the version of this bug that
  reaches a real calendar.
* an aware datetime in another zone is fine arithmetic but breaks the
  convention the seam depends on, so it must be converted rather than kept -
  the block written back to the calendar is the one that would drift.

`free_slots` and the Teams reader have their own checks; those are tested where
they live. This file is about the models themselves.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from pydantic import ValidationError

from pli.models import Block, ChannelMessage, Deadline, Material, RemoteEvent, Slot, Task

#: +05:45, deliberately not a whole hour: an offset that survives a conversion
#: by accident (a half-hour shift, a fixed +05:00) is still wrong, and an hour-
#: aligned test would not show it.
KATHMANDU = ZoneInfo("Asia/Kathmandu")

#: A Monday, 10:00 local in Kathmandu.
AWARE = datetime(2026, 10, 5, 10, 0, tzinfo=KATHMANDU)
#: The same instant as UTC, which is what every model must hold afterwards.
AS_UTC = AWARE.astimezone(UTC)
#: The same wall clock, with no zone at all.
NAIVE = AWARE.replace(tzinfo=None)


# --- one factory per model, taking the instant it should hold ---------------------


def _block(at: datetime) -> Block:
    return Block(
        block_key="0123456789abcdef",
        task_key="t1",
        subject="Study",
        start=at,
        end=at + timedelta(minutes=60),
    )


def _slot(at: datetime) -> Slot:
    return Slot(start=at, end=at + timedelta(minutes=60))


def _task(at: datetime) -> Task:
    return Task(key="t1", title="Problem Set 4", course="CS301", due_at=at, estimated_minutes=60)


def _deadline(at: datetime) -> Deadline:
    return Deadline(
        source="stub",
        external_id="d1",
        course_external_id="CS301",
        title="Problem Set 4",
        due_at=at,
    )


def _event(at: datetime) -> RemoteEvent:
    return RemoteEvent(
        remote_id="event-1", subject="Study", start=at, end=at + timedelta(minutes=60)
    )


def _material(at: datetime) -> Material:
    return Material(
        source="stub",
        external_id="m1",
        course_external_id="CS301",
        name="slides.pdf",
        rel_path="cs301/slides.pdf",
        modified_at=at,
    )


def _message(at: datetime) -> ChannelMessage:
    return ChannelMessage(
        source="teams",
        external_id="c1",
        team="CS301 Algorithms",
        channel="General",
        author="Lecturer",
        posted_at=at,
        body="The lab moved to Thursday.",
    )


#: Every model carrying a datetime across a boundary, with the factory that
#: builds it. A model added with a datetime field but no entry here is a gap in
#: this file, which is why the list is a plain dict and not a set of imports
#: spelled out in each test.
CARRIERS = {
    "Block": _block,
    "Slot": _slot,
    "Task": _task,
    "Deadline": _deadline,
    "RemoteEvent": _event,
    "Material": _material,
    "ChannelMessage": _message,
}


@pytest.mark.parametrize("name", sorted(CARRIERS))
def test_a_naive_datetime_is_refused_at_the_edge(name):
    """It would be read as the *local* zone, and no later stage could tell."""
    with pytest.raises(ValidationError, match="timezone-aware"):
        CARRIERS[name](NAIVE)


@pytest.mark.parametrize("name", sorted(CARRIERS))
def test_an_aware_datetime_is_kept_as_the_same_instant_in_utc(name):
    """Every datetime field, not just the first one.

    `Block` carries two and the validator is attached to both; a spot check of
    `start` would pass with `end` left in the caller's zone. The same instant
    built in UTC is the control, so both halves are asserted at once: the offset
    is gone, and the moment is unchanged.
    """
    local = CARRIERS[name](AWARE)
    same_moment = CARRIERS[name](AS_UTC)

    datetimes = {f: v for f, v in local.__dict__.items() if isinstance(v, datetime)}
    assert datetimes, f"{name} carries no datetime, so this test proves nothing"
    for field, value in datetimes.items():
        assert value.utcoffset() == timedelta(0), f"{name}.{field} kept a local offset"
        assert value == getattr(same_moment, field), f"{name}.{field} moved in time"


def test_remote_event_is_ours_only_when_it_carries_a_block_key():
    """`None` is the whole safety mechanism: an event with no key is not this
    tool's, and every "never touch it" rule downstream is this one check."""
    assert _event(AWARE).model_copy(update={"block_key": None}).is_ours is False
    assert _event(AWARE).model_copy(update={"block_key": "0123456789abcdef"}).is_ours is True
