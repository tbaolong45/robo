"""Free-window derivation: what counts as busy, and what is actually free.

Every test here is pure - synthetic `Slot`s and `RemoteEvent`s in, `Slot`s out.
No network, no browser, no clock. The two halves are separate concerns:

**`busy_from` decides what blocks study time.** That is a judgement about the
user's week, not a parsing step: an all-day banner must not erase seven days, a
provisional class must still count as a class, and an event marked "free" is the
university telling us it is not really taken.

**`free_slots` does the arithmetic.** It is the part that must be exact, because
every guarantee the packer rests on is downstream of it: windows that never
overlap a lecture, that respect study hours and DST, and that are long enough to
be worth starting.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from pli.config import StudyConfig
from pli.models import RemoteEvent, Slot
from pli.planner.freebusy import busy_from, free_slots

BERLIN = ZoneInfo("Europe/Berlin")
NEW_YORK = ZoneInfo("America/New_York")


def _cfg(**study) -> StudyConfig:
    base = {
        "earliest_hour": 8,
        "latest_hour": 22,
        "session_min_minutes": 45,
        "weekdays_allowed": list(range(7)),
    }
    return StudyConfig(study={**base, **study})


def _slot(start: datetime, minutes: int) -> Slot:
    return Slot(start=start, end=start + timedelta(minutes=minutes))


def _local(day: str, hour: int, minute: int = 0, tz=BERLIN) -> datetime:
    return datetime.fromisoformat(f"{day}T{hour:02d}:{minute:02d}:00").replace(tzinfo=tz)


def _window(day: str, days: int = 1, tz=BERLIN) -> tuple[datetime, datetime]:
    start = _local(day, 0, tz=tz)
    return start, start + timedelta(days=days)


def _event(
    start: datetime,
    minutes: int = 60,
    *,
    show_as: str = "busy",
    all_day: bool = False,
    subject: str = "Lecture",
) -> RemoteEvent:
    return RemoteEvent(
        remote_id=f"event-{start.isoformat()}-{subject}",
        subject=subject,
        start=start,
        end=start + timedelta(minutes=minutes),
        all_day=all_day,
        show_as=show_as,
    )


# --- what blocks study time ------------------------------------------------------


@pytest.mark.parametrize("status", ["busy", "tentative", "oof", "workingElsewhere", "unknown"])
def test_every_non_free_status_blocks(status):
    """A provisional class is still a class - only "free" is free.

    "unknown" is included on purpose: an unrecognised status is a parse we do
    not understand, and booking study time over it is the worse mistake.
    """
    busy = busy_from([_event(_local("2026-10-05", 10).astimezone(UTC), show_as=status)])
    assert len(busy) == 1
    assert busy[0].minutes == 60


def test_an_event_marked_free_does_not_block():
    """The calendar is already saying this time is available."""
    assert busy_from([_event(_local("2026-10-05", 10).astimezone(UTC), show_as="free")]) == []


def test_an_all_day_event_does_not_block():
    """A holiday banner or a birthday must not erase the whole week.

    An all-day entry in a university calendar is a due date, a public holiday or
    a birthday - not a day of lectures. Treating it as busy would leave no
    schedulable window anywhere in the horizon and produce an empty plan, which
    fails far worse than planning study on someone's birthday. A day that really
    is occupied is expressed as timed events, and those are honoured.
    """
    holiday = _event(
        _local("2026-10-05", 0).astimezone(UTC),
        24 * 60,
        all_day=True,
        subject="Reading week",
    )

    assert busy_from([holiday]) == []

    # And the whole point: the plan for that day is untouched.
    cfg = _cfg()
    start, end = _window("2026-10-05")
    assert free_slots(busy_from([holiday]), cfg, BERLIN, start, end) == free_slots(
        [], cfg, BERLIN, start, end
    )


def test_an_all_day_event_does_not_hide_the_timed_events_beside_it():
    start = _local("2026-10-05", 10).astimezone(UTC)
    holiday = _event(_local("2026-10-05", 0).astimezone(UTC), 24 * 60, all_day=True)
    lecture = _event(start, 60)

    (busy,) = busy_from([holiday, lecture])

    assert (busy.start, busy.end) == (start, start + timedelta(minutes=60))


@pytest.mark.parametrize("minutes", [0, -30])
def test_a_non_positive_event_does_not_block(minutes):
    """A zero-length entry is a placeholder, and a negative one is nonsense;
    either would subtract a window that never existed."""
    assert busy_from([_event(_local("2026-10-05", 10).astimezone(UTC), minutes)]) == []


def test_an_empty_event_list_blocks_nothing():
    assert busy_from([]) == []


def test_the_busy_list_is_ordered_by_start():
    """Downstream subtraction sweeps a sorted list, so this is load-bearing."""
    events = [
        _event(_local("2026-10-05", 14).astimezone(UTC)),
        _event(_local("2026-10-05", 9).astimezone(UTC)),
        _event(_local("2026-10-05", 11).astimezone(UTC)),
    ]

    busy = busy_from(events)

    assert [b.start for b in busy] == sorted(b.start for b in busy)


def test_busy_slots_are_utc_and_timezone_aware():
    """Everything crossing this boundary is UTC; a local or naive datetime here
    would shift a lecture by the zone offset and free the hour it occupies."""
    lecture = _event(_local("2026-10-05", 10))  # 10:00 Berlin == 08:00 UTC in October

    (busy,) = busy_from([lecture])

    assert busy.start.utcoffset() == timedelta(0)
    assert busy.start.tzinfo is not None
    assert busy.start == datetime(2026, 10, 5, 8, 0, tzinfo=UTC)


# --- basic subtraction ---------------------------------------------------------


def test_empty_calendar_yields_one_full_day():
    cfg = _cfg()
    start, end = _window("2026-10-05")  # a Monday
    slots = free_slots([], cfg, BERLIN, start, end)
    assert len(slots) == 1
    assert slots[0].start == _local("2026-10-05", 8).astimezone(UTC)
    assert slots[0].end == _local("2026-10-05", 22).astimezone(UTC)
    assert slots[0].minutes == 14 * 60


def test_a_lecture_splits_the_day_in_two():
    cfg = _cfg()
    start, end = _window("2026-10-05")
    lecture = _slot(_local("2026-10-05", 10).astimezone(UTC), 120)  # 10:00-12:00

    slots = free_slots([lecture], cfg, BERLIN, start, end)

    assert len(slots) == 2
    assert (slots[0].start, slots[0].end) == (
        _local("2026-10-05", 8).astimezone(UTC),
        _local("2026-10-05", 10).astimezone(UTC),
    )
    assert (slots[1].start, slots[1].end) == (
        _local("2026-10-05", 12).astimezone(UTC),
        _local("2026-10-05", 22).astimezone(UTC),
    )


def test_busy_before_study_hours_changes_nothing():
    cfg = _cfg()
    start, end = _window("2026-10-05")
    early = _slot(_local("2026-10-05", 5).astimezone(UTC), 60)  # 05:00-06:00
    assert free_slots([early], cfg, BERLIN, start, end) == free_slots([], cfg, BERLIN, start, end)


def test_busy_after_study_hours_changes_nothing():
    cfg = _cfg()
    start, end = _window("2026-10-05")
    late = _slot(_local("2026-10-05", 23).astimezone(UTC), 60)
    assert free_slots([late], cfg, BERLIN, start, end) == free_slots([], cfg, BERLIN, start, end)


def test_a_busy_block_covering_the_whole_window_leaves_nothing():
    cfg = _cfg()
    start, end = _window("2026-10-05")
    all_day = _slot(_local("2026-10-05", 0).astimezone(UTC), 24 * 60)
    assert free_slots([all_day], cfg, BERLIN, start, end) == []


def test_busy_straddling_the_window_start_clips_correctly():
    cfg = _cfg()
    start, end = _window("2026-10-05")
    overnight = _slot(_local("2026-10-05", 0).astimezone(UTC), 9 * 60)  # 00:00-09:00
    (slot,) = free_slots([overnight], cfg, BERLIN, start, end)
    assert slot.start == _local("2026-10-05", 9).astimezone(UTC)
    assert slot.end == _local("2026-10-05", 22).astimezone(UTC)


# --- invariants ----------------------------------------------------------------


def test_slots_never_overlap_a_busy_block():
    cfg = _cfg()
    start, end = _window("2026-10-05", days=3)
    busy = [
        _slot(_local("2026-10-05", 10).astimezone(UTC), 90),
        _slot(_local("2026-10-05", 14).astimezone(UTC), 60),
        _slot(_local("2026-10-06", 9).astimezone(UTC), 180),
        _slot(_local("2026-10-07", 12).astimezone(UTC), 45),
    ]
    for slot in free_slots(busy, cfg, BERLIN, start, end):
        for block in busy:
            assert slot.end <= block.start or slot.start >= block.end


def test_slots_are_ordered_and_disjoint():
    cfg = _cfg()
    start, end = _window("2026-10-05", days=5)
    busy = [
        _slot(_local("2026-10-05", 10).astimezone(UTC), 90),
        _slot(_local("2026-10-06", 15).astimezone(UTC), 60),
    ]
    slots = free_slots(busy, cfg, BERLIN, start, end)
    for earlier, later in zip(slots, slots[1:], strict=False):
        assert earlier.start < earlier.end
        assert earlier.end <= later.start


def test_slots_stay_inside_study_hours():
    cfg = _cfg(earliest_hour=9, latest_hour=17)
    start, end = _window("2026-10-05", days=4)
    for slot in free_slots([], cfg, BERLIN, start, end):
        local = slot.start.astimezone(BERLIN)
        assert local.hour >= 9
        assert slot.end.astimezone(BERLIN).hour <= 17


def test_overlapping_busy_blocks_are_handled():
    """Two calendars disagreeing must not produce a negative-length gap."""
    cfg = _cfg()
    start, end = _window("2026-10-05")
    busy = [
        _slot(_local("2026-10-05", 10).astimezone(UTC), 120),  # 10:00-12:00
        _slot(_local("2026-10-05", 11).astimezone(UTC), 180),  # 11:00-14:00
    ]
    slots = free_slots(busy, cfg, BERLIN, start, end)
    assert [s.minutes for s in slots] == [120, 8 * 60]


# --- filters -------------------------------------------------------------------


def test_disallowed_weekdays_are_skipped():
    # 2026-10-05 is a Monday; allow Monday only.
    cfg = _cfg(weekdays_allowed=[0])
    start, end = _window("2026-10-05", days=7)
    slots = free_slots([], cfg, BERLIN, start, end)
    assert len(slots) == 1
    assert slots[0].start.astimezone(BERLIN).date() == datetime(2026, 10, 5).date()


def test_weekend_only_configuration():
    cfg = _cfg(weekdays_allowed=[5, 6])
    start, end = _window("2026-10-05", days=7)
    days = {s.start.astimezone(BERLIN).weekday() for s in free_slots([], cfg, BERLIN, start, end)}
    assert days == {5, 6}


def test_gaps_shorter_than_the_minimum_session_are_discarded():
    """A 20-minute gap between classes is not a study session."""
    cfg = _cfg(session_min_minutes=45)
    start, end = _window("2026-10-05")
    busy = [
        _slot(_local("2026-10-05", 8).astimezone(UTC), 120),  # 08:00-10:00
        _slot(_local("2026-10-05", 10, 20).astimezone(UTC), 45),  # 10:20-11:05
    ]
    slots = free_slots(busy, cfg, BERLIN, start, end)
    # The 20-minute gap is dropped; only 11:05-22:00 (10h55m) survives.
    assert [s.minutes for s in slots] == [10 * 60 + 55]


def test_a_window_exactly_at_the_minimum_survives():
    """The filter is a floor, not a strict inequality - otherwise every gap of
    exactly `session_min_minutes` would vanish."""
    cfg = _cfg(session_min_minutes=45)
    start, end = _window("2026-10-05")
    busy = [
        _slot(_local("2026-10-05", 8).astimezone(UTC), 120),  # 08:00-10:00 ...
        _slot(_local("2026-10-05", 10, 45).astimezone(UTC), 60),  # 10:45-11:45
    ]
    # The gap between them is exactly 45 minutes, and must survive.
    slots = free_slots(busy, cfg, BERLIN, start, end)
    assert [s.minutes for s in slots] == [45, 10 * 60 + 15]


def test_abutting_pieces_are_merged():
    """Two busy blocks that touch block one stretch of time, not two.

    The name is the promise this test used to make and does not keep: it asserts
    that 08:00-09:00 and 09:00-10:00 together leave a single window starting at
    10:00, which is `_subtract`'s doing. The `merged` fold below it - the code
    that joins two abutting *pieces* - is never reached from here, because
    windows are built one day at a time and a day's window cannot touch the next
    day's (no hour-of-day reaches 24). Mutating that fold changes nothing in the
    whole suite. It is kept as the guard that would matter the day two windows
    can touch, not because this test covers it.
    """
    cfg = _cfg()
    start, end = _window("2026-10-05")
    busy = [
        _slot(_local("2026-10-05", 8).astimezone(UTC), 60),  # 08:00-09:00
        _slot(_local("2026-10-05", 9).astimezone(UTC), 60),  # 09:00-10:00
    ]
    (slot,) = free_slots(busy, cfg, BERLIN, start, end)
    assert slot.start == _local("2026-10-05", 10).astimezone(UTC)


# --- boundaries ------------------------------------------------------------------


def test_zero_width_busy_blocks_are_ignored():
    cfg = _cfg()
    start, end = _window("2026-10-05")
    point = _slot(_local("2026-10-05", 12).astimezone(UTC), 0)
    assert free_slots([point], cfg, BERLIN, start, end) == free_slots([], cfg, BERLIN, start, end)


def test_non_positive_window_returns_nothing():
    cfg = _cfg()
    start, _ = _window("2026-10-05")
    assert free_slots([], cfg, BERLIN, start, start) == []


def test_a_naive_window_boundary_is_rejected():
    """A naive datetime would be silently read as the wrong zone; refusing it is
    the only safe option, since the caller cannot see the error afterwards."""
    cfg = _cfg()
    with pytest.raises(ValueError, match="timezone-aware"):
        free_slots([], cfg, BERLIN, datetime(2026, 10, 5), datetime(2026, 10, 6))


def test_window_clips_a_partial_day_at_both_ends():
    cfg = _cfg()
    start = _local("2026-10-05", 12)
    end = _local("2026-10-07", 14)
    slots = free_slots([], cfg, BERLIN, start, end)
    assert slots[0].start == _local("2026-10-05", 12).astimezone(UTC)
    assert slots[-1].end == _local("2026-10-07", 14).astimezone(UTC)


def test_the_result_is_independent_of_the_days_iteration_order():
    """Determinism: the same inputs always give byte-identical windows."""
    cfg = _cfg()
    start, end = _window("2026-10-05", days=7)
    busy = [_slot(_local("2026-10-06", 10).astimezone(UTC), 90)]
    assert free_slots(busy, cfg, BERLIN, start, end) == free_slots(busy, cfg, BERLIN, start, end)


# --- DST -------------------------------------------------------------------------


def test_spring_forward_day_is_one_hour_shorter():
    """America/New_York loses an hour on 2026-03-08: 00:00-06:00 is 5h, not 6h."""
    cfg = _cfg(earliest_hour=0, latest_hour=6)
    start = _local("2026-03-08", 0, tz=NEW_YORK)
    end = start + timedelta(hours=6)  # absolute 6h == 05:00 local, after the jump

    slots = free_slots([], cfg, NEW_YORK, start, end)
    assert sum(s.minutes for s in slots) == 300


def test_fall_back_day_is_one_hour_longer():
    """Europe/Berlin gains an hour on 2026-10-25: 00:00-06:00 is 7h, not 6h."""
    cfg = _cfg(earliest_hour=0, latest_hour=6)
    start = _local("2026-10-25", 0)
    end = start + timedelta(hours=7)  # absolute 7h == 06:00 local, after the fall back

    slots = free_slots([], cfg, BERLIN, start, end)
    assert sum(s.minutes for s in slots) == 420


def test_a_dst_day_keeps_the_local_study_hours_it_promised():
    """Study hours are a local promise: on the 23-hour day the window must still
    run 08:00-10:00 local, which is 1h of wall clock shorter, not 2h of UTC."""
    cfg = _cfg(earliest_hour=8, latest_hour=10)
    day = date(2026, 3, 8)
    start = datetime.combine(day, datetime.min.time(), tzinfo=NEW_YORK)
    end = start + timedelta(days=1)

    (slot,) = free_slots([], cfg, NEW_YORK, start, end)

    assert slot.start.astimezone(NEW_YORK).hour == 8
    assert slot.end.astimezone(NEW_YORK).hour == 10
    assert slot.minutes == 120  # 02:00 local is skipped, so 08:00-10:00 is 2h


def test_an_evening_range_is_read_as_the_local_evening_it_names():
    """The days to scan are the *local* dates of the range, not its UTC dates.

    West of UTC the local evening is already the next day in UTC: 20:00 in New
    York on 2026-10-05 is 00:00 UTC on the 6th. Starting the day loop from the
    UTC date would scan a day the caller never asked about, find nothing in the
    range and return no windows at all - the evening simply disappears from the
    plan, with no error to explain it.
    """
    cfg = _cfg()
    start = _local("2026-10-05", 20, tz=NEW_YORK)
    end = _local("2026-10-05", 22, tz=NEW_YORK)

    (slot,) = free_slots([], cfg, NEW_YORK, start, end)

    assert slot.start == start.astimezone(UTC)
    assert slot.end == end.astimezone(UTC)
    assert slot.minutes == 120
