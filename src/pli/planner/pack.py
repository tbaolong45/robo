"""The deterministic scheduler.

This module owns every hard constraint. The LLM decides *what matters* and *how
long it takes* (`planner/score.py`); it never places anything. Everything here is
pure arithmetic over `Task` and `Slot`, so the guarantees hold no matter how
confused the model gets:

  * blocks never overlap each other
  * blocks never intersect a busy slot (class, appointment, anything)
  * consecutive blocks are separated by at least `break_minutes`
  * no block falls outside the configured study hours
  * daily and per-course daily caps are never exceeded
  * a task's sessions sum to at least its estimated duration
  * no block ends after the deadline it is for
  * `block_key` is stable across runs, so the calendar writer reconciles
    instead of duplicating

Given fixed input the output is identical every run.
"""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from pli.config import StudyConfig
from pli.models import Block, Slot, Task

MAX_SUBJECT = 250  # Graph truncates past 255; leave headroom.


@dataclass
class PackResult:
    blocks: list[Block] = field(default_factory=list)
    #: (task, minutes that could not be placed before the deadline)
    unscheduled: list[tuple[Task, int]] = field(default_factory=list)


def block_key_for(task_key: str, session_index: int) -> str:
    """Stable identity for one session of one task.

    Derived only from task identity and session ordinal, so moving a block in
    time does NOT change its key - the writer can then update the existing
    calendar event rather than creating a duplicate.
    """
    return hashlib.sha1(f"{task_key}|{session_index}".encode()).hexdigest()[:16]


def _split_sessions(estimated_minutes: int, cfg: StudyConfig) -> tuple[int, int]:
    """Divide a task into sessions. Returns (session_count, minutes_per_session).

    `ceil` on both steps guarantees count * length >= estimated_minutes, so a
    task is never under-scheduled.
    """
    lo = max(5, cfg.study.session_min_minutes)
    hi = max(lo, cfg.study.session_max_minutes)
    count = max(1, math.ceil(estimated_minutes / hi))
    length = math.ceil(estimated_minutes / count)
    return count, min(hi, max(lo, length))


def _target_day(i: int, count: int, today: date, deadline_day: date) -> date:
    """Spread session `i` of `count` across the days before the deadline.

    Front-loads without clustering: with 6 days available and 3 sessions the
    sessions land on days 0, 2 and 4 - not all on the last night.
    """
    span = max(0, (deadline_day - today).days)
    offset = min(int(i * (span + 1) / count), span)
    return today + timedelta(days=offset)


def _daily_cap(day: date, cfg: StudyConfig) -> int:
    if day.weekday() >= 5:
        return cfg.study.weekend_daily_cap_minutes
    return cfg.study.daily_cap_minutes


class _Calendar:
    """Mutable capacity tracker over the free slots.

    Every mutation keeps `by_day` sorted and non-overlapping, which is what
    makes the no-overlap guarantee hold by construction rather than by luck.
    """

    def __init__(self, free: list[Slot], tz: ZoneInfo, break_minutes: int) -> None:
        self.tz = tz
        self.break_minutes = break_minutes
        self.by_day: dict[date, list[Slot]] = {}
        for slot in sorted(free, key=lambda s: s.start):
            self.by_day.setdefault(slot.start.astimezone(tz).date(), []).append(slot)
        self.day_used: dict[date, int] = {}
        self.course_day_used: dict[tuple[date, str], int] = {}

    def _capacity_left(self, day: date, course: str, cfg: StudyConfig) -> int:
        total = _daily_cap(day, cfg) - self.day_used.get(day, 0)
        per_course = cfg.study.course_daily_cap_minutes - self.course_day_used.get((day, course), 0)
        return min(total, per_course)

    def _consume(self, day: date, idx: int, slot: Slot, minutes: int) -> None:
        """Take `minutes` off the front of a slot, leaving a break before the rest."""
        self.day_used[day] = self.day_used.get(day, 0) + minutes
        rest = self.by_day[day][:idx] + self.by_day[day][idx + 1 :]
        remainder_start = slot.start + timedelta(minutes=minutes + self.break_minutes)
        if remainder_start < slot.end:
            rest.append(Slot(start=remainder_start, end=slot.end))
        rest.sort(key=lambda s: s.start)
        self.by_day[day] = rest

    def _place_in_day(
        self,
        day: date,
        minutes: int,
        before_hour: int | None,
        before_instant: datetime | None = None,
    ) -> Slot | None:
        """Earliest fitting slot on this day, optionally restricted to a start hour.

        `before_instant` is the task's deadline. A block that would *end* after it
        is passed over, and so is every later slot: slots on a day are
        start-ordered, so a later start with the same length ends later still and
        cannot fit either. Without this the search window ended at the deadline's
        whole day, and a task due 09:00 Monday could be handed an 18:00 sitting
        that Monday - a plan that tells the user to revise for the exam after the
        exam.
        """
        for idx, slot in enumerate(self.by_day.get(day, [])):
            if before_hour is not None and slot.start.astimezone(self.tz).hour >= before_hour:
                continue
            if slot.minutes < minutes:
                continue
            if before_instant is not None:
                ends_after = slot.start + timedelta(minutes=minutes) > before_instant
                if ends_after:
                    break
            self._consume(day, idx, slot, minutes)
            return Slot(start=slot.start, end=slot.start + timedelta(minutes=minutes))
        return None

    def find(
        self,
        *,
        start_day: date,
        end_day: date,
        course: str,
        minutes: int,
        cfg: StudyConfig,
        before_hour: int | None = None,
        before_instant: datetime | None = None,
    ) -> Slot | None:
        day = start_day
        while day <= end_day:
            if (
                day.weekday() in cfg.study.weekdays_allowed
                and self._capacity_left(day, course, cfg) >= minutes
            ):
                found = self._place_in_day(day, minutes, before_hour, before_instant)
                if found is not None:
                    return found
            day += timedelta(days=1)
        return None

    def reserve_course(self, day: date, course: str, minutes: int) -> None:
        key = (day, course)
        self.course_day_used[key] = self.course_day_used.get(key, 0) + minutes


def pack(
    tasks: list[Task],
    free: list[Slot],
    *,
    cfg: StudyConfig,
    tz: ZoneInfo,
    now: datetime,
) -> PackResult:
    """Place `tasks` into `free` slots. Pure and deterministic."""
    result = PackResult()
    cal = _Calendar(free, tz, cfg.study.break_minutes)

    today = now.astimezone(tz).date()
    open_tasks = [t for t in tasks if t.due_at > now]
    # Most important first; ties broken by whichever is due sooner.
    open_tasks.sort(key=lambda t: (-t.priority, t.due_at))

    for task in open_tasks:
        count, length = _split_sessions(task.estimated_minutes, cfg)
        deadline_day = max(today, task.due_at.astimezone(tz).date())
        prefers_morning = task.energy == "deep"
        placed = 0

        for index in range(count):
            target = _target_day(index, count, today, deadline_day)
            slot = cal.find(
                start_day=target,
                end_day=deadline_day,
                course=task.course,
                minutes=length,
                cfg=cfg,
                before_hour=cfg.deep_work.prefer_before_hour if prefers_morning else None,
                before_instant=task.due_at,
            )
            if slot is None and prefers_morning:
                # No morning window anywhere before the deadline - take any hour.
                slot = cal.find(
                    start_day=target,
                    end_day=deadline_day,
                    course=task.course,
                    minutes=length,
                    cfg=cfg,
                    before_instant=task.due_at,
                )
            if slot is None:
                continue
            # Reserve on the day the block actually landed, not the target day.
            cal.reserve_course(slot.start.astimezone(tz).date(), task.course, length)
            placed += length
            result.blocks.append(_make_block(task, index, count, length, slot))

        if placed < task.estimated_minutes:
            result.unscheduled.append((task, task.estimated_minutes - placed))

    result.blocks.sort(key=lambda b: b.start)
    return result


def _make_block(task: Task, index: int, count: int, minutes: int, slot: Slot) -> Block:
    suffix = f" ({index + 1}/{count})" if count > 1 else ""
    subject = f"Study · {task.course} — {task.title}{suffix}"
    lines = [task.detail] if task.detail else []
    if count > 1:
        lines.append(f"Session {index + 1} of {count} · {minutes} min")
    lines.append(f"Due {task.due_at:%Y-%m-%d %H:%M} UTC")
    lines.extend(task.urls)
    return Block(
        block_key=block_key_for(task.key, index),
        task_key=task.key,
        subject=subject[:MAX_SUBJECT],
        start=slot.start,
        end=slot.start + timedelta(minutes=minutes),
        body="\n".join(line for line in lines if line),
        session_index=index,
        session_count=count,
    )
