"""Turn the calendar into genuinely free windows.

The events come from whatever `pli.backend.CalendarBackend` reads; this module
does not know or care whether that is a browser driving the Outlook web UI or a
test double. All it needs is the set of intervals that are occupied.

Everything crossing this module's boundary is UTC, per `pli.models`; the single
conversion into the user's zone happens inside `free_slots`, which is a pure
function so the packer's output stays reproducible.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from pli.config import StudyConfig
from pli.models import RemoteEvent, Slot

__all__ = ["busy_from", "free_slots"]


def busy_from(events: list[RemoteEvent]) -> list[Slot]:
    """Events that should block study time, as UTC `Slot`s, ordered.

    Only status "free" is excluded - tentative, oof and workingElsewhere all
    block, because a provisional class is still a class.

    All-day events are excluded too, and this is the important judgement call:
    an all-day entry in a university calendar is a holiday banner, a birthday,
    or an assignment due date. Treating those as busy would erase every window
    in the horizon and produce an empty plan. A genuinely blocked day is
    expressed as timed events, which are honoured.
    """
    blocked = [
        Slot(start=e.start, end=e.end)
        for e in events
        if not e.all_day and str(e.show_as).lower() != "free" and e.end > e.start
    ]
    blocked.sort(key=lambda s: (s.start, s.end))
    return blocked


# --- free windows ---------------------------------------------------------------


def free_slots(
    busy: list[Slot],
    cfg: StudyConfig,
    tz: ZoneInfo,
    start: datetime,
    end: datetime,
) -> list[Slot]:
    """Free, schedulable windows inside [start, end), UTC and non-overlapping.

    Candidate windows are built day by day in `tz` between `earliest_hour` and
    `latest_hour`, skipping disallowed weekdays; every busy interval is
    subtracted; the remainder is merged and trimmed to `session_min_minutes`.
    Pure and deterministic - no network, no clock reads.
    """
    local_start = _as_utc(start).astimezone(tz)
    local_end = _as_utc(end).astimezone(tz)
    if local_end <= local_start:
        return []

    blocked = sorted(
        (b.start.astimezone(tz), b.end.astimezone(tz)) for b in busy if b.end > b.start
    )

    pieces: list[tuple[datetime, datetime]] = []
    day: date = local_start.date()
    last_day = local_end.date()
    while day <= last_day:
        if day.weekday() in cfg.study.weekdays_allowed:
            window = _clip(_day_window(day, cfg, tz), local_start, local_end)
            if window is not None:
                pieces.extend(_subtract(window, blocked))
        day += timedelta(days=1)

    pieces.sort()
    merged: list[tuple[datetime, datetime]] = []
    for piece_start, piece_end in pieces:
        if merged and piece_start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], piece_end))
        else:
            merged.append((piece_start, piece_end))

    shortest = timedelta(minutes=cfg.study.session_min_minutes)
    return [
        Slot(start=s.astimezone(UTC), end=e.astimezone(UTC)) for s, e in merged if e - s >= shortest
    ]


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise ValueError("datetime must be timezone-aware")
    return value.astimezone(UTC)


def _day_window(day: date, cfg: StudyConfig, tz: ZoneInfo) -> tuple[datetime, datetime]:
    """Local [earliest_hour, latest_hour) on one day.

    Built with `datetime.combine` rather than string formatting so the zone's own
    offset rules apply - a formatted local time would silently pick the wrong
    side of a DST transition.
    """
    return (
        datetime.combine(day, time(cfg.study.earliest_hour), tzinfo=tz),
        datetime.combine(day, time(cfg.study.latest_hour), tzinfo=tz),
    )


def _clip(
    window: tuple[datetime, datetime], lo: datetime, hi: datetime
) -> tuple[datetime, datetime] | None:
    clipped = (max(window[0], lo), min(window[1], hi))
    return clipped if clipped[0] < clipped[1] else None


def _subtract(
    window: tuple[datetime, datetime], blocked: list[tuple[datetime, datetime]]
) -> list[tuple[datetime, datetime]]:
    """Carve busy intervals out of one window; returns disjoint, ordered pieces.

    A single cursor sweep: everything before the cursor is already known busy, so
    the gap from the cursor to the next busy start is free. Because `blocked` is
    sorted, pieces cannot overlap and never intersect a busy interval.
    """
    w_start, w_end = window
    free: list[tuple[datetime, datetime]] = []
    cursor = w_start
    for b_start, b_end in blocked:
        if b_end <= cursor:
            continue
        if b_start >= w_end:
            break
        if b_start > cursor:
            free.append((cursor, b_start))
        cursor = max(cursor, b_end)
    if cursor < w_end:
        free.append((cursor, w_end))
    return free
