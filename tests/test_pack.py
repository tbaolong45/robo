"""Invariant tests for the deterministic packer.

These are the guarantees the whole design rests on: the LLM may be wrong about
priority, but it can never produce an overlapping or out-of-hours calendar.
Pure functions, no network, no fixtures on disk.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest

from pli.config import StudyConfig
from pli.models import Slot, Task
from pli.planner.pack import MAX_SUBJECT, block_key_for, pack

TZ = ZoneInfo("Asia/Bangkok")
# Monday 2026-09-28 00:00 Bangkok.
NOW = datetime(2026, 9, 28, 0, 0, tzinfo=TZ).astimezone(UTC)


def days_of_free(start_day: date, count: int, *, split: bool = False) -> list[Slot]:
    """Free 08:00-22:00 each day. With `split`, busy 12:00-14:00 is carved out."""
    out: list[Slot] = []
    for offset in range(count):
        day = start_day + timedelta(days=offset)
        if split:
            out.append(Slot(start=combine(day, 8), end=combine(day, 12)))
            out.append(Slot(start=combine(day, 14), end=combine(day, 22)))
        else:
            out.append(Slot(start=combine(day, 8), end=combine(day, 22)))
    return out


def combine(day: date, hour: int) -> datetime:
    return datetime.combine(day, time(hour), tzinfo=TZ).astimezone(UTC)


def task(
    key: str,
    *,
    due_days: int = 5,
    minutes: int = 120,
    priority: float = 0.5,
    energy: str = "shallow",
    course: str = "CS301",
) -> Task:
    return Task(
        key=key,
        title=f"Task {key}",
        course=course,
        due_at=(NOW + timedelta(days=due_days)),
        estimated_minutes=minutes,
        priority=priority,
        energy=energy,  # type: ignore[arg-type]
    )


def cfg(**study_overrides: object) -> StudyConfig:
    base = StudyConfig()
    for field, value in study_overrides.items():
        setattr(base.study, field, value)
    return base


# --- the guarantees ------------------------------------------------------------


def test_no_blocks_overlap():
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    tasks = [task(f"t{i}", minutes=180, priority=0.9 - i * 0.1) for i in range(5)]
    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    assert result.blocks, "expected the packer to place something"
    ordered = sorted(result.blocks, key=lambda b: b.start)
    for earlier, later in zip(ordered, ordered[1:], strict=False):
        assert earlier.end <= later.start, f"{earlier.subject} overlaps {later.subject}"


def test_no_block_touches_a_busy_window():
    # 12:00-14:00 is busy every day and must stay empty.
    free = days_of_free(NOW.astimezone(TZ).date(), 8, split=True)
    tasks = [task(f"t{i}", minutes=240, priority=0.9) for i in range(6)]
    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    for block in result.blocks:
        local_start = block.start.astimezone(TZ)
        local_end = block.end.astimezone(TZ)
        busy_start = local_start.replace(hour=12, minute=0, second=0, microsecond=0)
        busy_end = busy_start.replace(hour=14)
        assert not (local_start < busy_end and local_end > busy_start), (
            f"{block.subject} ran into the busy window at {local_start}"
        )


def test_blocks_stay_inside_study_hours():
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    tasks = [task(f"t{i}", minutes=300, priority=0.9) for i in range(4)]
    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    for block in result.blocks:
        local_start = block.start.astimezone(TZ)
        local_end = block.end.astimezone(TZ)
        day_open = local_start.replace(hour=8, minute=0, second=0, microsecond=0)
        day_close = local_start.replace(hour=22, minute=0, second=0, microsecond=0)
        assert local_start >= day_open, f"{block.subject} starts before 08:00"
        assert local_end <= day_close, f"{block.subject} runs past 22:00"


def test_daily_cap_is_respected():
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    caps = cfg(daily_cap_minutes=120, course_daily_cap_minutes=600)
    tasks = [task(f"t{i}", minutes=120, priority=0.9 - i * 0.05) for i in range(6)]
    result = pack(tasks, free, cfg=caps, tz=TZ, now=NOW)

    per_day: dict[date, int] = {}
    for block in result.blocks:
        day = block.start.astimezone(TZ).date()
        per_day[day] = per_day.get(day, 0) + block.minutes
    for day, minutes in per_day.items():
        assert minutes <= 120, f"{day} used {minutes} minutes, over the 120 cap"


def test_per_course_daily_cap_is_respected():
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    caps = cfg(daily_cap_minutes=600, course_daily_cap_minutes=120)
    # Four tasks, all the same course.
    tasks = [task(f"t{i}", minutes=120, priority=0.9) for i in range(4)]
    result = pack(tasks, free, cfg=caps, tz=TZ, now=NOW)

    # Every task here is the same course, so the per-course cap doubles as a
    # per-day total cap: no day may exceed 120 minutes of CS301.
    per_day: dict[date, int] = {}
    for block in result.blocks:
        day = block.start.astimezone(TZ).date()
        per_day[day] = per_day.get(day, 0) + block.minutes
    assert per_day, "expected something to be scheduled"
    for day, minutes in per_day.items():
        assert minutes <= 120, f"{day} used {minutes} minutes of one course, over the cap"


def test_each_session_of_a_task_is_its_own_labelled_block():
    """A split task produces distinct blocks, not one block stamped `count` times.

    `block_key` is derived from the task and the session ordinal, so reusing an
    ordinal collides the keys and the calendar writer reconciles the sessions as
    one event - silently dropping sittings the student was promised. The suffix
    is how the student tells the sittings apart.
    """
    free = days_of_free(NOW.astimezone(TZ).date(), 6)
    tasks = [task("t0", minutes=360, due_days=5)]

    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    sessions = sorted(result.blocks, key=lambda b: b.session_index)
    assert [b.session_index for b in sessions] == [0, 1, 2]
    assert {b.session_count for b in sessions} == {3}
    assert len({b.block_key for b in sessions}) == 3
    assert [b.subject.rsplit(" ", 1)[-1] for b in sessions] == ["(1/3)", "(2/3)", "(3/3)"]


def test_a_subject_too_long_for_graph_is_truncated():
    """`MAX_SUBJECT` is headroom below Graph's 255-character ceiling.

    A long course name plus a long assignment title is ordinary, and a subject
    Graph refuses loses the whole event - the plan silently never reaches the
    calendar. Truncation has to happen here, before the write.
    """
    long_title = "Problem Set 4 " * 20  # 280 characters on its own
    free = days_of_free(NOW.astimezone(TZ).date(), 4)
    tasks = [task("t0", minutes=60, due_days=3).model_copy(update={"title": long_title})]

    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    assert result.blocks
    assert all(len(b.subject) <= MAX_SUBJECT for b in result.blocks)


def test_sessions_cover_the_estimate():
    free = days_of_free(NOW.astimezone(TZ).date(), 10)
    tasks = [task("t0", minutes=310)]
    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    placed = sum(b.minutes for b in result.blocks if b.task_key == "t0")
    assert placed >= 310, f"only placed {placed} of 310 minutes"


def test_break_is_kept_between_neighbouring_blocks():
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    tasks = [task(f"t{i}", minutes=60, priority=0.9 - i * 0.05) for i in range(4)]
    result = pack(tasks, free, cfg=cfg(break_minutes=15), tz=TZ, now=NOW)

    ordered = sorted(result.blocks, key=lambda b: b.start)
    for earlier, later in zip(ordered, ordered[1:], strict=False):
        if earlier.start.astimezone(TZ).date() == later.start.astimezone(TZ).date():
            gap = (later.start - earlier.end).total_seconds() / 60
            assert gap >= 15, f"only {gap} minutes between back-to-back blocks"


def test_weekday_filter_is_respected():
    free = days_of_free(NOW.astimezone(TZ).date(), 10)
    # 2026-09-28 is a Monday; allow Mondays and Tuesdays only.
    cfg_weekdays = cfg(weekdays_allowed=[0, 1])
    tasks = [task("t0", minutes=120)]
    result = pack(tasks, free, cfg=cfg_weekdays, tz=TZ, now=NOW)

    for block in result.blocks:
        assert block.start.astimezone(TZ).weekday() in (0, 1)


def test_a_disallowed_weekday_is_never_used_even_when_it_is_the_target_day():
    """The packer filters the weekdays itself; it does not trust its input.

    Free time is offered on all seven days here and only Monday is allowed. A
    session's target day is an ideal and the search walks forward from it, so the
    day it lands on is the one that must be checked. Only Monday's session is
    legitimate; the other two must be reported, never moved to Wednesday.
    """
    today = NOW.astimezone(TZ).date()
    free = days_of_free(today, 7)
    tasks = [task("t0", minutes=360, due_days=6)]

    result = pack(tasks, free, cfg=cfg(weekdays_allowed=[0]), tz=TZ, now=NOW)

    assert {b.start.astimezone(TZ).weekday() for b in result.blocks} == {0}
    # Sessions 2 and 3 of 3 have no allowed day left before the deadline.
    assert [(t.key, missing) for t, missing in result.unscheduled] == [("t0", 240)]


def test_the_weekend_cap_is_tighter_than_the_weekday_cap():
    """`weekend_daily_cap_minutes` is the promise of a lighter weekend.

    Enough work is offered to overflow the Monday-Friday capacity, so the only
    thing keeping Saturday and Sunday clear is the weekend cap. A session longer
    than that cap does not fit a weekend day at all, and the minutes it cannot
    take must be reported instead of being pushed into the weekend.
    """
    today = NOW.astimezone(TZ).date()
    free = days_of_free(today, 7)
    caps = cfg(daily_cap_minutes=300, course_daily_cap_minutes=600, weekend_daily_cap_minutes=100)
    # 8 x 240 minutes = 32 hours of work against 25 hours of weekday capacity.
    tasks = [task(f"t{i}", minutes=240, due_days=6, priority=0.9 - i * 0.05) for i in range(8)]

    result = pack(tasks, free, cfg=caps, tz=TZ, now=NOW)

    assert result.blocks, "expected the weekdays to absorb some of this"
    assert all(b.start.astimezone(TZ).weekday() < 5 for b in result.blocks)
    assert result.unscheduled, "overflow must be reported, not moved to the weekend"


# --- the judgement actually drives the schedule ---------------------------------


def test_priority_decides_who_gets_the_scarce_window():
    """Scoring is only worth doing if the packer obeys it.

    One hour of free time and two tasks that both need it: the higher-priority
    task must get it even though the other is due sooner. Ordering by the
    deadline alone (or by priority backwards) would hand the window to the less
    important task and leave the important one for a night it may not have.
    """
    today = NOW.astimezone(TZ).date()
    free = [Slot(start=combine(today, 8), end=combine(today, 9))]
    soon = task("soon", minutes=60, due_days=1, priority=0.1)
    important = task("important", minutes=60, due_days=3, priority=0.9)

    result = pack([soon, important], free, cfg=cfg(), tz=TZ, now=NOW)

    assert [b.task_key for b in result.blocks] == ["important"]
    assert [(t.key, missing) for t, missing in result.unscheduled] == [("soon", 60)]


def test_sessions_are_spread_across_the_runway():
    """Front-loaded, and not clustered - the days `_target_day` documents.

    Six days of runway and three sessions land on days 0, 2 and 4: early enough
    to leave room for a bad day, far enough apart to be three real sittings. All
    three packed into the first three days is the clustering this avoids.
    """
    today = NOW.astimezone(TZ).date()
    free = days_of_free(today, 8)
    tasks = [task("t0", minutes=360, due_days=6)]

    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    by_session = sorted(result.blocks, key=lambda b: b.session_index)
    assert [b.start.astimezone(TZ).date() for b in by_session] == [
        today,
        today + timedelta(days=2),
        today + timedelta(days=4),
    ]


# --- determinism and identity ---------------------------------------------------


def test_pack_is_deterministic():
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    tasks = [task(f"t{i}", minutes=150, priority=0.8 - i * 0.1) for i in range(4)]
    first = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)
    second = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    assert [(b.block_key, b.start, b.end) for b in first.blocks] == [
        (b.block_key, b.start, b.end) for b in second.blocks
    ]


def test_block_key_is_stable_when_the_block_moves():
    """The calendar writer depends on this: moving a block must not orphan it."""
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    early = pack([task("t0", minutes=120, due_days=6)], free, cfg=cfg(), tz=TZ, now=NOW)

    later_now = NOW + timedelta(days=2)
    later = pack([task("t0", minutes=120, due_days=6)], free, cfg=cfg(), tz=TZ, now=later_now)

    assert early.blocks[0].block_key == later.blocks[0].block_key
    assert early.blocks[0].start != later.blocks[0].start


def test_block_key_for_is_stable_and_distinct():
    assert block_key_for("abc", 0) == block_key_for("abc", 0)
    assert block_key_for("abc", 0) != block_key_for("abc", 1)
    assert len(block_key_for("abc", 0)) == 16


# --- edge cases -----------------------------------------------------------------


def test_past_deadlines_are_ignored():
    free = days_of_free(NOW.astimezone(TZ).date(), 8)
    stale = task("old", due_days=-3)
    result = pack([stale], free, cfg=cfg(), tz=TZ, now=NOW)
    assert result.blocks == []
    assert result.unscheduled == []  # never scheduled, not "failed" either


def test_unplaceable_work_is_reported_not_silently_dropped():
    # A single 1-hour window cannot absorb 12 hours of work.
    free = [
        Slot(start=combine(NOW.astimezone(TZ).date(), 8), end=combine(NOW.astimezone(TZ).date(), 9))
    ]
    tasks = [task("t0", minutes=720, due_days=1)]
    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    assert result.unscheduled, "expected work to be reported as unplaceable"
    shortfall = result.unscheduled[0][1]
    assert shortfall > 0


def test_a_session_never_lands_after_its_deadline():
    """Time booked after the deadline is worse than time not booked at all.

    It fills a real slot on the calendar while the student is already late, and
    the report that should have warned them says nothing. The search for a home
    for a session therefore stops at the deadline day; when the days up to it
    are full the minutes go to `unscheduled`.
    """
    today = NOW.astimezone(TZ).date()
    tasks = [task("t0", minutes=60, due_days=2, priority=0.9)]

    # Free time exists, but only past the deadline.
    too_late = [
        Slot(
            start=combine(today + timedelta(days=3), 8),
            end=combine(today + timedelta(days=3), 22),
        )
    ]
    missed = pack(tasks, too_late, cfg=cfg(), tz=TZ, now=NOW)
    assert missed.blocks == []
    assert [(t.key, missing) for t, missing in missed.unscheduled] == [("t0", 60)]

    # The same window one day earlier is before the deadline, and is used.
    in_time = [
        Slot(
            start=combine(today + timedelta(days=1), 8),
            end=combine(today + timedelta(days=1), 22),
        )
    ]
    placed = pack(tasks, in_time, cfg=cfg(), tz=TZ, now=NOW)
    assert len(placed.blocks) == 1
    assert placed.unscheduled == []


def test_the_shortfall_is_the_exact_minutes_that_did_not_fit():
    """`unscheduled` is the report the user acts on, so its number must be right.

    Half of this task fits and half of it does not: two sessions of 100 minutes,
    a 120-minute window on the first day and nothing free on the second. The
    report has to name the 100 minutes that were left over - a placeholder like
    "1" reads as success, and reporting nothing at all reads as a full week.
    """
    today = NOW.astimezone(TZ).date()
    free = [Slot(start=combine(today, 8), end=combine(today, 10))]  # 120 minutes, today only
    tasks = [task("t0", minutes=200, due_days=1)]

    result = pack(tasks, free, cfg=cfg(), tz=TZ, now=NOW)

    assert [b.minutes for b in result.blocks] == [100]
    assert [(t.key, missing) for t, missing in result.unscheduled] == [("t0", 100)]
    placed = sum(b.minutes for b in result.blocks if b.task_key == "t0")
    assert placed + result.unscheduled[0][1] == 200


def test_empty_input_is_fine():
    result = pack([], [], cfg=cfg(), tz=TZ, now=NOW)
    assert result.blocks == []
    assert result.unscheduled == []


def test_deep_work_prefers_mornings():
    free = [
        Slot(
            start=combine(NOW.astimezone(TZ).date(), 15), end=combine(NOW.astimezone(TZ).date(), 22)
        )
    ] + days_of_free(NOW.astimezone(TZ).date() + timedelta(days=1), 3)

    shallow = pack([task("s", minutes=120, energy="shallow")], free, cfg=cfg(), tz=TZ, now=NOW)
    deep = pack([task("d", minutes=120, energy="deep")], free, cfg=cfg(), tz=TZ, now=NOW)

    assert shallow.blocks[0].start.astimezone(TZ).date() == NOW.astimezone(TZ).date()
    # Today only offers 15:00+, so deep work spills to tomorrow morning.
    assert deep.blocks[0].start.astimezone(TZ).date() != NOW.astimezone(TZ).date()
    assert deep.blocks[0].start.astimezone(TZ).hour < cfg().deep_work.prefer_before_hour


@pytest.mark.parametrize("minutes", [30, 45, 60, 119, 120, 121, 240, 600])
def test_session_lengths_never_exceed_the_maximum(minutes: int):
    free = days_of_free(NOW.astimezone(TZ).date(), 14)
    result = pack([task("t0", minutes=minutes, due_days=13)], free, cfg=cfg(), tz=TZ, now=NOW)
    for block in result.blocks:
        assert block.minutes <= cfg().study.session_max_minutes


def test_a_session_never_lands_later_than_the_deadlines_own_hour():
    """The deadline's *time*, not just its date.

    Agent-C's sibling test above stops the search at the deadline day, but the
    last day of the search was still the whole day: a task due 09:00 could be
    handed an 18:00 sitting, because the window's end was `deadline_day` and the
    only check on the slot was that it fit inside 08:00-22:00. Nine hours late is
    still late - the plan tells the student to revise for the exam after the
    exam, and the slot it burns on the calendar is one nothing can reuse.
    """
    today = NOW.astimezone(TZ).date()
    due_at = combine(today + timedelta(days=2), 9)  # 09:00 local, two days out
    tasks = [
        Task(
            key="t0",
            title="Task t0",
            course="CS301",
            due_at=due_at,
            estimated_minutes=60,
            priority=0.9,
            energy="shallow",  # type: ignore[arg-type]
        )
    ]

    # Free time on the deadline day, but only in the evening - after the deadline.
    deadline_day = today + timedelta(days=2)
    evening = [Slot(start=combine(deadline_day, 18), end=combine(deadline_day, 22))]
    missed = pack(tasks, evening, cfg=cfg(), tz=TZ, now=NOW)
    assert missed.blocks == [], "booked after the deadline it is for"
    assert [(t.key, missing) for t, missing in missed.unscheduled] == [("t0", 60)]

    # A window that ends exactly at the deadline is in time, and is used: the
    # boundary is "ends after", not "ends at".
    boundary = [Slot(start=combine(deadline_day, 8), end=combine(deadline_day, 9))]
    placed = pack(tasks, boundary, cfg=cfg(), tz=TZ, now=NOW)
    assert len(placed.blocks) == 1
    assert placed.blocks[0].end == due_at
    assert placed.unscheduled == []
