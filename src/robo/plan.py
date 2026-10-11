"""Today's study plan, pure and deterministic: tasks go into the free time around busy
intervals, never overlapping busy time, never starting before now, never ending after a task's
deadline. `main` is `robo plan`, the JSON-in/JSON-out command Hermes runs from the terminal."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MINUTE = timedelta(minutes=1)


def _aware(*values: datetime) -> None:
    if any(v.tzinfo is None or v.utcoffset() is None for v in values):
        raise ValueError("datetimes must be timezone-aware")


@dataclass(frozen=True)
class Busy:
    start: datetime
    end: datetime

    def __post_init__(self) -> None:
        _aware(self.start, self.end)


@dataclass(frozen=True)
class Task:
    id: str
    title: str
    minutes: int
    deadline: datetime | None = None
    priority: float = 0.5  # 0..1, higher goes first

    def __post_init__(self) -> None:
        m, p = self.minutes, self.priority
        if isinstance(m, bool) or not isinstance(m, int) or m < 1:
            raise ValueError("minutes must be a positive whole number")
        if isinstance(p, bool) or not isinstance(p, int | float) or not 0 <= p <= 1:
            raise ValueError("priority must be a number from 0 to 1")
        if self.deadline is not None:
            _aware(self.deadline)


@dataclass(frozen=True)
class Block:
    task_id: str
    title: str
    start: datetime
    end: datetime


def free_slots(busy: list[Busy], day_start: datetime, day_end: datetime,
               min_minutes: int = 25) -> list[tuple[datetime, datetime]]:
    """Free (start, end) windows in [day_start, day_end), ordered and disjoint. Windows shorter
    than `min_minutes` are dropped; empty or backwards busy entries are ignored."""
    _aware(day_start, day_end)
    gaps, cursor = [], day_start
    for b in sorted(busy, key=lambda b: (b.start, b.end)):
        if b.start >= day_end:
            break
        if b.end <= max(cursor, b.start):
            continue
        if b.start > cursor:
            gaps.append((cursor, b.start))
        cursor = b.end
    if cursor < day_end:
        gaps.append((cursor, day_end))
    return [(s, e) for s, e in gaps if e - s >= min_minutes * MINUTE]


def _ceil5(t: datetime) -> datetime:
    """Round up to whole five minutes, so a plan reads like a person wrote it."""
    floor = t.replace(second=0, microsecond=0)
    floor -= (floor.minute % 5) * MINUTE
    return floor if floor == t else floor + 5 * MINUTE


def _split(minutes: int, cap: int) -> list[int]:
    """Near-equal parts of at most `cap` that sum to exactly `minutes`."""
    n = -(-minutes // cap)
    q, r = divmod(minutes, n)
    return [q + 1] * r + [q] * (n - r)


def plan_day(tasks: list[Task], busy: list[Busy], *, day_start: datetime, day_end: datetime,
             now: datetime, max_block: int = 90, break_min: int = 10,
             min_block: int = 25) -> list[Block]:
    """Blocks ordered by start. Tasks go highest priority first, then nearest deadline (then id,
    so input order never matters). Each is split into near-equal blocks of at most `max_block`
    minutes, each at the earliest free time that fits, `break_min` after any block before it in
    the same window. A block that cannot end by its deadline is skipped; see `unscheduled`."""
    _aware(day_start, day_end, now)
    free = free_slots(busy, max(day_start, now), day_end, min_block)
    blocks = []
    for task in sorted(tasks, key=lambda t: (-t.priority, t.deadline is None, t.deadline, t.id)):
        for minutes in _split(task.minutes, max_block):
            for i, (s, e) in enumerate(free):
                start = _ceil5(s)
                end = start + minutes * MINUTE
                if task.deadline is not None and end > task.deadline:
                    break  # windows are ordered, so every later one ends later still
                if end <= e:
                    rest = end + break_min * MINUTE
                    free[i : i + 1] = [(rest, e)] if rest < e else []
                    blocks.append(Block(task.id, task.title, start, end))
                    break
    return sorted(blocks, key=lambda b: (b.start, b.task_id))


def unscheduled(tasks: list[Task], blocks: list[Block]) -> list[tuple[Task, int]]:
    """(task, minutes the plan could not place) for every task not fully placed."""
    placed: Counter[str] = Counter()
    for b in blocks:
        placed[b.task_id] += (b.end - b.start) // MINUTE
    return [(t, t.minutes - placed[t.id]) for t in tasks if placed[t.id] < t.minutes]


# --- robo plan --------------------------------------------------------------------------------


class _Bad(Exception):
    """Bad input: one line on stderr, exit 2."""


class _Parser(argparse.ArgumentParser):
    def error(self, message: str):  # one line instead of usage + message + SystemExit
        raise _Bad(message)


def _load(src: str):
    name = "stdin" if src == "-" else src
    try:
        raw = sys.stdin.read() if src == "-" else Path(src).read_bytes()
    except OSError as e:
        raise _Bad(f"cannot read {name}: {e.strerror}") from None
    try:
        return json.loads(raw)
    except ValueError as e:
        raise _Bad(f"{name}: invalid JSON ({e})") from None


def _rows(data, name: str):
    if not isinstance(data, list) or not all(isinstance(r, dict) for r in data):
        raise _Bad(f"{name}: expected a JSON list of objects")
    return enumerate(data)


def _when(value, tz: ZoneInfo, where: str) -> datetime:
    """ISO datetime; one without an offset is read in `tz`."""
    try:
        t = datetime.fromisoformat(value)
    except (TypeError, ValueError):
        raise _Bad(f"{where}: not an ISO datetime: {value!r}") from None
    return t if t.tzinfo else t.replace(tzinfo=tz)


def _tasks(data, tz: ZoneInfo) -> list[Task]:
    tasks = []
    for i, r in _rows(data, "tasks"):
        where = f"tasks[{i}]"
        try:
            deadline = r.get("deadline")
            if deadline is not None:
                deadline = _when(deadline, tz, f"{where}.deadline")
            tasks.append(Task(str(r["id"]), str(r["title"]), r["minutes"], deadline,
                              r.get("priority", 0.5)))
        except KeyError as e:
            raise _Bad(f"{where}: missing {e.args[0]!r}") from None
        except ValueError as e:
            raise _Bad(f"{where}: {e}") from None
    ids = Counter(t.id for t in tasks)
    if dup := next((i for i, n in ids.items() if n > 1), None):
        raise _Bad(f"tasks: duplicate id {dup!r}")
    return tasks


def _busy(data, tz: ZoneInfo) -> list[Busy]:
    return [Busy(_when(r.get("start"), tz, f"busy[{i}].start"),
                 _when(r.get("end"), tz, f"busy[{i}].end")) for i, r in _rows(data, "busy")]


def _parse(fn, text: str, flag: str, shape: str):
    try:
        return fn(text)
    except ValueError:
        raise _Bad(f"{flag}: expected {shape}, got {text!r}") from None


def main(argv: list[str] | None = None, *, now: datetime | None = None) -> int:
    """`robo plan` (argv is everything after "plan"). Prints the plan as JSON; bad input is
    exit 2 with one line on stderr."""
    p = _Parser(prog="robo plan", description="Plan a day of study blocks around busy time. "
                'Prints {"blocks": [{title, start, end}], "unscheduled": [{id, title, minutes}]}.')
    p.add_argument("--tasks", required=True, metavar="FILE",
                   help='JSON list (or - for stdin): [{"id", "title", "minutes", "deadline"?, '
                        '"priority"? 0..1}]')
    p.add_argument("--busy", metavar="FILE", help='JSON list (or -): [{"start", "end"}], ISO times')
    p.add_argument("--day", help="YYYY-MM-DD (default: today)")
    p.add_argument("--start", default="08:00", help="HH:MM (default 08:00)")
    p.add_argument("--end", default="22:00", help="HH:MM (default 22:00)")
    p.add_argument("--tz", default="Asia/Dubai", help="time zone (default Asia/Dubai); also "
                   "used for ISO times without an offset")
    try:
        a = p.parse_args(argv)
        if a.tasks == "-" and a.busy == "-":
            raise _Bad("only one of --tasks and --busy can read stdin ('-')")
        try:
            tz = ZoneInfo(a.tz)
        except (ZoneInfoNotFoundError, ValueError):
            raise _Bad(f"--tz: unknown time zone {a.tz!r}") from None
        now = now or datetime.now(tz)
        day = _parse(date.fromisoformat, a.day, "--day", "YYYY-MM-DD") if a.day \
            else now.astimezone(tz).date()
        start, end = (datetime.combine(day, _parse(time.fromisoformat, v, f, "HH:MM"), tz)
                      for v, f in ((a.start, "--start"), (a.end, "--end")))
        if end <= start:
            raise _Bad("--end must be after --start")
        tasks = _tasks(_load(a.tasks), tz)
        busy = _busy(_load(a.busy), tz) if a.busy else []
    except _Bad as e:
        print(f"robo plan: {e}", file=sys.stderr)
        return 2
    blocks = plan_day(tasks, busy, day_start=start, day_end=end, now=now)

    def iso(t: datetime) -> str:
        return t.astimezone(tz).isoformat(timespec="minutes")

    print(json.dumps({
        "blocks": [{"title": b.title, "start": iso(b.start), "end": iso(b.end)} for b in blocks],
        "unscheduled": [{"id": t.id, "title": t.title, "minutes": m}
                        for t, m in unscheduled(tasks, blocks)],
    }, ensure_ascii=False))
    return 0
