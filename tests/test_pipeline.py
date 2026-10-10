"""End to end: deadlines -> tasks -> judged -> free windows -> packed week -> Outlook.

The unit tests prove each stage in isolation against hand-built inputs. This one
runs the *real* stages in sequence, so the packer's invariants are checked
against `free_slots()` output rather than against `Slot`s a test wrote itself -
which is where a wiring mistake between the stages would actually show up.

Only the two outside boundaries are faked: the calendar (no Microsoft 365
account, so no browser and no signed-in profile) and the LLM (no key).
Everything between them is production code.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from pli.config import StudyConfig, load_study_config
from pli.db import Store
from pli.models import Block, Deadline, RemoteEvent
from pli.planner.apply import CalendarWriter, body_for, read_marker
from pli.planner.freebusy import busy_from, free_slots
from pli.planner.pack import pack
from pli.planner.score import heuristic_scores
from pli.planner.tasks import build_tasks
from pli.sources.stub import StubSource

DUBAI = ZoneInfo("Asia/Dubai")
#: Monday 10:00 in Dubai.
NOW = datetime(2026, 10, 5, 6, 0, tzinfo=UTC)

#: A plausible teaching week: two lectures Monday, a lab Wednesday, a tutorial Thursday.
CLASSES = [
    ("2026-10-05", 9, 11, "CS301 Algorithms lecture"),
    ("2026-10-05", 14, 16, "CS310 Databases tutorial"),
    ("2026-10-07", 10, 12, "CS301 Algorithms lab"),
    ("2026-10-08", 13, 15, "GEN101 Academic Writing seminar"),
]


def _local(day: str, hour: int, minute: int = 0) -> datetime:
    return datetime.fromisoformat(f"{day}T{hour:02d}:{minute:02d}:00").replace(tzinfo=DUBAI)


def _utc(day: str, hour: int) -> datetime:
    """A class time as a `RemoteEvent` carries it.

    Every datetime crossing the backend boundary is timezone-aware UTC (see
    `pli.backend`), so the classes are emitted as UTC instants rather than as
    the local wall clock - the same conversion the browser backend owes the
    planner. Emitting local time here is exactly the off-by-a-zone bug the
    models guard against, and it is what this helper exists to avoid.
    """
    return _local(day, hour).astimezone(UTC)


def _as_event(remote_id: str, block: Block) -> RemoteEvent:
    """A written block as the calendar hands it back, marker and all.

    The marker round-trips through the body exactly as the browser backend
    recovers it from the page, so `discover_events` is exercised for real.
    """
    body = body_for(block)
    return RemoteEvent(
        remote_id=remote_id,
        subject=block.subject,
        start=block.start,
        end=block.end,
        body=body,
        block_key=read_marker(body),
    )


class FakeCalendar:
    """A calendar implementing `pli.backend.CalendarBackend`, in memory.

    The house double lives in `tests/test_apply.py`; this one is the same idea
    plus the one thing this test needs - classes that are *read* as well as
    written, so free/busy sees a real timetable. They are kept out of `events`
    so the write path can still be counted on its own.
    """

    def __init__(self, classes=CLASSES):
        self.classes: list[RemoteEvent] = [
            RemoteEvent(
                remote_id=f"class:{index}",
                subject=subject,
                start=_utc(day, start_hour),
                end=_utc(day, end_hour),
            )
            for index, (day, start_hour, end_hour, subject) in enumerate(classes)
        ]
        self.events: dict[str, RemoteEvent] = {}
        self._seq = 0

    def list_events(self, start: datetime, end: datetime) -> list[RemoteEvent]:
        every = [*self.classes, *self.events.values()]
        return [e for e in every if e.start < end and e.end > start]

    def create_event(self, block: Block) -> str:
        self._seq += 1
        remote_id = f"event-{self._seq}"
        self.events[remote_id] = _as_event(remote_id, block)
        return remote_id

    def update_event(self, remote_id: str, block: Block) -> None:
        self.events[remote_id] = _as_event(remote_id, block)

    def delete_event(self, remote_id: str) -> None:
        self.events.pop(remote_id, None)


@pytest.fixture
def calendar():
    return FakeCalendar()


def _deadline(
    external_id: str, course: str, title: str, days: float, kind="assignment"
) -> Deadline:
    return Deadline(
        source="stub",
        external_id=external_id,
        course_external_id=course.split()[0],
        course_name=course,
        title=title,
        due_at=NOW + timedelta(days=days),
        kind=kind,
    )


DEADLINES = [
    _deadline("d1", "CS301 Algorithms", "Problem Set 4 - dynamic programming", 3),
    _deadline("d2", "CS310 Databases", "Lab report - normalisation", 5),
    _deadline("d3", "GEN101 Academic Writing", "Essay draft - 1500 words", 7),
]


def _free_windows(calendar, cfg: StudyConfig):
    """What `_build_plan` does with the calendar: read it, then carve out time."""
    start = NOW.astimezone(DUBAI).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=cfg.horizon.days)
    return free_slots(busy_from(calendar.list_events(start, end)), cfg, DUBAI, start, end)


def _run(calendar, cfg: StudyConfig | None = None):
    """The production pipeline, minus the LLM and the browser."""
    cfg = cfg or load_study_config()
    tasks = build_tasks(DEADLINES, [], now=NOW, study_config=cfg)
    tasks = heuristic_scores(tasks, study_config=cfg, now=NOW)

    free = _free_windows(calendar, cfg)
    result = pack(tasks, free, cfg=cfg, tz=DUBAI, now=NOW)
    return tasks, free, result


# --- wiring --------------------------------------------------------------------


def test_the_pipeline_produces_blocks(calendar):
    tasks, free, result = _run(calendar)
    assert tasks and free and result.blocks


def test_every_block_lands_inside_a_detected_free_window(calendar):
    _, free, result = _run(calendar)
    for block in result.blocks:
        assert any(slot.start <= block.start and block.end <= slot.end for slot in free), (
            f"{block.subject} at {block.start} is outside every free window"
        )


def test_detected_free_windows_never_contain_a_class(calendar):
    """The packer is only safe because its input is already class-free."""
    _, free, _ = _run(calendar)
    for day, start_hour, end_hour, subject in CLASSES:
        class_start = _local(day, start_hour).astimezone(UTC)
        class_end = _local(day, end_hour).astimezone(UTC)
        for slot in free:
            assert slot.end <= class_start or slot.start >= class_end, (
                f"free window overlaps {subject}"
            )


def test_no_block_lands_during_a_class(calendar):
    """The single most important promise the system makes."""
    _, _, result = _run(calendar)
    for day, start_hour, end_hour, subject in CLASSES:
        class_start = _local(day, start_hour).astimezone(UTC)
        class_end = _local(day, end_hour).astimezone(UTC)
        for block in result.blocks:
            assert block.end <= class_start or block.start >= class_end, (
                f"{block.subject} overlaps {subject}"
            )


# --- invariants ------------------------------------------------------------------


def test_no_two_blocks_overlap(calendar):
    _, _, result = _run(calendar)
    ordered = sorted(result.blocks, key=lambda b: b.start)
    for earlier, later in zip(ordered, ordered[1:], strict=False):
        assert earlier.end <= later.start


def test_blocks_stay_within_study_hours(calendar):
    cfg = load_study_config()
    _, _, result = _run(calendar, cfg)
    for block in result.blocks:
        local_start = block.start.astimezone(DUBAI)
        local_end = block.end.astimezone(DUBAI)
        assert local_start.hour >= cfg.study.earliest_hour
        assert local_end.hour <= cfg.study.latest_hour
        assert local_end.minute == 0 or local_end.hour < cfg.study.latest_hour


def test_every_block_is_on_an_allowed_weekday(calendar):
    cfg = load_study_config()
    _, _, result = _run(calendar, cfg)
    for block in result.blocks:
        assert block.start.astimezone(DUBAI).weekday() in cfg.study.weekdays_allowed


def test_daily_cap_is_respected(calendar):
    cfg = load_study_config()
    _, _, result = _run(calendar, cfg)
    per_day: dict[str, int] = {}
    for block in result.blocks:
        key = block.start.astimezone(DUBAI).date().isoformat()
        per_day[key] = per_day.get(key, 0) + block.minutes
    assert all(total <= cfg.study.daily_cap_minutes for total in per_day.values())


def test_per_course_daily_cap_is_respected(calendar):
    """No single subject may eat a whole evening."""
    cfg = load_study_config()
    tasks, _, result = _run(calendar, cfg)
    course_of = {t.key: t.course for t in tasks}

    per_day_course: dict[tuple[str, str], int] = {}
    for block in result.blocks:
        key = (block.start.astimezone(DUBAI).date().isoformat(), course_of[block.task_key])
        per_day_course[key] = per_day_course.get(key, 0) + block.minutes

    for (day, course), total in per_day_course.items():
        assert total <= cfg.study.course_daily_cap_minutes, f"{course} on {day}: {total} min"


def test_every_scheduled_task_covers_its_estimate(calendar):
    """Scheduled minutes plus reported shortfall must equal the estimate.

    Nothing may be silently dropped: a task either gets its time or is named in
    `unscheduled` with the exact number of minutes that did not fit.
    """
    tasks, _, result = _run(calendar)
    shortfall = {task.key: missing for task, missing in result.unscheduled}

    for task in tasks:
        placed = sum(b.minutes for b in result.blocks if b.task_key == task.key)
        missing = shortfall.get(task.key, 0)
        assert placed + missing >= task.estimated_minutes, (
            f"{task.title}: {placed} placed + {missing} reported < {task.estimated_minutes}"
        )


def test_every_block_belongs_to_a_known_task(calendar):
    tasks, _, result = _run(calendar)
    keys = {t.key for t in tasks}
    assert all(block.task_key in keys for block in result.blocks)


def test_no_block_starts_after_its_deadline(calendar):
    tasks, _, result = _run(calendar)
    due = {t.key: t.due_at for t in tasks}
    for block in result.blocks:
        assert block.end <= due[block.task_key]


def test_session_numbering_is_consistent(calendar):
    """`session_count` drives the "(1/3)" suffix, so it must describe the task."""
    _, _, result = _run(calendar)
    for task_key in {b.task_key for b in result.blocks}:
        sessions = [b for b in result.blocks if b.task_key == task_key]
        indices = [b.session_index for b in sessions]
        assert len(set(indices)) == len(indices), "a session index was reused"
        assert all(0 <= i < b.session_count for i, b in zip(indices, sessions, strict=True))
        assert len({b.session_count for b in sessions}) == 1


def test_blocks_of_one_task_have_distinct_keys(calendar):
    """Two sessions of one task must never collide on `block_key`."""
    _, _, result = _run(calendar)
    keys = [b.block_key for b in result.blocks]
    assert len(keys) == len(set(keys))


def test_a_long_task_is_split_across_days_when_time_allows(calendar):
    """A 6-hour essay must not land as one solid evening.

    Stacking is allowed when the deadline is close - meeting it matters more
    than spreading - but with a week of runway the sessions should be apart.
    """
    cfg = load_study_config()
    _, _, result = _run(calendar, cfg)
    for task_key in {b.task_key for b in result.blocks}:
        sessions = sorted(
            (b for b in result.blocks if b.task_key == task_key), key=lambda b: b.start
        )
        if len(sessions) < 2:
            continue
        deadline = max(b.end for b in sessions)
        runway = (deadline.astimezone(DUBAI).date() - NOW.astimezone(DUBAI).date()).days
        if runway >= len(sessions):  # enough days to spread over
            days = {b.start.astimezone(DUBAI).date() for b in sessions}
            assert len(days) == len(sessions), "sessions stacked with runway to spare"


def test_the_week_is_deterministic(calendar):
    """Same inputs, same week - the calendar writer's idempotency depends on it."""
    _, _, first = _run(calendar)
    _, _, second = _run(calendar)
    assert [(b.block_key, b.start, b.end) for b in first.blocks] == [
        (b.block_key, b.start, b.end) for b in second.blocks
    ]


# --- the write path ---------------------------------------------------------------


def test_applying_the_week_twice_is_a_no_op(calendar, tmp_path):
    """The plan's stated idempotency check, end to end."""
    _, _, result = _run(calendar)

    with Store(tmp_path / "state.db") as store:
        writer = CalendarWriter(calendar, store)
        first = writer.apply(result.blocks, dry_run=False)
        # A copy: the double hands back `RemoteEvent`s, so the comparison is
        # model-for-model. What is asserted is unchanged - the second apply
        # wrote nothing at all.
        snapshot = dict(calendar.events)

        second = writer.apply(result.blocks, dry_run=False)

    assert first.created == len(result.blocks)
    assert (second.created, second.updated, second.deleted) == (0, 0, 0)
    assert second.unchanged == len(result.blocks)
    assert calendar.events == snapshot


def test_a_replan_moves_blocks_without_orphaning_any(calendar, tmp_path):
    """When a deadline shifts, blocks must move - not duplicate and not orphan.

    A moved date changes the task's identity, so its blocks are replaced rather
    than edited. The guarantee is that the calendar ends up holding exactly the
    new plan: no stale events left behind, no duplicates accumulating.
    """
    _, _, before = _run(calendar)
    assert before.blocks

    # Same work, different date: new task identity, so new block keys.
    shifted = DEADLINES[0].model_copy(update={"due_at": NOW + timedelta(days=1)})
    cfg = load_study_config()
    tasks = build_tasks([shifted, *DEADLINES[1:]], [], now=NOW, study_config=cfg)
    tasks = heuristic_scores(tasks, study_config=cfg, now=NOW)

    after = pack(tasks, _free_windows(calendar, cfg), cfg=cfg, tz=DUBAI, now=NOW)

    with Store(tmp_path / "state.db") as store:
        writer = CalendarWriter(calendar, store)
        writer.apply(before.blocks, dry_run=False)
        assert len(calendar.events) == len(before.blocks)

        writer.apply(after.blocks, dry_run=False)

    assert len(calendar.events) == len(after.blocks), "stale events were orphaned in the calendar"


# --- the shipped Phase 1 config -----------------------------------------------------


def test_the_shipped_stub_deadlines_are_well_formed():
    """The file a user actually edits must parse into usable deadlines."""
    result = StubSource().ingest()

    assert result.errors == []
    assert len(result.deadlines) == 5
    assert len(result.courses) == 3
    for deadline in result.deadlines:
        assert deadline.due_at.tzinfo is not None, "every due date needs an offset"
        assert deadline.course_name
        assert deadline.title


def test_the_shipped_stub_deadlines_are_unique():
    result = StubSource().ingest()
    ids = [d.external_id for d in result.deadlines]
    assert len(ids) == len(set(ids))


def test_the_shipped_study_config_loads():
    cfg = load_study_config()
    assert cfg.horizon.days > 0
    assert cfg.study.session_min_minutes <= cfg.study.session_max_minutes
    assert cfg.study.earliest_hour < cfg.study.latest_hour
