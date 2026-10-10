"""Turn raw source deadlines into schedulable tasks.

Pure data transformation: no network, no LLM. The scorer refines priority,
duration and energy afterwards; the stable `Task.key` is what lets the calendar
writer reconcile a replan instead of duplicating every block.
"""

from __future__ import annotations

import hashlib
import re
from datetime import datetime
from difflib import SequenceMatcher

from pli.config import StudyConfig
from pli.models import Deadline, Material, Task

__all__ = ["build_tasks"]

#: Same course, same day, titles this close: one piece of work reported twice
#: (typically Moodle and Teams both announcing the same assignment).
TITLE_SIMILARITY = 0.75
#: Short titles are compared for equality only. "Quiz 3" and "Quiz 4" score 0.83
#: on the ratio above - well past the threshold - so fuzzy matching them would
#: silently merge two distinct pieces of work. Below this length the ratio
#: carries no signal, so the merge must be exact.
FUZZY_MIN_CHARS = 12
_PUNCTUATION = re.compile(r"[^\w\s]|_", re.UNICODE)


def build_tasks(
    deadlines: list[Deadline],
    materials: list[Material],
    *,
    now: datetime,
    study_config: StudyConfig,
) -> list[Task]:
    """Build one `Task` per distinct piece of work still ahead of `now`.

    Deadlines already due are dropped. Duplicates across sources collapse into a
    single task that keeps every source URL; the earliest stated due date wins,
    so an earlier announcement is never silently relaxed.
    """
    live = [d for d in deadlines if d.due_at > now]
    hours_by_course = _material_hours(materials)
    tasks: list[Task] = []

    for group in _cluster(live):
        group.sort(key=lambda d: (d.due_at, d.source, d.external_id))
        due_at = min(d.due_at for d in group)
        title = max((d.title.strip() for d in group), key=len) or "(untitled)"
        course = _course_label(group[0])
        tasks.append(
            Task(
                key=_task_key(course, _normalise(title), due_at),
                title=title,
                course=course,
                due_at=due_at,
                estimated_minutes=_estimate_minutes(group, hours_by_course, study_config),
                urls=list(dict.fromkeys(d.url for d in group if d.url)),
            )
        )

    tasks.sort(key=lambda t: (t.due_at, t.key))
    return tasks


def _cluster(deadlines: list[Deadline]) -> list[list[Deadline]]:
    """Group deadlines describing the same work. O(n^2), and n is tiny."""
    parent = list(range(len(deadlines)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(deadlines):
        for j in range(i + 1, len(deadlines)):
            if _same_work(a, deadlines[j]):
                parent[find(j)] = find(i)

    groups: dict[int, list[Deadline]] = {}
    for i, deadline in enumerate(deadlines):
        groups.setdefault(find(i), []).append(deadline)
    return list(groups.values())


def _same_work(a: Deadline, b: Deadline) -> bool:
    """Same day, same course, and either the same normalised title or a near match.

    The identity is the one `_task_key` encodes - course, title, day. Course
    labels are compared as canonical token sets, because the same course is
    labelled "CS301 Algorithms" on one source and "Algorithms (CS301)" on
    another; an empty label matches anything.
    """
    if a.due_at.date() != b.due_at.date() or not _courses_compatible(a, b):
        return False
    title_a, title_b = _normalise(a.title), _normalise(b.title)
    if not title_a or not title_b:
        return title_a == title_b
    if title_a == title_b:
        return True
    if min(len(title_a), len(title_b)) < FUZZY_MIN_CHARS:
        return False
    return SequenceMatcher(None, title_a, title_b).ratio() >= TITLE_SIMILARITY


def _courses_compatible(a: Deadline, b: Deadline) -> bool:
    key_a, key_b = _course_key(a), _course_key(b)
    return not key_a or not key_b or key_a == key_b


def _material_hours(materials: list[Material]) -> dict[str, float]:
    """Largest per-course estimate from enriched materials, keyed by course id."""
    hours: dict[str, float] = {}
    for material in materials:
        if material.estimated_hours is None:
            continue
        key = material.course_external_id
        hours[key] = max(hours.get(key, 0.0), material.estimated_hours)
    return hours


def _estimate_minutes(
    group: list[Deadline], hours_by_course: dict[str, float], study_config: StudyConfig
) -> int:
    """Seed the estimate from the course's materials, else the session ceiling.

    The scorer refines this; the value only has to be a sane starting point.
    """
    hours = [
        hours_by_course[d.course_external_id]
        for d in group
        if d.course_external_id in hours_by_course
    ]
    if not hours:
        return study_config.study.session_max_minutes
    return max(1, round(max(hours) * 60))


def _task_key(course: str, normalised_title: str, due_at: datetime) -> str:
    """Stable across runs - the calendar writer's idempotency depends on it."""
    raw = f"{course}|{normalised_title}|{due_at:%Y-%m-%d}".encode()
    return hashlib.sha1(raw).hexdigest()[:16]


def _course_label(deadline: Deadline) -> str:
    return deadline.course_name.strip() or deadline.course_external_id


def _course_key(deadline: Deadline) -> str:
    """Canonical course identity: normalised, word order removed, so that
    "CS301 Algorithms" and "Algorithms (CS301)" compare equal."""
    return " ".join(sorted(_normalise(_course_label(deadline)).split()))


def _normalise(text: str) -> str:
    """Lowercase, punctuation removed, whitespace collapsed."""
    return " ".join(_PUNCTUATION.sub(" ", text.lower()).split())
