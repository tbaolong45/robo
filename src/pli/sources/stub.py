"""Phase 1 source: hand-written deadlines from config/stub_deadlines.toml.

This exists so the whole loop - free/busy, LLM scoring, packing, calendar write -
can be built and proven before any scraping is written. Phase 2 replaces it with
the real Moodle source and Phase 3 with Teams; the planner cannot tell the
difference, which is the point.
"""

from __future__ import annotations

import tomllib
from datetime import datetime
from pathlib import Path

from pydantic import ValidationError

from pli.config import REPO_ROOT
from pli.models import Course, Deadline
from pli.sources.base import IngestResult, Source

DEFAULT_PATH = REPO_ROOT / "config" / "stub_deadlines.toml"


class StubEntryError(Exception):
    """One unusable `[[deadline]]` entry, in a sentence."""


def _label(index: int, entry: object) -> str:
    """How to name an entry in an error.

    TOML gives no line numbers, so the title is the only handle the user has on
    the entry, and the position is the fallback for one that has no title yet.
    """
    title = entry.get("title") if isinstance(entry, dict) else None
    return f"deadline {index} ({title!r})" if title else f"deadline {index}"


def _entry_to_deadline(entry: object, source: str) -> Deadline:
    """One `[[deadline]]` table as a `Deadline`, or a sentence saying why not."""
    if not isinstance(entry, dict):
        msg = "not a [[deadline]] table"
        raise StubEntryError(msg)

    course_name = str(entry.get("course") or "UNKNOWN")
    code = course_name.split()[0] if course_name.split() else course_name

    if "due" not in entry:
        msg = "no `due`"
        raise StubEntryError(msg)
    raw = entry["due"]
    try:
        due_at = raw if isinstance(raw, datetime) else datetime.fromisoformat(str(raw))
    except (TypeError, ValueError):
        msg = f"`due` {raw!r} is not an ISO-8601 datetime"
        raise StubEntryError(msg) from None
    if due_at.tzinfo is None or due_at.tzinfo.utcoffset(due_at) is None:
        # The file's own header asks for an offset, and a naive time cannot be
        # placed: the planner would silently read it as the machine's zone.
        msg = f"`due` has no timezone - add an offset, e.g. {due_at.isoformat()}+00:00"
        raise StubEntryError(msg)

    if "title" not in entry:
        msg = "no `title`"
        raise StubEntryError(msg)
    title = str(entry["title"])

    return Deadline(
        source=source,
        external_id=f"{source}:{code}:{title}:{due_at:%Y-%m-%d}",
        course_external_id=code,
        course_name=course_name,
        title=title,
        due_at=due_at,
        kind=str(entry.get("kind", "assignment")),
        url=entry.get("url"),
    )


class StubSource(Source):
    name = "stub"

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or DEFAULT_PATH

    def ingest(self, *, store: object = None, full: bool = False) -> IngestResult:
        result = IngestResult()
        if not self.path.exists():
            result.errors.append(f"stub: no deadline file at {self.path}")
            return result

        try:
            with self.path.open("rb") as fh:
                data = tomllib.load(fh)
        except tomllib.TOMLDecodeError as exc:
            result.errors.append(f"{self.name}: {self.path} is not valid TOML: {exc}")
            return result

        entries = data.get("deadline", [])
        if not isinstance(entries, list):
            result.errors.append(f"{self.name}: {self.path}: expected [[deadline]] tables")
            return result

        # One bad entry must not cost the others. This file is hand-edited and the
        # reader's rule is the same one: a single unusable entry is reported and
        # skipped, because losing every deadline in the file over one missing
        # `title` means the plan silently contains no work at all.
        seen_courses: dict[str, Course] = {}
        for index, entry in enumerate(entries, start=1):
            try:
                deadline = _entry_to_deadline(entry, self.name)
            except (StubEntryError, KeyError, TypeError, ValueError, ValidationError) as exc:
                detail = exc.args[0] if isinstance(exc, StubEntryError) else exc
                result.errors.append(f"{self.name}: {self.path}: {_label(index, entry)}: {detail}")
                continue
            if deadline.course_external_id not in seen_courses:
                seen_courses[deadline.course_external_id] = Course(
                    source=self.name,
                    external_id=deadline.course_external_id,
                    name=deadline.course_name,
                    short_name=deadline.course_external_id,
                )
            result.deadlines.append(deadline)

        result.courses = list(seen_courses.values())
        return result
